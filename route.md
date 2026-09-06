# FastBlock Client 源码阅读路线

> **链接使用说明**：本文所有代码链接都是相对路径 + `#L行号`，在 VSCode 的 Markdown 编辑器或预览（`Ctrl+Shift+V`）里点击即可直接打开对应文件并跳转到指定行。

**设计原则**：走通一段，再进入下一段。不要求一次理解整个 Client。

**阶段总览**：

| 阶段 | 主线 | 状态 |
|---|---|---|
| 第一阶段 | 上层 IO → Image → Object → PG → `send_request()` | **本文当前重点** |
| 第二阶段 | PG → Leader OSD（leader 查询） | 见文末预览 |
| 第三阶段 | 请求队列和 poller | 见文末预览 |
| 第四阶段 | Data RPC / RDMA 发送 | 见文末预览 |
| 第五阶段 | response / completion 回调链 | 见文末预览 |

---

## 当前阶段：第一阶段

### 目标

只搞懂这一条主线，**到 `send_request()` 为止就停**：

```
上层块 IO
↓
bdev_fastblock_write()
↓
libblk_client::write()          ← Image → Object 拆分
↓
calc_first_object_position()    ← Object 序号 / Object 内 offset / 首 Object 大小
↓
get_image_object_name()         ← Object 名生成
↓
fblock_client::write_object()   ← 构造 osd::write_request
↓
calc_target()                   ← Object 名 → PG id
↓
send_request()                  ← 把请求封装好，入队（下阶段入口）
```

这一阶段**不要碰**：leader 查询、三个 poller、`_leader_osd`、请求队列内部、write ring、RDMA、completion 回调链、monclient 内部、OSD 端实现。这些都是后续阶段的内容。

### 第一阶段涉及文件（只读这些）

