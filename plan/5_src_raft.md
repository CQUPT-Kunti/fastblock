# FastBlock 第五阶段：`src/raft/`（一次 write 的 Raft 主线）

> 前置：已理解 OSD 收到 Client write → 找到 PG → 交给 PG State Machine。
> 本阶段边界：从 `raft_write_entry()`（propose）追到 `osd_stm::apply()`（apply）。
> 不深入：LocalStore（disk_log 内部）、RDMA、snapshot、membership change、故障恢复。

> 链接说明：文档中所有 `文件:行号` 均为可点击链接（相对仓库根的 GitHub 风格锚点，如 `[raft_server.cc:1086](../src/raft/raft_server.cc#L1086)`），在 GitHub / 支持相对链接的 Markdown 预览器中点击即可跳转对应代码行。

---

## 1. 本阶段主线

```text
OSD / PG（Leader OSD3 / PG10）
↓  raft_write_entry()                 propose
↓  _entry_queue → entry_cache         生成 log entry（分配 idx/term）
↓  raft_flush()                       Leader 本地 append + 构造 AppendEntries
↓  raft_send_appendentries()          复制给 OSD1 / OSD7
↓  raft_recv_appendentries()          Follower append + 落盘
↓  raft_process_appendentries_reply() Leader 收到 ACK，更新 match_idx
↓  raft_node_process_commit()         计算多数派
↓  raft_set_commit_idx()              commit
↓  state_machine::raft_apply_entry()  apply
↓  osd_stm::apply()                   交回 OSD State Machine（ObjectStore 边界）
```

---

## 2. `src/raft/` 文件扫描

| 文件 | 作用 | 本阶段 |
|---|---|---|
| `raft.h` / `raft_server.cc` | `raft_server_t`：一个 PG 在本机的 Raft 实例（核心，2872 行） | **必看** |
| `raft_log.h` / `raft_log.cc` | `raft_log`：内存 entry_cache + `disk_log` 封装，管理 `_next_idx` | **必看** |
| `raft_cache.h` | `entry_cache`：内存 log 缓存，同时保存客户端 complete context | **必看** |
| `raft_node.h` | `raft_node`：每个 peer 的 `next_idx` / `match_idx` / lease | **必看** |
| `state_machine.h` / `state_machine.cc` | apply 循环（`raft_apply_entry`） | **必看** |
| `append_entry_buffer.cc` | Follower 侧 appendentries 缓冲队列 + poller | **必看** |
| `raft_client_protocol.cc` | Raft RPC 收发（到网络层边界） | 看 `send_appendentries` 即可 |
| `raft_service.h` | Raft RPC 服务端入口（`append_entries()`） | 看这一个函数即可 |
| `pg_group.h` / `pg_group.cc` | PG ↔ raft 实例注册、心跳 | 看 `create_pg` 即可 |
| `raft_types.h` | 基础类型（term/index/node id） | 扫一眼 |
| `configuration_manager.*` | 成员变更 | 跳过 |
| `raft_node.cc` | 节点辅助逻辑 | 跳过 |

---

## 3. PG 和 Raft Group 的对应关系

```text
PG10  = (pool_id, pg_id) = "0.10"
  ↓ 每个 OSD 上各创建一个 raft_server_t 实例
OSD1: raft_server_t(pool_id, pg_id)   ← 可能是 Follower
OSD3: raft_server_t(pool_id, pg_id)   ← 可能是 Leader
OSD7: raft_server_t(pool_id, pg_id)   ← 可能是 Follower
```

