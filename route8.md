# FastBlock 第八阶段：`src/rpc/` + `src/msg/`（网络通信层：Protobuf RPC + RDMA）

> **前置**：已知 `stub->process_write()` 会把 write_request 发给 PG Leader；Raft 复制（AppendEntries）也走网络。
> **本阶段范围**：一条 RPC 从本机发出到远端被处理的完整链路。Raft 算法、Client 业务逻辑、性能分析一律不展开。
> **链接说明**：FastBlock 函数用可点击的相对路径 + `#L行号`；`ibv_*` 是 libibverbs 外部 API；`↓` 表示调用方向。
> **架构概念图用代码块，源码调用链用 Markdown 链接列表（保证可点击）。**

---

## 1. 网络相关文件扫描

| 文件 | 职责 | 判定 |
|---|---|---|
| [osd_msg.pb.h](src/include/fastblock/rpc/osd_msg.pb.h)（生成） | `osd::rpc_service_osd` service + [rpc_service_osd_Stub](src/include/fastblock/rpc/osd_msg.pb.h#L5579) | **核心（查 Stub 时翻）** |
| [raft_msg.pb.h](src/rpc/raft_msg.pb.h)（生成） | `rpc_service_raft` service + Stub + 全部 Raft 消息 | **核心（OSD↔OSD）** |
| [server.h](src/rpc/server.h) | `rpc_server`：每核一个 `msg::rdma::server` 的薄封装 | 核心 |
| [connect_cache.h](src/include/fastblock/rpc/connect_cache.h) | OSD 侧连接缓存：每 shard 一个 `msg::rdma::client` + 按 node 存 connection | **核心（OSD↔OSD）** |
| [msg/rdma/client.h](src/include/fastblock/msg/rdma/client.h)（1859行） | **RDMA 客户端全部实现**：connection/RpcChannel、发送、接收、CQ 轮询 | **最核心** |
| [msg/rdma/server.h](src/include/fastblock/msg/rdma/server.h)（1309行） | **RDMA 服务端**：监听、收包、反序列化、RPC 分发 | **最核心** |
| [msg/rdma/socket.h](src/include/fastblock/msg/rdma/socket.h) | 单条连接的 QP 管理、[ibv_post_send](src/include/fastblock/msg/rdma/socket.h#L370)、[ibv_post_recv](src/include/fastblock/msg/rdma/socket.h#L384)、[create_qp](src/include/fastblock/msg/rdma/socket.h#L786) | 核心 |
| [msg/rdma/transport_data.h](src/include/fastblock/msg/rdma/transport_data.h) | RPC 消息的内存表示：序列化、SGE/WR 链、大消息分块 | **核心** |
| [msg/rdma/memory_pool.h](src/include/fastblock/msg/rdma/memory_pool.h) | 预注册 MR 的内存池 | **核心** |
| [msg/rdma/types.h](src/include/fastblock/msg/rdma/types.h) | [request_meta](src/include/fastblock/msg/rdma/types.h#L82)（RPC 头） | 核心 |
| [msg/rdma/cq.h](src/include/fastblock/msg/rdma/cq.h) | [completion_queue](src/include/fastblock/msg/rdma/cq.h#L34)：[ibv_create_cq](src/include/fastblock/msg/rdma/cq.h#L178) / [ibv_poll_cq](src/include/fastblock/msg/rdma/cq.h#L202) | 核心 |
| [msg/rpc_controller.h](src/include/fastblock/msg/rpc_controller.h) | [rpc_controller](src/include/fastblock/msg/rpc_controller.h#L22)：protobuf RpcController 实现 | 核心 |
| [msg/rdma/pd.h / device.h / endpoint.h / provider.h / event_channel.h / connection_id.h / work_request_id.h] | PD、设备、地址解析、verbs/mlx5dv 后端、cm event、id 生成 | **第一遍跳过** |
| proto/ | service 与消息定义 | 查消息时翻 |
| [raft_client_protocol.h](src/raft/raft_client_protocol.h) / [.cc](src/raft/raft_client_protocol.cc) | **Raft 客户端**：按 node 持 `rpc_service_raft_Stub`，发 AppendEntries/vote | **核心（OSD↔OSD）** |
| [raft_service.h](src/raft/raft_service.h) | **Raft 服务端**：`raft_service : public rpc_service_raft` 的 handler | **核心（OSD↔OSD）** |

---

## 2. 网络层整体图

```text
业务层：Client / OSD（raft_client_protocol / osd_service）
↓
Protobuf Stub（生成的 rpc_service_osd_Stub / rpc_service_raft_Stub）
↓
RpcChannel（msg::rdma::client::connection 实现 google::protobuf::RpcChannel）
↓
CallMethod() → 序列化 → request_meta + payload 入队
↓
连接 poller → 构造 WR/SGE → ibv_post_send → QP
↓
RNIC → Network
↓
远端 RNIC → CQ → CQE
↓
远端 server 收包 → 反序列化 → 按 service/method 分发
↓
远端业务 handler（osd_service::process_write / raft_service::append_entries）
```

---

## 3. Protobuf RPC 层

### Stub

- **谁生成**：protoc 从 [proto/osd_msg.proto#L171](proto/osd_msg.proto#L171)（`service rpc_service_osd`）/ [raft_msg.proto#L256](proto/raft_msg.proto#L256)（`service rpc_service_raft`）生成。
- **定义位置**：[rpc_service_osd_Stub](src/include/fastblock/rpc/osd_msg.pb.h#L5579)（osd_msg.pb.h）；`rpc_service_raft_Stub` 在 raft_msg.pb.h。
- **内部**：只持有 `RpcChannel* channel_`（[osd_msg.pb.h#L5639](src/include/fastblock/rpc/osd_msg.pb.h#L5639)）；[process_write()](src/include/fastblock/rpc/osd_msg.pb.h#L5593) 生成的实现就是 `channel_->CallMethod(...)`。
- 创建点：Client 在 [get_stub](src/include/fastblock/client/fb_client.h#L605)；Raft 在 [raft_client_protocol.h#L177](src/raft/raft_client_protocol.h#L177) `make_shared<rpc_service_raft_Stub>(conn)`。

### RpcChannel

- **FastBlock 的实现**：[msg::rdma::client::connection](src/include/fastblock/msg/rdma/client.h#L152) —— `class connection : public std::enable_shared_from_this<connection>, public google::protobuf::RpcChannel`。一条 RDMA 连接同时就是 RpcChannel。
- **为什么 Stub 需要它**：Stub 决定"调哪个远端方法"，Channel 决定"从哪条连接走、怎么把消息发出去"。二者解耦，Stub 与协议绑定、Channel 与传输绑定。

### `CallMethod()`

- **位置**：[connection::CallMethod()](src/include/fastblock/msg/rdma/client.h#L510)（client.h）
- **输入**：`const MethodDescriptor* method`（描述"哪个服务哪个方法"，含服务名/方法名，是 RPC 头的来源）、`RpcController* ctrlr`（状态）、`request`（write_request 等）、`response`（空壳，等远端填充）、`Closure* done`（完成回调）
- **做什么**：状态检查 → 分配 `req_key` → [make_request_meta](src/include/fastblock/msg/rdma/client.h#L545) → 打包 [rpc_request](src/include/fastblock/msg/rdma/client.h#L156) → 入队（[enqueue_request](src/include/fastblock/msg/rdma/client.h#L394)）。**CallMethod 只"登记"，不发送**——发送由连接自己的 poller 在下一轮做。
- **下一步**：[enqueue_request()](src/include/fastblock/msg/rdma/client.h#L394)

---

## 4. 请求序列化与 RPC 头

- **序列化点**：[transport_data::serialize_data()](src/include/fastblock/msg/rdma/transport_data.h#L283)，核心是 `request->SerializeToArray(...)`（[L307](src/include/fastblock/msg/rdma/transport_data.h#L307)），直接写进已注册的 DMA 内存。
- **调用者**：[process_request_once()](src/include/fastblock/msg/rdma/client.h#L330)（连接 poller 每轮处理一个）。
- **RPC header（metadata）**：[request_meta](src/include/fastblock/msg/rdma/types.h#L82)：`service_name / method_name / data_size`（字符串方式编码，不用数字 id）；由 [make_request_meta](src/include/fastblock/msg/rdma/types.h#L95) 生成，放在 payload 前。
- **request id**：有。`req_key = _unresponsed_request_key_gen++`（[client.h#L542](src/include/fastblock/msg/rdma/client.h#L542)），随消息发出（metadata 里的 correlation_index）。
- **响应怎么找回原请求**：回复里带 correlation index → [read_correlation_index](src/include/fastblock/msg/rdma/transport_data.h#L155) → 查 [\_unresponsed_requests](src/include/fastblock/msg/rdma/client.h#L836) → 找到 rpc_request → 反序列化进 response → [closure->Run()](src/include/fastblock/msg/rdma/client.h#L786)。

---

## 5. RDMA Connection

- **类**：[msg::rdma::client::connection](src/include/fastblock/msg/rdma/client.h#L152)。
- **Client 创建**：`msg::rdma::client::emplace_connection(addr, port, cb)`（[client.h#L1802](src/include/fastblock/msg/rdma/client.h#L1802)）。Client 侧调用点：[fb_client.h#L403](src/include/fastblock/client/fb_client.h#L403)（`ensure_connection`）；OSD 侧：`connect_cache::create_connect`（[connect_cache.h#L44](src/include/fastblock/rpc/connect_cache.h#L44)）。
- **OSD 接受**：`msg::rdma::server::create_listener(port)`（[server.h#L1149](src/include/fastblock/msg/rdma/server.h#L1149)），由 [rpc_server::start](src/rpc/server.h#L38) 调用；cm 事件 `RDMA_CM_EVENT_CONNECT_REQUEST` 在 [socket.h#L405](src/include/fastblock/msg/rdma/socket.h#L405) 处理。
- **保存/复用**：
  - Client：`_stubs[conn_id]`（按 node_id+port 合成 id，[fb_client.h#L604-608](src/include/fastblock/client/fb_client.h#L604)）
  - OSD：`connect_cache::_cache[shard_id][node_id] = conn`（[connect_cache.h#L55](src/include/fastblock/rpc/connect_cache.h#L55)）——**按 OSD id 索引，复用**；`get_connect(shard, node)` 取（[L88](src/include/fastblock/rpc/connect_cache.h#L88)）。
- **断线处理**：连接终止 → `free_resources()` 把所有在途请求以失败释放（[client.h#L1048-1084](src/include/fastblock/msg/rdma/client.h#L1048)）；上层重连（Client 的 [retry_request](src/include/fastblock/client/fb_client.h#L326)、Raft 的 `process_disconnect_rpc`）。
- **connection 与 shard/port 关系**：OSD 每 shard 一个 `msg::rdma::client`（connect_cache.h:28-39），每个 shard 连到对端 OSD 的对应 shard 端口（`sharded_ports[shard_id].port`）。

---

## 6. RDMA 概念结合 FastBlock

### 6.1 QP（Queue Pair）

- **为什么叫 Pair**：一个 Send Queue + 一个 Receive Queue 成对（+ 一个 Completion Queue）。
- **一个 connection = 一个 QP**：`socket` 持有 `_id->qp`（[socket.h#L43](src/include/fastblock/msg/rdma/socket.h#L43) 起），`create_qp` 在 [socket.h#L786-839](src/include/fastblock/msg/rdma/socket.h#L786)，通过 provider（mlx5dv/verbs）创建。
- **状态 INIT→RTR→RTS**：FastBlock 用 `rdma_cm` 建连（`rdma_create_ep`/`rdma_connect`），QP 状态由 cm 驱动；socket.h 里只看到状态字符串 `IBV_QPS_RTR/RTS`（[L188-191](src/include/fastblock/msg/rdma/socket.h#L188)）。**源码不足以确认手动 modify_qp 的位置**（由 rdma_cm 内部完成）。

### 6.2 CQ（Completion Queue）

- **创建**：[completion_queue::completion_queue](src/include/fastblock/msg/rdma/cq.h#L178) `::ibv_create_cq(...)`（外部 API）。
- **Poll**：[completion_queue::poll()](src/include/fastblock/msg/rdma/cq.h#L202) `::ibv_poll_cq(...)`（外部 API）；Client 的 [handle_core_poll](src/include/fastblock/msg/rdma/client.h#L1714) 每轮 poll 一批（batch size 128，[client.h#L60](src/include/fastblock/msg/rdma/client.h#L60)），把 CQE 分发到对应连接的 `cqe_list`（[client.h#L1760](src/include/fastblock/msg/rdma/client.h#L1760)）。
- **区分 send/receive completion**：CQE 的 opcode（`IBV_WC_SEND` / `IBV_WC_RECV`，[client.h#L817-826](src/include/fastblock/msg/rdma/client.h#L817)）。
- **CQ 与 Poller 的关系**：CQ 是硬件队列，Poller 是软件轮询它的人——client 侧是 `rpc_cli_conn` 连接 poller 调 [handle_poll](src/include/fastblock/msg/rdma/client.h#L449)，其中 [handle_cqe](src/include/fastblock/msg/rdma/client.h#L799) 消费 `cqe_list`。

### 6.3 WR（Work Request）

- **WR = 交给网卡的任务**。发送：`ibv_send_wr`（opcode、SGE、wr_id）；接收：`ibv_recv_wr`。
- **构造位置**：发送 WR 在 [transport_data::make_send_request](src/include/fastblock/msg/rdma/transport_data.h#L425)（普通 SEND）、[make_read_request](src/include/fastblock/msg/rdma/transport_data.h#L382)（RDMA READ）；接收 WR 在 [per_post_recv](src/include/fastblock/msg/rdma/client.h#L417)。
- **post_send**：[socket::send()](src/include/fastblock/msg/rdma/socket.h#L370) → `::ibv_post_send(_id->qp, wr, &bad)`（外部 API）。
- **post_recv**：[socket::receive()](src/include/fastblock/msg/rdma/socket.h#L384) → `::ibv_post_recv(...)`（外部 API）。

### 6.4 SGE（Scatter Gather Element）

- **内容**：`addr`（本地内存地址）、`length`、`lkey`（该内存所在 MR 的本地键）。
- **FastBlock 用法**：一个 RPC 消息的发送被组织成 **多个 WR 链**，每个 WR 一个 SGE；预注册的 [net_context](src/include/fastblock/msg/rdma/memory_pool.h#L35) 里 SGE 出厂就指向自己的 8KB 块（[memory_pool.h#L95-97](src/include/fastblock/msg/rdma/memory_pool.h#L95)）。大消息 = 多 SGE 多 WR（transport_data 分块，[make_send_request](src/include/fastblock/msg/rdma/transport_data.h#L444-449) 用 `wr.next` 串链）。

### 6.5 MR（Memory Region）—— 重点

- **为什么需要**：RNIC 通过 DMA 访问内存时必须知道"这段内存能不能碰、在哪、多大"——普通 malloc 内存 RNIC 无法访问。
- **注册**：[memory_pool 构造](src/include/fastblock/msg/rdma/memory_pool.h#L45)：一次 `spdk_zmalloc` 大块（4KB 对齐 DMA 内存，[L56-61](src/include/fastblock/msg/rdma/memory_pool.h#L56)），切成 N 个 element，**每个 element 单独 `::ibv_reg_mr(...)`**（[L81-83](src/include/fastblock/msg/rdma/memory_pool.h#L81)，外部 API），权限 `LOCAL_WRITE | REMOTE_WRITE | REMOTE_READ`。
- **lkey / rkey**：同一 MR 的两个键——`lkey` 本地用（SGE 引用自己内存）；`rkey` 给远端用（远端 RDMA READ/WRITE 你的内存时用）。
- **FastBlock 的预注册池**：`_meta_pool` / `_data_pool`（[client.h#L1298-1305](src/include/fastblock/msg/rdma/client.h#L1298)，8KB element），`transport_data` 借块/还块（[transport_data.h#L573-581](src/include/fastblock/msg/rdma/transport_data.h#L573) 对应 reply 路径——即 [transport_data.h#L89-112](src/include/fastblock/msg/rdma/transport_data.h#L89) 的构造/析构）。

---

## 7. 一次 SEND 的真实路径（Client → OSD）

[stub->process_write()](src/include/fastblock/rpc/osd_msg.pb.h#L5593)（生成代码）

↓

[connection::CallMethod()](src/include/fastblock/msg/rdma/client.h#L510)（登记：req_key + meta + rpc_request 入队）

↓

[enqueue_request()](src/include/fastblock/msg/rdma/client.h#L394)（创建 transport_data，进 `_onflight_requests`）

↓

连接 poller [handle_poll()](src/include/fastblock/msg/rdma/client.h#L449) → [process_rpc_request()](src/include/fastblock/msg/rdma/client.h#L588)

↓

[process_request_once()](src/include/fastblock/msg/rdma/client.h#L330)（[SerializeToArray](src/include/fastblock/msg/rdma/transport_data.h#L307) 序列化）

↓

[make_send_request()](src/include/fastblock/msg/rdma/transport_data.h#L425)（构造 IBV_WR_SEND 链 + SGE）

↓

[send_request → _sock->send()](src/include/fastblock/msg/rdma/client.h#L272)

↓

[::ibv_post_send(qp, wr)](src/include/fastblock/msg/rdma/socket.h#L370)（**libibverbs 外部 API**）

↓

QP Send Queue → RNIC → 网络

---

## 8. RECEIVE 路径（远端 OSD 收包 → process_write）

- **接收 WR 提前 post**：[per_post_recv()](src/include/fastblock/msg/rdma/client.h#L417)（client 侧）/ server 侧同样在连接建立时批量 `ibv_post_recv`（[socket.h#L384](src/include/fastblock/msg/rdma/socket.h#L384)），**在收到数据之前就准备好接收 buffer**。
- **收包**：CQ 出现 `IBV_WC_RECV` → [handle_cqe()](src/include/fastblock/msg/rdma/client.h#L826)（client 侧）或 server 侧对应处理。
- **server 侧完整链**：

[msg::rdma::server 收包 + 反序列化](src/include/fastblock/msg/rdma/server.h#L625)（`unserialize_data` 解析 request_meta + payload）

↓

[按 service_name 查表](src/include/fastblock/msg/rdma/server.h#L556)（`_services` 是启动时 [add_service](src/include/fastblock/msg/rdma/server.h#L1187) 注册的）

↓

[生成 response 原型 + rpc_controller](src/include/fastblock/msg/rdma/server.h#L629)（controller 附带 PD 和 peer_address，供 write ring 用）

↓

[service->CallMethod(method, ctrlr, request, response, done)](src/include/fastblock/msg/rdma/server.h#L649) —— 生成的分发器按 method 调对应 handler

↓

[osd_service::process_write()](src/osd/osd_service.h#L71)（Client RPC）或 [raft_service::append_entries()](src/raft/raft_service.h#L74)（Raft RPC）

---

## 9. Client ↔ OSD 网络路径

[Client write_object()](src/include/fastblock/client/fb_client.h#L1267)

↓

[stub->process_write()](src/include/fastblock/client/fb_client.h#L1160)（调用点）

↓

[connection::CallMethod()](src/include/fastblock/msg/rdma/client.h#L510)

↓

[::ibv_post_send](src/include/fastblock/msg/rdma/socket.h#L370)

↓

**网络**

↓

[msg::rdma::server 收包反序列化](src/include/fastblock/msg/rdma/server.h#L625)

↓

[CallMethod 分发](src/include/fastblock/msg/rdma/server.h#L649)

↓

[osd_service::process_write()](src/osd/osd_service.h#L71)

```text
Client 代码（fb_client / libfblock）
──────────────────────────────────
msg/rdma（client.h + socket.h + transport_data.h）
──────────────────────────────────
OSD 代码（osd_service / osd_stm）
```

**边界**：两端各自的 `msg/rdma` 是对称的同一套框架；业务代码（Client 的 fb_client、OSD 的 osd_service）只接触 Stub 和 handler。

---

## 10. OSD ↔ OSD 网络路径（Raft RPC）

- **service**：`rpc_service_raft`（[raft_msg.proto#L256](proto/raft_msg.proto#L256)），方法 [append_entries](proto/raft_msg.proto#L257)、vote、heartbeat 等。
- **Leader 端调用**：[raft_client_protocol::send_appendentries()](src/raft/raft_client_protocol.cc#L166)：

```cpp
auto stub = _get_stub(shard_id, target_node_id);        // 按目标 node 取 stub
stub->append_entries(&source->ctrlr, request, &source->response, done);   // L178
```

- **连接来源**：`connect_cache`（每 shard 一个 `msg::rdma::client`，[connect_cache.h#L28-39](src/include/fastblock/rpc/connect_cache.h#L28)）；stub 缓存 `_stubs[shard][node]`（[raft_client_protocol.h#L142/177](src/raft/raft_client_protocol.h#L142)）。
- **Follower 端 handler**：[raft_service::append_entries()](src/raft/raft_service.h#L74) → [raft->append_entries_to_buffer()](src/raft/raft_service.h#L120)（进入 raft 处理，本阶段不展开）。
- **注册**：[osd.cc#L315-316](src/osd/osd.cc#L315) `add_service(global_raft_service.get())` —— **与 Client RPC 共用同一套 msg::rdma::server 框架**。

---

## 11. Client ↔ OSD vs OSD ↔ OSD 对比

| 项目 | Client ↔ OSD | OSD ↔ OSD |
|---|---|---|
| RPC 类型 | Data RPC（write/read/delete/get_leader） | Raft RPC（append_entries/vote/heartbeat/...） |
| Protobuf 消息 | [osd_msg.proto](proto/osd_msg.proto) | [raft_msg.proto](proto/raft_msg.proto) |
| Stub | [rpc_service_osd_Stub](src/include/fastblock/rpc/osd_msg.pb.h#L5579) | `rpc_service_raft_Stub`（raft_msg.pb.h） |
| RDMA connection | `fblock_client` 自建（[fb_client.h#L403](src/include/fastblock/client/fb_client.h#L403)） | `connect_cache` 管理（[connect_cache.h#L44](src/include/fastblock/rpc/connect_cache.h#L44)） |
| QP | `msg::rdma::client::connection` 内一个 QP | 同左（**同一框架**） |
| service | `rpc_service_osd`（osd_msg.proto#L171） | `rpc_service_raft`（raft_msg.proto#L256） |
| request handler | [osd_service::process_write](src/osd/osd_service.h#L71) | [raft_service::append_entries](src/raft/raft_service.h#L74) |

**结论**：两条业务路径完全不同，但**底层完全复用同一套 msg/rdma RPC 框架**（同一 connection/RpcChannel/transport_data/memory_pool）。

---

## 12. 内存怎么交给 RNIC（一次 4KB write）

- **CPU 负责**：把 write_request 序列化进**已注册 MR 的 buffer**（[transport_data.h#L307](src/include/fastblock/msg/rdma/transport_data.h#L307)），构造 SGE（指向 MR 内地址 + lkey）和 WR，`ibv_post_send`。
- **RNIC 负责**：按 SGE 里的地址通过 **PCIe DMA 自己读内存**，拆包发送。
- **是否有 memcpy**：protobuf `SerializeToArray` 是一次 CPU 拷贝（业务数据从 request 结构到 DMA buffer）；网络侧**没有额外拷贝**（SGE 直接引用 DMA buffer）。write ring 路径下，数据直接在 [post_ring_write](src/include/fastblock/client/fb_client.h#L496) 里序列化后 RDMA WRITE 出去，连 RPC 收包解析都省了。
- **普通 RPC vs write ring**：普通 = SEND（远端先 post RECV 再收）；ring = RDMA WRITE 直写远端预注册 slot + 小 commit RPC。

---

## 13. Write Ring（简单版）

```text
普通路径：Protobuf RPC（SEND）→ 对端 RECV 收
Write Ring：RDMA WRITE 数据 → 远端 slot（预注册内存）
         → commit_ring_write RPC（控制消息：告诉 OSD slot N 数据好了）
```

- **远端 slot 怎么获得**：[acquire_write_ring_async](src/include/fastblock/client/fb_client.h#L457) → `process_acquire_write_ring` → OSD 返回 `slots[]{remote_addr, remote_key, slot_size}`（[osd_service.cc#L321-330](src/osd/osd_service.cc#L321)）。
- **remote addr/rkey 是什么**：OSD 侧 slot 的 MR 地址和 **rkey**（[osd_service.cc#L327-328](src/osd/osd_service.cc#L327)，MR 注册时有 REMOTE_WRITE 权限）。
- **RDMA WRITE vs SEND 区别**：WRITE 是单向"直写远端内存"，**对端不需要提前 post RECV**，也没有收包解析；SEND 需要对端先 post RECV。
- **为什么数据/控制分开**：大 payload 走 WRITE 免解析，小控制消息走 RPC 保序/应答。

---

## 14. SEND/RECV vs RDMA READ/WRITE

| 模式 | 语义 | FastBlock 位置 |
|---|---|---|
| SEND / RECV | 对端必须提前 post RECV，才收得到 | 普通 RPC：发送 [make_send_request](src/include/fastblock/msg/rdma/transport_data.h#L425)、接收 [per_post_recv](src/include/fastblock/msg/rdma/client.h#L417) |
| RDMA WRITE | 主动直写远端 MR（不需要对端 post RECV） | write ring 数据路径：[post_ring_write](src/include/fastblock/client/fb_client.h#L496)（`IBV_WR_RDMA_WRITE`，[L557](src/include/fastblock/client/fb_client.h#L557)） |
| RDMA READ | 主动读远端 MR | 大响应回读：reply 数据 [make_read_request](src/include/fastblock/msg/rdma/transport_data.h#L382)（`IBV_WR_RDMA_READ`） |

---

## 15. Polling 网络 CQ

- **谁 poll**：client 每轮 [handle_core_poll](src/include/fastblock/msg/rdma/client.h#L1714) 调 [completion_queue::poll](src/include/fastblock/msg/rdma/cq.h#L202)（`::ibv_poll_cq`，外部 API）。
- **Poller 注册**：`msg::rdma::client` 的 `_core_poller`（[client.h#L1295](src/include/fastblock/msg/rdma/client.h#L1295)）+ 每条连接的 `rpc_cli_conn` poller（[client.h#L495-503](src/include/fastblock/msg/rdma/client.h#L495)）。
- **每次 poll 多少**：batch 128（[client.h#L60](src/include/fastblock/msg/rdma/client.h#L60)），CQE 按 wr_id 分发到连接（[client.h#L1756-1760](src/include/fastblock/msg/rdma/client.h#L1756)）。
- **completion 怎么映射回请求**：CQE 的 wr_id ↔ [work_request_id](src/include/fastblock/msg/rdma/client.h#L1167)（发送时分配）；RECV 则按 [read_correlation_index](src/include/fastblock/msg/rdma/transport_data.h#L155) 找 `_unresponsed_requests`。

---

## 16. 一次完整 4KB Write 串起来（Client → OSD3）

[stub->process_write(ctrlr, req, reply, done)](src/include/fastblock/client/fb_client.h#L1160)（Client 调用点）

↓

[connection::CallMethod()](src/include/fastblock/msg/rdma/client.h#L510)（req_key + [request_meta](src/include/fastblock/msg/rdma/types.h#L82)）

↓

[enqueue_request()](src/include/fastblock/msg/rdma/client.h#L394) → 连接 poller → [process_request_once()](src/include/fastblock/msg/rdma/client.h#L330)

↓

[SerializeToArray → DMA buffer](src/include/fastblock/msg/rdma/transport_data.h#L307)

↓

[make_send_request()（WR 链 + SGE）](src/include/fastblock/msg/rdma/transport_data.h#L425)

↓

[::ibv_post_send(qp, wr)](src/include/fastblock/msg/rdma/socket.h#L370)（**libibverbs 外部 API**）

↓

RNIC → 网络 → OSD3 RNIC → 预先 post 的 RECV WR

↓

[msg::rdma::server 收包反序列化](src/include/fastblock/msg/rdma/server.h#L625)

↓

[按 service_name 查表 → CallMethod 分发](src/include/fastblock/msg/rdma/server.h#L649)

↓

[osd_service::process_write()](src/osd/osd_service.h#L71) → write_reply 原路返回（client [process_response](src/include/fastblock/client/fb_client.h#L932)）

---

## 17. 一次 Raft AppendEntries 串起来

[raft_client_protocol::send_appendentries()](src/raft/raft_client_protocol.cc#L166)（Leader）

↓

[_get_stub → stub->append_entries(...)](src/raft/raft_client_protocol.cc#L172)（`rpc_service_raft_Stub`）

↓

[connection::CallMethod()](src/include/fastblock/msg/rdma/client.h#L510) → RDMA SEND（同上框架）

↓

Follower 端 [msg::rdma::server 分发](src/include/fastblock/msg/rdma/server.h#L649)

↓

[raft_service::append_entries()](src/raft/raft_service.h#L74) → [raft->append_entries_to_buffer()](src/raft/raft_service.h#L120)（进入 Raft，本阶段结束）

---

## 18. 核心函数（统一格式）

### [connection::CallMethod()](src/include/fastblock/msg/rdma/client.h#L510)

- **作用**：RpcChannel 入口：把一次 RPC 调用登记成"待发送任务"，不直接发送。
- **输入**：`method / ctrlr / request / response / done`
- **内部关键步骤**：1) 状态检查；2) 分配 req_key；3) make_request_meta；4) 打包 rpc_request 入队。
- **下一步**：[enqueue_request()](src/include/fastblock/msg/rdma/client.h#L394) → 连接 poller
- **只需搞懂**：CallMethod = 打包登记；发送由 poller 在下一轮做。

### [process_request_once()](src/include/fastblock/msg/rdma/client.h#L330)

- **作用**：真正把消息发出去：序列化 + post WR。
- **内部关键步骤**：1) [serialize_data](src/include/fastblock/msg/rdma/transport_data.h#L283)；2) [send_metadata_request](src/include/fastblock/msg/rdma/client.h#L304)；3) 成功则入 `_unresponsed_requests`。
- **下一步**：[::ibv_post_send](src/include/fastblock/msg/rdma/socket.h#L370)
- **只需搞懂**：ENOMEM 时返回 -EAGAIN 等下一轮（发送压力控制）。

### [handle_cqe()](src/include/fastblock/msg/rdma/client.h#L799)

- **作用**：消费 CQE：SEND 完成记账、RECV 找请求、RDMA READ/WRITE 完成处理。
- **只需搞懂**：RECV 路径如何用 correlation index 找回请求并解析 response。

### [raft_client_protocol::send_appendentries()](src/raft/raft_client_protocol.cc#L166)

- **作用**：Raft 复制消息的发出点：取 stub → `append_entries`。
- **只需搞懂**：与 Client 侧 process_write 走的是**同一个 CallMethod/RDMA 框架**。

---

## 19. 核心概念表

| 名称 | 全称 | 在 FastBlock 中干什么 |
|---|---|---|
| Stub | — | protobuf 生成的远端服务代理；调用转给 RpcChannel（[osd_msg.pb.h#L5579](src/include/fastblock/rpc/osd_msg.pb.h#L5579)） |
| RpcChannel | — | 传输抽象接口；由 RDMA connection 实现（[client.h#L152](src/include/fastblock/msg/rdma/client.h#L152)） |
| RPC | Remote Procedure Call | 把"调函数"变成"发消息 + 回调"；FastBlock 的 RPC 承载 Data 与 Raft 消息 |
| Connection | — | 一条到对端的 RDMA 连接，同时是 RpcChannel（[client.h#L152](src/include/fastblock/msg/rdma/client.h#L152)） |
| RNIC | RDMA Network Interface Card | 网卡硬件：执行 WR、DMA 内存、收发包 |
| QP | Queue Pair | 网卡上的收发队列对；一个 connection 一个 QP |
| SQ | Send Queue | QP 里提交发送 WR 的队列 |
| RQ | Receive Queue | QP 里提交接收 WR 的队列 |
| CQ | Completion Queue | 网卡完成 WR 后写 CQE 的队列（[cq.h#L34](src/include/fastblock/msg/rdma/cq.h#L34)） |
| CQE | Completion Queue Entry | 一条完成记录；按 wr_id/opcode 分发（[client.h#L817](src/include/fastblock/msg/rdma/client.h#L817)） |
| WR | Work Request | 交给网卡的任务（ibv_send_wr/ibv_recv_wr）；[transport_data.h#L425](src/include/fastblock/msg/rdma/transport_data.h#L425) 构造 |
| SGE | Scatter Gather Element | 一段内存描述（addr/length/lkey），WR 的数据来源（[memory_pool.h#L35](src/include/fastblock/msg/rdma/memory_pool.h#L35)） |
| MR | Memory Region | 注册给网卡的内存区；[memory_pool.h#L81](src/include/fastblock/msg/rdma/memory_pool.h#L81) 逐块注册 |
| lkey | Local Key | MR 的本地键：SGE 引用本地内存用 |
| rkey | Remote Key | MR 的远端键：对端 RDMA READ/WRITE 你的内存用（write ring slot 依赖它） |

---

## 20. 推荐阅读顺序

1. **proto service / message**：[osd_msg.proto#L171](proto/osd_msg.proto#L171)、[raft_msg.proto#L256](proto/raft_msg.proto#L256)
2. **Stub**：[osd_msg.pb.h#L5579](src/include/fastblock/rpc/osd_msg.pb.h#L5579)（生成代码）
3. **RpcChannel / CallMethod**：[connection 类](src/include/fastblock/msg/rdma/client.h#L152) → [CallMethod](src/include/fastblock/msg/rdma/client.h#L510)
4. **RDMA connection**：[emplace_connection](src/include/fastblock/msg/rdma/client.h#L1802)、[connect_cache](src/include/fastblock/rpc/connect_cache.h#L28)
5. **Memory Pool / MR**：[memory_pool.h](src/include/fastblock/msg/rdma/memory_pool.h#L45)（注册/借还）
6. **SGE / WR**：[transport_data.h#L283](src/include/fastblock/msg/rdma/transport_data.h#L283)（serialize）→ [L425](src/include/fastblock/msg/rdma/transport_data.h#L425)（make_send_request）
7. **QP**：[socket.h#L786](src/include/fastblock/msg/rdma/socket.h#L786)（create_qp）
8. **post_send**：[socket.h#L370](src/include/fastblock/msg/rdma/socket.h#L370)（`::ibv_post_send`）
9. **CQ polling**：[cq.h#L202](src/include/fastblock/msg/rdma/cq.h#L202) + [client.h#L1714](src/include/fastblock/msg/rdma/client.h#L1714)
10. **Receive path**：[per_post_recv](src/include/fastblock/msg/rdma/client.h#L417) + [handle_cqe](src/include/fastblock/msg/rdma/client.h#L799)
11. **RPC dispatch**：[server.h#L625-655](src/include/fastblock/msg/rdma/server.h#L625)
12. **Client ↔ OSD**：第 16 节链路
13. **OSD ↔ OSD**：[raft_client_protocol.cc#L166](src/raft/raft_client_protocol.cc#L166) + [raft_service.h#L74](src/raft/raft_service.h#L74)

---

## 21. Checklist

- [ ] `stub->process_write()` 为什么实际上是远程调用？（stub 只是代理，内部 `channel_->CallMethod`）
- [ ] Stub 是什么？（protobuf 生成的远端服务代理）
- [ ] RpcChannel 是什么？（传输抽象；由 connection 实现）
- [ ] `CallMethod()` 做了什么？（打包登记：req_key + meta + 入队，不发送）
- [ ] Protobuf request 在哪里序列化？（[transport_data.h#L307](src/include/fastblock/msg/rdma/transport_data.h#L307) SerializeToArray）
- [ ] RPC header 在哪里构造？（[types.h#L82](src/include/fastblock/msg/rdma/types.h#L82) request_meta：service/method/data_size）
- [ ] Connection 是什么？（一条 RDMA 连接 = RpcChannel）
- [ ] QP / CQ / WR / SGE / MR 分别是什么？（见概念表）
- [ ] `lkey / rkey` 分别做什么？（本地键 vs 远端键）
- [ ] FastBlock 在哪里 `post_send`？（[socket.h#L370](src/include/fastblock/msg/rdma/socket.h#L370) `::ibv_post_send`）
- [ ] FastBlock 在哪里 poll CQ？（[cq.h#L202](src/include/fastblock/msg/rdma/cq.h#L202) + client.h:1714）
- [ ] OSD 怎么收到并解析一个 RPC？（server.h:625 反序列化 → correlation index 找请求）
- [ ] RPC 怎么 dispatch 到 `process_write()`？（server.h:649 `service->CallMethod` 按 method 分发）
- [ ] Client ↔ OSD 的完整网络路径？（第 16 节）
- [ ] OSD ↔ OSD 的 Raft RPC 路径？（第 17 节：同一框架）
- [ ] SEND/RECV 和 RDMA WRITE 有什么区别？（SEND 需提前 post RECV；WRITE 直写远端 MR）
- [ ] Write Ring 为什么使用 RDMA WRITE？（数据直达远端预注册 slot，控制走小 RPC）

---

## 22. RDMA 内存 / Buffer / Memory Pool 专题（重点补充）

> 目标：一次 4KB write 中，Client 和 OSD 两侧的数据分别住在哪块内存、谁申请、谁注册、谁发送/接收、什么时候回收。
> **一句话答案先行**：FastBlock 是"**启动/建连时创建并注册 Memory Pool，请求到来时从 Pool 取 Buffer**"；唯一例外是 **Write Ring 路径**——Client 每次请求动态 `spdk_zmalloc + ibv_reg_mr`（见第 22.10 节结论）。

### 22.1 Client 发送 4KB 数据：内存来源全追

```text
bdev iovs（SPDK bdev 的原始 buffer）
↓ ① memcpy 成 std::string
[libblk_client::write()](src/client/libfblock.cc#L97)（iov → data string）
↓ ② 进入 protobuf
[req->set_data(buf)](src/include/fastblock/client/fb_client.h#L1281)（write_request 自己持有这份数据的拷贝）
↓ ③ 序列化进 DMA buffer
[transport_data::serialize_data()](src/include/fastblock/msg/rdma/transport_data.h#L283)：request->SerializeToArray（L307）
        ↓ 目标 = memory_pool 的 element（见下）
↓ ④ SEND
[::ibv_post_send](src/include/fastblock/msg/rdma/socket.h#L370)
```

**逐问回答**：

- **上层 4KB 最初在哪**：SPDK bdev 的 iov buffer（[bdev_fastblock_write](src/bdev/bdev_fastblock.cc#L308) 的 `bdev_io->u.bdev.iovs`）。
- **是否 memcpy**：是，且不止一次——① iov→std::string（libfblock.cc:97-110）；② string→protobuf bytes 字段（fb_client.h:1281，protobuf 内部再持有一份）；③ protobuf→DMA pool element（transport_data.h:307 `SerializeToArray`）。
- **新 buffer 是什么**：①②是临时对象（std::string / protobuf 字段）；③的最终目标是 **`_data_pool` 的 element**——不是 malloc，不是每次新建。
- **最终交给 RDMA 的 buffer 谁创建**：[msg::rdma::client 构造时](src/include/fastblock/msg/rdma/client.h#L1298) 创建 `_data_pool`（8KB element，预注册 MR）；请求到来时 [enqueue_request](src/include/fastblock/msg/rdma/client.h#L394) 创建 [transport_data](src/include/fastblock/msg/rdma/transport_data.h#L73)，由 [init()](src/include/fastblock/msg/rdma/transport_data.h#L677) 计算需要几块并从池里 [get()](src/include/fastblock/msg/rdma/transport_data.h#L598)。
- **每次 RPC 动态申请吗**：**不**。元素从池借，用完由 [~transport_data()](src/include/fastblock/msg/rdma/transport_data.h#L103) 归还（put），池长期存活。

### 22.2 FastBlock 的 RDMA Memory Pool

**存在，且是核心结构**：[memory_pool<work_request_type>](src/include/fastblock/msg/rdma/memory_pool.h#L31)。

| 问题 | 答案 | 证据 |
|---|---|---|
| 在哪创建 | `msg::rdma::client` 构造（Client 侧）、`msg::rdma::server` 构造（OSD 侧）、每连接一个 recv pool | [client.h#L1298-1305](src/include/fastblock/msg/rdma/client.h#L1298) / [server.h#L236-240](src/include/fastblock/msg/rdma/server.h#L236) / [server.h#L397-402](src/include/fastblock/msg/rdma/server.h#L397) |
| 总共多大 | meta: 1024B×N；data: 8192B×N（N 默认 1024，配置可调） | [client.h#L61-64](src/include/fastblock/msg/rdma/client.h#L61) |
| 每个 buffer 多大 | meta element 1024B，data element 8KB，recv element 1024B | 同上 |
| 每核是否有自己的 pool | 是——每 shard 一个 `msg::rdma::client/server`（[connect_cache](src/include/fastblock/rpc/connect_cache.h#L28) 每 shard 建 client；osd.cc 每 shard 建 server） | [connect_cache.h#L28-39](src/include/fastblock/rpc/connect_cache.h#L28) |
| Client 和 OSD 是否各有 pool | 是，各自独立一套 | client.h:1298 / server.h:236 |
| Send/Receive 是否不同 pool | **是**：发送用 `_meta_pool/_data_pool`；接收用 `memory_pool<ibv_recv_wr>`（类型都不同） | [client.h#L496-500](src/include/fastblock/msg/rdma/client.h#L496) |
| 用什么数据结构管理 | `std::list<net_context*>` freelist（get=pop_front / put=push_back） | [memory_pool.h#L119-131](src/include/fastblock/msg/rdma/memory_pool.h#L119) |

### 22.3 MR 是一次注册还是每次注册？

**启动时一次注册，请求复用，不重复 reg/dereg**：

[memory_pool 构造](src/include/fastblock/msg/rdma/memory_pool.h#L45) 里对每个 element 各调一次 [ibv_reg_mr](src/include/fastblock/msg/rdma/memory_pool.h#L81)（`LOCAL_WRITE|REMOTE_WRITE|REMOTE_READ`），此后：

- **MR 保存在哪**：element 的 `net_context.mr`（memory_pool.h:35），连同预填好的 `sge{lkey}` 一起
- **每个 buffer 怎么知道自己的 lkey**：池构造时 `sge.lkey = mr->lkey` 已预填（[L95-97](src/include/fastblock/msg/rdma/memory_pool.h#L95)），SGE 出厂即武装
- **rkey 从哪来**：数据块的 rkey 通过 **RPC metadata 里的 rm_info 表**传给对端（[transport_data.h#L606-613](src/include/fastblock/msg/rdma/transport_data.h#L606) 把 `_datas[i]->mr->addr/rkey` 填进 metadata）
- **释放**：池整体销毁时 dereg（[memory_pool::free](src/include/fastblock/msg/rdma/memory_pool.h#L160)，client.h:1108-1109 / server.h:910-911）

> 唯一例外：Write Ring 路径 Client 侧每请求 reg/dereg（见 22.6）。

### 22.4 SGE 最终指向哪块内存？

以 4KB write 为例（非 inline，因为 4KB > inline 上限 1008B，见 [max_inline_size](src/include/fastblock/msg/rdma/transport_data.h#L482) 与 [init() 的 inline 判断](src/include/fastblock/msg/rdma/transport_data.h#L677)）：

- **addr**：指向 **memory_pool 的 element**（`_data_pool` 8KB 块），不是 Application buffer、不是 protobuf 内部 buffer——`SerializeToArray` 已经把请求体拷进去了（transport_data.h:307）
- **length**：SEND 只发 **metadata WR**（[make_send_request 只用 _metas](src/include/fastblock/msg/rdma/transport_data.h#L425)，头 = [request_meta](src/include/fastblock/msg/rdma/types.h#L82) + rm_info 表）；**真正的 4KB payload 不随 SEND 走**，而是由对端用 metadata 里的 rm_info 通过 **RDMA READ 拉取**（[make_read_request](src/include/fastblock/msg/rdma/transport_data.h#L382)）
- **lkey**：该 element 自己 MR 的 lkey（池预填）

### 22.5 OSD 收数据：内存是谁提前准备的？

**是"提前准备"的**，证据链：

1. 连接建立时创建 recv pool：[server.h#L397-402](src/include/fastblock/msg/rdma/server.h#L397)（`srv_recv_*`，`memory_pool<ibv_recv_wr>`，512 个）
2. 立即批量 [per_post_recv()](src/include/fastblock/msg/rdma/server.h#L327)：`get_bulk(512)` → 逐个 `sock->receive()`（= ibv_post_recv）——**数据来之前 RECV WR 已挂在 QP 上**（同样在 Client 侧，[client.h#L417-443](src/include/fastblock/msg/rdma/client.h#L417)）
3. Client SEND → OSD RNIC 找到已 post 的 RECV WR → **DMA 直接写进 recv pool 的 element**
4. 处理完该请求后 **重新 post**（[server.h#L618](src/include/fastblock/msg/rdma/server.h#L618) `post_recv`；Client 侧同款 [client.h#L962-968](src/include/fastblock/msg/rdma/client.h#L962)）
5. buffer 真正归还 freelist 只在连接关闭时 `put_bulk`（[server.h#L303](src/include/fastblock/msg/rdma/server.h#L303)）——运行期靠"重新 post"循环复用

### 22.6 普通 RPC vs Write Ring 内存路径

**普通 RPC（4KB write 为例）**：

- Client：pool element（`_data_pool`）← 序列化 ← protobuf ← std::string ← bdev iov（**3 次 CPU memcpy**）
  → SEND(metadata + rm_info)
- OSD：recv pool element 收 metadata → [request_data = transport_data(_data_pool)](src/include/fastblock/msg/rdma/server.h#L862) 从 **server 的 data_pool** 借块 → **RDMA READ 从 Client 的 pool element 拉 4KB** → [ParseFromArray 到新 protobuf](src/include/fastblock/msg/rdma/server.h#L616)（request_body）
- buffer 来源：**全部来自各自 pool**；临时对象只有 std::string / protobuf 消息体

**Write Ring**：

- OSD 侧 slot：[create_write_ring](src/osd/osd_service.cc#L61) 时每 slot `spdk_zmalloc`（默认 16×256KB，一次性）+ [ibv_reg_mr(REMOTE_WRITE)](src/osd/osd_service.cc#L83)——**提前注册、租约制复用**，rkey 经 [process_acquire_write_ring](src/osd/osd_service.cc#L327) 告诉 Client
- Client 侧：[post_ring_write](src/include/fastblock/client/fb_client.h#L496) **每次请求** `spdk_zmalloc(4KB 对齐) + ibv_reg_mr(LOCAL_WRITE)`（[L516-534](src/include/fastblock/client/fb_client.h#L516)）→ SerializeToArray（L524）→ RDMA WRITE 到 slot（remote addr/rkey，L560-561）→ 完成回调里 commit RPC（L571）→ [ring_write_context 析构](src/include/fastblock/client/fb_client.h#L87) dereg+free
- OSD：commit 到达后 [ParseFromArray(slot.data)](src/osd/osd_service.cc#L437) → 正常写路径

```text
普通 RPC：Client pool element ──SEND(meta)──▶ OSD recv pool
          Client pool element ◀──RDMA READ── OSD data_pool（拉 4KB payload）

Write Ring：Client 临时 DMA buffer ──RDMA WRITE──▶ OSD slot.data（预注册）
             Client ──commit RPC──▶ OSD（通知 slot N 就绪）
```

### 22.7 Client 与 OSD 两侧内存图

```text
Client
────────────────────────────
bdev iovs（SPDK bdev buffer，非注册）
  ↓ memcpy
std::string（libfblock.cc:97）
  ↓ set_data
protobuf write_request（fb_client.h:1281）
  ↓ SerializeToArray
_data_pool element（8KB，预注册 MR，transport_data.h:307）  ← 最终 SEND/RDMA 用的内存
  ↓ SGE(addr=element, lkey=MR)
WR → ibv_post_send → RNIC
  归还：transport_data 析构 put()（transport_data.h:111）

========= Network =========

OSD
────────────────────────────
RNIC → 预 post 的 RECV WR
  ↓ DMA
recv pool element（1024B，预注册，server.h:397）
  ↓ 解析 metadata → 查 service/method（server.h:556-581）
_data_pool element（server 侧，8KB，RDMA READ 拉 payload，server.h:862）
  ↓ ParseFromArray（server.h:616）
新 protobuf request_body（GetRequestPrototype().New()，server.h:609）→ process_write()
  归还：recv WR 重新 post（server.h:618）；request_data 析构归还 data_pool
```

### 22.8 4KB write 内存生命周期（14 步）

1. **4KB 最初在哪**：bdev iovs（[bdev_fastblock_write](src/bdev/bdev_fastblock.cc#L308)）
2. **Client memcpy ①**：iov → `std::string`（[libfblock.cc#L97-110](src/client/libfblock.cc#L97)）
3. **Client memcpy ②**：→ `write_request.data`（[fb_client.h#L1281](src/include/fastblock/client/fb_client.h#L1281)）
4. **RDMA Send Buffer 从哪来**：`_data_pool->get()`（[transport_data.h#L598](src/include/fastblock/msg/rdma/transport_data.h#L598)，池创建于 [client.h#L1302](src/include/fastblock/msg/rdma/client.h#L1302)）
5. **MR 已注册**：池构造时（[memory_pool.h#L81](src/include/fastblock/msg/rdma/memory_pool.h#L81)），无需每次注册
6. **形成 SGE**：池预填（[memory_pool.h#L95-97](src/include/fastblock/msg/rdma/memory_pool.h#L95)）+ [make_send_request](src/include/fastblock/msg/rdma/transport_data.h#L425)
7. **形成 WR**：同上（IBV_WR_SEND 链）
8. **RNIC 读 Client 内存**：[ibv_post_send](src/include/fastblock/msg/rdma/socket.h#L370)（SEND 只发 metadata；4KB 由对端 READ）
9. **OSD 数据写进哪**：先 recv pool（metadata，[server.h#L397-402](src/include/fastblock/msg/rdma/server.h#L397)）；payload 由 OSD **RDMA READ** 拉进 server `_data_pool` element（[server.h#L862](src/include/fastblock/msg/rdma/server.h#L862)）
10. **OSD Receive Buffer 从哪来**：连接建立时预建 recv pool + 批量 post_recv（[server.h#L327-353](src/include/fastblock/msg/rdma/server.h#L327)）
11. **Receive completion 处理**：CQ → [server 分发](src/include/fastblock/msg/rdma/server.h#L556) → 查 service/method
12. **protobuf 得到 write_request**：[GetRequestPrototype(method).New()](src/include/fastblock/msg/rdma/server.h#L609) + [ParseFromArray](src/include/fastblock/msg/rdma/server.h#L616)——**新对象，从 pool buffer 拷进 protobuf 自有内存**
13. **data 是否再次 copy**：是——ParseFromArray 时 protobuf 内部持有 4KB 拷贝（request_body 生命周期归任务，任务结束 delete）
14. **何时释放**：recv WR 处理完立即重 post（[server.h#L618](src/include/fastblock/msg/rdma/server.h#L618)）；request_data 析构归还 server data_pool；Client 侧 transport_data 析构归还 client `_data_pool`（[transport_data.h#L103-112](src/include/fastblock/msg/rdma/transport_data.h#L103)）

### 22.9 Buffer 生命周期表

| Buffer | 谁创建 | 创建时间 | 是否 MR | 用途 | 什么时候释放/归还 |
|---|---|---|---|---|---|
| Application Buffer（bdev iovs） | SPDK bdev 模块 | IO 到达时 | 否 | 上层数据源 | bdev_io_complete 后 |
| std::string（libfblock.cc:97） | `libblk_client::write` | 每次 write | 否 | 拼装 iov | 函数返回后（临时对象） |
| protobuf `write_request` | `write_object`（fb_client.h:1276） | 每次 write | 否 | 请求消息体 | 请求栈帧释放时 |
| RDMA Send Buffer（pool element） | `msg::rdma::client`（client.h:1302） | **启动时** | **是（一次）** | 序列化+RDMA 发送 | transport_data 析构 put()（transport_data.h:111） |
| RDMA Receive Buffer（recv pool element） | `client/server` 建连时（client.h:496 / server.h:397） | **建连时** | **是（一次）** | RNIC DMA 落点 | 重 post 循环复用；关连接 put_bulk（server.h:303） |
| Write Ring Buffer（Client 侧） | `post_ring_write`（fb_client.h:517） | **每次请求** | **是（每次）** | RDMA WRITE 数据源 | [ring ctx 析构 dereg+free](src/include/fastblock/client/fb_client.h#L87) |
| Write Ring slot（OSD 侧） | `create_write_ring`（osd_service.cc:61） | **acquire 时一次性** | **是（一次）** | 远端 RDMA WRITE 落点 | [slot 析构 dereg+free](src/osd/osd_service.cc#L52) + 租约过期清理 |

### 22.10 特别回答：动态分配还是 Memory Pool？

```text
Client 普通 RPC：Memory Pool（_data_pool/_meta_pool，启动时创建+注册，请求取/还）
OSD 普通 Receive：Memory Pool（recv_pool 建连时创建+注册+批量 post_recv；大 payload
                 用 server data_pool + RDMA READ 拉取）
Client Write Ring：动态分配（每次请求 spdk_zmalloc + ibv_reg_mr，用完 dereg+free）
OSD Write Ring：预分配（acquire 时一次性 16×256KB 注册，租约制复用，过期释放）
```

**总结论**：热路径主体是"**启动/建连时创建并注册 Pool，请求到来从 Pool 取 Buffer**"；只有 Client 的 Write Ring 发送 buffer 是唯一"每次请求动态 malloc + 注册"的地方。两条路径的 buffer 全部独立（详见第 22.9 表），不存在跨路径共享。

---

## 下一阶段（可选）

深入 `msg/rdma` 剩余部分：provider（verbs/mlx5dv 差异）、pd/device 管理、连接事件（rdma_cm）、写 ring 完整实现；或进入 OSD 内部 Raft 与存储的衔接。