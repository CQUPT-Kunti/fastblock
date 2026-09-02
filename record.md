# FastBlock 本地开发环境搭建记录

## 1. 最终结果

`OFFICIAL DEV FLOW SUCCESS`

本次成功验证时的 commit：

```text
0dbe472914c7bf5bcbb8f63a966d6d8e9dd01fc1
```

最终状态：

```text
Monitor: 1
OSD: 3 up / 3 in
PG: 8 active
pool: fb
image: dev-verify-1788343625
WRITE: success
READ: success
VERIFY: success
```

说明：

- image 名称由官方脚本按时间戳自动生成，每次运行可能变化。
- 本文记录的是本次实际成功验证对应的 image：`dev-verify-1788343625`。

## 2. 环境信息

- FastBlock source：`/home/yangjilei/Code/C++/fastblock`
- Build：`/media/yangjilei/Elements/YangJiLei/fastblock-build`
- Large dependency/build root：`/media/yangjilei/Elements/YangJiLei`
- vcpkg：`/home/yangjilei/vcpkg`
- RDMA：`rdmanic`
- Network interface：`eno1`
- OS：Ubuntu 24.04.4 LTS
- Kernel：`6.17.0-22-generic`
- GCC：`13.3.0`
- G++：`13.3.0`
- CMake：`3.28.3`
- protobuf：
  `/home/yangjilei/vcpkg/installed/x64-linux/tools/protobuf/protoc-29.5.0`
  `/home/yangjilei/vcpkg/installed/x64-linux/include`
  `/home/yangjilei/vcpkg/installed/x64-linux/lib/libprotobuf.a`
- 明确原则：FastBlock 的 C/C++ 构建和运行不使用 Anaconda/Conda protobuf。

## 3. 成功流程记录

### 3.1 环境检查

本次整理时确认过的有效检查命令：

```bash
df -h / /media/yangjilei/Elements/YangJiLei
lsblk -o NAME,SIZE,MOUNTPOINT
uname -a
cat /etc/os-release
gcc --version | head -n 1
g++ --version | head -n 1
cmake --version | head -n 1
git rev-parse HEAD
```

### 3.2 磁盘规划

源码保留在：

```text
/home/yangjilei/Code/C++/fastblock
```

大型构建与依赖产物放在：

```text
/media/yangjilei/Elements/YangJiLei
```

对应主构建目录为：

```text
/media/yangjilei/Elements/YangJiLei/fastblock-build
```

这样做的直接原因是系统盘空间相对紧张，而移动盘空间充足。

### 3.3 dependency

本次成功路径中的依赖来源可以分为四类：

- 系统已有：`gcc`、`g++`、`cmake`、系统 RDMA 头文件与基础运行库
- `~/vcpkg` 复用：protobuf、abseil 等
- 本地/移动盘依赖安装：SPDK 相关内容落在 `/media/yangjilei/Elements/YangJiLei/deps-install`
- FastBlock 自身构建目录：`/media/yangjilei/Elements/YangJiLei/fastblock-build`

当前 `compile_commands.json` 可见成功构建时实际使用了：

```text
-isystem /home/yangjilei/vcpkg/installed/x64-linux/include
-isystem /media/yangjilei/Elements/YangJiLei/deps-install/include
```

### 3.4 protobuf

本次成功构建确认使用的是 vcpkg protobuf：

```text
/home/yangjilei/vcpkg/installed/x64-linux/tools/protobuf/protoc-29.5.0
/home/yangjilei/vcpkg/installed/x64-linux/include/google/protobuf/message.h
/home/yangjilei/vcpkg/installed/x64-linux/lib/libprotobuf.a
```

版本核对结果：

```text
libprotoc 29.5
// Protobuf C++ Version: 5.29.5
```

当前 shell 默认 `protoc` 仍然可能指向 Anaconda，但这不是本次成功构建所使用的 protobuf 组合。成功构建缓存 `CMakeCache.txt` 记录的 protobuf 解析结果全部来自 `~/vcpkg`。

### 3.5 CMake configure

本轮整理时，从现有 `CMakeCache.txt` 能确认以下成功构建信息：

```text
source dir: /home/yangjilei/Code/C++/fastblock
build dir : /media/yangjilei/Elements/YangJiLei/fastblock-build
generator : Unix Makefiles
build type: Release
C compiler: /usr/bin/gcc
CXX comp. : /usr/bin/g++
install prefix: /usr/local
Protobuf_DIR: /home/yangjilei/vcpkg/installed/x64-linux/share/protobuf
```

本轮没有从现有 history 中恢复出完整的一次性 `cmake -S ... -B ...` 命令参数，因此这里不补写未经证实的 configure 命令。

### 3.6 Build

本次成功路线中确认使用过的增量构建命令是：

```bash
cmake --build /media/yangjilei/Elements/YangJiLei/fastblock-build --parallel 6
```

说明：

- 最大并发限制为 6
- 没有使用全机全部 CPU
- 没有删除已有 build 后重来

### 3.7 编译产物

本次实际确认存在的主要二进制：

