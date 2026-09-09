# FastBlock 源码阅读路线

> 目标：沿着一次完整 Write Path，从 Client 一直追到 OSD、Raft、LocalStore、SPDK/NVMe，最后再研究控制面、故障恢复和性能。

---

## 1. README / 整体架构 ✅

目标：

* 理解 FastBlock 是什么
* 理解系统整体组件
* 建立完整架构图

核心概念：

```text
Client
PG
OSD
Raft
Monitor
RDMA
SPDK
NVMe
```

整体数据路径：

```text
Application / VM
↓
Client
↓
Object
↓
PG
↓
Leader OSD
↓
Raft
↓
LocalStore
↓
SPDK
↓
NVMe SSD
```

状态：**已完成**

---

## 2. `src/client/` ✅

目标：

理解一次上层 IO 是怎么经过 Client，最终发送到目标 OSD，并处理完成回调。

### 2.1 Image → Object

理解：

```text
Image offset
↓
Object
↓
Object offset
```

包括：

* Image 如何切分成 Object
* Object 序号怎么计算
* Object 内 offset 怎么计算
* 跨 Object IO 怎么拆分
* Object name 怎么生成

---

### 2.2 Object → PG

理解：

```text
Object
↓
Hash
↓
PG
```

包括：

* `calc_target()`
* Object 如何映射到 PG
* PG 数量从哪里获得

---

### 2.3 PG → Leader OSD

理解：

```text
PG
↓
PG 成员 OSD
↓
查询 Leader
↓
Leader OSD
```

包括：

* Leader cache
* PG 成员从哪里获得
* 第一个可用 OSD
* get leader RPC
* `leader_id`
* `leader_addr`
* `leader_port`

---

### 2.4 请求队列 / Poller

理解：

```text
send_request()
↓
request_stack_type
↓
_requests
↓
Poller
↓
process_request()
↓
get_stub()
```

包括：

* `_requests`
* `_on_flight_requests`
* `request_stack_type`
* SPDK Poller
* `process_request()`

---

### 2.5 Data RPC / RDMA

理解：

```text
stub->process_write()
↓
RPC Stub
↓
RpcChannel
↓
RDMA Connection
↓
发送到 OSD
```

包括：

* protobuf RPC
* RDMA connection
* Stub / Channel
* Write Ring
* 请求真正发送

---

### 2.6 Response / Completion

理解：

```text
OSD Response
↓
on_response()
↓
process_response()
↓
write callback
↓
write_source
↓
spdk_bdev_io_complete()
```

包括：

* 请求完成
* 错误重试
* Leader 变化
* 多 Object completion 聚合
* 最终通知上层

状态：**已完成**

---

## 3. Object → PG → OSD / Leader 映射 ✅

这一部分已经在 Client 阶段基本完成。

核心关系：

```text
Object
↓
PG
↓
PG Members
↓
PG Leader
↓
OSD
```

状态：**基本完成**

---

# 4. `src/osd/`

目标：

理解 Client 请求到达 OSD 后，怎么一路进入 PG 和 Raft。

主线：

```text
Client RPC
↓
OSD RPC Service
↓
process_write()
↓
找到 PG
↓
进入 PG State Machine
↓
Leader 检查
↓
转交给 Raft
```

重点：

### 4.1 Client RPC 怎么进入 OSD

理解：

```text
RDMA RPC
↓
OSD Service
↓
process_write()
```

### 4.2 OSD 怎么找到对应 PG

理解：

```text
pool_id + pg_id
↓
PG Manager / partition_manager
↓
对应 PG
```

### 4.3 PG 请求怎么进入状态机

理解：

```text
PG
↓
osd_stm
↓
write request
```

### 4.4 怎么转交给 Raft

理解：

```text
write
↓
State Machine
↓
Raft API
↓
进入 src/raft/
```

---

# 5. `src/raft/`

目标：

理解一个 PG 对应的 Raft Group 如何完成一次写操作。

主线：

```text
OSD Write
↓
Raft Propose
↓
Append Log
↓
Replicate
↓
Majority
↓
Commit
↓
Apply
```

重点：

### 5.1 PG 对应的 Raft Group

理解：

```text
PG
≈
Raft Group
```

### 5.2 Propose

理解 Client write 如何变成 Raft 操作。

### 5.3 Append

理解 Raft Log 怎么生成。

### 5.4 Replicate

理解：

```text
Leader
↓
Followers
```

日志如何复制。

### 5.5 Commit

理解多数派确认以后怎么提交。

### 5.6 Leader / Follower

理解不同节点在一个 PG 中的角色。

### 5.7 Apply

理解：

```text
Committed Log
↓
State Machine Apply
```

并追到 LocalStore 边界。

---

# 6. `src/localstore/`

目标：

理解 Raft Log 和真正的 Object 数据怎么落到本地 SSD。

核心结构：

```text
LocalStore
├── disk_log
├── object_store
└── kv_store
```

### 6.1 `disk_log`

理解：

```text
Raft Log
↓
disk_log
↓
SPDK Blob
```

重点：

* Raft log 怎么落盘
* PG 和 log blob 的关系

### 6.2 `object_store`

理解：

```text
State Machine Apply
↓
Object Store
↓
Object 数据
```

重点：

* Object 怎么创建
* Object 怎么读写
* offset 怎么处理
* 是否存在 RMW

### 6.3 `kv_store`

理解：

