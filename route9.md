# FastBlock 第九阶段：Monitor / monclient 控制面

> **前置**：已完成数据面（Client → OSD → Raft → LocalStore）。本阶段讲控制面：Monitor 保存什么、monclient 怎么把地图同步到 Client/OSD 本地、数据面怎么消费这些信息。
> **链接说明**：FastBlock 函数用可点击的相对路径 + `#L行号`；Monitor 是 **Go 程序**（[monitor/](monitor/)），monclient 是 C++（[src/monclient/](src/monclient/)）。`↓` 表示调用方向。
> **重要分层**：Monitor（Go，etcd 存储）↔ monclient（C++ 客户端 + 本地缓存）↔ Client/OSD 数据面。

---

## 一、总体架构（先建立模型）

**Monitor 是控制面**：保存集群"地图"和元数据，本身不参与普通数据 IO。

```text
控制面：Client/OSD → monclient → Monitor（etcd）→ 获取/维护元数据
数据面：Client 拿本地缓存的 Map 直接找 OSD，普通 IO 不经过 Monitor
```

Monitor 负责四类信息：

| 信息 | 一句话 |
|---|---|
| OSDMap | 集群里有哪些 OSD、地址、端口、`up/down`、`in/out` |
| PGMap | 每个 Pool 的每个 PG 由哪些 OSD 组成 |
| Pool Metadata | Pool 的 pg_num、pg_size、故障域等 |
| Image Metadata | Image 的名字、大小、object_size |

数据面依赖：Client 拿 Pool pg_num 算 PG → 拿 PGMap 找成员 → 拿 OSDMap 找地址 → get_leader 找 Leader → 数据 RPC。**Monitor 只提供"地图"，Client 拿着地图直接找 OSD**。

---

## 二、OSDMap

### 消息结构（线路上的 OSD 信息）