```text
/media/yangjilei/Elements/YangJiLei/fastblock-build/src/osd/fastblock-osd
/media/yangjilei/Elements/YangJiLei/fastblock-build/src/tools/block_bench/block_bench
/media/yangjilei/Elements/YangJiLei/fastblock-build/src/bdev/fastblock-vhost
/home/yangjilei/Code/C++/fastblock/monitor/fastblock-mon
/home/yangjilei/Code/C++/fastblock/monitor/fastblock-client
```

### 3.8 Soft-RoCE

本次环境使用的 RDMA 设备是：

```text
rdmanic
```

官方脚本：

```text
./scripts/create-rdma-rxe.sh -n rdmanic
```

脚本核心逻辑是：

```text
modprobe rdma_rxe
rdma link add rdmanic type rxe netdev <netdev>
```

当前成功环境还可见：

```text
rdma_ucm
rdma_cm
rdma_rxe
```

验证结果：

```text
link rdmanic/1 state ACTIVE physical_state LINK_UP netdev eno1
```

### 3.9 官方 dev 集群启动

官方 README 推荐的最简命令是：

```bash
./vstart.sh -m dev -c 3 -r 3 -C 2
```

本次最终实际成功执行的也是：

```bash
./vstart.sh -m dev -c 3 -r 3 -C 2
```

重要说明：

- 最终 `OFFICIAL DEV FLOW` 没有手工加 `-n rdmanic`
- 最终 `OFFICIAL DEV FLOW` 没有额外设置 `LD_LIBRARY_PATH`
- `vstart.sh` 在本地 `dev` 模式下检测到本地二进制存在后，自动使用仓库内 `.vstart/` 目录和本地构建产物启动

### 3.10 集群验证

本次实际使用过的状态检查命令：

```bash
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=status
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=getosdmap
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=getpgmap
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=listpools
```

本次成功结果：

```text
mon: 1 mons, 10.16.84.43
osd: 3 osds: 3 up, 3 in
pools: 1 pools, 8 pgs
8 active
pool: fb
```

### 3.11 Image

本次官方最小验证实际使用到的 image：

```text
dev-verify-1788343625
```

查询命令：

```bash
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=getimage -poolname=fb -imagename=dev-verify-1788343625
```

查询结果：

```text
Imagename: dev-verify-1788343625
Poolname: fb
Size: 16777216
Objectsize: 4194304
```

### 3.12 WRITE / READ / VERIFY

第一次直接执行官方脚本时，默认 CPU mask 与 OSD 抢核，报错为：

```text
Cannot create lock on core 2
Unable to acquire lock on assigned core mask - exiting
```

在确认 OSD 已占用 `0-5` 号核后，改为使用空闲核重新执行官方脚本：

```bash
BLOCK_BENCH_CPU_MASK=0x40 ./scripts/run-dev-write-read-verify.sh
```

本次成功结果：

```text
WRITE:
  total_io_count: 64

READ:
  total_io_count: 64

VERIFY:
  Write-read-verify completed for image: dev-verify-1788343625
```

最终结论：

```text
OFFICIAL DEV FLOW SUCCESS
```

## 4. 快速复现

以下只保留本次已经验证通过的命令和原则。

### 4.1 启动前

- 退出 Conda，或使用不含 Conda 污染的干净 shell
- 确认 `rdmanic` 存在
- 确认 `rdma_rxe`、`rdma_cm`、`rdma_ucm` 已可用

可用检查命令：

```bash
rdma link
lsmod | grep -E 'rdma_rxe|rdma_cm|rdma_ucm'
which protoc
```

注意：

- 当前 shell 默认 `protoc` 可能仍指向 Anaconda
- 但 FastBlock 的 C/C++ 构建和运行应继续坚持使用 `~/vcpkg` 的 protobuf

### 4.2 启动

```bash
./vstart.sh -m dev -c 3 -r 3 -C 2
```

### 4.3 状态检查

```bash
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=status
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=getosdmap
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=getpgmap
./monitor/fastblock-client -conf=.vstart/etc/fastblock/fastblock.json -op=listpools
```

### 4.4 官方最小测试

```bash
BLOCK_BENCH_CPU_MASK=0x40 ./scripts/run-dev-write-read-verify.sh
```

### 4.5 停止

本轮没有单独验证一条“官方 stop 命令”作为复现步骤，因此这里不补写未验证命令。

已确认的事实是：`vstart.sh` 源码内部包含本地进程停止逻辑，会管理 `.vstart/run/*.pid` 下的 monitor / osd 进程。

## 5. 与早期自定义流程的区分

本文只记录最终跑通的 `OFFICIAL FLOW`。

需要单独区分的点：

- 早期诊断阶段曾出现自定义 RDMA 运行方式、额外环境变量和非标准测试路径
- 最终成功的 `OFFICIAL DEV FLOW` 不需要手工加 `-n rdmanic`
- 最终成功的 `OFFICIAL DEV FLOW` 不需要额外 `LD_LIBRARY_PATH`
- 早期异常现象不能直接等同于 FastBlock 已确认源码缺陷
