# FastBlock 第四阶段：`src/osd/`（write 请求进入 OSD → 交给 Raft）

> **前置**：Client 侧已完成（write RPC 经 RDMA 发出）。
> **本阶段范围**：一次 write RPC 到达 OSD 后，如何找到 PG、进入 PG 状态机、最终交给 Raft。**到 [raft_write_entry()](src/raft/raft.h#L462) 为止**。Raft 复制/commit/apply、LocalStore、Monitor、RDMA 接收细节一律不展开。
> **链接说明**：本文所有代码链接都是相对路径 + `#L行号`，在 VSCode 中点击函数名可直接跳转；`↓` 表示调用方向。

---

## 1. `src/osd/` 文件清单

| 文件 | 职责 | 判定 |
|---|---|---|
| [osd.cc](src/osd/osd.cc)（1400行） | OSD 主程序：启动、建 `partition_manager`、建并注册 RPC service | 只看注册部分 |
| [osd_service.h](src/osd/osd_service.h) / [osd_service.cc](src/osd/osd_service.cc) | **RPC 服务层**：[process_write 入口](src/osd/osd_service.h#L71)、PG 查找、Leader 检查、分发到状态机 | **核心，第 1 个看** |
| [osd_stm.h](src/osd/osd_stm.h) / [osd_stm.cc](src/osd/osd_stm.cc) | **PG 状态机**：[write_and_wait](src/osd/osd_stm.cc#L160)、构造 Raft 日志条目、调用 [raft_write_entry](src/osd/osd_stm.cc#L185) | **核心，第 2 个看** |
| [partition_manager.h](src/osd/partition_manager.h) / [partition_manager.cc](src/osd/partition_manager.cc) | **PG 管理**：PG→core 映射、PG→raft 组、PG→osd_stm 三个表 | **核心，第 3 个看** |
| [mon_client.cc](src/osd/mon_client.cc) | OSD 侧的 monitor 客户端（拿地址/OSD 信息） | 顺带看，2 个函数 |
| [raw_tcp_server.cc](src/osd/raw_tcp_server.cc) | 另一套 raw TCP 协议入口（也调 [service->process_write](src/osd/raw_tcp_server.cc#L768)） | **第一遍跳过** |
| [data_statistics.cc](src/osd/data_statistics.cc) | IO 统计 | **跳过** |

---

## 2. OSD 内部主线图（先看全貌）

- Client write RPC（RDMA）
  ↓
- [msg::rdma::server](src/include/fastblock/msg/rdma/server.h)（OSD 侧 RPC 服务器）——反序列化 + 按 service/method 分发
  ↓
- [osd_service::process_write()](src/osd/osd_service.h#L71)
  ↓
- [process<write_request, write_reply>()](src/osd/osd_service.h#L215) —— 读 pool_id / pg_id
  ↓
- [partition_manager::get_pg_shard()](src/osd/partition_manager.cc#L22) —— 找 PG 在哪个 core
  ↓
- [invoke_on(shard_id)](src/osd/osd_service.h#L228) —— 切到 PG 所在线程
  ↓
- [partition_manager::get_pg()](src/osd/partition_manager.h#L82) —— 返回该 PG 的 [raft_server_t](src/raft/raft.h)
  ↓
- [raft->raft_is_leader()](src/osd/osd_service.h#L238) —— Leader 检查
  ↓
- [raft_get_op_state()](src/osd/osd_service.h#L246) —— PG 状态检查
  ↓
- [partition_manager::get_osd_stm()](src/osd/partition_manager.h#L75) —— 取该 PG 的状态机
  ↓
- [osd_stm::write_and_wait()](src/osd/osd_stm.cc#L160)
  ↓
- 构造 [raft_entry_t](src/osd/osd_stm.cc#L180)（RAFT_LOGTYPE_WRITE）
  ↓
- [raft->raft_write_entry(entry, complete)](src/osd/osd_stm.cc#L185) → [raft.h#L462](src/raft/raft.h#L462)
  ↓
- **★ 本阶段结束，进入 src/raft/**

---

## 3. Client RPC 怎么进入 OSD

**RPC service 定义**：[osd_service.h#L29](src/osd/osd_service.h#L29) `class osd_service : public osd::rpc_service_osd` —— 继承 protobuf 生成的 service 基类，override 每个 RPC 方法。

**[process_write() 服务端实现](src/osd/osd_service.h#L71)**：只做一件事——转给模板函数 [process<osd::write_request, osd::write_reply>](src/osd/osd_service.h#L76)。

**启动时注册**：[osd.cc#L330](src/osd/osd.cc#L330) 创建 `global_osd_service = make_unique<osd_service>(global_pm.get(), g_monitor_client)`；[osd.cc#L315-316](src/osd/osd.cc#L315) 每个 shard 的 RDMA server [add_service(global_osd_service.get())](src/osd/osd.cc#L316)。

**RDMA 收到 write 后最终进入哪个函数**：[server.h#L649-654](src/include/fastblock/msg/rdma/server.h#L649)：

```cpp
service_it->second->data->CallMethod(        // 按 RPC header 里的 service/method 分发
  method, ctrlr, request_body, response_body, done);
```

即：RDMA server 收包 → [unserialize_data 反序列化请求体](src/include/fastblock/msg/rdma/server.h#L625) → 生成 response 原型（[L629-630](src/include/fastblock/msg/rdma/server.h#L629)）→ 生成 `rpc_controller`（带 PD 和 peer 地址，供 write ring 用，[L631-633](src/include/fastblock/msg/rdma/server.h#L631)）→ protobuf 生成的分发器调到 `osd_service::process_write`。

**`write_request` 怎么被拿到**：`CallMethod` 的 `request_body` 就是反序列化好的 `osd::write_request*`，直接作为参数传入。

---

## 4. write request 里有什么

[proto/osd_msg.proto#L16-23](proto/osd_msg.proto#L16)：

| 字段 | OSD 为什么需要 |
|---|---|
| `pool_id` | 定位 PG 的第一维（PG 名 = pool_id+pg_id，[pg_id_to_name](src/raft/raft.h#L66)） |
| `pg_id` | 定位 PG 的第二维；两者共同决定"这个写属于哪个 PG/Raft 组" |
| `object_name` | 落盘对象名 + 对象锁的 key（[_object_rw_lock.lock(object_name, ...)](src/osd/osd_stm.cc#L189)） |
| `offset` | 对象内偏移，随 [write_cmd](proto/osd_msg.proto#L58) 进 Raft 日志（OSD 端不需要它定位 PG） |
| `data` | 写入数据，作为 Raft 日志条目的 data 部分 |

---

## 5. OSD 怎么找到对应 PG —— [process<> 模板](src/osd/osd_service.h#L215)

```cpp
template<typename request_type, typename reply_type>
void osd_service::process(const request_type* request, reply_type* response, google::protobuf::Closure* done){
    auto pool_id = request->pool_id();          // L217
    auto pg_id = request->pg_id();              // L218
    uint32_t shard_id;

    if(!_pm->get_pg_shard(pool_id, pg_id, shard_id)){          // L221: PG→core
        response->set_state(err::RAFT_ERR_NOT_FOUND_PG);       // PG 不存在
        done->Run(); return;
    }

    _pm->get_shard().invoke_on(shard_id, [this, ...](){        // L228: 切到 PG 所在线程
        auto raft = _pm->get_pg(shard_id, pool_id, pg_id);     // L231: PG→raft_server_t
        if(!raft){ ...RAFT_ERR_NOT_FOUND_PG... }
        if(!raft->raft_is_leader()){                           // L238: Leader 检查
            response->set_state(err::RAFT_ERR_NOT_LEADER);
            done->Run(); return;
        }
        auto err_num = raft_state_to_errno(raft->raft_get_op_state());  // L246: PG 状态检查
        if(err_num != err::E_SUCCESS){ ... }
        auto osd_stm_p = _pm->get_osd_stm(shard_id, pool_id, pg_id);    // L255: PG→状态机
        if(!osd_stm_p){ ...RAFT_ERR_NOT_FOUND_PG... }
        process(osd_stm_p, request, response, done);           // L262: 交给状态机
    });
}
```

**重点**：
- PG 用 `pool_id + pg_id` 共同定位（拼成 PG 名，两级查表：先 [get_pg_shard](src/osd/partition_manager.cc#L22) 找 core，再在对应 shard 的表里找 PG）。
- **PG 不存在** → `RAFT_ERR_NOT_FOUND_PG`（Client 收到后会重试并重新查 map）。
- **PG 状态不允许写** → [raft_get_op_state()](src/raft/raft.h#L646) 翻译成的错误码（如初始化中、已关闭，+ [raft_state_to_errno](src/raft/raft.h#L64)）。
- 返回值 [get_pg](src/osd/partition_manager.h#L82) 是 **`std::shared_ptr<raft_server_t>`**——OSD 里"一个 PG"本质就是一个 Raft 服务器实例。

---

## 6. `partition_manager` — PG 管理核心

[partition_manager.h#L152-157](src/osd/partition_manager.h#L152) 内部就是三张表：

```cpp
pg_group_t _pgs;                                        // PG → raft_server_t（Raft 组）
std::map<std::string, shard_revision> _shard_table;     // PG → 所在 shard(core)
std::vector<std::map<std::string, std::shared_ptr<osd_stm>>> _sm_table;  // shard → PG → 状态机
```

write path 用到的三个查询（都按 [pg_id_to_name(pool_id, pg_id)](src/raft/raft.h#L66) 拼名字）：

| 查询 | 位置 | 返回 | 作用 |
|---|---|---|---|
| [get_pg_shard()](src/osd/partition_manager.cc#L22) | partition_manager.cc:22 | bool + shard_id | 查 `_shard_table`：PG 属于哪个 core |
| [get_pg()](src/osd/partition_manager.h#L82) | partition_manager.h:82-85 | `shared_ptr<raft_server_t>` | 查 `_pgs`（[pg_group.h#L134-137](src/raft/pg_group.h#L134)）：PG 的 Raft 组 |
| [get_osd_stm()](src/osd/partition_manager.h#L75) | partition_manager.h:75-80 | `shared_ptr<osd_stm>` | 查 `_sm_table[shard]`：PG 的状态机 |

**回答你的问题**：
- 管理什么：PG→core 映射、PG→Raft 组、PG→状态机，以及 PG 的创建/删除/激活（[create_partition](src/osd/partition_manager.h#L59) 等，本阶段不展开）。
- PG 什么时候创建的：Monitor 下发建 PG 请求 → [process_create_pg](src/osd/osd_service.cc#L269) → [_pm->create_partition()](src/osd/osd_service.cc#L290)，建好后三张表各填一项。
- **一个 OSD 为什么有很多 PG**：一个 PG 是一个 Raft 组，组成员分布在多个 OSD 上；一个 OSD 同时是很多 PG 的成员，所以 OSD 内"多 PG 共存"，每个 PG 都有自己的 raft 实例和 osd_stm。

---

## 7. write path 必需的数据结构

| 结构 | 是什么 | 与 PG 的关系 | 保存什么关键状态 |
|---|---|---|---|
| [raft_server_t](src/raft/raft.h) | 一个 PG 的 Raft 服务器实例 | **一个 PG = 一个 raft_server_t** | 节点角色/Leader 信息、日志、op 状态（[raft_is_leader](src/raft/raft.h#L296)、[raft_get_op_state](src/raft/raft.h#L646) 都从它取） |
| [osd_stm](src/osd/osd_stm.h#L218) | PG 的**状态机**，继承 [raft::state_machine](src/raft/state_machine.h) | 一个 PG 对应一个 osd_stm，与 raft 实例成对 | 对象读写锁、LocalStore 引用（`_store`）、[get_raft()](src/osd/osd_stm.h#L15) 拿回 raft |
| [raft_entry_t](src/raft/raft.h#L964) | Raft **日志条目** | 承载一次写操作 | `type(RAFT_LOGTYPE_WRITE) / meta(write_cmd) / data(用户数据)` |
| [osd::write_cmd](proto/osd_msg.proto#L58) | 日志里的"写命令" | 进 raft 的 meta | `object_name / offset` |

write 最终要找到 `osd_stm` 的原因：**它是 PG 与 Raft 之间的桥**——[osd_stm::write_and_wait](src/osd/osd_stm.cc#L160) 负责把用户请求翻译成 `raft_entry_t` 并提交给 raft。

---

## 8. write 进入状态机 —— [osd_stm::write_and_wait()](src/osd/osd_stm.cc#L160)

```cpp
void osd_stm::write_and_wait(const osd::write_request* request,
            osd::write_reply* response, google::protobuf::Closure* done){
    osd_service_complete<osd::write_reply> *write_complete =
      new osd_service_complete<osd::write_reply>(this, request->object_name(),
        request->data().size(), response, done);                    // L165: 完成回调（最终填 response + done）

    auto write_func = [this, request, write_complete](){
        osd::write_cmd cmd;
        cmd.set_object_name(request->object_name());                // L171
        cmd.set_offset(request->offset());                          // L172
        std::string buf;
        cmd.SerializeToString(&buf);                                // L174: 命令序列化成 meta

        auto entry_ptr = std::make_shared<raft_entry_t>();          // L180
        entry_ptr->set_type(RAFT_LOGTYPE_WRITE);                    // L181
        entry_ptr->set_meta(std::move(buf));                        // L182: write_cmd
        entry_ptr->set_data(std::move(request->data()));            // L183: 用户数据

        get_raft()->raft_write_entry(entry_ptr, write_complete);    // L185: ★ 交给 Raft
    };

    lock_complete *complete = new lock_complete(std::move(write_func));
    _object_rw_lock.lock(request->object_name(),                    // L189: 对象级 RW 锁
      utils::operation_type::WRITE, complete);
}
```

**要点**：
- `osd_stm` 就是 PG 的 State Machine：继承 [state_machine](src/osd/osd_stm.h#L218)，一个 PG 一个实例。
- 流程：**先拿对象写锁**（同 object 的读写互斥，[lock_manager](src/osd/osd_stm.h#L144)/[op_type_excl_lock](src/osd/osd_stm.h#L25)）→ 锁到手后构造日志条目 → 提交给 raft。
- `write_complete`（[osd_service_complete](src/osd/osd_stm.cc#L108)）是整个 write 的"终点回调"：raft 完成后它负责 [response->set_state(r) + done->Run()](src/osd/osd_stm.cc#L143) + 解锁——**这就是 Client 端收到的 `write_reply` 的来源**。
- 状态机的 [apply()](src/osd/osd_stm.cc#L31) 是 Raft commit 后回调落盘的地方（进 LocalStore），**属于下一阶段**，本阶段不展开。

---

## 9. Leader 判断

**在哪里检查**：[osd_service.h#L238](src/osd/osd_service.h#L238) `if(!raft->raft_is_leader())`。

**Leader 状态从哪取**：[raft_server_t::raft_is_leader()](src/raft/raft.h#L296)——查该 PG 的 Raft 实例自己的角色状态（本地判定，不问别人）。

**不是 Leader 返回什么**：[osd_service.h#L241-243](src/osd/osd_service.h#L241)：

```cpp
response->set_state(err::RAFT_ERR_NOT_LEADER);
done->Run();
```

**Client 为什么之后可能收到 `RAFT_ERR_NOT_LEADER`**：Client 的 `_leader_osd` 是缓存（第二阶段），缓存的 Leader 可能已经过期——Raft 随时可能选出新 Leader（旧 Leader 宕机/网络分区），或者 PG 发生了成员变更。所以 OSD 收到请求时必须以**自己当前的 raft 状态**为准重新确认。

**Client 收到后的行为**（回顾 2.5）：`RAFT_ERR_NOT_LEADER` 在 [should_retry_request()](src/include/fastblock/client/fb_client.h#L210) 的重试集合里 → [retry_request()](src/include/fastblock/client/fb_client.h#L326) 失效 Leader 缓存 → 重新 get_leader → 重新发。这就是"缓存会过期 → 每次都要复核"的闭环。

---

## 10. 转交给 Raft —— 本阶段终点

**调用点**：[osd_stm.cc#L185](src/osd/osd_stm.cc#L185)：

```cpp
get_raft()->raft_write_entry(entry_ptr, write_complete);
```

- [get_raft()](src/osd/osd_stm.h#L15)：`osd_stm` 继承自 `state_machine`，拿回本 PG 绑定的 `raft_server_t`。
- **接口**：[raft.h#L462](src/raft/raft.h#L462) `int raft_write_entry(std::shared_ptr<raft_entry_t> ety, utils::context *complete);`
- **交给 Raft 的核心内容**：一个 `raft_entry_t` 日志条目——`type = RAFT_LOGTYPE_WRITE`（[raft.h#L964](src/raft/raft.h#L964)）、`meta = 序列化的 write_cmd（object_name + offset）`、`data = 用户数据`。
- **callback 一起传下去**：`write_complete`（`osd_service_complete`，本身是 `utils::context`）随条目提交；Raft 完成（commit/apply）后会回调它，从而触发 [response->set_state(r) + done->Run()](src/osd/osd_stm.cc#L143)。

**从这一行开始正式进入 `src/raft/`**。之后 Raft 内部（复制、选举、commit、apply 回 [osd_stm::apply()](src/osd/osd_stm.cc#L31)）全部放到下一阶段。

---

## 11. 一次 4KB write 贯穿 OSD 阶段

```text
前提：pool_id=1, pg_id=10, object_name="object_100", offset=4096, data=4KB
      OSD3 是 PG10 的 Leader（Client 缓存 + OSD 自身确认）
```

| 步骤 | 实际过程 | 源码位置 |
|---|---|---|
| 1 | RDMA server 收包、反序列化 `write_request`，按 meta 分发 | [server.h#L625-654](src/include/fastblock/msg/rdma/server.h#L625) |
| 2 | [osd_service::process_write()](src/osd/osd_service.h#L71) → [process<write_request, write_reply>()](src/osd/osd_service.h#L215) | osd_service.h:71 / L215 |
| 3 | 读 `pool_id=1, pg_id=10`，[get_pg_shard(1,10)](src/osd/osd_service.h#L221) → shard_id | osd_service.h:217-221 |
| 4 | [invoke_on(shard_id)](src/osd/osd_service.h#L228) 切到 PG10 所在线程 | osd_service.h:228 |
| 5 | [get_pg(shard, 1, 10)](src/osd/osd_service.h#L231) → PG10 的 `raft_server_t` | osd_service.h:231 |
| 6 | [raft_is_leader()](src/osd/osd_service.h#L238) 确认 OSD3 是 Leader（是 → 继续） | osd_service.h:238 |
| 7 | [raft_get_op_state()](src/osd/osd_service.h#L246) 确认 PG10 可写 | osd_service.h:246 |
| 8 | [get_osd_stm(shard, 1, 10)](src/osd/osd_service.h#L255) → PG10 的状态机 | osd_service.h:255 |
| 9 | [process(osd_stm, ...)](src/osd/osd_service.cc#L446) → [osd_stm->write_and_wait(...)](src/osd/osd_service.cc#L451) | osd_service.cc:446-451 |
| 10 | 拿 object_100 写锁 → 构造 [raft_entry_t{WRITE, write_cmd, 4KB data}](src/osd/osd_stm.cc#L180) | osd_stm.cc:169-189 |
| 11 | [get_raft()->raft_write_entry(entry, write_complete)](src/osd/osd_stm.cc#L185) | osd_stm.cc:185 |
| 12 | ★ 进入 `src/raft/`，本阶段结束 | — |

---

## 12. 本阶段建议阅读顺序

- 1. [osd_service.h](src/osd/osd_service.h)（重点：[process_write L71](src/osd/osd_service.h#L71) / [process 模板 L215-263](src/osd/osd_service.h#L215)）
  ↓
- 2. [osd_stm.cc](src/osd/osd_stm.cc)（重点：[write_and_wait L160-190](src/osd/osd_stm.cc#L160)，到 [raft_write_entry](src/osd/osd_stm.cc#L185) 停止）
  ↓
- 3. [partition_manager.h](src/osd/partition_manager.h)（重点：[三张表 L152-157](src/osd/partition_manager.h#L152) + [get_pg](src/osd/partition_manager.h#L82)/[get_osd_stm](src/osd/partition_manager.h#L75)）
  ↓
- 4. [osd.cc 注册](src/osd/osd.cc#L315)（L315-316、L330）+ [raft.h 的 raft_write_entry 签名](src/raft/raft.h#L462)
  ↓
- 到这里停止

辅助查阅：[pg_group.h#L134-137](src/raft/pg_group.h#L134)（get_pg 实现）、[raft.h#L296/L646](src/raft/raft.h#L296)（Leader/状态查询）、[osd_msg.proto#L58](proto/osd_msg.proto#L58)（write_cmd）、[server.h#L649](src/include/fastblock/msg/rdma/server.h#L649)（RPC 分发）。

---

## 13. 一屏调用链

- Client write RPC（RDMA）
  ↓
- [msg::rdma::server 收包反序列化](src/include/fastblock/msg/rdma/server.h#L625)
  ↓
- [CallMethod 分发](src/include/fastblock/msg/rdma/server.h#L649)
  ↓
- [osd_service::process_write()](src/osd/osd_service.h#L71)
  ↓
- [process<write_request, write_reply>()](src/osd/osd_service.h#L215)
  ↓
- [get_pg_shard() → shard_id](src/osd/partition_manager.cc#L22)
  ↓
- [invoke_on(shard)](src/osd/osd_service.h#L228)
  ↓
- [get_pg() → raft_server_t（PG10 的 Raft 组）](src/osd/partition_manager.h#L82)
  ↓
- [raft_is_leader() / raft_get_op_state()](src/osd/osd_service.h#L238)
  ↓
- [get_osd_stm() → osd_stm](src/osd/partition_manager.h#L75)
  ↓
- [osd_stm::write_and_wait()](src/osd/osd_stm.cc#L160)
  ↓
- [构造 raft_entry_t → raft->raft_write_entry(entry, complete)](src/osd/osd_stm.cc#L185) → [raft.h#L462](src/raft/raft.h#L462)
  ↓
- **★ 进入 src/raft/**

---

## 14. Checklist

- [ ] Client 的 write RPC 在 OSD 端从哪个函数进入？（[osd_service::process_write](src/osd/osd_service.h#L71)，osd_service.h:71）
- [ ] `write_request` 里哪些字段是 OSD 处理所必须的？（pool_id/pg_id 定位 PG，object_name/offset/data 进日志）
- [ ] OSD 内 PG 保存在哪里？（`partition_manager` 的三张表：[_shard_table](src/osd/partition_manager.h#L154) / [_pgs](src/osd/partition_manager.h#L152) / [_sm_table](src/osd/partition_manager.h#L157)）
- [ ] `pool_id + pg_id` 怎么找到对应 PG？（拼成 PG 名，先查 shard 再查 raft 组/状态机）
- [ ] `partition_manager` 在 write path 里做什么？（PG→core、PG→raft、PG→stm 三级查找）
- [ ] `osd_stm` 是什么？（PG 的状态机，继承 `state_machine`，一个 PG 一个）
- [ ] write 请求怎么进入 `osd_stm`？（[process(osd_stm_p, ...)](src/osd/osd_service.h#L262) → [write_and_wait](src/osd/osd_stm.cc#L160)）
- [ ] OSD 在哪里判断自己是不是 PG Leader？（[raft_is_leader()](src/osd/osd_service.h#L238)，osd_service.h:238）
- [ ] 不是 Leader 时返回什么？（`RAFT_ERR_NOT_LEADER`，Client 收到后会重试并重查 Leader）
- [ ] write 最后调用哪个 Raft 接口？（[raft_write_entry(raft_entry_t, utils::context*)](src/raft/raft.h#L462)）
- [ ] 哪一行开始正式进入 `src/raft/`？（[osd_stm.cc:185](src/osd/osd_stm.cc#L185) `get_raft()->raft_write_entry(...)`）

---

## 15. 下一阶段预告（暂不展开）

`src/raft/`：[raft_write_entry 内部](src/raft/raft_server.cc#L1086)（日志追加、`AppendEntries` 复制到 Follower、过半确认、commit）→ commit 后回调 [osd_stm::apply()](src/osd/osd_stm.cc#L31) → [write_obj](src/osd/osd_stm.cc#L79) → LocalStore 落盘 → `write_complete` 回包给 Client。**LocalStore 完整文档：[route6.md](route6.md)**。