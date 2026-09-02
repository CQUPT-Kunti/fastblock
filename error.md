# FastBlock 环境搭建问题记录

## 环境信息

- 操作系统：Ubuntu 24.04.4 LTS，内核 `6.17.0-22-generic`
- GCC：`gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
- G++：`g++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`
- CMake：`3.28.3`
- FastBlock commit：`0dbe472914c7bf5bcbb8f63a966d6d8e9dd01fc1`
- FastBlock 源码路径：`/home/yangjilei/Code/C++/fastblock`
- 主构建目录：`/media/yangjilei/Elements/YangJiLei/fastblock-build`
- vcpkg 路径：`/home/yangjilei/vcpkg`
- 大型依赖与产物根目录：`/media/yangjilei/Elements/YangJiLei`
- 当前 RDMA 设备：`rdmanic`，`netdev eno1`
- 最终测试方式：官方 `./vstart.sh -m dev -c 3 -r 3 -C 2` 启动，官方 `run-dev-write-read-verify.sh` 完成最小 WRITE/READ/VERIFY

## Error 1：SPDK 相关下载阶段曾受 Gitee/TLS 网络问题影响

### 现象

前序构建阶段曾出现过 Gitee / SPDK 下载失败，保留下来的错误摘要为：

```text
gnutls_handshake() failed
TLS connection was non-properly terminated
```

本轮整理时，仓库内未保留当次下载失败的完整原始终端输出。

### 原因

已确认这是环境相关的网络访问问题，不是 FastBlock 源码问题。前序排查时曾关注 VPN、TUN、Fake-IP 一类网络环境对 Gitee 访问的影响，但没有沉淀出一个对所有场景都稳定成立的通用修复方案。

### 排查过程

- 对失败点做过重试控制，没有对同一新下载资源无限重试。
- 下载失败阶段与后续源码编译阶段分开处理，避免把网络问题误判为编译问题。
- 在已有依赖可复用后，后续流程继续走本地已有内容，没有重复下载已存在依赖。

### 解决方法

这一项没有形成可复用的“网络修复命令”。实际采取的是：

- 遵守失败重试上限；
- 后续直接复用已经落盘的依赖和缓存继续推进；
- 不把它写成已经彻底解决的通用问题。

### 验证

后续构建能够在不重新下载同一批已有依赖的前提下继续完成。

### 状态

`环境相关问题 / 未形成通用修复`

---

## Error 2：系统盘空间有限，需要把大型构建内容迁移到移动盘

### 现象

本机磁盘状态显示系统盘可用空间明显小于移动盘：

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  233G  181G   41G  82% /
/dev/sda1       1.9T  388G  1.5T  21% /media/yangjilei/Elements
```

### 原因

FastBlock 及其第三方依赖，尤其是 SPDK/DPDK，构建过程中会产生大量中间文件和产物。继续把主构建目录放在系统盘上，存在把系统盘空间进一步压满的风险。

### 排查过程

- 先确认系统盘和移动盘挂载情况。
- 保留源码在原路径，仅迁移大型构建与依赖产物。

### 解决方法

将主构建目录与大型依赖产物放到移动盘：

```text
/media/yangjilei/Elements/YangJiLei
/media/yangjilei/Elements/YangJiLei/fastblock-build
```

### 验证

- 当前 `build` 解析到：`/media/yangjilei/Elements/YangJiLei/fastblock-build`
- 主要二进制均在该目录下生成并可执行。

### 状态

`RESOLVED`

---

## Error 3：protobuf 版本混用风险，曾误用 Anaconda 的 protoc

### 现象

当前 shell 默认 `protoc` 仍然指向 Anaconda：

```text
/home/yangjilei/anaconda3/bin/protoc
libprotoc 29.3
```

而当前成功构建使用的 CMake 缓存明确记录的是 vcpkg protobuf：

```text
FIND_PACKAGE_MESSAGE_DETAILS_Protobuf:INTERNAL=[/home/yangjilei/vcpkg/installed/x64-linux/tools/protobuf/protoc-29.5.0][optimized;/home/yangjilei/vcpkg/installed/x64-linux/lib/libprotobuf.a;debug;/home/yangjilei/vcpkg/installed/x64-linux/debug/lib/libprotobufd.a][/home/yangjilei/vcpkg/installed/x64-linux/include][v29.5.0()]
```

当前生成文件头部也显示为 `5.29.5`：

