# FastBlock Client 2.3：请求队列与 Poller

> **前置**：2.1 得到 `pg_id`，2.2 得到 PG Leader 并缓存到 `_leader_osd`（如 PG10 → OSD3@10.0.0.3:9000）。
> **本阶段终点**：请求从队列中取出，调用 `stub->process_write(...)`，随即进入 `_on_flight_requests`。RDMA、protobuf 序列化、response/completion 一律不展开。
> **链接说明**：相对路径 + `#L行号` 的链接在 VSCode 中可点击跳转。

---

## 1. 本阶段目标

- `send_request()` 之后请求保存在哪里？
- `request_stack_type` 是干什么的？
- `_requests` / `_on_flight_requests` 是什么？
- Poller 是什么、在哪里注册、为什么会被不断执行？
- `process_request()` 如何拿到 Leader OSD？
- `get_stub()` 负责什么？
- 请求什么时候从 `_requests` 移到 `_on_flight_requests`？
- 最后为什么调用 `stub->process_write(...)`？

---

## 2. 真实调用链（以当前源码为准）

```text
send_request()                       fb_client.h:709
↓  new request_stack_type（装 req/cb/ctx），算 leader_osd_key
do_send_request()                    fb_client.h:820
↓  (spdk_thread_send_msg 到 Client 线程)
handle_send_request()                fb_client.h:869
↓  已有 Leader 时先 get_stub()，然后请求入队
_requests                            fb_client.h:1364（队列）
↓
poll_request  (poller，周期 0)        fb_client.h:797
↓
process_request()                    fb_client.h:1063
↓  查 _leader_osd（按 leader_osd_key）
↓  refresh_leader_transport_from_cluster_map()   fb_client.h:668
↓  get_stub(leader_id, addr, port)   fb_client.h:587
↓  update_leader_state()             fb_client.h:648
↓  std::visit 按请求类型分发
stub->process_write(ctrlr, req, reply, done)      fb_client.h:1160
↓
请求移入 _on_flight_requests         fb_client.h:1191-1192
↓
★ 本阶段结束（下一阶段：RDMA 发送 + response）
```

---

## 3. 重点：`request_stack_type` — 为什么异步系统需要它