| 文件 | 在本阶段的作用 |
|---|---|
| [bdev_fastblock.cc](src/bdev/bdev_fastblock.cc) | 只看 [bdev_fastblock_write()](src/bdev/bdev_fastblock.cc#L308) 和 [struct bdev_fastblock](src/bdev/bdev_fastblock.cc#L38) |
| [libfblock.cc](src/client/libfblock.cc) | 本阶段主战场：write 入口 + Object 拆分 |
| [libfblock.h](src/include/fastblock/client/libfblock.h) | 只看 [default_object_size](src/include/fastblock/client/libfblock.h#L28) 和 write 声明 |
| [fb_client.cc](src/client/fb_client.cc) | 只看 [calc_target()](src/client/fb_client.cc#L138) 和 [jenkins_hash()](src/client/fb_client.cc#L55) |
| [fb_client.h](src/include/fastblock/client/fb_client.h) | 只看 [write_object()](src/include/fastblock/client/fb_client.h#L1267) 和 [send_request()](src/include/fastblock/client/fb_client.h#L709) |

> proto 只需要扫一眼 [write_request](proto/osd_msg.proto#L16) 的 5 个字段，不要展开 RPC 系统。

---

### 第 1 个函数：`bdev_fastblock_write()`

- **位置**：[bdev_fastblock.cc#L308](src/bdev/bdev_fastblock.cc#L308)
- **作用**：SPDK bdev 模块收到上层（NVMe/vhost/测试）write 请求后的回调入口，FastBlock Client 的"第一站"。
- **输入**：`spdk_bdev_io *bdev_io`（含 iov、块偏移）、`offset`、`len`；bdev 上下文 [struct bdev_fastblock](src/bdev/bdev_fastblock.cc#L38) 里存着 `pool_id` / `image_name` / `block_size`
- **输出/下一步**：调用 `blk_cli->write(...)`（[L333](src/bdev/bdev_fastblock.cc#L333)），`blk_cli` 是按当前 shard 从 `global::blk_clients` 取出的一个 `libblk_client`
- **只需要搞懂**：
  1. 上层传入的 offset 是"块号"，这里为什么要乘 `blocklen`？（[L336](src/bdev/bdev_fastblock.cc#L336)：换算成字节偏移）
  2. `pool_id`、`image_name` 是从哪来的？（bdev 创建时填入 [struct bdev_fastblock](src/bdev/bdev_fastblock.cc#L38)）

---

### 第 2 个函数：`libblk_client::write()`（iov 版）

- **位置**：[libfblock.cc#L83](src/client/libfblock.cc#L83)
- **作用**：把 SPDK 的 iov 列表**拷贝拼成一个 `std::string buf`**，让后面可以按字节切 Object。
- **输入**：`pool_id / image_name / offset / length / bdev_io / cb`
- **输出/下一步**：转发给 buf 版 `write()`（[L110](src/client/libfblock.cc#L110)）
- **只需要搞懂**：为什么要把 iov 拷出来？（因为拆分 Object 时要反复按偏移切数据，用连续 string 最方便）

---

### 第 3 个函数：`libblk_client::write()`（buf 版）—— 拆分循环

- **位置**：[libfblock.cc#L177](src/client/libfblock.cc#L177)
- **作用**：**Image 切成 Object 的核心循环发生在这里**，一次 IO 可能发多次 object 写。
- **输入**：`pool_id / image_name / offset（字节）/ bdev_io / buf / cb`
- **关键计算**（只记住用途，实现见第 4、5 函数）：
  - [calc_image_object_prefix()](src/client/libfblock.cc#L332)：Object 名前缀
  - [calc_first_object_position()](src/client/libfblock.cc#L337)：首 Object 的 `(大小, 内偏移, 序号)`
  - [get_obj_num()](src/client/libfblock.cc#L169)：这次 IO 跨几个 Object
- **核心循环**（[L197-213](src/client/libfblock.cc#L197)）：
  1. `get_image_object_name(prefix, object_seq)` 生成 Object 名（[L200](src/client/libfblock.cc#L200)）
  2. 从 `buf` 切出该 Object 对应的数据片（[L202](src/client/libfblock.cc#L202)）
  3. `_client->write_object(object_name, object_offset, str, pool_id, &write_source::write_done, source)`（[L204](src/client/libfblock.cc#L204)）
  4. 首 Object 特殊大小之后恢复 `default_object_size`，`object_seq++`，直到数据发完
- **输出/下一步**：每个 Object 调一次 [write_object()](src/include/fastblock/client/fb_client.h#L1267)
- **只需要搞懂**：
  1. 首 Object 大小为什么特殊？（`object_size - (offset % object_size)`）
  2. 为什么 Object 内 offset 只有首 Object 不为 0？（后续 Object 都从 0 开始）
  3. `write_source` 现在不用深入，它只是"把 N 个 Object 的完成聚合到一次回调"的壳，第五阶段再讲。

---

### 第 4 个函数：`calc_first_object_position()`

- **位置**：[libfblock.cc#L337](src/client/libfblock.cc#L337)
- **作用**：把 Image 字节偏移换算成"首 Object 的一切信息"。
- **输入**：`offset / length / object_size`
- **输出**（三元组）：
  - `first_object_offset = offset % object_size`（首 Object **内部**的起始偏移）
  - `object_seq = offset / object_size`（首 Object 的**序号**，从 0 起）
  - `first_object_size = min(length, object_size - first_object_offset)`（首 Object 要写的字节数）
- **下一步**：返回给 `write()` 的拆分循环使用
- **只需要搞懂**：三句话——序号 = 整除，内偏移 = 取模，首段大小 = 到边界为止（不够则截断）。

---

### 第 5 个函数：`calc_image_object_prefix()` / `get_image_object_name()`

- **位置**：[libfblock.cc#L332](src/client/libfblock.cc#L332) / [libfblock.cc#L352](src/client/libfblock.cc#L352)
- **作用**：生成 Object 的唯一名字，作为后续 PG 映射（`calc_target`）的输入。
- **输入**：`pool_id` + `image_name`（前缀）；`prefix` + `seq`（完整名字）
- **输出**：`"{pool_id}__blk_data__{image_name}{seq}"`，例如 `1__blk_data__fbimage0`、`1__blk_data__fbimage1`
- **下一步**：`object_name` 传给 `write_object()`
- **只需要搞懂**：Object 名 = 固定前缀 + 序号，**`seq` 就是第 4 函数的 `object_seq`**。

---

### 第 6 个函数：`fblock_client::write_object()`

- **位置**：[fb_client.h#L1267](src/include/fastblock/client/fb_client.h#L1267)
- **作用**：把"一个 Object 的写"翻译成 RPC 请求：先算 PG，再填 `osd::write_request`，然后交给 `send_request()`。
- **输入**：`object_name / offset（Object 内偏移）/ buf（Object 数据片）/ target_pool_id / cb_fn / source`
- **过程**：
  1. `target_pg = calc_target(object_name, target_pool_id)`（[L1274](src/include/fastblock/client/fb_client.h#L1274)）
  2. 构造 [osd::write_request](proto/osd_msg.proto#L16)，填 `pool_id / pg_id / object_name / offset / data` 5 个字段（[L1276-1281](src/include/fastblock/client/fb_client.h#L1276)）
  3. `send_request(target_pool_id, target_pg, std::move(req), cb_fn, source)`（[L1282](src/include/fastblock/client/fb_client.h#L1282)）
- **下一步**：`calc_target()` → `send_request()`
- **只需要搞懂**：`write_request` 的 5 个字段分别从哪来。`cb_fn/source` 先当成"不透明回调"跳过。

---

### 第 7 个函数：`calc_target()`

- **位置**：[fb_client.cc#L138](src/client/fb_client.cc#L138)
- **作用**：**Object → PG 的哈希映射**。
- **输入**：`object_name` + `pool_id`
- **过程**：
  - `seed = jenkins_hash(object_name, len)`（[L140](src/client/fb_client.cc#L140)，[jenkins_hash 定义 L55](src/client/fb_client.cc#L55)）
  - [calc_pg_masks()](src/client/fb_client.cc#L145) 从 `_mon_cli->get_pg_num(pool_id)` 拿到该 pool 的 PG 总数
  - `return seed % _pg_num` → **PG id**
- **输出**：目标 PG id
- **下一步**：回 `write_object()` 填进 `write_request.pg_id`
- **只需要搞懂**：映射 = 对 Object 名做哈希再取模。`_mon_cli` 是 monclient 句柄，这里只借一个"PG 总数"，monclient 内部不展开。

---

### 第 8 个函数：`send_request()`

- **位置**：[fb_client.h#L709](src/include/fastblock/client/fb_client.h#L709)
- **作用**：把"一个 Object 的请求"封装成请求帧，并确保在 Client 线程上继续处理。
- **输入**：`pool_id / pg_id / req（osd::write_request）/ cb / ctx / obj_idx`
- **过程**：
  - 构造 [request_stack_type](src/include/fastblock/client/fb_client.h#L79)：请求的完整状态容器（req/resp/cb/ctx/stub…），本阶段只需知道"请求被包进这个栈帧"
  - `leader_osd_key = make_leader_key(pool_id, pg_id)`（[L611](src/include/fastblock/client/fb_client.h#L611)），把 pool+pg 压成一个 key
  - 若已在 Client 线程则直接 `do_send_request`，否则 `spdk_thread_send_msg` 切过去（[L724-728](src/include/fastblock/client/fb_client.h#L724)）
- **输出/下一步**：`do_send_request` → `handle_send_request()`，**这是第二阶段的入口，本阶段到此为止**
- **只需要搞懂**：`send_request()` 拿到的是"完整定义好去哪个 PG 的请求"，它只负责打包和投递，不负责网络。后面的事第二阶段再看。

---

### 第一阶段必懂的数据结构（最少量）

| 结构 | 位置 | 本阶段要知道的 |
|---|---|---|
| `struct bdev_fastblock` | [bdev_fastblock.cc#L38](src/bdev/bdev_fastblock.cc#L38) | 一个 bdev = 一个 image 句柄，持 `pool_id / image_name / block_size` |
| `default_object_size` | [libfblock.h#L28](src/include/fastblock/client/libfblock.h#L28) | 4 MiB，image 切 Object 的粒度 |
| Object | 无独立 struct，用 `std::string object_name` | `{pool_id}__blk_data__{image_name}{seq}` |
| `osd::write_request` | [osd_msg.proto#L16](proto/osd_msg.proto#L16) | 5 字段：`pool_id / pg_id / object_name / offset / data` |
| `request_stack_type` | [fb_client.h#L79](src/include/fastblock/client/fb_client.h#L79) | 请求的状态容器，先当黑盒 |

---

### 第一阶段最终调用链

```
Application / SPDK bdev
   │
   ▼
bdev_fastblock_write()                                [bdev_fastblock.cc#L308](src/bdev/bdev_fastblock.cc#L308)
   │  offset_blocks × blocklen → 字节 offset
   ▼
libblk_client::write() (iov 版)                       [libfblock.cc#L83](src/client/libfblock.cc#L83)
   │  拼 iov 进 std::string buf
   ▼
libblk_client::write() (buf 版)                       [libfblock.cc#L177](src/client/libfblock.cc#L177)
   │  get_obj_num / calc_first_object_position / calc_image_object_prefix
   │  while 循环逐个 Object 发写
   ▼
calc_first_object_position()                         [libfblock.cc#L337](src/client/libfblock.cc#L337)
   │  返回 (first_object_size, first_object_offset, object_seq)
   ▼
get_image_object_name()                              [libfblock.cc#L352](src/client/libfblock.cc#L352)
   │  返回 {pool_id}__blk_data__{image_name}{seq}
   ▼
fblock_client::write_object()                        [fb_client.h#L1267](src/include/fastblock/client/fb_client.h#L1267)
   │  填 osd::write_request 5 字段
   ▼
calc_target()                                        [fb_client.cc#L138](src/client/fb_client.cc#L138)
   │  jenkins_hash(object_name) % pg_num → PG id
   ▼
send_request()                                       [fb_client.h#L709](src/include/fastblock/client/fb_client.h#L709)
   │  ★ 第一阶段到此为止，下阶段从 do_send_request / handle_send_request 继续
   ▼
（第二阶段：PG → Leader OSD）
```

### 跨 Object 示例（务必亲手算一遍）

设 `object_size = 4MiB`，`offset = 4MiB - 2KiB`，`length = 4KiB`。

`calc_first_object_position(offset, length, object_size)`：

- `first_object_offset = (4MiB - 2KiB) % 4MiB = 4MiB - 2KiB`（落在 Object 尾部）
- `first_object_size = 4MiB - (4MiB - 2KiB) = 2KiB`（到边界为止）
- `object_seq = (4MiB - 2KiB) / 4MiB = 0`

拆分循环：

| 迭代 | Object 名 | 写在哪 | 写多少 |
|---|---|---|---|
| 1 | `..__blk_data__fbimage0` | 该 Object 内偏移 `4MiB-2KiB` | 2KiB（尾部） |
| 2 | `..__blk_data__fbimage1` | 该 Object 内偏移 `0` | 2KiB（头部） |

结论：**一个 4KiB 写如果恰好跨 Object 边界，会拆成两个 Object 写，每段 2KiB**。

> 注意：`offset = 3MiB, length = 4KiB` 不会跨边界（`3MiB + 4KiB < 4MiB`），那是一个 Object 内的写。

---

### 第一阶段 Checklist

我能回答：

- [ ] 上层 write 从哪里进入 FastBlock？（[bdev_fastblock_write()](src/bdev/bdev_fastblock.cc#L308)，bdev 模块回调）
- [ ] block offset 怎么变成 byte offset？（乘 `blocklen`，[L336](src/bdev/bdev_fastblock.cc#L336)）
- [ ] Image offset 怎么计算 Object 序号？（`object_seq = offset / object_size`，[calc_first_object_position](src/client/libfblock.cc#L337)）
- [ ] Object 内 offset 怎么计算？（`offset % object_size`，只有首 Object 非 0）
- [ ] 一次 IO 跨 Object 时怎么拆分？（[write() 的 while 循环](src/client/libfblock.cc#L197)：首段到边界，后续整 Object，最后截断）
- [ ] Object name 怎么生成？（`{pool_id}__blk_data__{image_name}{seq}`，[L332](src/client/libfblock.cc#L332) + [L352](src/client/libfblock.cc#L352)）
- [ ] `write_object()` 接收到了哪些信息？（object_name / object内offset / 数据片 / pool_id / 回调）
- [ ] Object 怎么通过 `calc_target()` 映射成 PG？（[jenkins_hash % pg_num](src/client/fb_client.cc#L138)）
- [ ] `send_request()` 接收到什么，准备进入下一阶段？（完整请求 + pool/pg key，封装成 `request_stack_type`，入队前夜）

以上 9 个问题都能不看源码回答，第一阶段就通过了。

---

## 后续阶段预览（只列标题和目标，本路线暂不展开）

> 这些内容是从原完整版路线保留下来的，改到这里按阶段推进。**每个阶段走通后再看下一个。**

### 第二阶段：PG → Leader OSD

**目标**：搞懂 `send_request()` 之后发生了什么——Client 怎么找到 PG 的 Leader。

覆盖（暂不展开）：`do_send_request` / `handle_send_request()`、`enqueue_leader_request()`、`get_pg_first_available_osd_info()`、`process_leader_request()`、`on_leader_acquired()`、`_leader_osd` 缓存、`leader_osd_info`、`get_stub()` 与连接建立。

**入口**：[send_request()](src/include/fastblock/client/fb_client.h#L709) → `do_send_request` → `handle_send_request()`（[fb_client.h#L869](src/include/fastblock/client/fb_client.h#L869)）。

### 第三阶段：请求队列和 poller

**目标**：搞懂 Client 的事件驱动骨架——请求从入队到发出由谁驱动。

覆盖（暂不展开）：`_requests` / `_on_flight_requests` 队列、三个 poller（`fbcli_leader` / `fbcli_request` / `fbcli_response`）、`process_request()`、`should_retry_request()` / `retry_request()`、写失败后的重试路径。

### 第四阶段：Data RPC / RDMA

**目标**：搞懂 `stub->process_write()` 到底怎么把请求发出去。

覆盖（暂不展开）：`osd::rpc_service_osd_Stub`、`connection::CallMethod()` 序列化与入队、`post_ring_write()` write ring 优化分支、`get_stub()` 的连接管理。

### 第五阶段：response / completion

**目标**：搞懂写完成之后回调怎么一路返回上层。

覆盖（暂不展开）：`on_response()`、`process_response()` 分发、`write_object_callback` → `write_source::write_done()` 聚合 → `invoke()` → `bdev_fastblock_write_callback()` → `spdk_bdev_io_complete()`、monclient 内部实现、OSD 端处理。