```text
// Protobuf C++ Version: 5.29.5
#if PROTOBUF_VERSION != 5029005
#error "Protobuf C++ gencode is built with an incompatible version of"
```

### 原因

问题根因是 `protoc`、protobuf 头文件和 `libprotobuf` 不能跨来源混用。曾经使用 Anaconda 的 `protoc` 时，极易与 C++ 编译阶段实际使用的另一套 protobuf 头文件或库发生 cross-version 冲突。

### 排查过程

- 检查当前默认 `protoc` 指向；
- 检查 `CMakeCache.txt` 中 protobuf 的真实解析结果；
- 检查生成后的 `*.pb.h` 头部版本号；
- 检查构建文件中是否仍残留 `anaconda3`。

### 解决方法

最终统一以 `~/vcpkg` 为准：

```text
/home/yangjilei/vcpkg/installed/x64-linux/tools/protobuf/protoc-29.5.0
/home/yangjilei/vcpkg/installed/x64-linux/include/google/protobuf/message.h
/home/yangjilei/vcpkg/installed/x64-linux/lib/libprotobuf.a
```

明确原则：

```text
FastBlock 的 C/C++ 构建不再使用 Anaconda/Conda protobuf。
```

### 验证

- `CMakeCache.txt` 记录的 protoc、headers、libprotobuf 均来自 `~/vcpkg`
- 当前 `compile_commands.json` 与 `CMakeCache.txt` 中未检出 `anaconda3`
- 当前 `pb.h` 版本号与 vcpkg protobuf 对齐为 `29.5`

### 状态

`RESOLVED`

---

## Error 4：Conda / Anaconda 对构建环境存在污染风险

### 现象

本轮整理时，当前 shell 默认 `protoc` 仍优先命中：

```text
/home/yangjilei/anaconda3/bin/protoc
```

这说明 PATH 级别的污染风险真实存在。

### 原因

FastBlock 依赖较多，若 PATH、头文件路径、库路径被 Anaconda 注入，容易出现以下混用问题：

- `protoc` 命中 Conda
- `include` 命中 Conda
- `libprotobuf` / `grpc` / `absl` 命中 Conda
- Python 包和构建工具版本与底层环境不一致

### 排查过程

- 核对 `which protoc`
- 检查构建缓存里 protobuf 的实际解析路径
- 用 `rg` 检查成功构建目录中是否仍残留 `anaconda3`

### 解决方法

最终有效原则不是“继续在 Conda 上补丁式修”，而是：

```text
FastBlock C/C++ 构建和运行不使用 Conda/Anaconda dependency。
```

成功构建结果表明，真正参与此次成功构建的 protobuf 来自 `~/vcpkg`，而不是当前 shell 默认命中的 Anaconda `protoc`。

### 验证

- 当前成功构建目录中未检出 `anaconda3`
- protobuf 解析结果全部落在 `~/vcpkg`
- 官方 dev flow 最终成功时没有额外引入 Conda 依赖

### 状态

`RESOLVED`

---

## Error 5：SPDK / DPDK 构建过程中存在 RDMA、meson、pyelftools、libaio、NUMA 依赖门槛

### 现象

前序构建阶段实际遇到过 DPDK 的 NUMA 问题，用户保留的已确认解决方式为：

```text
meson setup --reconfigure -Dmax_numa_nodes=1
```

另外，当前成功构建的产物中可以看到 SPDK/DPDK 已经被集成到本地依赖目录，且链接命令包含：

```text
-libverbs -lrdmacm -laio
```

### 原因

FastBlock 的 OSD / block_bench 依赖 SPDK/DPDK 和 RDMA 用户态库。缺失或不匹配的依赖会在第三方构建阶段暴露，而不是在业务代码阶段暴露。

### 排查过程

- 先补齐前置依赖，再继续第三方编译；
- 对 DPDK 的 NUMA 报错采用 reconfigure 方式处理，而不是删除整个构建目录重来；
- 避免重复重编已经完成的第三方部分。

### 解决方法

已实际使用并确认有效的方法包括：

```text
meson setup --reconfigure -Dmax_numa_nodes=1
```

并补齐本地 RDMA / meson / pyelftools / libaio 相关依赖后继续增量编译。

### 验证

- 当前 OSD 启动日志显示已经成功进入 `Starting SPDK v24.05.1-pre / DPDK 24.03.0 initialization`
- 三个 OSD 均可正常启动并对外提供服务