- **位置**：[fb_client.h#L79](src/include/fastblock/client/fb_client.h#L79)

**核心问题**：`stub->process_write()` 是异步的——调用后函数立即返回，而 OSD 的响应要等 RPC 回来（可能在几微秒甚至更久之后）。等响应回来时，`send_request()` 的栈帧早就没了。**回调触发时，代码必须还能找到"这是哪个请求、回调谁、带什么上下文"**。`request_stack_type` 就是为这次请求随身携带的"上下文背包"。

本阶段只需要这些字段：

| 字段 | 作用 |
|---|---|
| `req` | 要发的 `osd::write_request`（variant 持有） |
| `resp_cb` | 响应回来后调用的回调（variant：write/read/delete 回调） |
| `ctx` / `obj_index` | 回调时的上层上下文（如 `write_source`）和 Object 序号 |
| `ctrlr` | `rpc_controller`，RPC 状态（成败/错误文本）挂在它上面 |
| `stub` | **发往哪个 OSD**——本阶段由 `get_stub()` 填入 |
| `leader_osd_key` | 请求的 PG 身份（pool_id+pg_id 压成的 uint64），查 `_leader_osd` 用 |
| `is_responsed` | 响应是否已回来（下一阶段 `process_response()` 靠它判断） |

结合一次 write 请求：`write_object()` 构造 `write_request` → `send_request()` 把它连同回调一起装进 `request_stack_type` → 这个栈帧从 `_requests` 走到 `_on_flight_requests`，**无论响应何时回来，都能凭栈帧恢复全部现场**。

---

## 4. 重点：两个队列

### `_requests`（[fb_client.h#L1364](src/include/fastblock/client/fb_client.h#L1364)）

- **谁放进去**：`handle_send_request()` 末尾 `_requests.emplace_back(req_stk)`（[L925](src/include/fastblock/client/fb_client.h#L925)）。**无论 Leader 已知还是未知，请求都先进这个队列**。
- **里面是什么**：`std::list<std::unique_ptr<request_stack_type>>`，按到达顺序排队的待发请求。
- **什么时候取出**：`process_request()` poller 只处理队头（FIFO）；取出的条件（[L1068-1076](src/include/fastblock/client/fb_client.h#L1068)）：Leader 缓存存在、且不在查询中（`!is_onflight`）。
- **注意**：Leader 未知时请求也会先入队，只是 `process_request()` 发现 `_leader_osd` 没有/查询中，就返回 IDLE 等下一轮——**队列把"请求"和"Leader 查询"解耦了**。

### `_on_flight_requests`（[fb_client.h#L1365](src/include/fastblock/client/fb_client.h#L1365)）

- **什么叫 on flight**：请求已经"在路上"——`process_write` 已调用，正在等 OSD 响应。
- **什么时候进入**：`process_request()` 发出后：`_on_flight_requests.push_back(std::move(head)); _requests.pop_front();`（[L1191-1192](src/include/fastblock/client/fb_client.h#L1191)）。
- **为什么还要保存状态**：发出 ≠ 完成。响应回来时（下一阶段的 `process_response()`）要凭这个栈帧知道：回调谁、`resp` 填到哪、失败要不要重试。**队列即状态存储**。

---

## 5. 重点：Poller

**Poller 是什么**：注册在 SPDK 线程上的一个回调函数，SPDK 的 reactor 循环会**周期性（或每轮）自动调用它**。FastBlock Client 不自己开线程循环，而是借 SPDK 的轮询机制驱动所有异步逻辑。

**注册位置**：[`handle_start()`](src/include/fastblock/client/fb_client.h#L834) 里注册三个（[L837-839](src/include/fastblock/client/fb_client.h#L837)）：

```cpp
_leader_poller.register_poller(poll_leader, this, 0, "fbcli_leader");
_request_poller.register_poller(poll_request, this, 0, "fbcli_request");
_response_poller.register_poller(poll_response, this, 0, "fbcli_response");
```

- 调 `process_request()` 的是 **`fbcli_request` poller**：[poll_request](src/include/fastblock/client/fb_client.h#L797) → `process_request()`
- `register_poller` 本身通过 `spdk_thread_send_msg` 投到 Client 线程，再由 `SPDK_POLLER_REGISTER` 注册（[simple_poller.h#L100](src/include/fastblock/utils/simple_poller.h#L100) / [L76](src/include/fastblock/utils/simple_poller.h#L76)）
- **周期 0**：SPDK 中周期 0 表示"每个 reactor 迭代都执行"（持续轮询），不是定时器——所以请求能立刻被取走，而不是等下一个 tick

**为什么不是 `while(true)`**：Client 的所有工作（poller、RPC 回调、消息）都挤在同一个 SPDK 线程上。`while(true)` 会独占线程，其他事件永远得不到执行；poller 每次执行一小段（取一个队头、查一次缓存），执行完立即把 CPU 还给 reactor 循环。这也是 `process_request()` 返回值 `SPDK_POLLER_IDLE/BUSY` 的意义——告诉 reactor 这次干了多少活。

**和 OSD shard / SPDK thread 的关系**：每个 `fblock_client` 实例绑定一个 SPDK 线程（`_current_thread`，构造时传入，[L734-741](src/include/fastblock/client/fb_client.h#L734)）。bdev 层按 shard 取对应的 `libblk_client`（第一阶段见过 `global::blk_clients.at(worker_index)`），所以**每个核上的 IO 由各自线程上的 poller 驱动**，互不抢锁。

---

## 6. 重点：`process_request()`（[fb_client.h#L1063](src/include/fastblock/client/fb_client.h#L1063)）

按代码执行顺序：

1. **取请求**：`_requests.front()`（队头，FIFO）；队列空 → `SPDK_POLLER_IDLE`（[L1064-1068](src/include/fastblock/client/fb_client.h#L1064)）
2. **取 leader_osd_key**：`head->leader_osd_key`（2.2 阶段 `send_request` 时算好的）
3. **查缓存**：`_leader_osd.find(head->leader_osd_key)`（[L1069](src/include/fastblock/client/fb_client.h#L1069)）→ 得到 `leader_osd_info*`；不存在或 `is_onflight` → IDLE 等下一轮（[L1070-1076](src/include/fastblock/client/fb_client.h#L1070)）
4. **得到 leader_id / addr / port**：直接从缓存里读：`osd_info_it->second->leader_id / addr / port`（[L1082-1084](src/include/fastblock/client/fb_client.h#L1082) 的日志里就能看到这三个值）
5. **重新校验 Leader 状态**（两步）：
   - `refresh_leader_transport_from_cluster_map()`（[L1088](src/include/fastblock/client/fb_client.h#L1088)，[定义 L668](src/include/fastblock/client/fb_client.h#L668)）：用 monclient 的 OSD Map 核对 Leader 地址，若地址变了（如端口更新）就更新缓存并作废旧连接
   - `update_leader_state()`（[L1098](src/include/fastblock/client/fb_client.h#L1098)，[定义 L648](src/include/fastblock/client/fb_client.h#L648)）：确认 Leader `isup && isin`
6. **取 stub**：`head->stub = get_stub(leader_id, addr, port)`（[L1090-1093](src/include/fastblock/client/fb_client.h#L1090)）；拿不到（在建连）→ IDLE，下轮再来（[L1094-1096](src/include/fastblock/client/fb_client.h#L1094)）
7. **Leader 校验失败**：`!is_valid` → `enqueue_leader_request()` 重新查 Leader，本轮放弃该请求（[L1099-1128](src/include/fastblock/client/fb_client.h#L1099)）
8. **stub 最终是什么**：`osd::rpc_service_osd_Stub*`——绑定到 Leader 连接的 protobuf RPC 客户端对象
9. **发请求**：`std::visit` 按 `req` 类型分发（[L1130-1188](src/include/fastblock/client/fb_client.h#L1130)），write 分支：
   ```cpp
   stack_ptr->stub->process_write(stack_ptr->ctrlr.get(), req.get(), reply.get(),
       google::protobuf::NewCallback(this, &fblock_client::on_response, stack_ptr));
   ```
   （[L1158-1163](src/include/fastblock/client/fb_client.h#L1158)，`reply` 先 new 出来放进 `stack_ptr->resp`）
   - ⚠️ [L1136](src/include/fastblock/client/fb_client.h#L1136) 有 write ring 优化分支（默认开），属于第四阶段，本阶段只看 L1158-1163 的普通路径
10. **入 on-flight 队列**：`_on_flight_requests.push_back(std::move(head)); _requests.pop_front();`（[L1191-1192](src/include/fastblock/client/fb_client.h#L1191)）

**只需要搞懂**：`process_request()` 每个 poller 周期只处理**队头一个请求**，条件不满足就 IDLE 等下一轮——这就是"事件驱动 + 状态保存"的形态。

---

## 7. 重点：`get_stub()`（[fb_client.h#L587](src/include/fastblock/client/fb_client.h#L587)）

```text
leader_id / addr / port
↓ get_stub(node_id, addr, port)
rpc_service_osd_Stub*（或 nullptr，表示还在建连）
```

**stub 可以理解成什么**：远端 OSD 服务在 Client 侧的"本地代理"。Client 调 `stub->process_write(...)` 就像调本地函数，参数会被打包成 RPC 发过去——**Client 不需要知道 IP、端口、序列化、网络细节**。

**为什么不能直接拿 IP 调函数**：网络调用天然是异步、可能失败的；RPC 框架把这些都封装在 stub/channel/controller 里，上层只面对"调用 + 回调"。

**stub 和 connection 的关系**：

- `connection`（`msg::rdma::client::connection`）是一条到 OSD 的真实 RDMA 连接，同时实现 protobuf 的 `RpcChannel`
- `stub` 构造时绑定一个 channel：`_stubs[conn_id] = std::make_unique<osd::rpc_service_osd_Stub>(conn)`（[L605](src/include/fastblock/client/fb_client.h#L605)，连接就绪回调里 [L382](src/include/fastblock/client/fb_client.h#L382)）
- 调 `stub->process_write()` 最终会走到 `connection::CallMethod()` ——**这是下一阶段的入口，本阶段到此为止**

**get_stub 内部逻辑**（[L587-609](src/include/fastblock/client/fb_client.h#L587)）：

- `conn_id = to_connection_id(node_id, port)` 定位"到某 OSD 某端口的连接"
- **连接已存在** → 直接复用 `_stubs[conn_id]`（每个 (node, port) 一个 stub）
- **连接不存在** → `ensure_connection()` 发起异步建连，返回 `nullptr`；`process_request()` 看到 nullptr 就 IDLE，**连接建好后的下一轮 poller 再来取 stub**（连接管理的 RDMA 细节属于第四阶段）

> 注意：`get_stub` 在 `handle_send_request()`（[L922](src/include/fastblock/client/fb_client.h#L922)）和 `process_request()`（[L1090](src/include/fastblock/client/fb_client.h#L1090)）各调一次，后者是真正决定"发"的那次。

---

## 8. 完整例子

```text
前提：pool_id=1, pg_id=10, 2.2 阶段已缓存 Leader：
      _leader_osd[key(1,10)] = { leader_id:3, addr:"10.0.0.3", port:9000, is_valid:true }
      Client 手里有一个 write request（object_100 的数据）
```

| 步骤 | 实际过程 | 源码位置 |
|---|---|---|
| 1 | `send_request(1, 10, write_request, cb, ctx)`：`new request_stack_type`，装入 req/cb/ctx；`leader_osd_key = make_leader_key(1, 10)` | [fb_client.h#L709-718](src/include/fastblock/client/fb_client.h#L709) |
| 2 | `do_send_request` → `handle_send_request`：查 `_leader_osd` 命中（is_valid=true）→ `req_stk->stub = get_stub(3, "10.0.0.3", 9000)` | [fb_client.h#L869-922](src/include/fastblock/client/fb_client.h#L869) |
| 3 | 请求进入 **`_requests`**：`_requests.emplace_back(req_stk)` | [fb_client.h#L925](src/include/fastblock/client/fb_client.h#L925) |
| 4 | **Poller**：`fbcli_request` 每轮 reactor 调 `poll_request` → `process_request` | [fb_client.h#L797-807](src/include/fastblock/client/fb_client.h#L797) |
| 5 | `process_request`：`_requests.front()`，`_leader_osd.find(key)` 命中 OSD3 | [fb_client.h#L1068-1069](src/include/fastblock/client/fb_client.h#L1068) |
| 6 | `refresh_leader_transport_from_cluster_map` 核对地址 → `head->stub = get_stub(3, "10.0.0.3", 9000)`（连接已存在，直接复用 `_stubs[conn_id]`）→ `update_leader_state` 确认有效 | [fb_client.h#L1088-1098](src/include/fastblock/client/fb_client.h#L1088) |
| 7 | write 分支：`stub->process_write(ctrlr, req, reply, on_response callback)` | [fb_client.h#L1158-1163](src/include/fastblock/client/fb_client.h#L1158) |
| 8 | 请求移入 **`_on_flight_requests`**，`_requests.pop_front()` | [fb_client.h#L1191-1192](src/include/fastblock/client/fb_client.h#L1191) |

**本阶段结束**：write_request 已通过 stub 交给连接层（`connection::CallMethod`），请求在 on-flight 队列等待响应。

---

## 9. 本阶段必要数据结构

| 结构 | 是什么 | 保存什么 | 调用链中的作用 |
|---|---|---|---|
| `request_stack_type`（[fb_client.h#L79](src/include/fastblock/client/fb_client.h#L79)） | 请求的上下文背包 | req / resp_cb / ctx / ctrlr / stub / leader_osd_key / is_responsed | 从入队到完成全程跟随请求 |
| `_requests`（[fb_client.h#L1364](src/include/fastblock/client/fb_client.h#L1364)） | 待发请求队列（list） | 尚未发出的 `request_stack_type` | `handle_send_request` 入队，`process_request` 取队头 |
| `_on_flight_requests`（[fb_client.h#L1365](src/include/fastblock/client/fb_client.h#L1365)） | 在途请求队列（list） | 已调用 `process_write`、等响应的栈帧 | 本阶段末尾移入；下一阶段 `process_response` 消费 |
| `leader_osd_info`（[fb_client.h#L116](src/include/fastblock/client/fb_client.h#L116)） | PG 的 Leader 缓存值 | leader_id / addr / port / is_valid / is_onflight | `process_request` 从这里读目标 OSD |
| `rpc_service_osd_Stub`（[osd_msg.pb.h#L5579](src/include/fastblock/rpc/osd_msg.pb.h#L5579)） | 远端 OSD 服务的 RPC 客户端 | 绑定一个 connection（RpcChannel） | 提供 `process_write/get_leader/...` 调用点 |

---

## 10. 总结图（一屏）

```text
前两阶段已得到：
write request + PG10 + Leader OSD3
↓
send_request()                     fb_client.h:709
↓
request_stack_type（req/cb/ctx/leader_osd_key）
↓
handle_send_request()              fb_client.h:869
↓
_requests 队列                     fb_client.h:1364
↓
Poller：fbcli_request（周期 0）    fb_client.h:797
↓
process_request()                  fb_client.h:1063
↓
查 _leader_osd[key(1,10)] → OSD3
↓
refresh leader info + 校验有效性
↓
get_stub(3, 10.0.0.3, 9000)        fb_client.h:587
↓
rpc_service_osd_Stub（绑定 connection）
↓
stub->process_write(...)           fb_client.h:1160   ★ 本阶段终点
↓
请求移入 _on_flight_requests       fb_client.h:1191
↓
（下一阶段：CallMethod → protobuf → RDMA → OSD → response）
```

---

## 11. Checklist

- [ ] `request_stack_type` 为什么存在？（异步系统需要保存请求现场，回调回来才能恢复上下文）
- [ ] `_requests` 保存什么？（待发请求，`handle_send_request` 入队）
- [ ] `_on_flight_requests` 保存什么？（已发出、等响应的请求）
- [ ] Poller 在哪里注册？（`handle_start()`，[L837-839](src/include/fastblock/client/fb_client.h#L837)）
- [ ] `process_request()` 为什么会不断执行？（周期 0 的 SPDK poller，每个 reactor 迭代都跑）
- [ ] `process_request()` 怎么得到 Leader OSD？（按 `leader_osd_key` 查 `_leader_osd` 缓存）
- [ ] `get_stub()` 干什么？（按 leader 地址拿/建到 OSD 的 RPC stub，没连接就异步建连返回 nullptr）
- [ ] stub 是什么？（绑定 connection 的 protobuf RPC 客户端，`process_write` 的调用点）
- [ ] 请求什么时候进入 `_on_flight_requests`？（`stub->process_write(...)` 之后，[L1191-1192](src/include/fastblock/client/fb_client.h#L1191)）
- [ ] `stub->process_write()` 为什么是这一阶段的结束点？（从这里开始进入 RPC 传输层，属于第四阶段）

下一阶段入口：`connection::CallMethod()`（[msg/rdma/client.h#L510](src/include/fastblock/msg/rdma/client.h#L510)）——protobuf 序列化 + RDMA 发送，以及 `process_response()` 处理响应。**完整文档：[route4.md](route4.md)**。