[proto/messages.proto#L127-133](proto/messages.proto#L127)：

```protobuf
message OsdDynamicInfo {
    int32 osdid = 1;
    string address = 2;
    map<uint32, ShardCore> sharded_ports = 3;   // shard_id → {core_id, port, raw_port}
    bool isin = 4;
    bool isup = 5;
    bool ispendingcreate = 6;
}
```

### 本地缓存结构

- [monitor::client::osd_map](src/include/fastblock/monclient/client.h#L120)：`data`（`unordered_map<osd_id, unique_ptr<osd_info_t>>`）+ `version`
- [utils::osd_info_t](src/include/fastblock/utils/utils.h#L111)：`node_id / isin / isup / ispendingcreate / sharded_ports / address`

### `up/down` vs `in/out`（以源码字段为准）

- `isup`：OSD 进程当前是否存活可通信（心跳维护，[ProcessOsdStopMessage](monitor/osd/osd.go#L538) 会置 down）
- `isin`：OSD 是否在数据放置集合内（[ProcessOsdOutMessage](monitor/osd/osd.go#L588) / [ProcessOsdInMessage](monitor/osd/osd.go#L636) 切换）
- **"可用" = `isup && isin`**——这是 [get_pg_first_available_osd_info](src/monclient/client.cc#L1029) 挑选成员 OSD 的判据

### Client 怎么读 OSDMap

[get_osd_info()](src/monclient/client.cc#L1068)（按 osd_id 查 `_osd_map.data`）→ 上层用于：Leader 有效性校验（[update_leader_state](src/include/fastblock/client/fb_client.h#L648)）、Leader 地址刷新（[refresh_leader_transport_from_cluster_map](src/include/fastblock/client/fb_client.h#L668)）。

---

## 三、PGMap

### 消息结构

[proto/messages.proto#L100-107](proto/messages.proto#L100)：

```protobuf
message PGInfo {
    int32 pgid = 1;
    int64 version = 2;
    int32 state = 3;            // PgActive/PgDown/PgRemapped...
    uint32 coreindex = 4;
    repeated int32 osdid = 5;   // ★ PG 成员 OSD
    uint32 newcoreindex = 6;
    repeated int32 newosdid = 7; // 迁移后的新成员
}
```

### 本地缓存结构

- [utils::pg_info_type](src/include/fastblock/utils/utils.h#L121)：`pg_id / version / osds[]`（**成员 OSD id 列表**）
- [monitor::client::pg_map](src/include/fastblock/monclient/client.h#L128) 的层级：

```text
pool_pg_map[pool_id]                          （client.h:211）
└── pg_map[pg_id] → unique_ptr<pg_info_type>   （osds[] = 成员 OSD）
```

**PG 成员 ≠ PG Leader**：

```text
PGMap：PG 12 → OSD 1 / OSD 3 / OSD 7    ← "副本放哪些 OSD"（控制面，Monitor 下发）
Leader：可能是 OSD 3                     ← "现在谁是 Leader"（数据面，get_leader RPC 问出来的）
```

---

## 四、Pool Metadata

### Monitor 侧结构

[monitor/osd/pool.go#L93-104](monitor/osd/pool.go#L93)：

```go
type PoolConfig struct {
    Poolid        int
    Name          string
    PGSize        int    // 副本数
    PGCount       int    // ★ pg_num（PG 数量）
    FailureDomain string
    Root          string
    PoolPgMap     PoolPGsConfig
}
```

创建：[ProcessCreatePoolMessage](monitor/osd/pool.go#L367)；PG→OSD 分布由 [calculator.go 的 FlattenTree](monitor/osd/calculator.go#L102) 计算后写入 PoolPgMap。

### Client 侧：`pg_num` 从哪来

[calc_target()](src/client/fb_client.cc#L138)（Object→PG 哈希）→ [calc_pg_masks()](src/client/fb_client.cc#L145) → [get_pg_num()](src/monclient/client.cc#L1057)：

```text
get_pg_num(pool_id)
↓
查本地 _pg_map.pool_pg_map[pool_id].size()   ← 本地缓存（来自 Monitor 下发的 PGMap）
↓
calc_target: jenkins_hash(object_name) % pg_num
```

**不是每次问 Monitor**——pg_num 来自 monclient 本地缓存的 PGMap 条目数（client.cc:1057-1066）。

---

## 五、Image Metadata

### Monitor 侧结构

[monitor/osd/image.go#L31-37](monitor/osd/image.go#L31)：

```go
type ImageConfig struct {
    ImageID    int32
    Imagename  string
    Poolname   string
    Imagesize  int64
    Objectsize int64
}
```

接口：[ProcessCreateImageMessage](monitor/osd/image.go#L92)、[ProcessGetImageMessage](monitor/osd/image.go#L180)、[ProcessResizeImageMessage](monitor/osd/image.go#L196)、[ProcessRemoveImageMessage](monitor/osd/image.go#L149)。

### 线路消息

[ImageInfo](proto/messages.proto#L195)：`poolname / imagename / size / object_size`——与 C++ 侧 [client::image_info](src/include/fastblock/monclient/client.h#L60) 一一对应。

### Client 侧接口

[libfblock_client](src/client/libfblock.cc)：[create_image](src/client/libfblock.cc#L20)、[open_image](src/client/libfblock.cc#L37)、[get_image_info](src/client/libfblock.cc#L71) 等 → [emplace_create_image_request](src/monclient/client.cc#L144) 等 → 发给 Monitor。Client 打开 Image 只需知道 `pool_name + image_name`（size/object_size 由 Monitor 返回）；**bdev 创建时用 pool_name 换 pool_id**（[get_pool_id](src/include/fastblock/monclient/client.h#L545)）。

---

## 六、Monitor 数据存在哪里（etcd）

**Monitor 是 Go 程序，etcd 是它的持久化存储**（不是 Ceph 式"Monitor 自己就是状态源"）：

- etcd 封装：[etcdapi/api.go](monitor/etcdapi/api.go)（[Put](monitor/etcdapi/api.go#L63)、[Get](monitor/etcdapi/api.go#L134)、[GetWithPrefix](monitor/etcdapi/api.go#L154)）
- OSDMap 存取：[LoadOSDMapFromEtcd](monitor/osd/osd.go#L170) / OSD 注册 [ProcessBootMessage](monitor/osd/osd.go#L359)（写入 etcd）
- Pool/PGMap：`/config/pools`、`/config/pgmap`（pool.go 注释，[PoolPGsConfig](monitor/osd/pool.go#L50) 的 json 示例）
- Image：[monitor/osd/image.go](monitor/osd/image.go)（`LoadImageConfig` L45）

**架构定性**：Monitor 进程启动时从 etcd 加载全部状态到内存（`AllPools` / `Allimages` / OSDMap），对外提供 TCP RPC，变更写回 etcd——**Monitor 是"etcd 之上的协调者 + 地图服务"**。

---

## 七、monclient 是什么

**它不只是"Monitor 的客户端"，而是"Monitor RPC Client + Cluster Map 本地缓存管理器"**。证据：`monitor::client` 类（[client.h#L38](src/include/fastblock/monclient/client.h#L38)）同时持有：

| 成员 | 位置 | 作用 |
|---|---|---|
| `cluster _cluster` | [client.h#L558](src/include/fastblock/monclient/client.h#L558)（[cluster 类 L227](src/include/fastblock/monclient/client.h#L227)） | 到 Monitor 的 TCP 连接（spdk_sock） |
| `pg_map _pg_map` | [client.h#L553](src/include/fastblock/monclient/client.h#L553) | **PGMap + Pool 缓存**（pool_pg_map / pool_version / pools） |
| `osd_map _osd_map` | [client.h#L554](src/include/fastblock/monclient/client.h#L554) | **OSDMap 缓存** |
| `_get_cluster_map_poller` | [client.h#L564](src/include/fastblock/monclient/client.h#L564) | 周期拉取 cluster map（3 秒，[_poll_period_us](src/include/fastblock/monclient/client.h#L598)） |
| 请求队列 | [client.h#L578-582](src/include/fastblock/monclient/client.h#L578) | 业务请求（image 操作等） |

```text
monclient
├── 和 Monitor 通信（TCP，8 字节长度前缀分帧）
├── 拉取 OSDMap / PGMap / Pool 信息
├── 发 Image 业务请求
└── 缓存在本地 _osd_map / _pg_map
```

---

## 八、Client 怎么获得 Cluster Map（完整链路）

**初始化**：[client::start()](src/monclient/client.cc#L91) → [handle_start](src/monclient/client.cc#L100)：`_cluster->connect()`（[spdk_sock_connect_ext](src/include/fastblock/monclient/client.h#L274)，TCP 直连 Monitor）+ 注册 core poller。

**周期拉取**：[start_cluster_map_poller](src/monclient/client.cc#L135) → [handle_start_cluster_map_poller](src/monclient/client.cc#L139) 注册 `cluster_map` poller（周期 3 秒）→ [send_cluster_map_request](src/monclient/client.cc#L214)：

```text
构造 GetClusterMapRequest
├── gom_request：currentversion（本地 OSDMap 版本，初始 -1）+ osdid
└── gpm_request：pool_versions（本地各 pool 版本，用于增量更新）
↓ TCP
Monitor [handleRequest 的 GetClusterMapRequest 分支](monitor/cmd/fastblock-mon/main.go#L323)
↓ [ProcessGetOsdMapMessage](monitor/osd/osd.go#L481) + [ProcessGetPgMapMessage](monitor/osd/pool.go#L682)（读内存状态，内存来自 etcd）
↓ GetClusterMapResponse
monclient [handle_response → process_osd_map](src/monclient/client.cc#L537)
↓ 版本检查（client.cc:547-555：远端版本 < 本地 → 丢弃）
↓ 重建 _osd_map（isup/isin 更新）
[process_pg_map](src/monclient/client.cc#L363)
↓ 按 pool 版本对比 → create_pg（[L317](src/monclient/client.cc#L317)，填 osds[]）/ 更新成员
本地缓存替换完成
```

**版本机制**：OSDMap 有全局版本号（`osdmap_version`）；PGMap 按 pool 有版本号（`pool_version`），客户端上报自己版本，Monitor 只发变更（[ProcessGetPgMapMessage 的 pvs 参数](monitor/osd/pool.go#L682)）。

---

## 九、OSD 怎么获得 Cluster Map

**OSD 使用同一个 monclient 基类，但派生了专用子类**：[monitor_client : public monitor::client](src/osd/mon_client.h#L17)。同一套拉取/缓存机制，差异在**消费方式**：

| override | 位置 | OSD 用它做什么 |
|---|---|---|
| [load_pgs()](src/osd/mon_client.cc#L14) | 启动时 | 把本地 blobstore 里的 PG 加载进 `_pg_map`（恢复） |
| [emplace_osd_boot_request](src/osd/mon_client.cc#L33) | [osd.cc#L385](src/osd/osd.cc#L385) | **OSD 启动向 Monitor 注册自己**（id/地址/sharded_ports） |
| [create_pg / remove_pg / change_pg_membership / check_and_active_pg](src/osd/mon_client.cc#L196) | 收到新 PGMap 时 | **驱动 partition_manager 创建/删除/迁移本地 PG**（PG 创建入口） |
| [connect_osd](src/osd/mon_client.cc#L102) | PGMap 更新时 | 建立到其他 OSD 的 RDMA 连接（Raft 通信） |
| `start_cluster_map_poller` | [osd.cc#L353](src/osd/osd.cc#L353) | 同样每 3 秒拉一次 |

```text
Monitor
↓ monclient（同一基类，两种子类）
├── 普通 client（Client 用：查 pg_num/OSD/Leader）
└── monitor_client（OSD 用：boot 注册 + 建 PG + 连对端 OSD）
```

---

## 十、Cluster Map 更新机制

**实际使用的是"周期性 poll + 版本对比"**，不是 watch/push：

- Client 与 OSD 都是每 3 秒发 `GetClusterMapRequest`（[client.cc#L139-142](src/monclient/client.cc#L139)）
- 增量：上报本地版本（OSDMap 版本 / 各 pool 版本），Monitor 只回新版内容（[ProcessGetPgMapMessage](monitor/osd/pool.go#L682)）
- 本地更新：版本相同跳过（[client.cc#L555-561](src/monclient/client.cc#L555)）；PG 成员变化走 `create_pg / change_pg_membership`（[client.cc#L506-524](src/monclient/client.cc#L506)）
- 断线兜底：[core_poller_handler](src/monclient/client.cc#L232) 发现 3 个周期没收到响应就重连

**Client 每次 IO 都问 Monitor 吗？——不是**。Client 数据路径全部查本地缓存（`_pg_map` / `_osd_map`），Monitor 只在 3 秒周期和启动时被访问；`_leader_osd` 缓存失效才走 get_leader RPC（问 OSD，也不是问 Monitor）。

---

## 十一、把控制面和 Client 数据路径连起来

[calc_target()](src/client/fb_client.cc#L138)（Object→PG 哈希）

↓ [get_pg_num()](src/monclient/client.cc#L1057) ← **Pool/PGMap 缓存（控制面）**

↓ 得到 pg_id

[get_pg_first_available_osd_info()](src/monclient/client.cc#L1029) ← **PGMap 成员（控制面）**（`pg_info_type.osds[]` 里找第一个 `isup && isin`）

↓ [get_osd_info()](src/monclient/client.cc#L1068) ← **OSDMap（控制面）**（address / sharded_ports）

↓ 向成员 OSD 发 [process_get_leader](src/include/fastblock/client/fb_client.h#L1053)（数据面 RPC）

↓ 得到 PG Leader（地址来自 OSD 回答，不是 Monitor）

[get_stub → Data RPC](src/include/fastblock/client/fb_client.h#L587)（数据面）

```text
Image → Object
↓ Pool Metadata：pg_num（monclient 缓存）
计算 PG
↓ PGMap：PG → OSD members（monclient 缓存）
成员 OSD 列表
↓ OSDMap：OSD id → address/port/up/in（monclient 缓存）
找成员问 Leader（get_leader RPC）
↓ PG Leader
Data RPC（与 OSD 直连）
```

**强调**：Monitor 不参与普通 IO。它提供"地图"（Pool pg_num / PGMap / OSDMap），Client 拿着地图自己找 OSD。

---

## 十二、核心结构汇总

| 结构 | 定义 | 关键字段 | 谁写 | 谁读 | 生命周期 |
|---|---|---|---|---|---|
| [osd_info_t](src/include/fastblock/utils/utils.h#L111) | utils.h | node_id / isin / isup / address / sharded_ports | monclient 收 OSDMap 时写（client.cc:537-589） | fblock_client、monclient 查询 | 随 `_osd_map`，每次地图更新整体重建 |
| [osd_map](src/include/fastblock/monclient/client.h#L120) | monclient/client.h | data + version | process_osd_map | get_osd_info / get_osd_addr | 3 秒周期替换 |
| [pg_info_type](src/include/fastblock/utils/utils.h#L121) | utils.h | pg_id / version / osds[] | create_pg（client.cc:317） | get_pg_first_available_osd_info | 随 `_pg_map` |
| [pg_map](src/include/fastblock/monclient/client.h#L128) | monclient/client.h | pool_pg_map / pool_version / pools / pool_update | process_pg_map | get_pg_num、PG 成员查询 | 3 秒周期更新 |
| [PoolConfig](monitor/osd/pool.go#L93) | monitor（Go） | Poolid / PGSize / **PGCount(pg_num)** / FailureDomain | ProcessCreatePoolMessage | ProcessGetPgMapMessage | etcd + 内存常驻 |
| [ImageConfig](monitor/osd/image.go#L31) | monitor（Go） | ImageID / Imagename / Poolname / Imagesize / Objectsize | ProcessCreateImageMessage | ProcessGetImageMessage | etcd + 内存常驻 |
| [monitor::client](src/include/fastblock/monclient/client.h#L38) | monclient/client.h | _cluster / _pg_map / _osd_map / poller | — | Client 与 OSD 共用 | 进程生命周期 |
| [msg::Request/Response](proto/messages.proto) | proto | oneof（CreatePool/GetClusterMap/Image...） | monclient 构造 / Monitor 回复 | main.go handleRequest / client.cc handle_response | 单次 RPC |

---

## 十三、4 条源码调用链

**链 1：Client 获取 OSD 信息**

[fblock_client::update_leader_state](src/include/fastblock/client/fb_client.h#L653)（校验 Leader 是否可用）

↓ [_mon_cli->get_osd_info(leader_id)](src/include/fastblock/client/fb_client.h#L653)

↓ [client::get_osd_info()](src/monclient/client.cc#L1068)：查 `_osd_map.data[osd_id]`

↓ 返回 [osd_info_t](src/include/fastblock/utils/utils.h#L111)（isup / isin / address / sharded_ports）

**链 2：Client 获取 PG 成员**

[enqueue_leader_request](src/include/fastblock/client/fb_client.h#L626)（找问路的 OSD）

↓ [_mon_cli->get_pg_first_available_osd_info(pool_id, pg_id)](src/include/fastblock/client/fb_client.h#L626)

↓ [client.cc#L1029](src/monclient/client.cc#L1029)：`_pg_map.pool_pg_map[pool][pg]->osds[]` → 第一个 `isup && isin`

**链 3：Client 获取 pg_num**

[calc_target()](src/client/fb_client.cc#L138)

↓ [calc_pg_masks](src/client/fb_client.cc#L145) → [_mon_cli->get_pg_num](src/client/fb_client.cc#L147)

↓ [client::get_pg_num()](src/monclient/client.cc#L1057)：`_pg_map.pool_pg_map[pool_id].size()`

↓ `seed % pg_num` → pg_id

**链 4：Monitor → monclient 本地缓存更新**

[cluster_map poller（3 秒）](src/monclient/client.cc#L139) → [send_cluster_map_request](src/monclient/client.cc#L214)

↓ TCP → [main.go GetClusterMapRequest 分支](monitor/cmd/fastblock-mon/main.go#L323) → [ProcessGetOsdMapMessage](monitor/osd/osd.go#L481) + [ProcessGetPgMapMessage](monitor/osd/pool.go#L682)（读 etcd 加载的内存态）

↓ 响应 → [process_osd_map](src/monclient/client.cc#L537)（重建 `_osd_map`）→ [process_pg_map](src/monclient/client.cc#L363)（更新 `_pg_map`）

↓ Client/OSD 后续查询用新缓存

---

## 十四、总图

```text
Monitor（Go，etcd 持久化）
├── OSDMap（osd.go:170/481）
├── PGMap / Pool（pool.go:682，calculator.go:102 算 PG→OSD）
├── Image Metadata（image.go）
└── TCP RPC（main.go:79 handleRequest）
          ↓
        monclient（C++）
          ├── 拉取 + 缓存：_osd_map / _pg_map（client.cc:537/363）
          ├── 业务 RPC：Image/Pool 操作
          └── 周期 3 秒刷新（client.cc:139）
          ↓
        本地缓存
          ├── Client（fblock_client：pg_num / PG 成员 / OSD 信息）
          └── OSD（monitor_client：boot 注册 + 建 PG + 连对端，osd/mon_client.h:17）
```

```text
控制面到此结束：Monitor → monclient → Map 缓存
──────────────────────────────────────────────
数据面从此开始：
Client 使用：
Pool pg_num → Object→PG（calc_target）
PGMap → PG members
OSDMap → address/port/up/in
get_leader RPC → PG Leader
Data RPC → Leader OSD（不经过 Monitor）
```

---

## 十五、建议源码阅读顺序（10 步）

1. [proto/messages.proto](proto/messages.proto) —— 控制面消息（OsdDynamicInfo / PGInfo / GetClusterMapResponse / ImageInfo）
2. [monitor/cmd/fastblock-mon/main.go#L79](monitor/cmd/fastblock-mon/main.go#L79) —— Monitor RPC 入口（看它有哪些请求分支）
3. [monitor/osd/pool.go#L93](monitor/osd/pool.go#L93) —— PoolConfig / PGConfig（pg_num、成员、版本）
4. [monitor/osd/osd.go#L170](monitor/osd/osd.go#L170) + [L359](monitor/osd/osd.go#L359) —— OSDMap 加载 / OSD 注册
5. [monitor/osd/image.go#L31](monitor/osd/image.go#L31) —— ImageConfig
6. [src/include/fastblock/monclient/client.h](src/include/fastblock/monclient/client.h) —— monclient 数据结构（`_osd_map` / `_pg_map` / `cluster`）
7. [src/monclient/client.cc#L214](src/monclient/client.cc#L214) —— 拉取请求构造
8. [src/monclient/client.cc#L537](src/monclient/client.cc#L537) + [L363](src/monclient/client.cc#L363) —— 本地缓存更新
9. [src/monclient/client.cc#L1029](src/monclient/client.cc#L1029) + [L1057](src/monclient/client.cc#L1057) + [L1068](src/monclient/client.cc#L1068) —— Client 查询接口
10. [src/osd/mon_client.h](src/osd/mon_client.h) + [src/osd/mon_client.cc](src/osd/mon_client.cc) —— OSD 侧消费（建 PG / boot / 连对端）

---

## 十六、Checklist

- [ ] Monitor 是干什么的？（控制面：保存集群地图与元数据，不参与数据 IO）
- [ ] OSDMap 是什么？（osd_id → address/sharded_ports/isup/isin，[OsdDynamicInfo](proto/messages.proto#L127)）
- [ ] PGMap 是什么？（pool → pg → 成员 osds[]，[PGInfo](proto/messages.proto#L100)）
- [ ] `up/down` 与 `in/out` 区别？（isup=存活，isin=在放置集合；可用 = 两者都 true）
- [ ] PG 成员与 PG Leader 区别？（成员=控制面地图；Leader=数据面 get_leader 问出来）
- [ ] pg_num 从哪来？（monclient 缓存 `pool_pg_map[pool].size()`，[client.cc#L1057](src/monclient/client.cc#L1057)）
- [ ] Image 信息在哪？（Monitor ImageConfig + [ImageInfo](proto/messages.proto#L195)）
- [ ] Monitor 数据存哪？（**etcd**，[etcdapi](monitor/etcdapi/api.go)；Monitor 是 etcd 之上的协调者）
- [ ] monclient 是什么？（Monitor RPC Client + Map 缓存管理器）
- [ ] Client 怎么拿地图？（3 秒周期 GetClusterMapRequest + 版本增量，[client.cc#L214](src/monclient/client.cc#L214)）
- [ ] OSD 怎么拿地图？（同一基类的 [monitor_client](src/osd/mon_client.h#L17)，额外建 PG/连对端）
- [ ] 更新机制？（周期 poll + 版本对比，不是 watch/push）
- [ ] Client 每次 IO 问 Monitor 吗？（**不是**——查本地缓存，只有 get_leader 问 OSD）