### 状态

`RESOLVED`

---

## Error 6：安装前缀默认落在 `/usr/local`，直接安装会涉及权限

### 现象

当前构建缓存明确记录：

```text
CMAKE_INSTALL_PREFIX:PATH=/usr/local
```

仓库内的 `README.md` 和 `vstart.sh` 也都以 `/usr/local/bin` 作为默认安装位置或默认二进制查找路径。

### 原因

如果严格走 `make install`，默认会向 `/usr/local` 写入二进制和 systemd unit，需要具备相应权限。对于本地开发来说，这既是权限问题，也是“是否真的需要安装”的选择问题。

### 排查过程

- 先确认官方脚本是否支持直接复用本地构建产物；
- 检查 `vstart.sh` 的本地 dev 启动逻辑。

### 解决方法

本次最终成功路径没有依赖 `make install`。`vstart.sh` 在 `dev` 模式下检测到本地二进制存在后，自动切换到本地启动模式，直接使用：

```text
build/src/osd/fastblock-osd
build/src/tools/block_bench/block_bench
monitor/fastblock-mon
monitor/fastblock-client
```

因此避免了为了本地验证而强行写入 `/usr/local`。

### 验证

官方 dev flow 最终成功时使用的是仓库本地 `.vstart/` 状态目录和本地二进制，不依赖 `/usr/local/bin` 安装后的命令。

### 状态

`RESOLVED`

---

## Error 7：Soft-RoCE / RDMA 初始化需要内核模块与设备节点配合

### 现象

最终成功环境中的 RDMA 状态为：

```text
link rdmanic/1 state ACTIVE physical_state LINK_UP netdev eno1
```

当前系统内核模块状态为：

```text
rdma_ucm
rdma_cm
rdma_rxe
ib_uverbs
ib_core
```

`/dev/infiniband` 下当前可见：

```text
by-ibdev
rdma_cm
uverbs0
```

### 原因

在没有物理 RDMA NIC 的开发环境中，需要用 `rdma_rxe` 创建 Soft-RoCE 设备。若相关模块或设备节点不完整，RDMA 初始化会在运行期失败。

### 排查过程

- 检查 `rdma link`
- 检查 `lsmod`
- 检查 `/dev/infiniband`
- 阅读官方 `scripts/create-rdma-rxe.sh`

### 解决方法

官方脚本 `scripts/create-rdma-rxe.sh` 的核心处理是：

```text
modprobe rdma_rxe
rdma link add <name> type rxe netdev <netdev>
```

后续成功环境中，`rdmanic` 已经处于 ACTIVE 状态，相关 RDMA 模块也已加载。

### 验证

- `rdma link` 显示 `rdmanic` ACTIVE
- 官方 `./vstart.sh -m dev -c 3 -r 3 -C 2` 能在当前环境直接启动成功

### 状态

`RESOLVED`

---

## Error 8：早期自定义 RDMA 用户态库诊断曾出现 event channel 失败，但最终官方流程不需要额外 LD_LIBRARY_PATH

### 现象

前序诊断阶段曾围绕以下报错做过排查：

```text
create rdma event channel failed
rdma_create_event_channel failed: errno=19 (No such device)
```

这部分原始报错并不在本轮官方成功流程的日志中出现，属于早期自定义运行条件下观察到的现象。

### 原因

当时排查重点是本地编译的 rdma-core 用户态库、provider 与系统自带 RDMA 用户态库之间可能存在兼容差异。该现象说明“早期自定义运行环境”存在问题，但不能据此推导“官方 dev flow 必须手工混用 RDMA library”。

### 排查过程

- 关注过 `libibverbs` / RXE provider 与系统库的兼容性；
- 关注过 `/dev/infiniband/rdma_cm` 是否可见；
- 也关注过 `rdma_ucm`、`rdma_cm`、`rdma_rxe` 是否已加载。

### 解决方法

本轮最终验证采用的是官方启动路径，且成功时：

```text
没有额外 LD_LIBRARY_PATH
没有手工指定 -n rdmanic
```

因此这类 RDMA 用户态兼容问题被明确归类为：

```text
早期自定义运行环境问题，不是最终官方成功流程的必要条件。
```

### 验证

官方 dev flow 最终成功：

- `./vstart.sh -m dev -c 3 -r 3 -C 2`
- `BLOCK_BENCH_CPU_MASK=0x40 ./scripts/run-dev-write-read-verify.sh`

