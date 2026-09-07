# FastBlock Client 第二阶段：PG → Leader OSD

> **前置**：第一阶段已完成（`bdev_fastblock_write → write → Image→Object → write_object → calc_target → send_request`），得到 `pg_id`。
> **本阶段终点**：拿到 Leader OSD 的 `leader_id / address / port` 并缓存。RDMA 数据发送、OSD write 处理、completion、Raft 日志全部不涉及。
> **链接说明**：相对路径 + `#L行号` 的链接在 VSCode 中可点击跳转。

---

## 0. 第二阶段调用链（以当前源码为准）

```text
send_request()                       fb_client.h:709
↓  (spdk_thread_send_msg 切到 Client 线程)
do_send_request()                    fb_client.h:820
↓
handle_send_request()                fb_client.h:869
↓ 查 _leader_osd 缓存（key = pool_id + pg_id）
   ├─ 有有效 Leader → get_stub() 拿到连接 → 请求入 _requests（第三阶段再发数据）
   │
   └─ 没有 Leader → enqueue_leader_request()      fb_client.h:625
          ↓
      get_pg_first_available_osd_info()            monclient/client.cc:1029
          ↓（找到 PG10 的一个可用成员 OSD，如 OSD1）
      process_leader_request()  (poller)           fb_client.h:1034
          ↓
      stub->process_get_leader(...)                fb_client.h:1053
          ↓（RPC 边界；底层 RDMA 传输属于第四阶段）
      on_leader_acquired()                         fb_client.h:1199
          ↓
      leader_id / leader_addr / leader_port → 写入 _leader_osd 缓存
```

---

## 1. `send_request()`