* 本地 metadata
* Raft / PG 相关状态
* 每核存储设计

---

# 7. SPDK / NVMe

目标：

理解 FastBlock 最终怎么把数据真正写进 NVMe SSD。

主线：

```text
LocalStore
↓
SPDK Blobstore
↓
SPDK IO
↓
NVMe
↓
SSD
```

重点：

### 7.1 Blobstore

理解：

* Blob 是什么
* Blobstore 怎么管理数据

### 7.2 DMA Buffer

理解：

```text
Memory
↓
DMA
↓
NVMe Device
```

### 7.3 SPDK IO

理解：

* 异步 IO
* Polling
* Reactor
* Per-core

### 7.4 NVMe 真正落盘

理解：

```text
SPDK
↓
NVMe Command
↓
PCIe
↓
NVMe SSD
```

---

# 8. `src/rpc/` + `src/msg/`

目标：

深入理解 FastBlock 网络通信层。

主线：

```text
Client / OSD
↓
protobuf RPC
↓
RDMA
↓
RNIC
↓
Network
↓
Remote OSD
```

重点：

### 8.1 RDMA Connection

理解连接建立和管理。

### 8.2 Protobuf RPC

理解：

```text
Stub
↓
RpcChannel
↓
CallMethod()
```

### 8.3 RDMA 核心概念

理解：

```text
QP
CQ
WR
SGE
MR
```

### 8.4 网络路径

分别理解：

```text
Client ↔ OSD
```

以及：

```text
OSD ↔ OSD
```

---

# 9. Monitor / `monclient`

目标：

理解 FastBlock 控制面。

主线：

```text
Monitor
↓
Cluster Map
↓
Client / OSD
```

重点：

### 9.1 OSDMap

理解：

* 有哪些 OSD
* OSD 是否 up
* OSD 是否 in

### 9.2 PGMap

理解：

```text
PG
↓
哪些 OSD
```

### 9.3 Pool / Image Metadata

理解：

* Pool
* Image
* PG 数量
* Image 信息

### 9.4 Client / OSD 怎么获得 Cluster Map

理解：

```text
Monitor
↓
monclient
↓
本地缓存
```

---

# 10. 故障恢复

目标：

理解正常 Write Path 之外，系统发生故障时怎么工作。

### 10.1 Leader 切换

```text
Leader Down
↓
Election
↓
New Leader
```

### 10.2 OSD Down

理解：

* Monitor 怎么发现
* Map 怎么变化
* Client 怎么感知

### 10.3 Raft Recovery

理解节点恢复以后怎么重新加入。

### 10.4 Follower Catch-up

理解：

```text
Follower 落后
↓
同步 Raft Log
↓
追上 Leader
```

### 10.5 PG 恢复

理解：

* 副本恢复
* 数据同步
* PG 状态变化

---

# 11. 性能分析

前面的代码路径全部理解以后，再开始性能分析。

主线：

```text
一次 4KB Write
↓
到底消耗了多少：
CPU
Memory
Network
NVMe IO
```

重点：

### 11.1 `memcpy`

检查：

* 一次 IO 被复制多少次
* 哪些 copy 可以消除

### 11.2 Allocation

检查：

```text
new/delete
malloc/free
spdk_zmalloc
std::string
```

是否出现在热路径。

### 11.3 Batching

检查：

* Raft batching
* RPC batching
* RDMA batching
* CQ polling batching

### 11.4 Cross-core

检查：

```text
CPU0
↓
CPU1
```

是否存在频繁跨核通信。

### 11.5 NUMA

检查：

```text
CPU
RNIC
NVMe
Memory
```

是否位于同一 NUMA Node。

### 11.6 RDMA

检查：

* send 次数
* WR 数量
* memory registration
* zero-copy
* write ring

### 11.7 Raft 开销

检查：

```text
Client Write
↓
Leader
↓
Follower
↓
Commit
```

带来的 CPU / 网络 / 延迟成本。

### 11.8 p99 Latency

重点关注：

```text
p50
p95
p99
p99.9
```

而不仅仅是平均延迟。

---

# 12. 完整 Write Path 总结

最后重新从头走一遍一次 4KB Write。

目标是能够不看源码画出：

```text
Application / VM
↓
SPDK bdev
↓
libblk_client
↓
Image offset
↓
Object
↓
PG
↓
PG Leader OSD
↓
Data RPC / RDMA
↓
OSD RPC Service
↓
找到 PG
↓
PG State Machine
↓
Raft Propose
↓
Raft Log
↓
Follower Replication
↓
Majority
↓
Commit
↓
State Machine Apply
↓
LocalStore
↓
Object Store
↓
SPDK Blobstore
↓
NVMe
↓
SSD
↓
Response
↓
Client Completion
↓
Application
```

---

# 当前学习进度

```text
1. README / 整体架构                  ✅
2. src/client/                       ✅
3. Object → PG → OSD / Leader        ✅
4. src/osd/                          ← 当前
5. src/raft/
6. src/localstore/
7. SPDK / NVMe
8. src/rpc/ + src/msg/
9. Monitor / monclient
10. 故障恢复
11. 性能分析
12. 完整 Write Path 总结
```

当前下一步：

```text
src/osd/
↓
Client RPC 怎么进入 OSD
↓
OSD 怎么找到 PG
↓
PG 怎么进入 State Machine
↓
怎么转交给 Raft
```
