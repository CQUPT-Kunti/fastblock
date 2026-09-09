# FastBlock 第六阶段：`src/localstore/`（Raft Log 与 Object 数据的本地持久化）

> **前置**：已完成 Raft commit → State Machine Apply（[osd_stm::apply()](src/osd/osd_stm.cc#L31)）。
> **本阶段范围**：两条主线——Raft Log 怎么经 `disk_log` 落盘；Commit 后 Object 数据怎么经 `object_store` 落盘。`kv_store` 只讲职责。**到 SPDK Blobstore API 边界停止**。
> **链接说明**：本文所有代码链接都是相对路径 + `#L行号`，在 VSCode 中点击函数名可直接跳转；`↓` 表示调用方向。

---

## 1. `src/localstore/` 文件清单

| 文件 | 职责 | 判定 |
|---|---|---|
| [storage_manager.h](src/localstore/storage_manager.h) / [.cc](src/localstore/storage_manager.cc) | **总入口**：每个核一份，持有 kvstore + 各 PG 的 disk_log/object_store | **核心，第 1 个看** |
| [disk_log.h](src/localstore/disk_log.h) / [disk_log.cc](src/localstore/disk_log.cc) | **Raft Log 落盘**：`disk_log::append`，包 header + 数据 | **核心** |
| [rolling_blob.h](src/localstore/rolling_blob.h) / [.cc](src/localstore/rolling_blob.cc) | 环形日志 Blob（可 trim），**SPDK 写入发生在这** | **核心（只看 append/read）** |
| [log_entry.h](src/localstore/log_entry.h#L21) | [log_entry_t](src/localstore/log_entry.h#L21)：日志条目结构 | 查结构时翻 |
| [object_store.h](src/localstore/object_store.h) / [.cc](src/localstore/object_store.cc) | **Object 数据落盘**：object→blob 映射、读写、RMW | **核心** |
| [blob_manager.h](src/localstore/blob_manager.h) / [.cc](src/localstore/blob_manager.cc) | **每个核的 blob 目录**（`blob_tree`）+ blobstore 初始化 | **核心（只看 blob_tree）** |
| [kv_store.h](src/localstore/kv_store.h) / [.cc](src/localstore/kv_store.cc) | 每核一个的 KV 存储（PG/Raft 元数据） | 了解 API 即可 |
| [types.h](src/localstore/types.h) | [fb_blob{blob, blobid}](src/localstore/types.h#L27)、[blob_type 枚举](src/localstore/types.h#L32) | 查结构时翻 |
| buffer_pool / spdk_buffer / blob_pool / kv_checkpoint / object_recovery | 缓冲池、预分配 blob、KV checkpoint、恢复 | **第一遍跳过** |
| demo/ | 测试代码 | **跳过** |

**推荐阅读顺序**：[storage_manager.h](src/localstore/storage_manager.h) → [raft_log.cc 的 disk_append](src/raft/raft_log.cc#L102) → [disk_log.h 的 append](src/localstore/disk_log.h#L89) → [rolling_blob.h](src/localstore/rolling_blob.h)（SPDK 边界）→ [object_store.h/cc](src/localstore/object_store.h)（write 主线）→ [blob_manager.h](src/localstore/blob_manager.h)（blob_tree）→ [kv_store.h](src/localstore/kv_store.h) + [raft.h 的 kv 使用](src/raft/raft.h#L556) → 完。

---

## 2. LocalStore 整体结构

[storage_manager.h#L32-37](src/localstore/storage_manager.h#L32) 的注释直接给出分层：

```text
每个 CPU core 一个 storage_manager
├── kvstore         所有 PG 共用一个（每核一个 KV blob）
├── log_manager     每个 PG 一个 disk_log
└── object_manager  每个 PG 一个 object_store
```

**为什么 Raft Log 和 Object Data 分开存**（源码依据）：
- 生命周期不同：Log 是**追加式的、可 trim 的环形缓冲**（`rolling_blob`，含 `TRIM_TRIGGER_PERCENTAGE`，[disk_log.h#L42-44](src/localstore/disk_log.h#L42)）；Object 数据是**按 object 定位的随机读写**（4MB 大小的 blob）。
- 更新模式不同：Log 只 append/截断；Object 数据按 offset 就地改写。
- 底层形态不同：Log 每条是"4KB header + 数据"的连续流（[disk_log.h#L104](src/localstore/disk_log.h#L104)）；Object 是一个对象一个 blob。

**三者都建立在 SPDK Blobstore 上**：`blob_tree`（[blob_manager.h#L34-42](src/localstore/blob_manager.h#L34)）记录了每核的 blob 清单：

```cpp
struct blob_tree {
    spdk_blob_id kv_blob;                      // KV：每核 1 个 blob
    spdk_blob_id kv_checkpoint_blob;           // KV checkpoint
    spdk_blob_id kv_new_checkpoint_blob;
    std::map<std::string, struct spdk_blob *> log_blobs;       // Log：每 PG 1 个 blob
    std::map<std::string, object_store::container> object_blobs; // Object：每 PG 一个容器
    ...
};
```

---

## 3. 第一部分：`disk_log` —— Raft Log 落盘

### 从 Raft 到 disk_log 的调用链（真实源码）

- [raft_server_t::raft_write_entry()](src/raft/raft_server.cc#L1086) — 入口；[ety->set_term(current_term)](src/raft/raft_server.cc#L1117)
  ↓
- [raft_append_entry()](src/raft/raft_server.cc#L1118) → [raft_log::log_append()](src/raft/raft_log.cc#L45) 入 `_entry_queue`（内存缓冲）
  ↓
- [raft_log::entry_queue_flush()](src/raft/raft_log.cc#L53) — 分配 log index，进 `_entries` 缓存
  ↓
- [raft_server_t::raft_disk_append_entries()](src/raft/raft_server.cc#L1256)（leader 批量落盘）
  ↓
- [raft_log::disk_append()](src/raft/raft_log.cc#L102) — [raft_entry_to_log_entry()](src/raft/raft_log.h#L51) 转换后 [_log->append(...)](src/raft/raft_log.cc#L115)
  ↓
- [disk_log::append()](src/localstore/disk_log.h#L89) ← **本阶段主角**
  ↓
- [_rblob->append()](src/localstore/disk_log.h#L108)
  ↓
- [rolling_blob::append → spdk_blob_io_writev](src/localstore/rolling_blob.h#L186) ← **★ SPDK 边界**

### 逐点回答

1. **Raft 调用 disk_log 的位置**：[raft_log::disk_append()](src/raft/raft_log.cc#L102) 调 [_log->append(...)](src/raft/raft_log.cc#L115)，`_log` 是 `disk_log*`（[raft_log.h#L272](src/raft/raft_log.h#L272)）。
2. **一条 raft entry 怎么传进来**：[raft_entry_t](src/raft/raft.h#L964) → [raft_entry_to_log_entry()](src/raft/raft_log.h#L51) 转成 `log_entry_t{index, term_id, size, type, meta, data}`；**注意数据必须 4KB 对齐**（[raft_log.h#L61-66](src/raft/raft_log.h#L61)，否则报错）。
3. **disk_log 保存什么**：每条 = **4KB 的 log header**（[EncodeLogHeader](src/localstore/log_entry.h#L36)，定义在 log_entry.h:36，含 index/term 等信息）+ **entry.data 原始数据**；同时记录 `idx_pos`：raft_index → (blob 内 pos, 长度, term)，供读回（[disk_log.h#L102-105](src/localstore/disk_log.h#L102)）。
4. **log index / term / data 怎么表示**：[log_entry_t](src/localstore/log_entry.h#L21)（[log_entry.h](src/localstore/log_entry.h#L21)）字段：`index`（raft 日志序号）、`term_id`、`size`、`type`、`meta`（序列化的 write_cmd）、`data`（4KB 块列表）。
5. **PG 与 disk_log 关系**：**1:1**——每个 PG 一个 `disk_log`（[storage_manager.h#L35](src/localstore/storage_manager.h#L35) 注释），对应 `blob_tree.log_blobs[pg_name]` 一个 log blob。
6. **是否一个 PG 一个 log blob**：是。PG 创建时 [make_disk_log()](src/localstore/disk_log.cc#L62) 用 [make_rolling_blob(bs, channel, huge_blob_size, ...)](src/localstore/disk_log.cc#L77) 建一个**大环形 blob**。
7. **log append 函数**：[disk_log::append()](src/localstore/disk_log.h#L89)：为每条申请 header buffer、[EncodeLogHeader](src/localstore/log_entry.h#L36)、把 header+data 挂进 `buffer_list`，一次 [_rblob->append(...)](src/localstore/disk_log.h#L108)。
8. **truncate / remove 第一遍跳过**：是。[raft_log::log_truncate](src/raft/raft_log.h#L73)、disk_log 的 trim（`TRIM_TRIGGER_PERCENTAGE`）属于日志压缩/截断，跳过。
9. **SPDK 边界**：[rolling_blob::append](src/localstore/rolling_blob.h#L186) 内部 [spdk_blob_io_writev(blob, channel, iov, ...)](src/localstore/rolling_blob.h#L186)（批量版 [L218](src/localstore/rolling_blob.h#L218)）。

---

## 4. 重点：Raft Log 落盘 ≠ Object 数据落盘

一次 `write Object A, offset=4096, data=xxxx` 经历的**两个阶段**：

**第一阶段（写入前，leader 收到请求时）：**

- [raft_write_entry](src/raft/raft_server.cc#L1086) → [disk_log::append](src/localstore/disk_log.h#L89)
- 把"这次操作"作为日志条目落盘（4KB header + 原始数据）
- 这就是 Raft 复制/恢复的持久化基础
- （Follower 复制、majority、commit —— 本阶段不展开）

**第二阶段（commit 之后，状态机 apply 时）：**

- [osd_stm::apply](src/osd/osd_stm.cc#L31) → [write_obj](src/osd/osd_stm.cc#L79) → [object_store::write](src/localstore/object_store.cc#L131)
- 真正修改 Object A 的数据

**为什么一份用户 write 要经历两个阶段**（源码依据）：

- `disk_log` 里落的是**日志流**：一条条 `log_entry_t`，记录的是"操作"（write_cmd：object_name+offset），是顺序追加的、会被 trim 的、Raft 恢复要重放的（对应 [raft_log.h 的 disk_read](src/raft/raft_log.h#L96) 重放路径）。
- `object_store` 里落的是**对象数据**：按 `object_name → blob` 就地寻址改写，供 Client 直接读。
- 两者**物理上是不同的 blob**（`blob_tree.log_blobs` vs `object_blobs`，[blob_manager.h#L39-40](src/localstore/blob_manager.h#L39)），由完全不同的类管理。

一句话：**Log 是"账本"，Object 是"货"；先记账（disk_log），commit 后再改货（object_store）**。

---

## 5. 第二部分：`object_store` —— Object 数据落盘

### 调用链（从状态机继续追）

- Raft commit → state_machine apply
  ↓
- [osd_stm::apply()](src/osd/osd_stm.cc#L31) — RAFT_LOGTYPE_WRITE → 解析 [write_cmd](proto/osd_msg.proto#L58)（object_name/offset）
  ↓
- [osd_stm::write_obj()](src/osd/osd_stm.cc#L79) — 4KB 对齐 [spdk_zmalloc](src/osd/osd_stm.cc#L81) + 拷数据
  ↓
- [_store.write(...)](src/osd/osd_stm.cc#L90) — `_store` 是 state_machine 成员（[state_machine.h#L29](src/raft/state_machine.h#L29)/[L113](src/raft/state_machine.h#L113)），每个 PG 一个 object_store，绑定本核的 global_blobstore/channel
  ↓
- [object_store::write()](src/localstore/object_store.cc#L131)
  ↓
- [object_store::readwrite()](src/localstore/object_store.cc#L512) — 查 table：对象存在？→ [blob_readwrite](src/localstore/object_store.cc#L528)；不存在？→ [create_blob](src/localstore/object_store.cc#L534)（写）或 `-ENOENT`（读）
  ↓
- [blob_readwrite()](src/localstore/object_store.cc#L607)
  ↓
- [spdk_blob_io_write / spdk_blob_io_read](src/localstore/object_store.cc#L644) ← **★ SPDK 边界**

### 逐点回答

1. **进入 object_store 的入口**：[osd_stm::apply](src/osd/osd_stm.cc#L31) → [write_obj](src/osd/osd_stm.cc#L79) → [_store.write](src/osd/osd_stm.cc#L90)。`_store` 定义在 `state_machine`（[state_machine.h#L29](src/raft/state_machine.h#L29)），每个 PG 一个。
2. **write API**：[object_store::write()](src/localstore/object_store.cc#L131)（xattr / object_name / offset / buf / len / cb_fn / arg）；读是 [read()](src/localstore/object_store.cc#L138)。注释明确要求 buf 用 `spdk_malloc` 申请（[object_store.h#L50-51](src/localstore/object_store.h#L50)）。
3. **Object 标识**：`object_name`（字符串），底层映射到 [fb_blob{blob, blobid}](src/localstore/types.h#L27)。
4. **第一次写（对象不存在）**：[readwrite](src/localstore/object_store.cc#L512) 里 `table.find` 未命中且是写 → [create_blob()](src/localstore/object_store.cc#L534) → [spdk_bs_create_blob_ext](src/localstore/object_store.cc#L578)（`num_clusters=4`、带 xattr：type/pg/obj_name）→ [create_done](src/localstore/object_store.cc#L750) → [spdk_bs_open_blob](src/localstore/object_store.cc#L762) → [open_done](src/localstore/object_store.cc#L765) → **[table.emplace(object_name, obj)](src/localstore/object_store.cc#L782)** → 继续读写。
5. **已存在时怎么找到**：内存表 `object_store::table`（`absl::flat_hash_map<object_name, object{origin, recover, snap_list}>`，[object_store.h#L140-146](src/localstore/object_store.h#L140)）→ 命中则直接 [blob_readwrite(it->second.origin.blob, ...)](src/localstore/object_store.cc#L528)。
6. **object_name 怎么对应底层 blob**：`table` 映射 + blob 上的 xattr（`blob_set_xattr` 写 type/pg/obj_name，[object_store.cc#L553](src/localstore/object_store.cc#L553)）；重启时靠 xattr 重建 table（[object_store::load](src/localstore/object_store.h#L153)）。
7. **offset/length 怎么传下去**：[blob_readwrite](src/localstore/object_store.cc#L607) 里 [get_page_parameters(...)](src/localstore/object_store.cc#L627) → **字节 offset 转 512B LBA** → [spdk_blob_io_write(blob, channel, buf, start_lba, num_lba, ...)](src/localstore/object_store.cc#L644)。
8. **read/write API**：[read](src/localstore/object_store.h#L53) / [write](src/localstore/object_store.h#L57) / [delete_object](src/localstore/object_store.h#L61)。
9. **completion 回调链**：[rw_done](src/localstore/object_store.cc#L679)（记延迟、释放 pin_buf）→ [cb_fn(arg, 0)](src/localstore/object_store.cc#L720) → [write_obj_done](src/osd/osd_stm.cc#L52)（解锁 + `complete->complete`）→ [osd_service_complete::finish](src/osd/osd_stm.cc#L125)（填 response + done->Run）。

---

## 6. Object 和 Blob 的关系：**一个 Object = 一个 Blob**

源码依据：

- `object_store::object` 的 `origin` 就是 [fb_blob](src/localstore/types.h#L27)（[object_store.h#L140-142](src/localstore/object_store.h#L140)），一个对象持有一个 blob 句柄。
- Blob 大小固定 = `blob_cluster(4) × cluster_size(1MB) = 4MB`（[object_store.h#L31-33](src/localstore/object_store.h#L31)）——与 Client 侧 `default_object_size = 4MiB`（[libfblock.h#L28](src/include/fastblock/client/libfblock.h#L28)）完全对应。

```text
Object A → Blob X（blobid=X，4MB）
Object B → Blob Y
Object C → Blob Z
```

- **Object name 和 blob id 的关系**：无全局换算，靠**内存表 + blob xattr**：运行时查 [object_store::table](src/localstore/object_store.h#L146)（object_name → fb_blob）；持久化靠 blob 的 xattr（`type="blob_type::object"`、`pg`、`obj_name`，[object_store.cc#L553](src/localstore/object_store.cc#L553)），重启时枚举 blob 按 xattr 重建映射。
- **映射保存在哪里**：内存 = `object_store::table`；磁盘 = 各 blob 的 xattr（不是 kv_store）。
- **第一次创建怎么获得 blob id**：[spdk_bs_create_blob_ext](src/localstore/object_store.cc#L578) 回调 [create_done(blobid)](src/localstore/object_store.cc#L750)。
- **后续怎么再找到**：表命中（运行期）或 xattr 重建（重启后）。

---

## 7. offset 怎么到底层 Blob IO

对应函数：[get_page_parameters()](src/localstore/object_store.h#L125) + [blob_readwrite()](src/localstore/object_store.cc#L607)：

```cpp
*lba_size = object_store::unit_size;          // 512
*start_lba = offset / *lba_size;              // 字节 → LBA
*num_lba  = (offset + length - 1) / *lba_size - *start_lba + 1;  // 覆盖的 LBA 数
```

例：`offset=128KiB, len=4KiB` → `start_lba=256, num_lba=8` → [spdk_blob_io_write(blob, channel, buf, 256, 8, ...)](src/localstore/object_store.cc#L644)。

---

## 8. RMW：**存在**（非 512B 对齐的写）

判断位置：[blob_readwrite()](src/localstore/object_store.cc#L630)：

```cpp
if (is_lba_aligned(offset, len)) {          // offset % 512 == 0 && len % 512 == 0
    spdk_blob_io_write(...);                 // 直接写
} else {                                     // 非对齐 → RMW
    spdk_blob_io_read(blob, channel, pin_buf, start_lba, num_lba, read_done, ctx);  // L673
}
```

RMW 完整路径（注释明确说明，[object_store.cc#L724-725](src/localstore/object_store.cc#L724)）：

- 非对齐 write
  ↓
- [spdk_blob_io_read 读出整个对齐区域到 pin_buf](src/localstore/object_store.cc#L673)
  ↓
- [read_done()](src/localstore/object_store.cc#L726)
  ↓
- [memcpy(pin_buf + (offset & (blocklen-1)), buf, len)](src/localstore/object_store.cc#L743) ← 修改 buffer
  ↓
- [spdk_blob_io_write(pin_buf, start_lba, num_lba)](src/localstore/object_store.cc#L744)

**说明**：Client 的 object 内 offset 通常是 4KB 对齐的（对齐路径直写）；非 512 对齐的边角写才会走 RMW。[is_lba_aligned 定义](src/localstore/object_store.h#L117)。

---

## 9. 第三部分：`kv_store`

**职责**：每核一个、所有 PG 共享的小型 KV 存储（[storage_manager.h#L34](src/localstore/storage_manager.h#L34) 注释），key/value 都是 `std::string`（[put(key, value)](src/localstore/kv_store.h#L136) / [get(key)](src/localstore/kv_store.h#L147)）。

**保存什么**：PG / Raft 的持久化元数据。真实调用（都在 `raft_server_t`，[raft.h](src/raft/raft.h)）：

| 函数 | key | 内容 |
|---|---|---|
| [save_vote_for](src/raft/raft.h#L556) | `"{pool}.{pg}.vote_for"` | 本任期投过谁的票 |
| [save_current_term](src/raft/raft.h#L572) | `"{pool}.{pg}.term"` | 当前 term |
| [save_node_configuration](src/raft/raft.h#L588) | `"{pool}.{pg}.node_cfg"` | 成员配置 |
| [save_last_apply_index](src/raft/raft.h#L594) | `"{pool}.{pg}.lapply_idx"` | 已 apply 到的日志序号 |

**为什么不用 object_store**：这些元数据**小、更新频繁、且是"覆盖式"写**（同一 key 反复 put），而 object_store 是 4MB 大对象、按对象寻址；KV 需要 checkpoint 机制做恢复（`kv_checkpoint`，三个 blob 轮换），和对象数据生命周期完全不同。

**为什么每核一个 blob**：元数据总量小且所有 PG 共享同一核的存储上下文，一个 KV blob 就够（[blob_tree.kv_blob](src/localstore/blob_manager.h#L36)）。

---

## 10. LocalStore 与 SPDK 的边界

FastBlock 自己的代码到这些调用为止，之后就进入 SPDK Blobstore：

| 层 | 进入 SPDK 的位置 |
|---|---|
| Object | [spdk_bs_create_blob_ext](src/localstore/object_store.cc#L578)、[spdk_bs_open_blob](src/localstore/object_store.cc#L762)、[spdk_blob_io_write/read](src/localstore/object_store.cc#L644)、[spdk_blob_sync_md](src/localstore/object_store.cc#L564)、[spdk_bs_delete_blob](src/localstore/object_store.cc#L487) |
| Log | [spdk_blob_io_writev/readv](src/localstore/rolling_blob.h#L186)、[spdk_blob_sync_md](src/localstore/disk_log.cc#L60) |
| KV | kv_store 的 blob IO（kv_store.cc 内部） |
| 底座 | [blobstore_init](src/localstore/blob_manager.h#L56) / [global_blobstore](src/localstore/blob_manager.h#L44) / [global_io_channel](src/localstore/blob_manager.h#L46) |

```text
FastBlock 自己的代码（osd_stm / disk_log / object_store / kv_store）
↓
spdk_bs_* / spdk_blob_* / spdk_blob_io_*
──────────────────────────────────────
SPDK Blobstore（blob 分配、xattr、IO 调度）
↓
下一阶段：SPDK / NVMe / SSD
```

---

## 11. 一次真实 4KB Write 串起来

```text
前提：PG10, object_100, offset=4096, len=4KB（4KB 对齐 → 直写路径，无 RMW）
```

| 步骤 | 实际过程 | 源码位置 |
|---|---|---|
| 1 | Leader 收到 write：[raft_write_entry](src/raft/raft_server.cc#L1086) → 记 term → [raft_append_entry](src/raft/raft_server.cc#L1118) 入内存队列 | raft_server.cc:1086-1118 |
| 2 | [entry_queue_flush](src/raft/raft_log.cc#L53) 分配 index → 批量 [raft_disk_append_entries](src/raft/raft_server.cc#L1256) | raft_log.cc:53 / raft_server.cc:1256 |
| 3 | [raft_log::disk_append](src/raft/raft_log.cc#L102) → [raft_entry_to_log_entry](src/raft/raft_log.h#L51)（4KB 对齐校验）→ [_log->append](src/raft/raft_log.cc#L115) | raft_log.cc:102-115 |
| 4 | [disk_log::append](src/localstore/disk_log.h#L89)：[EncodeLogHeader](src/localstore/log_entry.h#L36)(4KB) + data，挂 buffer_list | disk_log.h:89-108 |
| 5 | [rolling_blob::append](src/localstore/rolling_blob.h#L186) → **spdk_blob_io_writev**（Raft Log 持久化） | rolling_blob.h:186 |
| 6 | （Follower 复制 / majority / commit —— 本阶段跳过） | — |
| 7 | Commit 后 [osd_stm::apply](src/osd/osd_stm.cc#L31)：解析 write_cmd → [write_obj](src/osd/osd_stm.cc#L79) | osd_stm.cc:31-35 / 79 |
| 8 | [_store.write(xattr, "object_100", 4096, buf, 4096, ...)](src/osd/osd_stm.cc#L90) | osd_stm.cc:90 |
| 9 | [object_store::readwrite](src/localstore/object_store.cc#L512)：table 未命中（首次）→ [create_blob](src/localstore/object_store.cc#L534)；命中 → 直走 | object_store.cc:512-535 |
| 10 | [create_blob](src/localstore/object_store.cc#L538) → spdk_bs_create_blob_ext(4×1MB) → open → [table.emplace](src/localstore/object_store.cc#L782) | object_store.cc:538-782 |
| 11 | [blob_readwrite](src/localstore/object_store.cc#L607)：对齐 → [get_page_parameters](src/localstore/object_store.cc#L627) → start_lba=8, num_lba=8 | object_store.cc:607-644 |
| 12 | **[spdk_blob_io_write(blob, channel, buf, 8, 8, rw_done, ctx)](src/localstore/object_store.cc#L644)**（进入 SPDK） | object_store.cc:644 |
| 13 | [rw_done](src/localstore/object_store.cc#L679) → [write_obj_done](src/osd/osd_stm.cc#L52)（解锁）→ [osd_service_complete](src/osd/osd_stm.cc#L125)（填 response + done） | object_store.cc:679 / osd_stm.cc:52 / 125 |

---

## 12. 核心函数（统一格式，函数名可点击）

### [disk_log::append()](src/localstore/disk_log.h#L89)

- **作用**：把一批 [log_entry_t](src/localstore/log_entry.h#L21) 编码成"4KB header + 数据"的连续流，交给环形 blob 落盘。
- **输入**：`std::vector<log_entry_t>& entries, cb_fn, arg`
- **内部关键操作**：1) 逐条 [EncodeLogHeader](src/localstore/log_entry.h#L36) 申请 header buffer；2) 记录 `idx_pos`（raft_index → blob pos/size/term）；3) [_rblob->append(bl, ...)](src/localstore/disk_log.h#L108)。
- **下一步**：[rolling_blob::append](src/localstore/rolling_blob.h#L186)
- **只需搞懂**：header 和 data 是分两次 append 进 buffer_list 的；idx_pos 是读回日志的索引。

### [object_store::write() → readwrite()](src/localstore/object_store.cc#L131) / [readwrite](src/localstore/object_store.cc#L512)

- **作用**：按 object_name 找到（或创建）blob 并下发 IO。
- **输入**：`xattr / object_name / offset / buf / len / cb_fn / arg`
- **内部关键操作**：1) `offset+len > 4MB` 则截断；2) 查 `table`：命中 → `blob_readwrite`；读未命中 → `-ENOENT`；写未命中 → `create_blob`。
- **下一步**：[create_blob](src/localstore/object_store.cc#L538) 或 [blob_readwrite](src/localstore/object_store.cc#L607)
- **只需搞懂**：对象存在与否的分支、创建后 table 何时写入（[sync_md_done](src/localstore/object_store.cc#L582) / [open_done](src/localstore/object_store.cc#L765)）。

### [blob_readwrite()](src/localstore/object_store.cc#L607)

- **作用**：字节 offset/len 转 LBA，走对齐直写或非对齐 RMW。
- **内部关键操作**：[get_page_parameters](src/localstore/object_store.cc#L627) → [is_lba_aligned](src/localstore/object_store.h#L117) 分支 → `spdk_blob_io_write/read` 或先读后写。
- **只需搞懂**：LBA 换算、对齐判定、RMW 的 [read_done](src/localstore/object_store.cc#L726) 入口。

### [create_blob()](src/localstore/object_store.cc#L538)

- **作用**：对象首次写入时创建 4MB blob 并挂 xattr（type/pg/obj_name）。
- **下一步**：[spdk_bs_create_blob_ext](src/localstore/object_store.cc#L578) → [create_done](src/localstore/object_store.cc#L750) → [spdk_bs_open_blob](src/localstore/object_store.cc#L762) → [open_done](src/localstore/object_store.cc#L765) → [table.emplace](src/localstore/object_store.cc#L782) → [blob_readwrite](src/localstore/object_store.cc#L784)。
- **只需搞懂**：opts（num_clusters=4）、xattr 写入时机、table 写入时机。

### [raft_log::disk_append()](src/raft/raft_log.cc#L102)

- **作用**：Raft 批量落盘的桥：缓存条目 → [log_entry_t](src/localstore/log_entry.h#L21) → disk_log。
- **只需搞懂**：它只做转换和转发，真正的 SPDK IO 在 [rolling_blob](src/localstore/rolling_blob.h#L186)。

---

## 13. 本阶段核心数据结构

| 结构 | 是什么 | 保存什么 | 谁使用 |
|---|---|---|---|
| [fb_blob](src/localstore/types.h#L27) | Blob 句柄 | `spdk_blob*` + `blobid` | object_store 的 origin/recover、blob_pool |
| [log_entry_t](src/localstore/log_entry.h#L21) | 磁盘日志条目 | index / term_id / size / type / meta / data | disk_log 读写、raft_log 转换 |
| [disk_log](src/localstore/disk_log.h#L72) | 一个 PG 的日志 | rolling_blob 指针、idx_pos 索引、trim poller | [raft_log::disk_append](src/raft/raft_log.cc#L102) 调用 append/read |
| [rolling_blob](src/localstore/rolling_blob.h) | 环形日志 blob | 追加位置、blob 句柄、trim 状态 | disk_log 的底层 |
| [object_store](src/localstore/object_store.h#L30) | 一个 PG 的对象存储 | `table`（object_name→object）、bs/channel | [osd_stm 的 _store](src/raft/state_machine.h#L113) |
| [object_store::table](src/localstore/object_store.h#L146) | **Object→Blob 内存映射** | object_name → `object{origin, recover, snap_list}` | 读写查找 |
| [kvstore](src/localstore/kv_store.h#L71) | 每核一个 KV | string→string（term/vote/cfg/lapply_idx） | [raft_server_t 持久化元数据](src/raft/raft.h#L556) |
| [blob_tree](src/localstore/blob_manager.h#L34) | 每核 blob 目录 | kv blob、log_blobs（每 PG）、object_blobs（每 PG） | 启动/恢复时登记 |

---

## 14. 推荐阅读顺序

- 1. [storage_manager.h](src/localstore/storage_manager.h) ← 总览：每核 1 kv + 每 PG 1 log + 每 PG 1 object
  ↓
- 2. [raft_log.cc 的 disk_append](src/raft/raft_log.cc#L102) ← Raft 与 disk_log 的桥
  ↓
- 3. [disk_log.h 的 append](src/localstore/disk_log.h#L89) ← 日志格式（4KB header + data）、idx_pos
  ↓
- 4. [rolling_blob.h 的 append](src/localstore/rolling_blob.h#L186) ← SPDK 边界（spdk_blob_io_writev）
  ↓
- 5. [object_store.h/cc](src/localstore/object_store.h) ← write → readwrite → create_blob → blob_readwrite（RMW）
  ↓
- 6. [blob_manager.h 的 blob_tree](src/localstore/blob_manager.h#L34) ← 三种 blob 的登记表
  ↓
- 7. [kv_store.h](src/localstore/kv_store.h) + [raft.h:556-607](src/raft/raft.h#L556) ← KV 的职责与真实调用
  ↓
- 8. 完 —— 下一阶段 SPDK

---

## 15. 总结图（一屏）

- [raft_write_entry()](src/raft/raft_server.cc#L1086)（Raft Write）
  ↓
- [raft_log::disk_append()](src/raft/raft_log.cc#L102)
  ↓
- [disk_log::append()](src/localstore/disk_log.h#L89)（4KB header + data）
  ↓
- [rolling_blob::append → spdk_blob_io_writev](src/localstore/rolling_blob.h#L186)
  ↓
- **Log Blob（每 PG 一个）★ Raft Log 持久化**
  ↓
- Follower / Majority / Commit（下一阶段）
  ↓
- [osd_stm::apply()](src/osd/osd_stm.cc#L31)
  ↓
- [write_obj → object_store::write()](src/osd/osd_stm.cc#L90) / [object_store.cc#L131](src/localstore/object_store.cc#L131)
  ↓
- [readwrite：查 table → create_blob（首次）→ blob_readwrite](src/localstore/object_store.cc#L512)
  ↓
- [spdk_blob_io_write/read](src/localstore/object_store.cc#L644) **★ Object 数据落盘**
  ↓
- **Object Blob（4MB，一对象一 blob）**

```text
kv_store（每核 1 blob）：put/get
PG/Raft 元数据：term / vote_for / node_cfg / lapply_idx   （raft.h:556-607）
```

---

## 16. Checklist

- [ ] `disk_log` 是什么？（一个 PG 的 Raft 日志，4KB header + 数据流的环形 blob）
- [ ] 一个 PG 的 Raft Log 怎么保存？（[raft_log::disk_append](src/raft/raft_log.cc#L102) → [disk_log::append](src/localstore/disk_log.h#L89) → [rolling_blob](src/localstore/rolling_blob.h#L186) → 每 PG 一个 log blob）
- [ ] PG 和 log blob 是什么关系？（1:1，[blob_tree.log_blobs[pg_name]](src/localstore/blob_manager.h#L39)）
- [ ] Raft Log 落盘和 Object 数据落盘有什么区别？（Log=账本，append 流、可 trim；Object=货，按对象寻址改写，一对象一 blob）
- [ ] Commit 后怎么进入 `object_store`？（[osd_stm::apply](src/osd/osd_stm.cc#L31) → [write_obj](src/osd/osd_stm.cc#L79) → [_store.write](src/osd/osd_stm.cc#L90)）
- [ ] Object 第一次写时怎么创建？（[create_blob](src/localstore/object_store.cc#L538) → spdk_bs_create_blob_ext → open → [table.emplace](src/localstore/object_store.cc#L782)）
- [ ] Object 怎么找到对应 Blob？（内存表 [object_store::table](src/localstore/object_store.h#L146)；重启靠 blob xattr 重建）
- [ ] offset 怎么传到底层 Blob IO？（[get_page_parameters](src/localstore/object_store.h#L125) 字节→512B LBA → [spdk_blob_io_write](src/localstore/object_store.cc#L644)）
- [ ] 当前代码是否存在 RMW？（**存在**：非 512B 对齐写走 [spdk_blob_io_read](src/localstore/object_store.cc#L673) → [read_done](src/localstore/object_store.cc#L726) 改 buffer → [spdk_blob_io_write](src/localstore/object_store.cc#L744)，object_store.cc:630-675）
- [ ] `kv_store` 主要保存什么？（PG/Raft 元数据：term / vote_for / node_cfg / lapply_idx，[raft.h:556-607](src/raft/raft.h#L556)）
- [ ] LocalStore 从哪里开始进入 SPDK？（[object_store.cc:578/644/762](src/localstore/object_store.cc#L578)、[rolling_blob.h:186](src/localstore/rolling_blob.h#L186)、[disk_log.cc:60](src/localstore/disk_log.cc#L60)）

---

## 下一阶段预告（暂不展开）

`SPDK Blobstore → Blob → bdev → NVMe → SSD`：blob 分配与 xattr、IO 调度、NVMe 驱动、DMA。