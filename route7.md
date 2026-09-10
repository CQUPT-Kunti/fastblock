# FastBlock 第七阶段：SPDK / NVMe（一次 IO 如何到达 NVMe SSD）

> **前置**：上一阶段已追到 [spdk_blob_io_write()](src/localstore/object_store.cc#L644)、[spdk_blob_io_writev()](src/localstore/rolling_blob.h#L186)、[spdk_bs_create_blob_ext()](src/localstore/object_store.cc#L578) 等 **SPDK API 调用点**。
> **本阶段范围**：理解这些 API 之后发生了什么——Blobstore / bdev / NVMe driver / DMA / SQ/CQ。到"NVMe 完成 → SPDK 回调 FastBlock"为止。
> **重要分层**：FastBlock 仓库内代码用**可点击的相对路径链接**；SPDK 是**外部依赖**（vcpkg port 声明版本 24.01，源码不在本工作区），其内部一律标注"外部 SPDK API"，不提供虚假本地路径。
> **链接说明**：相对路径 + `#L行号` 的链接在 VSCode 中可点击；`↓` 表示调用方向；"外部 SPDK API" 表示该函数属于 SPDK，不在本仓库。

---

## 1. 本阶段四块内容

| 小节 | 主题 | 一句话目标 |
|---|---|---|
| 7.1 | Blobstore | Blob 是什么、blob offset 怎么映射到盘上空间 |
| 7.2 | DMA Buffer | 数据为什么必须放在特殊内存、谁搬数据 |
| 7.3 | SPDK IO | 异步 + Polling + Reactor/Thread/Poller 模型 |
| 7.4 | NVMe 落盘 | SQ/CQ、NVMe Command、PCIe DMA 到 SSD |

---

## 2. 从 FastBlock 与 SPDK 的边界开始

FastBlock 侧的真实调用点（全部可点击）：

- [object_store::write()](src/localstore/object_store.cc#L131) → [object_store::blob_readwrite()](src/localstore/object_store.cc#L607) → **spdk_blob_io_write()**（[调用点 object_store.cc#L644](src/localstore/object_store.cc#L644)）
- [disk_log::append()](src/localstore/disk_log.h#L89) → [rolling_blob::append()](src/localstore/rolling_blob.h#L156) → **spdk_blob_io_writev()**（[调用点 rolling_blob.h#L186](src/localstore/rolling_blob.h#L186)）
- [create_blob()](src/localstore/object_store.cc#L538) → **spdk_bs_create_blob_ext()**（[调用点 :L578](src/localstore/object_store.cc#L578)）、**spdk_bs_open_blob()**（[:L762](src/localstore/object_store.cc#L762)）
- [kvstore](src/localstore/kv_store.cc#L76) 和 [log](src/localstore/disk_log.cc#L77) 底层都是 [rolling_blob](src/localstore/rolling_blob.h#L128)（内部包一个 `spdk_blob*`）

**整体层级**（FastBlock 之上全是 SPDK，标注外部）：

```text
FastBlock LocalStore（disk_log / object_store / kv_store）
↓  调用
SPDK Blobstore      ← 外部 SPDK API（blob/ blobfs 组件）
↓
SPDK bdev           ← 外部 SPDK API（bdev 组件）：块设备抽象
↓
SPDK NVMe driver    ← 外部 SPDK API（nvme 组件）：用户态 NVMe 驱动
↓
NVMe Controller（硬件）
↓
SSD（NAND Flash）
```

FastBlock 通过 pkg-config 链接这些 SPDK 组件（[Findspdk.cmake](cmake/Findspdk.cmake) 列出的 `blob / bdev / nvme / thread / env_dpdk / event` 等）。

---

## 3. 7.1 Blob 与 Blobstore

### Blob 是什么

**Blob 不是物理 SSD 上连续的一段空间**。它是 Blobstore 对外暴露的"逻辑大文件"抽象：一个 blob 有 id（`spdk_blob_id`，FastBlock 的 [fb_blob](src/localstore/types.h#L27) 保存它）、xattr、可读写的逻辑地址空间。底层空间由 Blobstore 按 **cluster**（如 1MB）分配，**可以分布在设备任意位置**——FastBlock 不必关心物理布局。

### Blobstore 管什么

Blobstore 是 SPDK 的**用户态对象存储层**（对应 SPDK `blob` 组件），负责：blob 创建/打开/删除、空间分配（cluster）、元数据（xattr）持久化、以及把 blob 逻辑偏移翻译成底层块设备的偏移。

### FastBlock 实际用到的 API 对照

| 操作 | FastBlock 调用点 | 属于 |
|---|---|---|
| 创建 blob | [spdk_bs_create_blob_ext](src/localstore/object_store.cc#L578)（4MB object blob）；log blob 由 [make_rolling_blob](src/localstore/disk_log.cc#L77) 创建 | 外部 SPDK API |
| 打开 blob | [spdk_bs_open_blob](src/localstore/object_store.cc#L762) | 外部 SPDK API |
| 删除 blob | [spdk_bs_delete_blob](src/localstore/object_store.cc#L487) | 外部 SPDK API |
| 读写 | [spdk_blob_io_write/read](src/localstore/object_store.cc#L644)；[spdk_blob_io_writev/readv](src/localstore/rolling_blob.h#L186) | 外部 SPDK API |
| 元数据同步 | [spdk_blob_sync_md](src/localstore/object_store.cc#L564) | 外部 SPDK API |

### Cluster / Page

- **Page**：Blobstore 内部 I/O 的最小单位（4KB 默认）；FastBlock 的数据天然 4KB 对齐（[raft_log.h#L61](src/raft/raft_log.h#L61) 强制）。
- **Cluster**：空间分配单位。FastBlock object blob 用 `num_clusters = 4`、cluster 1MB → **4MB 一个 blob**（[object_store.h#L31-33](src/localstore/object_store.h#L31)）。

### blob offset → 底层位置

FastBlock 把**字节 offset 转成 512B LBA** 交给 blob（[get_page_parameters](src/localstore/object_store.h#L125) + [调用点](src/localstore/object_store.cc#L627)）。Blobstore 内部再把 blob 的逻辑位置换算成 bdev 层偏移——**这一层在 SPDK 内部完成，本仓库无法贴源码，属于外部 SPDK API（blobstore 内部逻辑）**。

---

## 4. 从 `spdk_blob_io_write()` 继续往下（SPDK 内部，标注外部）

FastBlock 只能确认调用边界。边界之后 SPDK 内部典型路径（对应 SPDK 24.01 文档化的结构）：

[object_store::blob_readwrite()](src/localstore/object_store.cc#L607)

↓

**spdk_blob_io_write()**（外部 SPDK API，blob.h）——校验后转成 blobstore 内部 IO

↓

**blobstore 内部**：把 blob 逻辑 LBA → 该 blob 占用的 cluster → 底层 bdev 的物理偏移（外部 SPDK API，`blobstore.c`，本仓库无此文件）

↓

**spdk_bdev_io_write()**（外部 SPDK API，bdev 层）——bdev 是"块设备抽象层"：统一 NVMe / virtio / 文件等后端，负责 IO 拆分、channel 分发、回调

↓

**spdk_nvme_ns_cmd_write()**（外部 SPDK API，nvme 驱动层）——构造 NVMe Write Command（含 LBA、长度、内存地址），提交到 NVMe 队列

↓

**NVMe Controller**（硬件）

> **明确分层**：FastBlock 仓库能看到的只有 `spdk_blob_*` 这一层 API 的**调用点**；`spdk_blob_io_write` 内部、bdev、NVMe driver 全部是外部 SPDK API，不在本仓库。引用：SPDK 官方文档 [blob](https://spdk.io/doc/blob.html) / [bdev](https://spdk.io/doc/bdev.html) / [nvme](https://spdk.io/doc/nvme.html)。

---

## 5. 7.2 DMA 与 DMA Buffer

### DMA 是谁在搬数据

**DMA = Direct Memory Access（直接内存访问）**。搬数据的是 **NVMe Controller（+ PCIe 总线）**，不是 CPU。

一次 4KB write 的内存侧过程：

```text
CPU 构造 NVMe Write Command（LBA=8, 长度=8×512B, 内存地址=0x100000）
↓ 提交到 SQ
NVMe Controller 从 SQ 取走命令
↓
Controller 通过 PCIe DMA 主动读取 0x100000 处 4KB 数据
↓
Controller 把数据写入 SSD（NAND）
↓ 完成后把 Completion 放入 CQ
CPU 轮询 CQ 发现完成 → 执行 callback
```

**CPU 负责**：准备命令、把内存地址和长度告诉控制器、轮询完成。**CPU 不复制数据**。

### 为什么不能随便用 `malloc()` 内存

NVMe Controller 通过 PCIe 访问内存，它看到的是**物理地址**。普通 `malloc()` 的内存是虚拟地址、可能被换出、页也不固定——控制器要么读不到，要么读到错误页。所以 DMA buffer 需要：

1. **物理地址可访问**（注册给设备，如 DPDK 的 rte_malloc/hugepage）
2. **pinned / 大页**（不被换出）
3. **对齐**（如 4KB、512B 对齐，满足 NVMe PRP 要求）

### `spdk_malloc()/spdk_zmalloc()` 的意义

它们是 SPDK/DPDK 的"**DMA 安全内存分配器**"：从 hugepage 分配、物理连续（或可拆成 PRP 页）、按指定对齐、且**注册后可直接给设备用**。FastBlock 里大量使用：

| 位置 | 用途 |
|---|---|
| [osd_stm::write_obj](src/osd/osd_stm.cc#L81) `spdk_zmalloc(len, 0x1000, ..., SPDK_MALLOC_DMA)` | 对象写数据 buffer，4KB 对齐 DMA 内存 |
| [object_store::blob_readwrite](src/localstore/object_store.cc#L660) `spdk_malloc(pin_buf_length, lba_size, ...)` | 非对齐 RMW 的 pin buffer |
| [memory_pool 构造](src/include/fastblock/msg/rdma/memory_pool.h#L56) `spdk_zmalloc(element_size*capacity, 0x1000, ..., SPDK_MALLOC_DMA)` | RDMA 注册内存（同一块内存兼顾 DMA） |
| [post_ring_write](src/include/fastblock/client/fb_client.h#L517) `spdk_zmalloc(alloc_size, 0x1000, ...)` | write ring 的发送 buffer |

---

## 6. 7.3 异步 IO

```cpp
// FastBlock 的调用形态（以 object_store 为例）
spdk_blob_io_write(blob, channel, buf, start_lba, num_lba, rw_done, ctx);   // 提交
// 函数立即返回；SSD 执行期间 CPU 去干别的
// 完成 → rw_done(ctx, errno) 被调用                                  ← completion
```

FastBlock 中的真实异步例子：

| 环节 | FastBlock 代码 |
|---|---|
| 提交 | [spdk_blob_io_write(..., rw_done, ctx)](src/localstore/object_store.cc#L644) |
| completion callback | [object_store::rw_done()](src/localstore/object_store.cc#L679)（随后 [cb_fn(ctx->arg, 0)](src/localstore/object_store.cc#L720) 回 FastBlock） |
| context | `blob_rw_ctx`：保存 object_name/offset/buf/len/cb_fn/arg（[object_store.cc#L615-625](src/localstore/object_store.cc#L615)） |

**为什么异步**：SSD 一次 IO 要几十到几百微秒；如果同步等待，CPU 核就空转了。异步 = **提交后立即返回，完成时回调**，同一核可以同时"在途"很多 IO，靠 context 区分谁是谁。FastBlock 全链路（client → osd → raft → localstore）都是这种"提交 + 回调"模式，context 就是每一层的 [request_stack_type](src/include/fastblock/client/fb_client.h#L79)、[osd_service_complete](src/osd/osd_stm.cc#L108) 等。

---

## 7. 7.3 Polling（轮询）

传统中断路径：

```text
SSD 完成 → 中断 → 内核 → 唤醒应用 → 上下文切换
```

SPDK 轮询路径：

```text
CPU Core 上不断执行 poller → 查 CQ 有没有 completion → 有 → 立刻执行 callback
```

- **为什么少用中断**：中断 + 内核切换的延迟（微秒级）和不确定性在存储场景不可接受；轮询把"完成检测"变成一次内存读。
- **代价**：CPU 永远在跑（持续消耗一个核），所以 SPDK 通常要求**独占核**。
- **FastBlock 与 SPDK polling 的关系**：FastBlock 本身不碰 NVMe CQ，它借 SPDK 的 reactor 周期执行自己的 poller：
  - Client 侧三个 poller（[fbcli_leader / fbcli_request / fbcli_response](src/include/fastblock/client/fb_client.h#L837)），周期 0 = 每轮都跑
  - OSD 侧 [apply_task](src/raft/state_machine.cc#L19)（apply 驱动，[SPDK_POLLER_REGISTER](src/raft/state_machine.cc#L30)）
  - [simple_poller](src/include/fastblock/utils/simple_poller.h#L100) 包装了 [SPDK_POLLER_REGISTER](src/include/fastblock/utils/simple_poller.h#L76)
  - 它们的运行节奏与 SPDK 的 reactor 轮询循环完全一致——**FastBlock 的 poller 就是跑在 SPDK 的轮询框架里**。

---

## 8. 7.3 Reactor / SPDK Thread / CPU Core

```text
CPU Core（物理执行单元）
↓ 运行一个
SPDK Reactor（该核上的事件循环：反复执行所有已注册 poller）
↓ 管理若干
SPDK Thread（轻量线程，不是 pthread！）
↓ 上面挂着
Poller（spdk_poller*，由 spdk_thread_send_msg / SPDK_POLLER_REGISTER 注册）
↓ 驱动
IO
```

| 概念 | 是什么 |
|---|---|
| CPU Core | 物理/逻辑执行资源；SPDK 建议一个核只跑一个 reactor |
| Reactor | 该核上的主循环：每轮把该线程上所有 poller 跑一遍，也处理 `spdk_thread_send_msg` 投递的消息 |
| SPDK Thread | **不是 pthread**：是 reactor 内的事件调度结构（`struct spdk_thread`），有自己的一组 poller 和消息队列；多个 SPDK thread 可以跑在同一个 reactor 上，靠 `spdk_thread_send_msg` 互相投递任务。FastBlock 里每个 shard 一个 thread（[core_sharded](src/include/fastblock/base/core_sharded.h)），跨线程投递用 [spdk_thread_send_msg](src/include/fastblock/client/fb_client.h#L727) |
| Poller | 注册到某个 SPDK thread 上的回调（周期 0 = 每轮执行）；谁注册就在谁的 thread 上跑 |
| Per-core | FastBlock/SPDK 按核划分：每核自己的 PG、自己的 [IO channel](src/localstore/blob_manager.h#L46)、自己的队列——避免了全局锁和跨核通信 |

FastBlock 的 per-core 证据：[storage_manager 每核一个](src/localstore/storage_manager.h#L38)、[global_blobstore(shard_id)](src/localstore/blob_manager.h#L44)、[blob_tree 每 shard 一个](src/localstore/blob_manager.cc#L29)。

---

## 9. 7.3 IO Channel

**IO Channel 是什么**：SPDK 的"per-thread 访问某个设备的上下文"（`struct spdk_io_channel`），每个 SPDK thread 访问同一个设备时会各自创建/获取一个 channel。

**FastBlock 的证据**：

- [object_store 构造](src/localstore/object_store.h#L40) 接收外部传入的 `struct spdk_io_channel *channel`（注释明确：channel 必须外部传入，不能在内部 alloc，否则 blobstore 无法正常 unload）
- channel 来自 [global_io_channel(shard_id)](src/localstore/blob_manager.h#L46)，创建时 [spdk_bs_alloc_io_channel(blobstore)](src/localstore/blob_manager.cc#L52)——**每 shard 一个**，因此 blob IO 都在本核的 channel 上执行

**channel 与 NVMe queue pair 的关系**：**不是一一对应**。channel 是软件层的 per-thread 上下文；NVMe QP 是硬件队列。SPDK 的 bdev/NVMe 层会把 channel 映射到某个 QP（通常多个 channel 共享/分片到少数几个 QP）。这一层映射在 SPDK 内部，**源码不足以在本仓库确认具体映射策略**，只能确认：channel 保证"一个线程的 IO 走固定的上下文"，从而减少锁。

---

## 10. 7.4 NVMe Queue（SQ / CQ）

```text
SPDK NVMe driver
↓ 构造 NVMe Write Command（opcode=Write, LBA, 长度, 数据内存地址）
↓ 写入
Submission Queue (SQ)     ← 主机→控制器：命令队列
↓ Controller 取走命令，通过 PCIe DMA 读数据
↓ 执行写入
Completion Queue (CQ)     ← 控制器→主机：完成队列
↓ SPDK 轮询 CQ 发现完成（一个 CQE）
↓ 找到对应的 pending IO（靠 command id）
↓ 执行 callback（如 FastBlock 的 rw_done）
```

- **SQ**：命令提交队列（主机写，控制器读）
- **CQ**：完成队列（控制器写，主机轮询读）
- **Queue Pair**：一个 SQ + 一个 CQ 组成一对；`nvme` 组件里典型是 `spdk_nvme_qpair`
- **为什么 NVMe 支持很多队列**：NVMe 协议支持最多 64K 队列对，每条队列独立编址——**每个核可以有自己的 QP**，互不干扰，天然适配多核轮询模型（这就是 SPDK 能 per-core 轮询的硬件基础）

---

## 11. NVMe Command 里最重要的内容

一次 Write 的核心信息（NVMe Write Command）：

```text
Opcode = Write
Namespace ID
LBA（起始逻辑块地址）
Length（块数，如 8 × 512B = 4KB）
数据在主机内存的位置：PRP 或 SGL
```

**PRP / SGL**：NVMe Controller 怎么知道数据在哪——

- **PRP（Physical Region Page）**：指向物理内存页的地址列表（每页 4KB），一页连续就直接一个 PRP1，跨页就加 PRP List
- **SGL（Scatter-Gather List）**：更灵活的内存段描述列表

因为 `spdk_zmalloc(..., 0x1000, ...)` 保证了 4KB 对齐的物理页，SPDK 可以直接生成整齐的 PRP。这一层完全在外部 SPDK API（nvme 组件）内部。

---

## 12. PCIe 的角色

```text
SPDK = 软件框架（用户态库）
NVMe = 协议（SSD 的通信语言：命令/队列/寄存器）
PCIe = 总线（CPU↔内存↔NVMe Controller 之间的物理高速通道）
NVMe SSD = 硬件设备（含 Controller + NAND）
```

DMA 路径：

```text
RAM（4KB 数据，物理地址 0x100000）
↓  PCIe DMA（Controller 主动读）
NVMe Controller
↓
NAND Flash
```

PCIe 提供的是**地址空间共享 + DMA 能力**：Controller 可以直接读写主机内存，不需要 CPU 中转——这就是"数据不经过 CPU 拷贝"的物理基础。

---

## 13. 一次 FastBlock 4KB Write 完整串起来

```text
前提：4KB 对齐写，Object Blob 已存在（无创建/无 RMW）
```

- [object_store::write()](src/localstore/object_store.cc#L131)
  ↓
- [object_store::readwrite()](src/localstore/object_store.cc#L512)（table 命中）
  ↓
- [object_store::blob_readwrite()](src/localstore/object_store.cc#L607)（对齐 → 直写）
  ↓
- [spdk_blob_io_write(blob, channel, buf, lba, nblks, rw_done, ctx)](src/localstore/object_store.cc#L644) ← **FastBlock 调用边界**
  ↓
- 外部 SPDK API：blobstore 内部（blob 逻辑 LBA → cluster → bdev 偏移）
  ↓
- 外部 SPDK API：bdev 层（[spdk_bdev_io_write](https://spdk.io/doc/bdev.html)）
  ↓
- 外部 SPDK API：NVMe driver（[spdk_nvme_ns_cmd_write](https://spdk.io/doc/nvme.html)，构造命令 + PRP）
  ↓
- 提交到 NVMe SQ（外部 SPDK API / 硬件）
  ↓
- **NVMe Controller 通过 PCIe DMA 读取 4KB buffer → 写入 NAND**
  ↓
- Completion 放入 CQ（硬件）
  ↓
- SPDK 轮询 CQ → 找到对应 IO（外部 SPDK API）
  ↓
- [object_store::rw_done()](src/localstore/object_store.cc#L679)（SPDK 回调 FastBlock）
  ↓
- [cb_fn(ctx->arg, 0)](src/localstore/object_store.cc#L720) → [write_obj_done](src/osd/osd_stm.cc#L52) → 上层完成

> **以下属于 SPDK，不属于 FastBlock**：`spdk_blob_io_write` 内部、bdev 层、NVMe driver、PRP/SGL 生成、CQ 轮询。FastBlock 只提供 buffer、offset、长度、回调。

---

## 14. 核心函数（统一格式）

### [object_store::blob_readwrite()](src/localstore/object_store.cc#L607)

- **作用**：FastBlock 最后一层：字节 offset/len → LBA，对齐则直写，非对齐走 RMW。
- **输入**：`blob / channel / buf / offset / len / cb_fn / arg`
- **内部关键步骤**：1) [get_page_parameters](src/localstore/object_store.cc#L627)；2) [is_lba_aligned](src/localstore/object_store.h#L117) 判定；3) 提交或先读。
- **下一步**：[spdk_blob_io_write()](src/localstore/object_store.cc#L644)（外部 SPDK API）
- **只需搞懂**：FastBlock 侧 DMA buffer 从哪来（[osd_stm.cc#L81](src/osd/osd_stm.cc#L81) 的 spdk_zmalloc），LBA 怎么算。

### [object_store::rw_done()](src/localstore/object_store.cc#L679)

- **作用**：SPDK 完成回调 → FastBlock 恢复现场并继续上层回调。
- **输入**：`blob_rw_ctx*`（含 cb_fn/arg）
- **内部关键步骤**：1) 检查 errno；2) 释放 pin_buf；3) [cb_fn(ctx->arg, 0)](src/localstore/object_store.cc#L720)。
- **只需搞懂**：ctx 就是"异步上下文"——完成时凭它找回是谁的请求。

### [rolling_blob::append()](src/localstore/rolling_blob.h#L156)

- **作用**：日志环形写的封装：空间检查 + 一次/两次写 + 位置记账。
- **下一步**：[spdk_blob_io_writev()](src/localstore/rolling_blob.h#L186)（外部 SPDK API）
- **只需搞懂**：绕回时拆两次写；`available()` 决定能否写。

---

## 15. 本阶段核心概念表

| 名称 | 简单理解 |
|---|---|
| Blob | Blobstore 里的"逻辑大文件"：有 id/xattr/逻辑地址空间，底层空间按 cluster 散布在盘上 |
| Blobstore | SPDK 用户态对象存储层：管 blob 生命周期、空间分配、逻辑偏移→设备偏移 |
| bdev | SPDK 的块设备抽象层：统一 NVMe/virtio/文件等后端，blob IO 之下的一层 |
| DMA | Direct Memory Access：由设备（NVMe Controller）通过 PCIe 直接读写内存 |
| DMA Buffer | 物理可寻址、固定（pinned/大页）、对齐的内存；`spdk_zmalloc` 分配的缓冲区 |
| Reactor | CPU 核上的 SPDK 事件循环，反复执行该线程的所有 poller |
| SPDK Thread | 不是 pthread：reactor 内的事件调度结构，有自己的 poller 集和消息队列 |
| Poller | 注册在 SPDK thread 上的回调，周期 0 = 每轮执行；FastBlock 的 poller 跑在这里 |
| IO Channel | per-thread 访问设备的上下文，避免跨核加锁；与 NVMe QP 不一一对应 |
| NVMe SQ | Submission Queue：主机提交命令的队列 |
| NVMe CQ | Completion Queue：控制器写完成、主机轮询的队列 |
| NVMe Controller | SSD 上的硬件：取命令、DMA 数据、执行写、写 CQ |
| PCIe | CPU↔内存↔设备的高速总线，DMA 的物理通道 |

---

## 16. 推荐阅读顺序

1. **FastBlock 调用 SPDK 的边界**：[object_store.cc#L607-648](src/localstore/object_store.cc#L607)、[rolling_blob.h#L156-220](src/localstore/rolling_blob.h#L156)、[Findspdk.cmake](cmake/Findspdk.cmake)（SPDK 组件清单）
2. **Blob / Blobstore**：[create_blob](src/localstore/object_store.cc#L538)、[blob_tree](src/localstore/blob_manager.h#L34)、外部 SPDK API blob 文档
3. **spdk_blob_io_write 之后**：外部 SPDK API（blobstore 内部 → bdev → nvme），只记层级不追源码
4. **DMA Buffer**：[osd_stm.cc#L81](src/osd/osd_stm.cc#L81)、[object_store.cc#L660](src/localstore/object_store.cc#L660)、[memory_pool.h#L56](src/include/fastblock/msg/rdma/memory_pool.h#L56)
5. **异步 IO**：[rw_done](src/localstore/object_store.cc#L679) 与 [osd_service_complete](src/osd/osd_stm.cc#L108) 的回调链
6. **Reactor / Poller / Thread**：[apply_task](src/raft/state_machine.cc#L19)、[simple_poller.h](src/include/fastblock/utils/simple_poller.h#L100)、[core_sharded.h](src/include/fastblock/base/core_sharded.h)
7. **bdev**：外部 SPDK API（bdev 概念文档即可）
8. **NVMe SQ/CQ**：外部 SPDK API（nvme 概念）
9. **NVMe Command / PRP**：外部 SPDK API（nvme 概念）
10. **PCIe / DMA / SSD**：本文第 5、12 节

---

## 17. Checklist

- [ ] Blob 是什么？（逻辑大文件，非连续物理空间，有 id/xattr）
- [ ] Blobstore 是什么？（用户态对象存储层：创建/分配/映射）
- [ ] Blob 和 NVMe SSD 空间是什么关系？（逻辑空间 → cluster 散布 → bdev 偏移）
- [ ] `spdk_blob_io_write()` 后发生什么？（blobstore → bdev → NVMe driver → SQ → Controller → DMA → NAND → CQ → 回调；全部外部 SPDK API）
- [ ] SPDK bdev 是什么？（块设备抽象层）
- [ ] DMA 是谁在搬数据？（NVMe Controller 经 PCIe，不是 CPU）
- [ ] 为什么需要 DMA buffer？（设备按物理地址访问内存，普通 malloc 不行）
- [ ] `spdk_zmalloc()` 有什么作用？（大页/物理连续/对齐的 DMA 安全内存）
- [ ] 为什么 SPDK 使用异步 IO？（提交即返回，完成回调，一核多 IO 在途）
- [ ] Polling 是什么？（CPU 反复查 CQ，替代中断+内核切换）
- [ ] Reactor 是什么？（核上的事件循环）
- [ ] SPDK Thread 是什么？（reactor 内的事件调度结构，非 pthread）
- [ ] Poller 是什么？（注册在 thread 上的回调；FastBlock poller 跑在 SPDK 框架里）
- [ ] IO Channel 是什么？（per-thread 设备访问上下文，与 QP 不一一对应）
- [ ] NVMe SQ / CQ 是什么？（命令队列 / 完成队列）
- [ ] NVMe Controller 怎么读取内存数据？（PCIe DMA，靠 PRP/SGL 描述内存位置）
- [ ] PCIe 在整个过程里负责什么？（地址共享 + DMA 通道）
- [ ] 一次 4KB write 怎么最终进入 SSD？（见第 13 节完整链路）

---

## 下一阶段预告（可选）

如果要继续深入：SPDK 源码阅读（blobstore.c → bdev → nvme qpair/PRP）、DPDK hugepage 与内存管理、NVMe 协议细节。这些都需要引入 SPDK 外部源码树。**网络层完整文档：[route8.md](route8.md)**。