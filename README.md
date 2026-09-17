# pcoin-mac-miner

一键在 **macOS（Intel 与 Apple Silicon 双架构）** 上从源码构建并运行 [PCoin (PCN)](https://github.com/pars5555/pcoin) 的 headless 节点 + RandomX CPU 连池挖矿脚本。

PCoin 官方 release 只提供 Windows 二进制（`pcoin-win64-miner.zip`），不提供 macOS / Linux 可执行文件。本脚本在 Mac 上原生编译，无需改任何源码：RandomX 是 in-tree 子模块且以 x86_64 / arm64 为目标，矿池客户端与 CPU miner 使用 `std::thread` + 跨平台 socket，无平台硬编码。

## 支持架构

| 架构 | 机型示例 | RandomX JIT 后端 | 默认挖矿线程 | 验证状态 |
|---|---|---|---|---|
| **x86_64 (Intel)** | Intel MacBook / Mac mini / iMac | `jit_compiler_x86` | 物理核数（不含超线程） | ✅ 作者在 Intel Mac 上实测编译 + 挖矿 |
| **arm64 (Apple Silicon)** | M1 / M2 / M3 / M4 全系 | `jit_compiler_a64`（原生，非 Rosetta） | **性能核数**（`hw.perflevel0.physicalcpu`，不含能效核） | 🧪 经上游源码确认可原生运行，未在 M 真机实测，欢迎反馈 |

> Apple Silicon 的可行性依据：上游内嵌 RandomX 带原生 A64 JIT（`src/randomx/src/jit_compiler_a64.cpp`），并在 `__APPLE__ && __aarch64__` 下用 `MAP_JIT` + `pthread_jit_write_protect_np()` 正确处理了 M 芯片的 W^X JIT 限制。脚本不做任何 Rosetta 转译。

---

## 它做什么

`build → 配置 → 后台启动节点 → 等待 RPC → 连池开挖`，一条命令走完；也支持分步子命令。

- 自动安装 Xcode CLT / Homebrew / 编译依赖（`cmake pkgconf boost libevent`），Homebrew 路径自动兼容 Intel（`/usr/local`）与 Apple Silicon（`/opt/homebrew`）
- 按指定 release tag 克隆/更新源码并 headless 编译（无 GUI、无 Berkeley-DB、无 Qt）
- 首次运行**随机生成 RPC 密码**（仅监听 `127.0.0.1`，权限 600）
- 后台 `nohup` 运行节点，关终端不影响挖矿
- 挖矿线程数按架构智能取值（见上表），避免超线程 / 能效核拖慢 RandomX

## 前置要求

- **Intel Mac**：macOS 12 (Monterey) 或更高（Bitcoin Core v29.x 代码需要支持 C++20 的 clang）
  - macOS < 12 若编译失败：`brew install llvm`，再用
    `PCOIN_CC="$(brew --prefix llvm)/bin/clang" PCOIN_CXX="$(brew --prefix llvm)/bin/clang++" ./pcoin-mac.sh build`
- **Apple Silicon Mac**：原生 arm64 编译，需 arm64 版 Homebrew（`/opt/homebrew`，官方默认安装即是）；不要在 Rosetta 终端里跑
- 编译约 20–50 分钟（取决于机型）
- 首次启动需同步整条链（数小时），同步期间矿机会等待

## 快速开始

```bash
chmod +x pcoin-mac.sh

# 1) 只编译
./pcoin-mac.sh build

# 2) 后台启动节点（首次会生成配置、等待同步）
./pcoin-mac.sh start

# 3) 连池开挖 —— 必须换成你自己的收款地址
./pcoin-mac.sh mine pc1qYOUR_OWN_ADDRESS_HERE
```

或用环境变量后一条命令走完整流程：

```bash
export PCOIN_ADDRESS=pc1qYOUR_OWN_ADDRESS_HERE
./pcoin-mac.sh            # = build + mine
```

> ⚠️ **务必把收款地址换成你自己的。** 脚本不内置任何真实地址；不提供地址直接 `mine` 会报错退出，防止挖到错误地址。

## 子命令

| 命令 | 作用 |
|---|---|
| `./pcoin-mac.sh` | 全流程：装依赖 → 编译 → 启动 → 连池开挖 |
| `./pcoin-mac.sh build` | 只编译 `bitcoind` / `bitcoin-cli` |
| `./pcoin-mac.sh start` | 后台启动节点 |
| `./pcoin-mac.sh mine [地址] [线程数]` | 连池开挖（线程数默认见架构表，也可手动指定） |
| `./pcoin-mac.sh status` | 查看区块高度 + 矿机状态 |
| `./pcoin-mac.sh logs` | 跟踪 `debug.log`（Ctrl-C 退出，不影响挖矿） |
| `./pcoin-mac.sh stop` | 停挖 + 关节点 |
| `./pcoin-mac.sh restart` | 重启节点 |

## 可覆盖的环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PCOIN_TAG` | `v1.4.30` | 编译的 release tag（建议锁定 release，不用 master） |
| `PCOIN_ADDRESS` | （占位，必填） | 你的 `pc1q...` 收款地址 |
| `PCOIN_POOL` | `pool.pc.am:3333` | 矿池地址 |
| `PCOIN_HOME` | `$HOME/pcoin` | 安装/数据根目录（源码在 `src/`，数据在 `data/`） |
| `PCOIN_CC` / `PCOIN_CXX` | 系统 clang | 老系统可指向 `brew` 的 llvm |

## 线程与温度（重要）

**线程数怎么定：**
- **Intel**：默认 = 物理核数，**不要用逻辑核数**。RandomX 为 ALU/内存带宽密集型，同一物理核上的第二个超线程只会抢资源，实测加超线程反而降速且更热。
- **Apple Silicon**：默认 = **性能核数**（`sysctl -n hw.perflevel0.physicalcpu`，例如 M1 为 4）。脚本刻意**不算能效核**——E 核跑这种重型负载性价比很低，还可能拖累整体。M 系列没有超线程，无需考虑 SMT。
- 想手动调：`./pcoin-mac.sh mine <地址> <线程数>`，建议先从默认值开始，用 `status` 对比稳态算力后再决定。

**散热：**
- Intel MacBook 在持续满载下会降频：以 **30 分钟后的稳态算力**为准，不要看开头一分钟的爆发值。
- **无风扇的 MacBook Air（M 系同理）**长时间满载会降频，建议垫高散热、接电源，必要时减一两个线程。
- Mac mini / Studio / Pro 散热余量更大；Apple Silicon 的大缓存 / 高内存带宽对 RandomX 友好，能效通常明显好于 Intel。

## 数据与配置位置

```
$PCOIN_HOME/
├── src/                     # pcoin 源码 + build/
│   └── build/bin/           # bitcoind, bitcoin-cli (架构跟随你的 Mac)
├── data/
│   ├── pcoin.conf           # 随机 RPC 密码，仅 127.0.0.1
│   └── debug.log
├── bitcoind.pid
└── bitcoind-stdout.log
```

## 说明与安全

- 本脚本只是**编译/运行上游 [pars5555/pcoin](https://github.com/pars5555/pcoin) 的自动化封装**，不含任何挖矿程序本体，也不改动上游源码。
- 编译产物为 ad-hoc 签名，现代 Mac 上可通过 Gatekeeper；无 hardened runtime 但 JIT（RandomX 需要，含 Apple Silicon 的 `MAP_JIT`）正常工作。
- 脚本不内置任何收款地址、私钥或抽成：**请自行核对源码后再运行**（尤其是从非官方渠道拿到的分叉版本）。

## 免责声明

按 MIT 许可“原样”提供。挖矿收益、电费、硬件损耗、行情风险自行承担。请确认你所在司法辖区对加密货币挖矿的合规要求。

## License

[MIT](./LICENSE)
