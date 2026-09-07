# FastBlock Client 2.4 + 2.5：Data RPC / RDMA 与 Response / Completion

> **前置**：2.1-2.3 已完成，请求已到 `stub->process_write(...)` 这一行，Leader = OSD3@10.0.0.3:9000。
> **本阶段范围**：把 Client 剩余部分一次走完——请求如何经 RDMA 到达 OSD、响应如何回到上层。OSD 内部处理、Raft、LocalStore 一律不展开。
> **链接说明**：相对路径 + `#L行号` 的链接在 VSCode 中可点击跳转。

---

# 第一部分：2.4 Data RPC / RDMA

## 2.4 学习目标

```text
stub->process_write()
↓
protobuf RPC Stub
↓
RpcChannel
↓
connection::CallMethod()
↓
请求序列化
↓
构造 RPC metadata
↓
进入 RDMA 发送路径
↓
post send（ibv_post_send）
↓
RNIC → 网络 → OSD
```

## 2.4-1. `rpc_service_osd_Stub` 是什么

- **位置**：[osd_msg.pb.h#L5579](src/include/fastblock/rpc/osd_msg.pb.h#L5579)（protobuf 生成代码）
- **是什么**：远端 `rpc_service_osd` 服务在 Client 侧的**本地代理**。每个方法一个生成函数：[process_write](src/include/fastblock/rpc/osd_msg.pb.h#L5593)、`process_get_leader` 等。
- **内部**：只保存一个 `RpcChannel* channel_`（[L5639](src/include/fastblock/rpc/osd_msg.pb.h#L5639)）。调 `stub->process_write(...)` 时，生成代码做的唯一一件事就是：`channel_->CallMethod(method, controller, request, response, done)`——**把调用转交给 channel**。

## 2.4-2. 为什么 `stub->process_write(...)` 看起来像本地调用

这正是 protobuf RPC 的设计目标（远程调用透明化）：

```text
调用方视角:  stub->process_write(req, reply, done)     ← 像普通函数
实际路径:    stub ──转发──▶ channel_->CallMethod(...)   ← RpcChannel 接手
           channel 把 request 序列化后投到网卡
           响应回来时反序列化进 reply，触发 done
```

调用方不需要知道：目标地址、序列化格式、网络细节、如何匹配响应。

## 2.4-3. Stub、RpcChannel、RDMA connection 三者关系

```text
rpc_service_osd_Stub   ← 远端服务的代理（按服务生成）
        │ 持有
        ▼
RpcChannel             ← 抽象的"传输通道"接口（protobuf 定义）
        │ 实现
        ▼
msg::rdma::client::connection   ← 一条真实 RDMA 连接（也是本类）
```

- [connection 的类声明](src/include/fastblock/msg/rdma/client.h#L152)：`class connection : public std::enable_shared_from_this<connection>, public google::protobuf::RpcChannel` —— **connection 本身就是 RpcChannel**。
- 创建关系：Client 建连接后 `_stubs[conn_id] = new rpc_service_osd_Stub(conn.get())`（[fb_client.h#L605](src/include/fastblock/client/fb_client.h#L605)），stub 绑定这条连接。
- 三层对应一句话：**stub 决定"调哪个远端方法"，channel 决定"从哪条连接走"**。

## 2.4-4. `connection::CallMethod()` 在哪里、收到什么

- **位置**：[client.h#L510](src/include/fastblock/msg/rdma/client.h#L510)
- **收到**：`MethodDescriptor*`（方法描述）、`RpcController* ctrlr`、`request`（write_request）、`response`（write_reply 空壳）、`Closure* c`（完成回调）
- **做什么**（[L510-586](src/include/fastblock/msg/rdma/client.h#L510)）：
  1. 检查连接状态（非 running 则 `ctrlr` 置失败、直接 `c->Run()`，[L516-520](src/include/fastblock/msg/rdma/client.h#L516)）
  2. 分配唯一 `req_key`（`_unresponsed_request_key_gen++`，[L542](src/include/fastblock/msg/rdma/client.h#L542)）——**响应靠它找到请求**
  3. `make_request_meta(service_name, method_name, request->ByteSizeLong())`（[L545](src/include/fastblock/msg/rdma/client.h#L545)）
  4. 构造 `rpc_request`（[L156-169](src/include/fastblock/msg/rdma/client.h#L156)）：req_key / method / ctrlr / request / response / closure / meta 全装进去
  5. 若不在 Client 线程，`spdk_thread_send_msg` 投过去（[L574-582](src/include/fastblock/msg/rdma/client.h#L574)），否则直接 `enqueue_request()`（[L584](src/include/fastblock/msg/rdma/client.h#L584)）

**RPC metadata 是什么**：[types.h#L82](src/include/fastblock/msg/rdma/types.h#L82) 的 `request_meta`：

```text
request_meta
├── service_name（"osd.rpc_service_osd"）
├── method_name（"process_write"）
└── data_size（write_request 序列化后的字节数）
```

OSD 端靠它把请求分发给正确的服务方法（`CallMethod` 分发在 [server.h#L649](src/include/fastblock/msg/rdma/server.h#L649)）。

## 2.4-5. 请求序列化与 RDMA 发送路径

`CallMethod` 只是入队。真正的发送由**每条连接的专属 poller**（`"rpc_cli_conn"`，注册于 [L495-503](src/include/fastblock/msg/rdma/client.h#L495)）驱动：

```text
handle_poll()                        client.h:449（连接 poller）
↓
process_rpc_request()                client.h:588（从 _onflight_requests 取队头）
↓
process_request_once()               client.h:330
↓
serialize_data(meta, request)        client.h:355 → transport_data.h:283
│                                    └─ request->SerializeToArray()  ← protobuf 序列化点 (transport_data.h:307)
↓
send_metadata_request()              client.h:304 / 370
↓
make_send_request()                  transport_data.h:425
│                                    └─ 构造 IBV_WR_SEND 的 WR 链 + SGE
↓
send_request()                       client.h:272
↓
_sock->send(wr)                      socket.h:370
↓
::ibv_post_send(_id->qp, wr, &bad)   socket.h:372  ← ★ 真正提交给 RDMA 网卡
↓
_unresponsed_requests[req_key] = req client.h:386（记录在途，等响应）
```

关键点：

- **序列化**：`SerializeToArray` 直接写进**已注册给网卡的内存**（`transport_data` 从 memory pool 拿的 chunk，每块有 MR + SGE），避免额外拷贝。
- **一条连接多个 WR**：大请求拆成多个 SGE/WR 链（`wr.next` 串联，[transport_data.h#L444-449](src/include/fastblock/msg/rdma/transport_data.h#L444)）。
- **`_unresponsed_requests`**：以 `req_key` 为 key 的在途表，响应回来时靠它找回 `rpc_request`。

## 2.4-6. QP / CQ / WR / SGE / MR 在本链路中各自的作用

| 缩写 | 全称 | 在本链路中的作用 |
|---|---|---|
| QP | Queue Pair | 网卡上的发送/接收队列；`ibv_post_send` 把 WR 投进 QP 的发送队列 |
| WR | Work Request（`ibv_send_wr`） | 一次发送动作的描述（opcode、SGE、wr_id、send_flags） |
| SGE | Scatter-Gather Element（`ibv_sge`） | 一段内存的地址/长度/lkey，WR 通过它指出数据在哪 |
| MR | Memory Region（`ibv_mr`） | 注册给网卡的内存区（`ibv_reg_mr`）；SGE 引用的 lkey 来自 MR |
| CQ | Completion Queue | 网卡完成 WR 后产生 CQE；Client 的 `handle_cqe()`（[L799](src/include/fastblock/msg/rdma/client.h#L799)）轮询它 |

一句话链路：**内存先注册成 MR → 数据装进 SGE → SGE 挂到 WR → WR post 到 QP → 网卡发走 → 完成时 CQ 产生 CQE → handle_cqe 处理**。

## 2.4-7. 普通 RPC 与 Write Ring（优化路径）

> 当前默认走 ring（`should_use_write_ring()` 默认 true，除非设 `FASTBLOCK_DISABLE_RING_WRITE`，[fb_client.h#L200-203](src/include/fastblock/client/fb_client.h#L200)）。先理解普通路径，ring 只是它的优化变体。

### 普通路径（RPC SEND）

```text
process_request() 的 write 分支（ring 条件不满足时）
↓
stub->process_write(ctrlr, req, reply, done)     fb_client.h:1160
↓
connection::CallMethod() → RDMA SEND（见 2.4-5）
```

整个 `write_request`（含 data）作为一次 RPC 消息发过去。

### Write Ring（RDMA WRITE 数据 + commit RPC）

分两步，**数据和控制分离**：

```text
第一步（数据）：
post_ring_write()                     fb_client.h:496
↓
write_request->SerializeToArray()      fb_client.h:524（序列化进 DMA 内存）
↓
ibv_reg_mr()                           fb_client.h:530（注册成 MR）
↓
构造 IBV_WR_RDMA_WRITE 的 WR          fb_client.h:557
│  remote_addr / rkey = OSD 预留 ring slot 的地址
↓
post_external_send_wr()                fb_client.h:567
↓
RDMA WRITE 直接把数据写进 OSD 的 ring slot（不经过 OSD 的 RPC recv 路径）

第二步（控制）：
post_external_send_wr 完成回调里        fb_client.h:569-575
↓
stub->process_commit_ring_write(
    commit_req{queue_id, slot_index, serialized_size})   fb_client.h:571
↓
commit RPC 告诉 OSD："数据已在你的 ring slot N，处理吧"
↓
OSD 用 slot 里的数据落盘，通过 commit 的 reply 返回结果
```

**前置**：`acquire_write_ring_async()`（[L457](src/include/fastblock/client/fb_client.h#L457)）→ `process_acquire_write_ring`（[L472](src/include/fastblock/client/fb_client.h#L472)），OSD 返回 `queue_id / lease_us / slots[]{remote_addr, remote_key, slot_size}`（[on_write_ring_ready L411](src/include/fastblock/client/fb_client.h#L411)）。slot 是 OSD 侧**预注册的接收缓冲区**（默认 16 个 × 256KiB，[L196-197](src/include/fastblock/client/fb_client.h#L196)）。

**为什么这样设计**：

- 大 payload（4KB 数据）走 RDMA WRITE 直达 OSD 预注册内存，绕开 RPC 的收发解析路径，OSD 少一次数据拷贝
- 控制消息（commit）很小，用普通 RPC，保证可靠性/有序性/ack
- **数据通道（RDMA WRITE）+ 控制通道（commit RPC）分离**

`commit_ring_write` 即"提交 ring 写入"：告诉 OSD 哪个 slot 已就绪、数据多长。

## 2.4 最终调用链（基于真实源码）

```text
process_request()                         fb_client.h:1063（write 分支 L1158-1163）
↓
stub->process_write(ctrlr, req, reply, done)    osd_msg.pb.h:5593
↓
channel_->CallMethod(...)                 （stub 生成代码内部）
↓
connection::CallMethod()                  msg/rdma/client.h:510
↓
make_request_meta + rpc_request 入队      client.h:545 / 557 / 584
↓
连接 poller：handle_poll()                client.h:449
↓
process_request_once()                    client.h:330
↓
request->SerializeToArray()               transport_data.h:307  ← protobuf 序列化
↓
make_send_request() → IBV_WR_SEND + SGE   transport_data.h:425
↓
::ibv_post_send(qp, wr)                   socket.h:372  ← ★ 提交 RDMA 网卡
↓
RNIC → 网络 → OSD
```

---

# 第二部分：2.5 Response / Completion

## 2.5 主线

```text
OSD response
↓
RDMA 收到数据（CQ → handle_cqe）
↓
按 req_key 找到 rpc_request
↓
ParseFromArray 反序列化进 response
↓
closure->Run()
↓
on_response() → is_responsed = true
↓
process_response()（fbcli_response poller）
↓
成功 → write_object callback ／ 失败 → 重试
↓
write_source::write_done()（obj_num--）
↓
全部 Object 完成 → invoke()
↓
bdev_fastblock_write_callback() → spdk_bdev_io_complete()
↓
上层 IO 完成
```

## 2.5-1. 响应在 RPC 层如何回来

连接 poller 的 `handle_poll()` → `handle_cqe()`（[client.h#L799](src/include/fastblock/msg/rdma/client.h#L799)）：

1. CQ 上出现 `IBV_WC_RECV` 完成（[L826](src/include/fastblock/msg/rdma/client.h#L826)），按 wr_id 找到 recv 上下文
2. `req_key = read_correlation_index(recv_ctx)`（[L835](src/include/fastblock/msg/rdma/client.h#L835)）——OSD 回复时带上了请求号
3. 在 `_unresponsed_requests` 里按 req_key 找回 `rpc_request`（[L836](src/include/fastblock/msg/rdma/client.h#L836)）；超时检查（[L843](src/include/fastblock/msg/rdma/client.h#L843)）
4. 读回复状态 `read_reply_meta`（[L856](src/include/fastblock/msg/rdma/client.h#L856)），按状态分发：
   - `success`：**反序列化 response** —— 小响应内联直接 `response->ParseFromArray`（[L895-897](src/include/fastblock/msg/rdma/client.h#L895)）；大响应先 RDMA READ 取回正文，再 `unserialize_data → ParseFromArray`（[L775](src/include/fastblock/msg/rdma/client.h#L775) / [transport_data.h#L333](src/include/fastblock/msg/rdma/transport_data.h#L333)）
   - `no_content` / `terminating`：同样走到下面
5. **`closure->Run()`**（[L786](src/include/fastblock/msg/rdma/client.h#L786) 等）——触发 Client 层的完成回调

**closure 是什么**：`process_request` 里构造的 `google::protobuf::NewCallback(this, &fblock_client::on_response, stack_ptr)`（[fb_client.h#L1162](src/include/fastblock/client/fb_client.h#L1162)）——RPC 层"活干完了"，通过它叫醒 Client。

## 2.5-2. 重点：`on_response()`（[fb_client.h#L1261](src/include/fastblock/client/fb_client.h#L1261)）

```cpp
void on_response(request_stack_type* stack_ptr) noexcept {
    stack_ptr->is_responsed = true;   // 就这一行
}
```

- **什么时候被调用**：RPC 层 `closure->Run()` 时（可能在任何时刻、任意一次 poller 迭代里）
- **谁调用**：`connection::CallMethod` 传入的 closure，由 RPC 层在响应解析完成后触发
- **为什么只标记、不直接完成 IO**：Client 是**单线程事件驱动**。如果在这里直接做回调分发，回调里可能再发起新 RPC（重试/新请求），形成重入；统一改成"打标记 + 由 `fbcli_response` poller 在下一轮统一消费"，保证**所有状态变更都发生在 poller 上下文中**，串行、无锁、可重入。这也是"标记-轮询"模式的典型应用。

## 2.5-3. 重点：`process_response()`（[fb_client.h#L932](src/include/fastblock/client/fb_client.h#L932)）

按执行顺序：

1. **从哪个队列检查**：`_on_flight_requests.front()`（[L937](src/include/fastblock/client/fb_client.h#L937)），队列空则 IDLE
2. **怎么知道已返回**：`head->is_responsed == true`（[L939](src/include/fastblock/client/fb_client.h#L939)）——`on_response()` 打的标记
3. **怎么判断 RPC 是否失败**：`state = stack_ptr->ctrlr->Failed() ? -ENOLINK : resp->state()`（[L950](src/include/fastblock/client/fb_client.h#L950)）——**传输层失败（ctrlr 报错）统一当成 -ENOLINK**；传输成功才看 OSD 返回的业务 state
4. **读取 OSD 返回的 state**：`resp->state()`，write 分支里是 `osd::write_reply.state`（proto [osd_msg.proto#L25](proto/osd_msg.proto#L25)）
5. **成功时调哪个 callback**：取出 `std::get<write_object_callback>(resp_cb)`，`cb(stack_ptr->ctx, state)`（[L976-977](src/include/fastblock/client/fb_client.h#L976)）——这个 cb 就是 `write_source::write_done`
6. **失败时什么时候重试**：[should_retry_request()](src/include/fastblock/client/fb_client.h#L205) 判定，可重试的错误集：
   ```text
   -ENOLINK（连接断）  -ENOENT  -EINVAL
   RAFT_ERR_NOT_LEADER（leader 变了！）
   RAFT_ERR_NOT_FOUND_PG  RAFT_ERR_PG_SHUTDOWN  RAFT_ERR_PG_INITIALIZING
   RAFT_ERR_NO_CONNECTED  OSD_DOWN  OSD_STARTING
   ```
   命中则 `retry_request(stack_ptr, state)`（[L1024-1026](src/include/fastblock/client/fb_client.h#L1024)）
7. **什么错误导致重新查 Leader**：`RAFT_ERR_NOT_LEADER` 等说明请求打到了旧 Leader 上。[retry_request()](src/include/fastblock/client/fb_client.h#L326) 会把 `_leader_osd` 里该项 `is_valid = false`（[L328-331](src/include/fastblock/client/fb_client.h#L328)）、作废连接（[L332](src/include/fastblock/client/fb_client.h#L332)），请求重新放回 `_requests` 队首（[L346](src/include/fastblock/client/fb_client.h#L346)）——**下一轮 process_request 会发现 Leader 无效，重新走 2.2 的查 Leader 流程**
8. **什么时候从 `_on_flight_requests` 删除**：处理完这个队头后 `pop_front()`（[L1023](src/include/fastblock/client/fb_client.h#L1023)）；重试时也是先移出再放回 `_requests`

```text
错误处理分支：
-ENOLINK / RAFT_ERR_NOT_LEADER / OSD_DOWN ... → retry_request()
    → 失效 Leader 缓存 → 请求回 _requests 队首 → 重新查 Leader → 重新发
其他错误 → 直接 cb(ctx, state)，由上层（write_source）决定结果
```

## 2.5-4. 重点：callback 返回链（一次成功的 write）

```text
process_response() 的 write 分支              fb_client.h:948-978
↓  cb = write_object_callback（就是 write_source::write_done）
write_source::write_done(src, state)         libfblock.cc:151
↓  obj_num--
↓  obj_num == 0 ?
├─ 否 → 继续等（还有 Object 没完成）
└─ 是 → source->invoke()                     libfblock.cc:162
        ↓
write_source::invoke()                       libfblock.cc:138
        ↓  最终回调 = bdev_fastblock_write_callback
bdev_fastblock_write_callback(bdev_io, res)  bdev_fastblock.cc:290
        ↓
spdk_bdev_io_complete(bdev_io, SUCCESS/FAILED)   bdev_fastblock.cc:294
        ↓
上层 IO 完成
```

### 为什么有 `write_source`

一个上层 IO 会拆成 N 个 Object 写（第一阶段见过 while 循环），**不能第一个 Object 完成就通知上层**。`write_source` 就是"N 个完成的聚合器"：

- 构造时记下 `obj_num = N` 和原始线程（[libfblock.cc#L122-127](src/client/libfblock.cc#L122)）
- 每个 Object 完成回调一次 `write_done`，`obj_num--`（[L157](src/client/libfblock.cc#L157)）
- **归零才通知上层一次**（[L159-165](src/client/libfblock.cc#L159)）

### 跨 2 个 Object 的例子

```text
Object A 完成 → write_done → obj_num: 2 → 1（不通知，继续等）
Object B 完成 → write_done → obj_num: 1 → 0（全部完成！）
    ↓
invoke() → bdev_fastblock_write_callback → spdk_bdev_io_complete()
```

任何一个 Object 失败，`result` 记下失败状态，全部完成时一起上报（[L151-155](src/client/libfblock.cc#L151)）。

## 2.5-5. 线程切换（`invoke()` 里的 spdk_thread_send_msg）

[invoke()](src/client/libfblock.cc#L138)：

```cpp
#ifdef DEBUG
    spdk_thread_send_msg(thread, &thread_run, this);   // 切回原始线程再回调
#else
    cb(bdev_io, result);                                // 直接回调
#endif
```

- **为什么 callback 不一定在原始线程**：completion 链的运行线程是 **Client 线程**（RPC 层 `connection` 的 poller 注册在 Client 线程上，[client.h#L225](src/include/fastblock/msg/rdma/client.h#L225)）。而 bdev IO 可能从另一个 SPDK 线程提交（多核时每个 shard 一个 client 实例，还有 `app_thread` 的兜底路径，[bdev_fastblock.cc#L329-331](src/bdev/bdev_fastblock.cc#L329)）。
- **为什么保存原始 thread**：`write_source` 构造时 `thread = spdk_get_thread()`（[L127](src/client/libfblock.cc#L127)）——记下"这个 bdev IO 属于哪个线程"。
- **为什么最终要回原线程**：`spdk_bdev_io_complete` 要求与提交 IO 的线程一致（DEBUG 模式下有 assert，注释在 [L141-143](src/client/libfblock.cc#L141)）。用 `spdk_thread_send_msg` 把"完成通知"作为一条消息投回原线程执行。
- release 模式直接回调：生产配置里 bdev 线程就是 Client 线程（每个 shard 一个实例），无需切换。

---

# 两阶段核心数据结构

| 结构 | 是什么 | 保存什么 | 谁创建 | 谁最终消费 |
|---|---|---|---|---|
| `osd::write_request` | 写请求消息（proto） | pool_id / pg_id / object_name / offset / data | `write_object()`（[fb_client.h#L1276](src/include/fastblock/client/fb_client.h#L1276)） | `SerializeToArray`（[transport_data.h#L307](src/include/fastblock/msg/rdma/transport_data.h#L307)）发到 OSD |
| `osd::write_reply` | 写响应消息（proto） | state（成功/错误码） | `process_request()`（[fb_client.h#L1159](src/include/fastblock/client/fb_client.h#L1159)）new 出空壳 | RPC 层 `ParseFromArray` 填值 → `process_response()` 读 `resp->state()` |
| `request_stack_type` | 请求上下文背包（[fb_client.h#L79](src/include/fastblock/client/fb_client.h#L79)） | req / resp / resp_cb / ctrlr / stub / ctx / is_responsed | `send_request()`（[L713](src/include/fastblock/client/fb_client.h#L713)） | `process_response()`（读取、调回调、释放） |
| `ctrlr`（rpc_controller） | RPC 状态对象 | 传输层成败、错误文本 | stack 构造时创建（[L98](src/include/fastblock/client/fb_client.h#L98)） | RPC 层 `SetFailed`；Client 读 `ctrlr->Failed()` 判 -ENOLINK |
| `rpc_service_osd_Stub` | 远端服务代理 | 绑定的 `RpcChannel*`（即 connection） | `get_stub()`（[L605](src/include/fastblock/client/fb_client.h#L605)） | 每次 RPC 调用点（process_write / process_get_leader ...） |
| `msg::rdma::client::connection` | 一条 RDMA 连接 = RpcChannel（[client.h#L152](src/include/fastblock/msg/rdma/client.h#L152)） | QP 相关的发送/接收状态、`_unresponsed_requests`、`_onflight_requests` | `on_connection_ready()`（[fb_client.h#L382](src/include/fastblock/client/fb_client.h#L382)） | 序列化、`ibv_post_send`、响应解析、`closure->Run()` |
| `_on_flight_requests` | 在途请求队列（[fb_client.h#L1365](src/include/fastblock/client/fb_client.h#L1365)） | 已发出、等响应的 `request_stack_type` | `process_request()` 移入（[L1191](src/include/fastblock/client/fb_client.h#L1191)） | `process_response()` 消费（[L937/1023](src/include/fastblock/client/fb_client.h#L937)） |
| `write_source` | 跨 Object 完成聚合器（[libfblock.cc#L114](src/client/libfblock.cc#L114)） | obj_num / 最终回调 cb / bdev_io / result / 原始 thread | `libblk_client::write()`（[L193](src/client/libfblock.cc#L193)） | `write_done()` → `invoke()` → 上层 cb |

---

# 一个完整 4KB Write 串起来

```text
前提：object_100 → PG10 → Leader OSD3（10.0.0.3:9000），缓存有效
```

| 步骤 | 实际过程 | 源码位置 |
|---|---|---|
| 1 | `process_request()`：取队头，`_leader_osd` 命中 OSD3，`get_stub(3, 10.0.0.3, 9000)` 拿 stub，`update_leader_state` 确认有效 | [fb_client.h#L1063-1098](src/include/fastblock/client/fb_client.h#L1063) |
| 2 | write 分支：`stub->process_write(ctrlr, req, reply, NewCallback(on_response, stack))` | [fb_client.h#L1158-1163](src/include/fastblock/client/fb_client.h#L1158) |
| 3 | stub 生成代码 → `channel_->CallMethod(...)` → `connection::CallMethod()` | [osd_msg.pb.h#L5593](src/include/fastblock/rpc/osd_msg.pb.h#L5593) / [client.h#L510](src/include/fastblock/msg/rdma/client.h#L510) |
| 4 | `make_request_meta("osd.rpc_service_osd", "process_write", size)`，rpc_request 入连接队列 | [client.h#L545-584](src/include/fastblock/msg/rdma/client.h#L545) |
| 5 | 连接 poller：`process_request_once()` → `SerializeToArray` 写进注册内存 → 构造 `IBV_WR_SEND` + SGE | [client.h#L330-370](src/include/fastblock/msg/rdma/client.h#L330) / [transport_data.h#L283](src/include/fastblock/msg/rdma/transport_data.h#L283) |
| 6 | `::ibv_post_send(qp, wr)` → RNIC → 网络 → **OSD** | [socket.h#L372](src/include/fastblock/msg/rdma/socket.h#L372) |
| 7 | OSD 处理完，回复 `write_reply{state}` → CQ 出现 RECV 完成 | —（OSD 内部不展开） |
| 8 | `handle_cqe()`：按 req_key 找回 rpc_request → `ParseFromArray` 填 reply → `closure->Run()` | [client.h#L799-919](src/include/fastblock/msg/rdma/client.h#L799) |
| 9 | `on_response(stack)`：`is_responsed = true` | [fb_client.h#L1261](src/include/fastblock/client/fb_client.h#L1261) |
| 10 | `process_response()`：state 检查通过 → `cb(ctx, state)`（= write_done）→ `pop_front()` | [fb_client.h#L932-977](src/include/fastblock/client/fb_client.h#L932) |
| 11 | `write_source::write_done`：`obj_num--`（本例单 Object：2→…直接归 0）→ `invoke()` | [libfblock.cc#L151-162](src/client/libfblock.cc#L151) |
| 12 | `invoke()` → `bdev_fastblock_write_callback(bdev_io, success)` | [libfblock.cc#L138](src/client/libfblock.cc#L138) |
| 13 | `spdk_bdev_io_complete(bdev_io, SPDK_BDEV_IO_STATUS_SUCCESS)` → **上层 IO 完成** | [bdev_fastblock.cc#L290-294](src/bdev/bdev_fastblock.cc#L290) |

> 若走 write ring：步骤 5-6 变为 RDMA WRITE 数据到 OSD ring slot + `process_commit_ring_write` 提交；步骤 7 的回复走 commit 的 reply。其余不变。

---

# Checklist

## 2.4

- [ ] `stub->process_write()` 为什么是远程调用？（stub 只是代理，内部把调用转给 RpcChannel）
- [ ] Stub 和 RpcChannel 是什么关系？（stub 持有 channel；connection 实现 channel，[client.h#L152](src/include/fastblock/msg/rdma/client.h#L152)）
- [ ] `connection::CallMethod()` 干什么？（打包 req_key + request_meta + 请求体，入队交给连接 poller）
- [ ] protobuf 在哪里序列化？（`SerializeToArray`，[transport_data.h#L307](src/include/fastblock/msg/rdma/transport_data.h#L307)）
- [ ] RDMA 从哪里真正开始？（`::ibv_post_send`，[socket.h#L372](src/include/fastblock/msg/rdma/socket.h#L372)）
- [ ] QP / WR / SGE 在这条链路里分别做什么？（QP=网卡收发队列，WR=发送动作，SGE=数据段描述，MR=注册内存，CQ=完成队列）
- [ ] 普通 write RPC 和 write ring 有什么区别？（普通：整体 SEND；ring：RDMA WRITE 数据到 OSD 预注册 slot + 小 commit RPC 控制）

## 2.5

- [ ] Response 回来后谁首先处理？（RPC 层 `handle_cqe` 按 req_key 找回请求 → `closure->Run()`）
- [ ] `on_response()` 为什么只标记完成？（单线程事件驱动，统一由 poller 消费，避免重入）
- [ ] `process_response()` 做什么？（检查 is_responsed → 读 state → 成功调回调 / 失败重试）
- [ ] 成功和失败怎么区分？（`ctrlr->Failed() ? -ENOLINK : resp->state()`）
- [ ] Leader 变化后怎么重试？（`RAFT_ERR_NOT_LEADER` → `retry_request()` 失效 Leader 缓存、请求回 `_requests` 队首重新查 Leader）
- [ ] `_on_flight_requests` 的作用是什么？（保存已发出、等响应的请求现场）
- [ ] `write_source` 为什么存在？（一个 IO 拆 N 个 Object，需要聚合所有 Object 完成）
- [ ] 多 Object write 怎么聚合 completion？（`write_done` 里 `obj_num--`，归零才 `invoke()` 通知上层一次）
- [ ] 最终哪里调用 `spdk_bdev_io_complete()`？（`bdev_fastblock_write_callback`，[bdev_fastblock.cc#L294](src/bdev/bdev_fastblock.cc#L294)）

---

## 第二阶段（src/client/）完成标志

可以独立画出完整链路：

```text
Client 请求准备完成（write_object → calc_target → send_request）
↓
请求队列（request_stack_type → _requests → process_request）
↓
Data RPC（stub->process_write → CallMethod → 序列化 → ibv_post_send）
↓
RDMA / 网络
↓
OSD
↓
Response（handle_cqe → closure → on_response → process_response）
↓
Completion（write_source 聚合 → invoke）
↓
spdk_bdev_io_complete() → 上层 IO 完成
```

下一阶段：`src/osd/`（OSD 端如何接收这个 RPC、落盘、回复——那里有 Raft 和 LocalStore）。