- **文件**：`src/include/fastblock/client/fb_client.h`
- **作用**：第一阶段的终点、第二阶段的起点。把"已确定去哪个 PG 的请求"打包成请求帧，投递到 Client 线程。
- **重要输入**：`pool_id / pg_id / req（osd::write_request）/ cb（回调）/ ctx（上层上下文）/ obj_idx`
- **内部关键操作**：
  1. 构造 `request_stack_type`，把 req / cb / ctx / obj_idx 全部装进去（[L713-719](src/include/fastblock/client/fb_client.h#L713)）
  2. `leader_osd_key = make_leader_key(pool_id, pg_id)`（[L718](src/include/fastblock/client/fb_client.h#L718)）
  3. 在 Client 线程则直接 `do_send_request`，否则 `spdk_thread_send_msg` 投递（[L724-728](src/include/fastblock/client/fb_client.h#L724)）
- **重要数据结构**：[request_stack_type](src/include/fastblock/client/fb_client.h#L79)
- **下一步**：`do_send_request()`

**阅读时搞懂**：
1. 请求为什么不能直接在调用者线程继续走？（Client 是单线程事件驱动，必须回 `_current_thread`）
2. `leader_osd_key` 此刻就决定好了，它后面查什么用？

---

## 2. `do_send_request()`

- **文件**：`src/include/fastblock/client/fb_client.h`
- **作用**：极薄的静态转发壳，`spdk_thread_send_msg` 的回调入口，只做一件事：调用 `handle_send_request(stack_ptr)`（[L820-823](src/include/fastblock/client/fb_client.h#L820)）。
- **下一步**：`handle_send_request()`

**阅读时搞懂**：`do_*` 系列函数在 `fb_client.h` 里都是"线程回调壳"，真正的逻辑在 `handle_*` 里——这是 SPDK 编程的常见模式。

---

## 3. `handle_send_request()` — Leader 缓存决策

- **文件**：`src/include/fastblock/client/fb_client.h`
- **作用**：第二阶段的分岔口：查 Leader 缓存，决定是"直接发"还是"先查 Leader"。
- **重要输入**：`req_stk`（含 `leader_osd_key`）
- **内部关键操作**：
  1. `_leader_osd.find(leader_osd_key)`（[L870](src/include/fastblock/client/fb_client.h#L870)），按三种情况决定 `should_acquire_leader`：
     - 缓存不存在 → 需要查 Leader（[L872-874](src/include/fastblock/client/fb_client.h#L872)）
     - `is_onflight == true`（已有人正在查）→ 不重复查，直接入队等结果（[L875-877](src/include/fastblock/client/fb_client.h#L875)）
     - `is_valid == false`（缓存失效）→ 重新查（[L878-880](src/include/fastblock/client/fb_client.h#L878)）
  2. 需要查 Leader 时：`_leader_osd.emplace(key, 空 leader_osd_info)`（[L889](src/include/fastblock/client/fb_client.h#L889)），然后 `enqueue_leader_request(pool_id, pg_id)`（[L892](src/include/fastblock/client/fb_client.h#L892)）
  3. 有 Leader 时：`req_stk->stub = get_stub(leader_id, addr, port)`（[L922](src/include/fastblock/client/fb_client.h#L922)）
  4. **无论哪种情况，请求都入 `_requests` 队列**（[L925](src/include/fastblock/client/fb_client.h#L925)），由第三阶段的 poller 真正发出
  5. 边界：pool 不存在时（`ERR_NOT_FOUND_POOL`）直接调回调报错并释放栈帧（[L892-919](src/include/fastblock/client/fb_client.h#L892)）
- **下一步**：`enqueue_leader_request()`（无 Leader 分支）
- **阅读时搞懂**：`is_onflight` 是什么含义？（= "Leader 查询正在进行"，防止同一个 PG 并发发起多个查询）

---

## 4. 重点：请求帧与 Leader Key

### `request_stack_type` 为什么存在

Client 是异步的：请求发出去后，函数早已返回，等 RPC 回来时**必须能找到这个请求当初的所有信息**。`request_stack_type`（[L79](src/include/fastblock/client/fb_client.h#L79)）就是"请求的随身行李"，跟着请求从入队走到完成。

本阶段只需要知道这些字段：

| 字段 | 本阶段作用 |
|---|---|
| `req` | 要发的 `osd::write_request`（variant 持有） |
| `resp_cb` / `ctx` / `obj_index` | 完成后回调谁、带上什么上下文 |
| `leader_osd_key` | 这个请求的 PG 身份，查缓存用 |
| `this_client` | 回指 `fblock_client` |
| `stub` | 第二阶段末尾填上"发往哪个 OSD"的连接桩（有 Leader 时） |

### 为什么 `pool_id + pg_id` 要组成一个 key

缓存和请求都按 PG 定位，但 map 的 key 只能是一个数。`make_leader_key()`（[L611](src/include/fastblock/client/fb_client.h#L611)）把 `pool_id` 放高 32 位、`pg_id` 放低 32 位，压成一个 `uint64_t`；`from_leader_key()`（[L620](src/include/fastblock/client/fb_client.h#L620)）是逆运算。**PG 的身份 = (pool_id, pg_id)，两者缺一不可**（不同 pool 可以有同号 PG）。

---

## 5. 重点：Leader Cache（`_leader_osd` / `leader_osd_info`）

```text
pool_id + pg_id
↓ make_leader_key()
leader_osd_key
↓
_leader_osd[leader_osd_key]  →  leader_osd_info{ leader_id, addr, port, is_valid, is_onflight, epoch }
```

[leader_osd_info](src/include/fastblock/client/fb_client.h#L116) 是本阶段的核心缓存值。

**为什么缓存**：每个 PG 每次 IO 都去查 Leader 太贵（多一次 RPC 往返）。Leader 短时间内不会变，缓存命中就直接用。

**key**：`make_leader_key(pool_id, pg_id)`。

**value**：`leader_id / addr / port` + 两个标志：
- `is_valid`：缓存是否可信（Leader 是否仍在线）
- `is_onflight`：是否正在查 Leader（防止重复查询）

**第一次访问 PG**：缓存不存在 → `handle_send_request` 里 `emplace` 一个空的 `leader_osd_info`（`leader_id = -1`，`is_onflight = true`），然后走 `enqueue_leader_request()`。

**已有 Leader 时**：`get_stub(leader_id, addr, port)` 直接拿连接，请求入队，第三阶段直接发。

**失效处理**（本阶段只提概念）：`on_leader_acquired` 会校验有效性（见第 9 节）；后续阶段还有 `retry_request()` 会把 `is_valid` 置 false 重新查。

---

## 6. 第一次不知道 Leader：`enqueue_leader_request()`

- **文件**：`src/include/fastblock/client/fb_client.h`
- **作用**：为"查 Leader"这个动作准备状态：找一个问路的 OSD，构造查询请求。
- **内部关键操作**：
  1. `_mon_cli->get_pg_first_available_osd_info(pool_id, pg_id)`（[L626](src/include/fastblock/client/fb_client.h#L626)）← **进入 monclient**，见第 10 节
  2. 找不到可用 OSD：pool 不存在返回 `ERR_NOT_FOUND_POOL`，否则 `EAGAIN`（[L628-633](src/include/fastblock/client/fb_client.h#L628)）
  3. 构造 `leader_request_stack_type`（[L67](src/include/fastblock/client/fb_client.h#L67)）：`leader_req` 填 `pool_id / pg_id`，`osd` 指向问路目标，分配唯一 `leader_request_id`（[L635-643](src/include/fastblock/client/fb_client.h#L635)）
  4. 存入 `_leader_requests` 等待 poller 处理（[L643](src/include/fastblock/client/fb_client.h#L643)）
- **重要数据结构**：[leader_request_stack_type](src/include/fastblock/client/fb_client.h#L67)、`pg_info_type`、`osd_info_t`
- **下一步**：`process_leader_request()`（poller 驱动）
- **阅读时搞懂**：问路的 OSD 是"PG 成员里随便一个可用的"，**不是 Leader**（还没人知道 Leader 是谁）。

---

## 7. `process_leader_request()` — 发出查询

- **文件**：`src/include/fastblock/client/fb_client.h`
- **作用**：poller 周期性扫 `_leader_requests`，把 get_leader 请求真正发出去。
- **内部关键操作**：
  1. 遍历 `_leader_requests`（[L1039-1058](src/include/fastblock/client/fb_client.h#L1039)）
  2. `stack_ptr->stub = get_stub(stack_ptr->osd)`（[L1043](src/include/fastblock/client/fb_client.h#L1043)）：按 OSD 的 `address + sharded_ports[shard_id].port` 拿/建连接（连接细节属第四阶段）；拿不到说明还在建连，下一轮再来
  3. `stub->process_get_leader(ctrlr, leader_req, leader_resp, done)`（[L1053](src/include/fastblock/client/fb_client.h#L1053)）← **Leader 查询 RPC**
  4. 转入 `_on_flight_leader_requests`（[L1055](src/include/fastblock/client/fb_client.h#L1055)），等待响应
- **下一步**：远端 OSD 返回 → `on_leader_acquired()`
- **阅读时搞懂**：这里**只到 RPC 调用边界**。`process_get_leader` 底层的 RDMA 序列化发送、OSD 端 Raft 如何回答 Leader，分别是第四阶段和后续 OSD/Raft 模块的事。

---

## 8. Leader 查询 RPC（proto，只看这两个消息）

[proto/osd_msg.proto](proto/osd_msg.proto)：

```text
pg_leader_request      (L86)
├── pool_id
└── pg_id

pg_leader_response     (L92)
├── state           ← 查询是否成功
├── leader_id       ← Leader 的 OSD id
├── leader_addr     ← Leader 的 IP
└── leader_port     ← Leader 的端口
```

服务方法：`rpc process_get_leader(pg_leader_request) returns (pg_leader_response)`（[L176](proto/osd_msg.proto#L176)）。

---

## 9. `on_leader_acquired()` — 收尾

- **文件**：`src/include/fastblock/client/fb_client.h`
- **作用**：get_leader 响应的回调，第二阶段在这里完成：**填充 Leader 缓存**。
- **内部关键操作**：
  1. 按 `leader_request_id` 找回栈帧，由 `leader_req` 的 `pool_id/pg_id` 重建 `leader_key`，定位 `_leader_osd` 里的缓存项（[L1200-1217](src/include/fastblock/client/fb_client.h#L1200)）
  2. `osd_info->is_onflight = false`（查询结束）（[L1219](src/include/fastblock/client/fb_client.h#L1219)）
  3. 传输失败（`ctrlr->Failed()`）：标记 `is_valid = false`，清理后结束，下次请求重新查（[L1220-1230](src/include/fastblock/client/fb_client.h#L1220)）
  4. **成功时取出**（[L1231-1235](src/include/fastblock/client/fb_client.h#L1231)）：
     ```cpp
     osd_info->leader_id = resp->leader_id();       // 保存到缓存
     osd_info->addr      = resp->leader_addr();
     osd_info->port      = resp->leader_port();
     osd_info->epoch     = now;                     // 记录获取时间
     ```
  5. 校验有效性：`update_leader_state(osd_info)`（[L1240](src/include/fastblock/client/fb_client.h#L1240)，[定义 L648](src/include/fastblock/client/fb_client.h#L648)）：
     - `get_osd_info(leader_id)` 查 OSD Map，**确认该 Leader 当前 `isup && isin`** → `is_valid = true`
     - 兜底：如果查询时间比本地最后一次 cluster map 还新，也先当有效（[L659-663](src/include/fastblock/client/fb_client.h#L659)）
     - 否则 `is_valid = false`
  6. **无效时**：不放弃，用同一个栈帧**再发一次** `process_get_leader`（[L1248-1254](src/include/fastblock/client/fb_client.h#L1248)），直到拿到有效 Leader 或 OSD 端明确答复
- **阅读时搞懂**：`update_leader_state` 的作用一句话——"用本地 OSD Map 再确认这个 Leader 现在是不是还活着"。

---

## 10. monclient 接口（本阶段只用到两个）

### `get_pg_first_available_osd_info(pool_id, pg_id)` — [monclient/client.cc:1029](src/monclient/client.cc#L1029)

- **输入**：`pool_id / pg_id`
- **过程**：从 `_pg_map.pool_pg_map[pool_id][pg_id]->osds`（PG 成员 OSD id 列表，如 `[1,3,7]`）依次取 OSD id，在 `_osd_map.data` 里找**第一个 `isup && isin`** 的
- **输出**：`osd_info_t*`（一个可用的成员 OSD），找不到返回 `nullptr`
- **两个标志的含义**：
  - `isup`：OSD 进程在线（心跳正常）
  - `isin`：OSD 在集群成员名单内（未被踢出）
- 数据来源（一句话）：`_pg_map` / `_osd_map` 是 monclient 从 Monitor 周期性拉取的集群快照，本阶段不深入拉取机制。

### `get_osd_info(node_id)` — [monclient/client.cc:1068](src/monclient/client.cc#L1068)

- **输入**：`osd_id`
- **输出**：`osd_info_t*`：`node_id / address / sharded_ports / isup / isin`；查不到返回 `nullptr`

---

## 11. 本阶段数据结构（只列需要的）

| 结构 | 位置 | 本阶段要点 |
|---|---|---|
| `leader_osd_info` | [fb_client.h#L116](src/include/fastblock/client/fb_client.h#L116) | PG Leader 缓存值：`leader_id / addr / port / epoch / is_valid / is_onflight` |
| `request_stack_type` | [fb_client.h#L79](src/include/fastblock/client/fb_client.h#L79) | 数据请求帧，本阶段只用 `req / resp_cb / ctx / leader_osd_key / stub` |
| `leader_request_stack_type` | [fb_client.h#L67](src/include/fastblock/client/fb_client.h#L67) | 查 Leader 请求帧：`leader_req / leader_resp / osd(问路目标) / leader_request_id` |
| `pg_info_type` | [utils/utils.h#L121](src/include/fastblock/utils/utils.h#L121) | PG 与成员 OSD 的关系：`pg_id / version / osds[]` |
| `osd_info_t` | [utils/utils.h#L111](src/include/fastblock/utils/utils.h#L111) | 一个 OSD 的信息：`node_id / address / sharded_ports / isup / isin` |
| `pg_leader_request / response` | [osd_msg.proto#L86](proto/osd_msg.proto#L86) / [L92](proto/osd_msg.proto#L92) | Leader 查询的请求/响应消息 |

---

## 12. 完整例子（贯穿本阶段）

```text
前提：pool_id=1, object_name="object_100", calc_target 得到 pg_id=10
PG10 成员：OSD1, OSD3, OSD7（OSD3 是 Leader，但 Client 不知道）
```

| 步骤 | 实际过程 | 源码位置 |
|---|---|---|
| 1 | `send_request(1, 10, write_request{object_100}, cb, ctx)` | [fb_client.h#L709](src/include/fastblock/client/fb_client.h#L709) |
| 2 | `leader_osd_key = make_leader_key(1, 10)` → 例如 `(1<<32)\|10` | [fb_client.h#L718](src/include/fastblock/client/fb_client.h#L718) |
| 3 | `handle_send_request`：查 `_leader_osd[key]` → **没有缓存** → `emplace` 空缓存（`leader_id=-1, is_onflight=true`） | [fb_client.h#L870-889](src/include/fastblock/client/fb_client.h#L870) |
| 4 | `enqueue_leader_request(1, 10)`：`get_pg_first_available_osd_info(1,10)` → `pg_info_type.osds=[1,3,7]`，`osd_map` 中第一个 `isup&&isin` → **OSD1** | [fb_client.h#L625](src/include/fastblock/client/fb_client.h#L625) / [monclient/client.cc#L1029](src/monclient/client.cc#L1029) |
| 5 | `process_leader_request`（poller）：`get_stub(OSD1)` 拿连接 → `stub->process_get_leader({pool_id=1, pg_id=10}, ...)` | [fb_client.h#L1043-1053](src/include/fastblock/client/fb_client.h#L1043) |
| 6 | **OSD1 回答**：`leader_id=3, leader_addr="10.0.0.3", leader_port=9999`（OSD1 的 Raft 层知道 PG10 的 Leader 是 OSD3） | RPC 响应 |
| 7 | `on_leader_acquired`：写入缓存 `_leader_osd[key] = {leader_id:3, addr:"10.0.0.3", port:9999}`，`is_onflight=false` | [fb_client.h#L1231-1235](src/include/fastblock/client/fb_client.h#L1231) |
| 8 | `update_leader_state`：`get_osd_info(3)` 确认 OSD3 `isup&&isin` → `is_valid=true` | [fb_client.h#L648](src/include/fastblock/client/fb_client.h#L648) |

**第二阶段结束**：Client 已知道 PG10 的 Leader 是 `OSD3 @ 10.0.0.3:9999`。第三阶段起，`process_request()` 会用这个地址连接 OSD3，把队列里的 `write_request` 发过去。

---

## 13. 第二阶段总结图（一屏）

```text
第一阶段结束：
Object → calc_target → PG10
↓
send_request()
↓
request_stack_type + leader_osd_key(pool1|pg10)
↓
handle_send_request → 查 leader cache (_leader_osd)
   │
   ├─ 有有效 Leader
   │     ↓
   │  get_stub(leader_id, addr, port)
   │     ↓
   │  请求入 _requests → 第三阶段直接发数据
   │
   └─ 没有 Leader
         ↓
     enqueue_leader_request(1, 10)
         ↓
     PG Map: PG10 成员 = [OSD1, OSD3, OSD7]
         ↓
     找第一个 isup && isin 的 OSD → OSD1
         ↓
     process_leader_request（poller）
         ↓
     OSD1.process_get_leader({pool_id=1, pg_id=10})
         ↓
     OSD1 返回: leader_id=3 / leader_addr / leader_port
         ↓
     on_leader_acquired
         ↓
     update_leader_state 校验 OSD3 有效
         ↓
     写入缓存: _leader_osd[(1,10)] = {OSD3, addr, port}
         ↓
     第二阶段结束（已知道真正目标 OSD）
```

---

## 14. 第二阶段 Checklist

- [ ] `send_request()` 后请求信息保存在哪里？（`request_stack_type`，入 `_requests` 队列）
- [ ] `pool_id + pg_id` 为什么可以定位 Leader cache？（`make_leader_key` 压成 uint64 做 map key）
- [ ] `_leader_osd` 是什么？（PG → Leader 信息的缓存表，value 是 `leader_osd_info`）
- [ ] Client 第一次不知道 PG Leader 时怎么办？（`enqueue_leader_request` → 找可用成员 OSD → get_leader RPC）
- [ ] PG 的成员 OSD 从哪里查？（monclient `_pg_map.pool_pg_map[pool][pg]->osds`）
- [ ] 第一个可用 OSD 和 PG Leader 有什么区别？（前者只是"问路的对象"，后者才是真正的写入目标）
- [ ] get_leader 请求发给谁？（PG 的第一个 `isup && isin` 成员 OSD）
- [ ] `pg_leader_response` 返回什么？（`state / leader_id / leader_addr / leader_port`）
- [ ] `on_leader_acquired()` 做了什么？（取出响应、写入 `_leader_osd` 缓存、校验有效性，无效则重发）
- [ ] 第二阶段结束以后 Client 已经知道哪些信息？（PG10 → Leader OSD3 的 id、IP、端口）

下一阶段入口：`process_request()`（[fb_client.h#L1063](src/include/fastblock/client/fb_client.h#L1063)）——请求队列和 poller 把缓存的 Leader 地址用起来，真正发数据。**完整文档：[route3.md](route3.md)**。