* **在哪里创建**：[`pg_group_t::create_pg()`](../src/raft/pg_group.cc#L30-L43) → [`raft_new()`](../src/raft/raft_server.cc#L50-L57)。由 Monitor 下发 create_pg → [`partition_manager::create_pg()`](../src/osd/partition_manager.cc#L224-L229) 用 `invoke_on(shard_id, ...)` 投递到 PG 所属 shard 线程。启动加载走 [`load_pg()`](../src/raft/pg_group.cc#L45-L54)。
* **group id 与 pg_id 的关系**：Raft group 没有独立 id，**group = (pool_id, pg_id)**，保存在 [`raft_server_t::_pool_id / _pg_id`](../src/raft/raft.h#L913-L914)。三个 OSD 上持有相同 (pool_id, pg_id) 的实例构成一个 group。
* **一个 OSD 为什么有多个 Raft Group**：每个 OSD 有多个 shard 线程（[`shard_manager`](../src/raft/pg_group.h#L25-L80)），每个 shard 上 `_pgs` map（key = `"pool.pg"` 名字，value = `shared_ptr<raft_server_t>`，[`pg_group.h:78`](../src/raft/pg_group.h#L78)）。一个 PG 按哈希固定分到一个 shard，所以一个 OSD 上有"shard 数 × 每 shard 的 PG 数"个 raft 实例。
* **Leader/Follower 状态保存在哪里**：内存字段 [`raft_server_t::_identity`](../src/raft/raft.h#L879)（RAFT_STATE_LEADER/FOLLOWER/CANDIDATE）和 [`_leader_id`](../src/raft/raft.h#L896)（当前 leader 的 node id）；term/vote 持久化在 kvstore（[`save_vote_for` / `save_current_term`](../src/raft/raft.h#L556-L577)）。

---

## 4. write 怎么进入 Raft

```text
osd_service::process_ring_write()
  ↓ invoke_on(shard) + raft_is_leader()
osd_service::process()
  ↓
osd_stm::write_and_wait()
  ↓ 对象锁 _object_rw_lock.lock()
构造 raft_entry_t（type=WRITE, meta=write_cmd, data=用户数据）
  ↓
get_raft()->raft_write_entry(entry, complete)   ← Raft 入口
```

关键点：

* **OSD 调用的接口**：[`raft_server_t::raft_write_entry()`](../src/raft/raft_server.cc#L1086)（声明在 [raft.h:462](../src/raft/raft.h#L462)）。
* **调用链**：[`osd_service::process_ring_write()`](../src/osd/osd_service.cc#L354) → `invoke_on(shard)` + `raft_is_leader()` 检查（[osd_service.cc:369-385](../src/osd/osd_service.cc#L369-L385)）→ [`osd_service::process()`](../src/osd/osd_service.cc#L446) → [`osd_stm::write_and_wait()`](../src/osd/osd_stm.cc#L160)。
* **write 封装成什么**：`raft_entry_t`（protobuf，[raft_msg.proto:22-33](../proto/raft_msg.proto#L22-L33)），字段只有 `term / idx / type / meta / data`：
  * `type` = `RAFT_LOGTYPE_WRITE`（[raft.h:964](../src/raft/raft.h#L964)）
  * `meta` = `osd::write_cmd`（object_name + offset）的序列化字节
  * `data` = **用户数据本体（4KB 原样放进 Raft log）**（[osd_stm.cc:180-185](../src/osd/osd_stm.cc#L180-L185)）
* **callback 是否跟着保存**：是。`complete`（[`osd_service_complete<write_reply>`](../src/osd/osd_stm.cc#L108-L146)）与 entry 一起进入 `entry_cache`，apply 完成后才被触发。
* **哪一步正式形成新 entry**：**分配 index 的那一步**——Leader 在 [`raft_log::entry_queue_flush()`](../src/raft/raft_log.cc#L85-L98) 里 `entry->set_idx(_next_idx); _next_idx++; _entries.add(entry, complete)`；term 在 [`raft_write_entry()`](../src/raft/raft_server.cc#L1117) 里 `ety->set_term(raft_get_current_term())`。

---

## 5. Leader 本地 append

```text
raft_write_entry()
  ↓ set_term(current_term)
raft_append_entry() → log_append()   （Leader 版：只进 _entry_queue，还没有 idx）
  ↓
【poller 驱动】raft_task_func (100us)
  ↓ 仅 leader && current_idx <= commit_idx
raft_flush()
  ├─ entry_queue_flush()             ← 这里分配 idx，加入 entry_cache
  ├─ 给每个 follower 发 appendentries
  └─ raft_disk_append_entries() → disk_log::append
        └─ 落盘完成 → raft_node_process_commit(0, end_idx, 自己)
```

要点：

* **index 怎么生成**：[`raft_log::_next_idx`](../src/raft/raft_log.h#L248-L250) 单调递增，由 [`entry_queue_flush()`](../src/raft/raft_log.cc#L53) 逐个分配。注意 Leader 是先排队、由 100us poller 批量取号。
* **term 从哪里来**：`raft_server_t::_current_term`，propose 时写入 entry（[raft_server.cc:1117](../src/raft/raft_server.cc#L1117)）。
* **entry 关键字段**：`term / idx / type / meta / data`（[raft_msg.proto:22-33](../proto/raft_msg.proto#L22-L33)）。
* **内存还是落盘**：先内存（`_entry_queue` → `entry_cache`），随后同一批 batch 内：发网络 + 异步落盘（[`raft_log::disk_append`](../src/raft/raft_log.cc#L102-L128) → [`disk_log::append`](../src/localstore/disk_log.h#L89)）。**`disk_log` 在这里已参与**（Leader 自己的副本落盘），其内部（rolling_blob/SPDK blob）属于 LocalStore，本阶段到此为止。
* **批量语义**：[`raft_task_func`](../src/raft/raft_server.cc#L1173-L1184) 要求上一批 commit 完成才 flush 下一批（[raft_server.cc:1178](../src/raft/raft_server.cc#L1178)），因此一次写盘/一次复制可能包含多条 entry（[`_static_merger_info`](../src/raft/raft_server.cc#L1152) 统计）。

---

## 6. Leader → Follower replication

```text
raft_flush()
  ↓ 对每个非 self 节点
raft_send_appendentries(node, first, current)
  ├─ create_appendentries(node, first)
  │    term / pool / pg / leader_commit
  │    prev_log_idx = next_idx - 1
  │    prev_log_term = raft_get_entry_term()
  ├─ _raft_get_entries_from_idx(start,end,ae)   ← 从 entry_cache 取 [start,end]
  └─ _client.send_appendentries(...)
        └─ stub->append_entries(...)            ← 网络层边界（msg/RDMA），不深入
```

要点：

* **构造位置**：[`raft_server_t::raft_send_appendentries()`](../src/raft/raft_server.cc#L1583) + [`create_appendentries()`](../src/raft/raft_server.cc#L1547)。消息类型 `msg_appendentries_t`（[raft_msg.proto:39-63](../proto/raft_msg.proto#L39-L63)）：`term / prev_log_idx / prev_log_term / leader_commit / repeated entries`。
* **一次带多少 entry**：`[start_index, end_index]` 整批，即 `raft_flush` 的 `[_first_idx, _current_idx]`（[raft_server.cc:1231,1246](../src/raft/raft_server.cc#L1231-L1246)），batch 内可含多条。
* **next_idx / match_idx 如何参与**：`next_idx` 决定 `prev_log_idx = next_idx-1`（此处 `create_appendentries(node, _first_idx)` 以批次起点为准，[raft_server.cc:1562](../src/raft/raft_server.cc#L1562)）；`match_idx` 在收到 ACK 后更新（见 §8）。两者存在 `raft_node`（[raft_node.h:49-70](../src/raft/raft_node.h#L49-L70)）。
* **交给网络层的位置**：[`raft_client_protocol::send_appendentries()`](../src/raft/raft_client_protocol.cc#L166-L179)——`common_msg_source` 包装 + `stub->append_entries`。
* **Follower 入口**：[`raft_service<PartitionManager>::append_entries()`](../src/raft/raft_service.h#L74-L122) → `invoke_on(shard)` → `append_entries_to_buffer()`（入队）→ poller 处理（见 §7）。

---

## 7. Follower append

```text
raft_service::append_entries()
  ↓ invoke_on(shard) → 入队 append_entries_to_buffer()
【poller 驱动】buffer_flush (period 0) → do_flush()
raft_recv_appendentries()
  ├─ term 检查：小→拒绝；大→become_follower
  ├─ 更新 current_leader / election_timer
  ├─ prev_log_idx 连续性检查（raft_get_entry_term）
  ├─ 冲突检查（同 idx 不同 term）→ raft_log_truncate()
  ├─ success=1；current_idx=prev_log_idx
  ├─ 追加：raft_append_entries() → log_append()  follower 版（连续取号）
  ├─ 落盘：follow_disk_append_complete → raft_disk_append_entries()
  └─ commit 推进：new_commit_idx = min(leader_commit, current_idx)
        ↓ 落盘完成
follow_raft_disk_append_finish()
  ├─ raft_set_commit_idx(new_commit_idx)
  └─ follow_raft_write_entry_finish() → 触发 RPC done，响应回 Leader
```

要点：

* **入口**：[`raft_service::append_entries()`](../src/raft/raft_service.h#L74-L122)；入队后由 [`append_entries_buffer::buffer_flush`](../src/raft/append_entry_buffer.cc#L45) poller（period 0）在 [`do_flush()`](../src/raft/append_entry_buffer.cc#L61) 中逐个处理。
* **连续性判断**：[`raft_get_entry_term(prev_log_idx)`](../src/raft/raft_server.cc#L668)——本地有这条 log 且 term 匹配才算连续。
* **冲突处理**：[`raft_log_truncate(ety_index)`](../src/raft/raft_server.cc#L788) 删掉冲突点之后全部（[raft_log.cc:130-141](../src/raft/raft_log.cc#L130-L141)），然后重新追加。细节本阶段不展开。
* **返回什么**：`msg_appendentries_response_t`（[raft_msg.proto:69-93](../proto/raft_msg.proto#L69-L93)）：`success / current_idx（已 append 到的最高 idx）/ first_idx / lease / term`。
* **什么时候算安全写入**：本地 `disk_log::append` 完成（[`follow_disk_append_complete::finish`](../src/raft/raft_server.cc#L578-L586)），随后才回响应。
* **主函数**：[`raft_recv_appendentries()`](../src/raft/raft_server.cc#L594)（校验/截断/追加/落盘全部在这里）。

---

## 8. Majority / Commit（本阶段重点）

```text
Follower 响应 → process_appendentries_response()
raft_process_appendentries_reply(r, is_heartbeat)
  ├─ term 校验（r.term > 自己 → 退位）
  ├─ 失败分支：E_INVAL/LOG_NOT_MATCH → 回退 next_idx、recovery（跳过）
  ├─ success == 1：
  │    next_idx = current_idx + 1
  │    match_idx = current_idx        ← 记录 Follower 复制进度
  │    is_heartbeat → 返回（不推进 commit）
  └─ process_response(0, current_idx)
        ↓
raft_node_process_commit(result, index, node_id)
  ├─ 统计 votes：index <= node->match_idx 的节点数
  ├─ leader_match：自己的 match_idx >= index
  ├─ 自己（Leader）的 match_idx 由 disk 落盘完成时设置
  └─ 多数派判断：node_num/2 < votes
        ↓
raft_set_commit_idx(index)
```

3 副本场景（Leader OSD3 + Follower OSD1/OSD7）：

```text
OSD3 落盘完成（自己的 match_idx = N）           → votes = 1
OSD1 ACK（current_idx = N）→ match_idx = N     → votes = 2
OSD7 未回                                          2/3 > 1.5
node_num/2 = 1 < 2 ✓ 且 leader_match ✓
→ raft_set_commit_idx(N)                        → entry N committed
```

要点：

* **response 处理位置**：[`raft_process_appendentries_reply()`](../src/raft/raft_server.cc#L372-L558)，由 RPC 回调 [`process_appendentries_response`](../src/raft/raft_client_protocol.cc#L117-L128) 触发。
* **match index 更新**：[`node->raft_node_set_match_idx(r->current_idx())`](../src/raft/raft_server.cc#L535-L536)；Leader 自己的 match_idx 由本地落盘回调设置（[raft_server.cc:1015-1018](../src/raft/raft_server.cc#L1015-L1018)）。
* **多数派计算**：[`raft_node_process_commit()`](../src/raft/raft_server.cc#L1009-L1062)——遍历 `_nodes_stat`（含成员变更期间的 new_nodes），条件 `node_num / 2 < votes && (new_node_num == 0 || new_node_num / 2 < new_votes)`，且必须 `leader_match`（Leader 自己已落盘，[raft_server.cc:1053](../src/raft/raft_server.cc#L1053)）。
* **commit 推进**：[`raft_set_commit_idx(index)`](../src/raft/raft.h#L220-L225)（断言 `_commit_idx <= idx <= _current_idx`）。
* **Follower 侧的 commit**：由 [`follow_raft_disk_append_finish()`](../src/raft/raft_server.cc#L560-L567) 按 `min(leader_commit, 本地已追加 idx)` 推进（[raft_server.cc:734-740](../src/raft/raft_server.cc#L734-L740)），心跳（空 appendentries）也会携带 `leader_commit` 完成这个推进（[raft_server.cc:751-755](../src/raft/raft_server.cc#L751-L755)）。

---

## 9. Commit → Apply

```text
raft_set_commit_idx(N)
  ↓
【poller 驱动】apply_task (period 0)
state_machine::raft_apply_entry()
  ├─ snapshot 进行中 → IDLE
  ├─ last_applied_idx == commit_idx → IDLE
  ├─ _apply_in_progress 互斥
  ├─ log_idx = last_applied_idx + 1
  ├─ raft_get_entry_by_idx(log_idx)      ← cache 有则取，没有则 disk_read 回读
  └─ apply(entry, apply_complete)
        ↓
osd_stm::apply()                         ← State Machine 边界
  ├─ 解析 meta（object_name/offset），调 _store.write()（object_store）
  └─ 对象 IO 完成 → write_obj_done → apply_complete::finish
        ↓
apply_complete::finish()
  ├─ set_last_applied_idx(idx)
  └─ raft_write_entry_finish() → entry_cache::complete_entry_between()
        ↓
osd_service_complete::finish()  → response->set_state + done->Run()
```

要点：

* **apply loop**：[`state_machine::apply_task`](../src/raft/state_machine.cc#L30) poller（period 0），每轮 reactor 循环检查一次。
* **committed entry 怎么取**：[`raft_get_entry_by_idx()`](../src/raft/raft.h#L363-L382)——先查 `entry_cache`，不在 cache 则 `disk_read` 回读（适用于刚启动、commit 未加载到 cache 的场景）。
* **交给谁**：`apply()` 是 `state_machine` 的虚函数，OSD 侧实现为 [`osd_stm::apply()`](../src/osd/osd_stm.cc#L31)，真正执行 `_store.write()`（object_store 写入）。
* **callback 何时触发**：对象数据写盘完成后，[`apply_complete::finish`](../src/raft/state_machine.cc#L38) → `raft_write_entry_finish` → [`complete_entry_between`](../src/raft/raft_cache.h#L103-L124) → 客户端 write 的 `osd_service_complete`。
* **Client write 完成**：**在 apply 完成时**发生（Leader 上），中间还包括了一次对象数据落盘（object_store，属于下一阶段）。Follower 上的 complete 只是 RPC done（回 ACK 给 Leader）。

---

## 10. Append / Replicated / Committed / Applied 对照

| 概念 | FastBlock 对应 | 证据 |
|---|---|---|
| Append | entry 已进本节点 `entry_cache`，`_current_idx` 已覆盖 | [`entry_cache::add`](../src/raft/raft_cache.h#L39)；[`_current_idx`](../src/raft/raft.h#L918) |
| Replicated | 某 Follower 的 `raft_node::_match_idx` ≥ 该 idx | [raft_server.cc:536](../src/raft/raft_server.cc#L536)；[raft_node.h:62-70](../src/raft/raft_node.h#L62-L70) |
| Committed | 满足多数派，`raft_server_t::_commit_idx` ≥ 该 idx | [raft.h:220-225](../src/raft/raft.h#L220-L225)；[raft_server.cc:1052-1058](../src/raft/raft_server.cc#L1052-L1058) |
| Applied | `state_machine::_last_applied_idx` ≥ 该 idx，FSM 已执行 | [state_machine.h:105](../src/raft/state_machine.h#L105)；[state_machine.cc:43](../src/raft/state_machine.cc#L43) |

顺序：`Append ≤ Replicated ≤ Committed ≤ Applied`（对 Leader 而言）。

---

## 11. 两次"写盘"的区别

```text
第一次：Raft Log 落盘（本阶段）
  raft_flush() → raft_log::disk_append() → disk_log::append
  ↓ 进入 src/localstore/（rolling_blob / SPDK blob）—— 下一阶段
  每个节点各自落盘；Leader 落盘完成是其 commit 的必要条件（leader_match）

第二次：State Machine apply 后 Object 数据落盘（下一阶段）
  osd_stm::apply() → _store.write() → object_store → localstore
  Client write 的完成信号在第二次落盘完成后才发出（apply_complete → osd_service_complete）
```

注意 FastBlock 的实际顺序：Leader **先发 AppendEntries 再本地落盘**（[raft_server.cc:1236-1256](../src/raft/raft_server.cc#L1236-L1256)），两条路径并发；commit 等待两者都完成（follower ACK + 自己落盘）。

* 第一次：[`raft_log::disk_append()`](../src/raft/raft_log.cc#L102) → [`disk_log::append()`](../src/localstore/disk_log.h#L89)
* 第二次：[`osd_stm::apply()`](../src/osd/osd_stm.cc#L31) → [`_store.write()`](../src/osd/osd_stm.cc#L90)

---

## 12. 一次 4KB write 完整串起来

假设：PG10（pool 0, pg 10），Leader = OSD3，Follower = OSD1 / OSD7；`write object_100, offset=4096, length=4KB`。

| 步骤 | 文件 / 函数 | 作用 |
|---|---|---|
| 1. OSD3 收到 write | [`osd_service::process_ring_write`](../src/osd/osd_service.cc#L354) → [`osd_stm::write_and_wait`](../src/osd/osd_stm.cc#L160) | 定位 PG、取对象锁 |
| 2. 封装 entry | [osd_stm.cc:180-185](../src/osd/osd_stm.cc#L180-L185) | `raft_entry_t{type=WRITE, meta={object_100,4096}, data=4KB}` |
| 3. propose | [`raft_write_entry`](../src/raft/raft_server.cc#L1086) | leader 检查、`set_term`、进 `_entry_queue` |
| 4. 生成 entry index=N | [`entry_queue_flush`](../src/raft/raft_log.cc#L85-L98) | `set_idx(_next_idx=N)`，进 `entry_cache` |
| 5. Leader 本地落盘 | [`raft_disk_append_entries`](../src/raft/raft_log.cc#L102) → `disk_log::append` | 4KB log entry 写入 log blob（LocalStore 边界） |
| 6. 发 AppendEntries | [`raft_send_appendentries`](../src/raft/raft_server.cc#L1583) → [`_client.send_appendentries`](../src/raft/raft_client_protocol.cc#L166) | 携带 `[N,N]` + `prev_log_idx=N-1` + `leader_commit`，发给 OSD1/OSD7 |
| 7. OSD1 append | [`raft_recv_appendentries`](../src/raft/raft_server.cc#L594) → 落盘 → 回 `success=1, current_idx=N` | OSD1 安全写入 |
| 8. OSD3 处理 ACK | [`raft_process_appendentries_reply`](../src/raft/raft_server.cc#L372) | `OSD1.match_idx=N`；OSD7 未回，跳过 |
| 9. 多数派 | [`raft_node_process_commit`](../src/raft/raft_server.cc#L1009) | votes=2（自己+OSD1），2>3/2 ✓ |
| 10. commit | [`raft_set_commit_idx`](../src/raft/raft.h#L220) | entry N committed |
| 11. apply | [`raft_apply_entry`](../src/raft/state_machine.cc#L53) → [`raft_get_entry_by_idx`](../src/raft/raft.h#L363) | 取 entry |
| 12. 交回 State Machine | [`osd_stm::apply`](../src/osd/osd_stm.cc#L31) → `_store.write` | 对象数据落盘（下一阶段） |
| 13. Client 完成 | [`apply_complete::finish`](../src/raft/state_machine.cc#L38) → [`osd_service_complete::finish`](../src/osd/osd_stm.cc#L125) | `response->set_state(0); done->Run()` |

---

## 13. 核心函数卡片

### `raft_write_entry(ety, complete)`
- 文件：[raft_server.cc:1086](../src/raft/raft_server.cc#L1086)
- 作用：Leader 侧 propose 入口；封装检查 + 入队。
- 输入：`raft_entry_t`（type/meta/data 已填）+ 客户端 complete。
- 关键步骤：leader/状态检查 → `set_term`（[:1117](../src/raft/raft_server.cc#L1117)）→ `raft_append_entry` 入 `_entry_queue`（[:1118](../src/raft/raft_server.cc#L1118)）。
- 关键状态：`_current_term`。
- 下一步：`raft_flush()`（poller 驱动）。
- 要搞懂：propose 时 entry **还没有 idx**，只带 term。

### `raft_flush()`
- 文件：[raft_server.cc:1186](../src/raft/raft_server.cc#L1186)
- 作用：Leader 把排队 entry 批量取号、发 follower、落盘。
- 输入：无（读 `_entry_queue` / `entry_cache`）。
- 关键步骤：`entry_queue_flush`（分配 idx）→ `_first_idx/_current_idx` 定位批次 → 逐节点 `raft_send_appendentries` → `raft_disk_append_entries`。
- 关键状态：`_first_idx / _current_idx / _next_idx`。
- 下一步：[`raft_send_appendentries()`](../src/raft/raft_server.cc#L1583)、`disk_append`（LocalStore）。
- 要搞懂：复制与落盘并发；`raft_task_func` 在上一批 commit 前不会再来。

### `raft_send_appendentries(node, start, end)` / `create_appendentries()`
- 文件：[raft_server.cc:1583](../src/raft/raft_server.cc#L1583) / [:1547](../src/raft/raft_server.cc#L1547)
- 作用：构造并发送 AppendEntries。
- 关键步骤：`prev_log_idx = start-1`，`prev_log_term` 回查，`leader_commit` 附带，`_raft_get_entries_from_idx` 取 entry，`_client.send_appendentries`。
- 下一步：网络层（[raft_client_protocol.cc:166](../src/raft/raft_client_protocol.cc#L166)）。
- 要搞懂：**leader_commit 随消息下发**，Follower 靠它推进 commit。

### `raft_recv_appendentries(node_id, ae, r, complete)`
- 文件：[raft_server.cc:594](../src/raft/raft_server.cc#L594)
- 作用：Follower 处理 AppendEntries（校验、冲突删除、追加、落盘）。
- 关键步骤：term 检查（[:631-651](../src/raft/raft_server.cc#L631-L651)）→ prev_log 检查（[:662-676](../src/raft/raft_server.cc#L662-L676)）→ 冲突 `raft_log_truncate`（[:788](../src/raft/raft_server.cc#L788)）→ `log_append` 连续取号（[raft_log.cc:28-42](../src/raft/raft_log.cc#L28-L42)）→ 落盘（[:762-763](../src/raft/raft_server.cc#L762-L763)）→ 计算 `new_commit_idx = min(leader_commit, current_idx)`（[:734-740](../src/raft/raft_server.cc#L734-L740)）。
- 关键状态：`_current_idx / _commit_idx / _next_idx`。
- 下一步：[`follow_disk_append_complete`](../src/raft/raft_server.cc#L569)（落盘回调）。
- 要搞懂：Follower 的 idx 由自己 `_next_idx` 分配，必须与 `prev_log_idx` 衔接。

### `raft_process_appendentries_reply(r, is_heartbeat)`
- 文件：[raft_server.cc:372](../src/raft/raft_server.cc#L372)
- 作用：Leader 处理 Follower 的 ACK / 拒绝。
- 关键步骤：term 校验 → 失败分支（回退 next_idx / recovery，跳过）→ 成功：`next_idx`/`match_idx` 更新（[:535-536](../src/raft/raft_server.cc#L535-L536)）→ `raft_node_process_commit`。
- 关键状态：`node->next_idx / match_idx`。
- 下一步：[`raft_node_process_commit()`](../src/raft/raft_server.cc#L1009)。
- 要搞懂：心跳响应（is_heartbeat=true）只更新 lease，不推进 commit。

### `raft_node_process_commit(result, index, node_id)`
- 文件：[raft_server.cc:1009](../src/raft/raft_server.cc#L1009)
- 作用：多数派计数 + commit 推进（本阶段最重要的函数）。
- 关键步骤：遍历节点统计 `index <= match_idx` 的票数 → `leader_match` 检查 → `node_num/2 < votes` → `raft_set_commit_idx`（[:1052-1058](../src/raft/raft_server.cc#L1052-L1058)）。
- 关键状态：`_commit_idx`、各节点 `match_idx`。
- 下一步：[`raft_set_commit_idx()`](../src/raft/raft.h#L220) → apply poller。
- 要搞懂：Leader 自己的票来自本地落盘回调（[`raft_disk_append_finish`](../src/raft/raft_server.cc#L1064-L1066)）。

### `state_machine::raft_apply_entry()`
- 文件：[state_machine.cc:53](../src/raft/state_machine.cc#L53)
- 作用：apply 循环主体（由 `apply_task` poller 每轮调用）。
- 关键步骤：`last_applied == commit` 则停（[:70](../src/raft/state_machine.cc#L70)）→ `raft_get_entry_by_idx(last_applied+1)`（[:79](../src/raft/state_machine.cc#L79)）→ `apply(ety, apply_complete)`（[:93](../src/raft/state_machine.cc#L93)）。
- 关键状态：`_last_applied_idx / _apply_in_progress`。
- 下一步：[`osd_stm::apply()`](../src/osd/osd_stm.cc#L31)。
- 要搞懂：一条 entry 只能在前一条 apply 完成（`_apply_in_progress` 复位）后开始。

### `osd_stm::apply(entry, complete)`
- 文件：[osd_stm.cc:31](../src/osd/osd_stm.cc#L31)
- 作用：执行 committed entry，把用户数据写进 object_store（State Machine 边界）。
- 关键步骤：解析 meta → `_store.write()`（[:90](../src/osd/osd_stm.cc#L90)）→ 完成回调链。
- 下一步：[`apply_complete::finish`](../src/raft/state_machine.cc#L38) → 客户端完成。
- 要搞懂：这里开始是**第二次落盘**，属于下一阶段。

---

## 14. 必要数据结构（write path 最小集）

| 结构 | 是什么 | 保存什么 | write path 中的作用 |
|---|---|---|---|
| `raft_server_t`（[raft.h:862-951](../src/raft/raft.h#L862-L951)） | 一个 PG 在本机的 Raft 实例 | `_current_term / _commit_idx / _current_idx / _identity / _leader_id / _log / _machine / _nodes_stat` | 整个 Raft 逻辑的载体 |
| `raft_node`（[raft_node.h:26](../src/raft/raft_node.h#L26)） | 一个 peer 的视图 | `_next_idx / _match_idx / _lease / _suppress_heartbeats` | Leader 记录每个 Follower 的复制进度 |
| `raft_entry_t`（[raft_msg.proto:22-33](../proto/raft_msg.proto#L22-L33)） | 一条 Raft log | `term / idx / type / meta / data` | 4KB 用户数据在这里 |
| `msg_appendentries_t`（[raft_msg.proto:39-63](../proto/raft_msg.proto#L39-L63)） | Leader→Follower 消息 | `term / prev_log_idx / prev_log_term / leader_commit / entries[]` | 复制载体 |
| `msg_appendentries_response_t`（[raft_msg.proto:69-93](../proto/raft_msg.proto#L69-L93)） | Follower→Leader 响应 | `success / current_idx / first_idx / lease / term` | ACK 载体 |
| `raft_log`（[raft_log.h:26](../src/raft/raft_log.h#L26)） | 日志管理器 | `entry_cache _entries / _next_idx / disk_log*` | 内存 log + 落盘边界 |
| `entry_cache`（[raft_cache.h:24](../src/raft/raft_cache.h#L24)） | 内存 log 缓存 | `cache_item{entry, complete}` | 保存 entry 及其客户端 context |
| `state_machine`（[state_machine.h:23](../src/raft/state_machine.h#L23)） | FSM 基类 | `_last_applied_idx / _apply_in_progress / _store` | apply 边界 |

---

## 15. 阅读顺序

```text
第 1 个文件：pg_group.cc + pg_group.h      PG ↔ raft_server_t 绑定、创建
  ↓
第 2 个文件：osd_stm.cc (write_and_wait)   write 封装成 raft_entry_t、propose 入口
  ↓
第 3 个文件：raft_server.cc (raft_write_entry / raft_flush)   Leader append + 批量取号
  ↓
第 4 个文件：raft_server.cc (raft_send_appendentries / create_appendentries) + raft_client_protocol.cc   AppendEntries 构造与发送
  ↓
第 5 个文件：raft_service.h + append_entry_buffer.cc + raft_server.cc (raft_recv_appendentries)   Follower 接收与追加
  ↓
第 6 个文件：raft_server.cc (raft_process_appendentries_reply / raft_node_process_commit)   ACK / 多数派 / commit
  ↓
第 7 个文件：state_machine.cc (raft_apply_entry) + osd_stm.cc (apply)   apply 循环 → State Machine 边界
  ↓
进入 src/localstore/
```

---

## 16. 总结图

```text
PG Write (OSD3/PG10)
   ↓
Raft Propose ─ raft_write_entry()
   ↓
Leader Log ─ entry_queue_flush() 分配 idx=N → entry_cache → disk_append
   ↓
AppendEntries ─ raft_send_appendentries() (prev=N-1, leader_commit)
   ↓
Followers ─ raft_recv_appendentries() 校验+追加+落盘
   ↓
ACK ─ success=1, current_idx=N
   ↓
Majority ─ raft_node_process_commit()  (leader 落盘 + 1 follower = 2/3)
   ↓
Commit Index ─ raft_set_commit_idx(N)
   ↓
Apply ─ raft_apply_entry() (last_applied+1)
   ↓
OSD State Machine ─ osd_stm::apply() → object_store (下一阶段)
```

---

## Checklist

- [x] 一个 PG 和一个 Raft Group 是什么关系？→ `(pool_id, pg_id)` 相同的一组 `raft_server_t`（[pg_group.cc:30-43](../src/raft/pg_group.cc#L30-L43)）
- [x] write 从哪个函数进入 Raft？→ [`raft_server_t::raft_write_entry()`](../src/raft/raft_server.cc#L1086)
- [x] log entry 在哪里创建？→ [`osd_stm::write_and_wait()`](../src/osd/osd_stm.cc#L180-L185)；idx 在 [`entry_queue_flush()`](../src/raft/raft_log.cc#L85-L98) 分配
- [x] Leader 怎么 append 自己的日志？→ [`raft_flush()`](../src/raft/raft_server.cc#L1186) → `entry_queue_flush` + [`disk_append`](../src/raft/raft_log.cc#L102)
- [x] AppendEntries 在哪里构造？→ [`create_appendentries()`](../src/raft/raft_server.cc#L1547)
- [x] Follower 从哪个函数接收日志？→ [`raft_recv_appendentries()`](../src/raft/raft_server.cc#L594)，入口 [`raft_service::append_entries()`](../src/raft/raft_service.h#L74)
- [x] Follower append 成功后返回什么？→ `success=1 / current_idx / first_idx / lease / term`（[raft_server.cc:706-743](../src/raft/raft_server.cc#L706-L743)）
- [x] Leader 怎么记录 Follower 的复制进度？→ `raft_node::_match_idx / _next_idx`（[raft_server.cc:535-536](../src/raft/raft_server.cc#L535-L536)；[raft_node.h:49-70](../src/raft/raft_node.h#L49-L70)）
- [x] 多数派在哪里判断？→ [`raft_node_process_commit()`](../src/raft/raft_server.cc#L1009-L1062)
- [x] commit index 怎么前进？→ [`raft_set_commit_idx()`](../src/raft/raft.h#L220-L225)
- [x] committed entry 怎么进入 apply？→ `apply_task` poller → [`raft_apply_entry()`](../src/raft/state_machine.cc#L53) → [`raft_get_entry_by_idx()`](../src/raft/raft.h#L363)
- [x] apply 怎么回到 OSD State Machine？→ [`osd_stm::apply()`](../src/osd/osd_stm.cc#L31)，完成后 [`apply_complete::finish`](../src/raft/state_machine.cc#L38) 触发客户端完成
- [x] Raft log 落盘和 Object 数据落盘有什么区别？→ 第一次：[`raft_log::disk_append`](../src/raft/raft_log.cc#L102)→`disk_log`；第二次：[`osd_stm::apply`](../src/osd/osd_stm.cc#L90)→`object_store`，Client 完成信号在第二次之后