全程未额外设置 `LD_LIBRARY_PATH`。

### 状态

`RESOLVED`

---

## Error 9：官方 block_bench 脚本默认 CPU mask 与 OSD 抢核

### 现象

第一次直接执行官方脚本时，真实失败输出为：

```text
Running write benchmark for image: dev-verify-1788343543
[2026-09-02 18:05:44.539794] app.c: 771:claim_cpu_cores: *ERROR*: Cannot create lock on core 2, probably process 348915 has claimed it.
[2026-09-02 18:05:44.539828] app.c: 902:spdk_app_start: *ERROR*: Unable to acquire lock on assigned core mask - exiting.
[2026-09-02 18:05:44.539840] .../src/tools/block_bench/block_bench.cc: 960:main: *ERROR*: ERROR: Start spdk app failed
```

### 原因

官方脚本 `scripts/run-dev-write-read-verify.sh` 默认使用：

```text
BLOCK_BENCH_CPU_MASK=0x4
```

而本次官方 dev 集群中三个 OSD 实际占用的核为：

- OSD1：`0,1`
- OSD2：`2,3`
- OSD3：`4,5`

因此默认 `0x4` 对应的 core 2 与 OSD2 冲突。

### 排查过程

- 先不改源码，只检查官方脚本；
- 读取 `run-dev-write-read-verify.sh`，确认它本来就公开支持 `BLOCK_BENCH_CPU_MASK` 环境变量；
- 再核对当前 OSD 的实际 CPU 占用。

### 解决方法

使用空闲核重新执行官方脚本：

```bash
BLOCK_BENCH_CPU_MASK=0x40 ./scripts/run-dev-write-read-verify.sh
```

### 验证

成功输出：

```text
Write-read-verify completed for image: dev-verify-1788343625
```

并且 WRITE / READ 都输出了 `total_io_count: 64`。

### 状态

`RESOLVED`

---

## Error 10：测试过程曾出现超大日志文件，需要与 image 数据区分

### 现象

前序测试阶段曾出现名为：

```text
agent-test-output-20260824-0955.log
```

的异常大日志文件。该文件不是 FastBlock image 数据本身。

### 原因

这是测试工具或测试采集过程中的日志膨胀现象，不能直接等同于块设备写入的数据量，也不能据此认定 FastBlock image 数据异常增大。

### 排查过程

- 将“业务数据”与“工具输出日志”分开看待；
- 不把这个日志文件误判为块设备 image。

### 解决方法

这一项本轮没有重新回放，也没有重新制造该日志。这里只保留已经确认的经验：

```text
WRITE/READ/VERIFY 是否成功，应以官方脚本输出、monitor 状态和 image 元数据为准，
不能只看单个采集日志文件大小。
```

### 验证

本轮官方流程最终成功时，判断依据来自：

- `vstart.sh` 成功启动
- `fastblock-client` 状态检查
- `run-dev-write-read-verify.sh` 成功输出
- `getimage` 查询结果

### 状态

`RESOLVED`

---

## Error 11：早期非标准运行条件下出现过 I/O 与 OSD 异常诊断现象，但不能直接定性为源码缺陷

### 现象

前序诊断中曾关注过以下现象：

```text
PgMapSameVersion
RDMA_CM_EVENT_DISCONNECTED
allocate data mem failed
```

其中 `RDMA_CM_EVENT_DISCONNECTED`、`allocate data mem failed` 等字样可在源码和历史测试文档中看到，且曾被用于定位早期自定义运行问题。

### 原因

这些现象出现在早期的非标准、自定义运行条件下，和最终本轮已经验证成功的官方流程不是同一个结论层面。把它们直接写成“已经证明的 FastBlock 源码 bug”是不严谨的。

### 排查过程

- 这些现象被当作诊断线索处理；
- 在本轮目标切换为“严格官方流程验证”后，不再把早期自定义现象与官方成功流程混写。

### 解决方法

本轮没有基于这些现象修改源码。最终做法是回到官方 README / docs / 脚本，重新用官方最简 dev flow 验证。

### 验证

最终官方流程已经完成：

```text
WRITE SUCCESS
READ SUCCESS
VERIFY SUCCESS
```

因此这类历史现象目前只保留为“早期诊断记录”，不作为已确认源码缺陷结论。

### 状态

`RESOLVED`
