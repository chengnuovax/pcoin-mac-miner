#!/usr/bin/env bash
#
# pcoin-mac.sh — PCoin (PCN) RandomX CPU 挖矿：Intel macOS 一键构建 + 运行
#
# 用法:
#   ./pcoin-mac.sh                 # 全流程: 装依赖 -> 编译 -> 启动节点 -> 连池开挖
#   ./pcoin-mac.sh build           # 只编译 (bitcoind / bitcoin-cli)
#   ./pcoin-mac.sh start           # 后台启动节点
#   ./pcoin-mac.sh mine [地址] [线程数]   # 连池开挖 (默认: Intel=物理核 / Apple Silicon=性能核)
#   ./pcoin-mac.sh status          # 查看节点高度 + 矿机状态
#   ./pcoin-mac.sh logs            # 跟踪 debug.log (Ctrl-C 退出, 不影响挖矿)
#   ./pcoin-mac.sh stop            # 停挖 + 关节点
#
# 可覆盖的环境变量:
#   PCOIN_TAG=v1.4.30            编译的 release tag
#   PCOIN_ADDRESS=pc1...         【必填】你的收款地址 (脚本不内置任何默认地址)
#   PCOIN_POOL=pool.pc.am:3333   矿池
#   PCOIN_HOME=$HOME/pcoin       安装/数据根目录
#
set -euo pipefail

PCOIN_TAG="${PCOIN_TAG:-v1.4.30}"
PCOIN_HOME="${PCOIN_HOME:-$HOME/pcoin}"
# 占位地址，绝非真实地址；运行前必须替换成你自己的收款地址。
PCOIN_ADDRESS="${PCOIN_ADDRESS:-pc1qREPLACE_WITH_YOUR_OWN_ADDRESS}"
PCOIN_POOL="${PCOIN_POOL:-pool.pc.am:3333}"

SRC_DIR="$PCOIN_HOME/src"
DATA_DIR="$PCOIN_HOME/data"
BUILD_DIR="$SRC_DIR/build"
BITCOIND="$BUILD_DIR/bin/bitcoind"
BITCOINCLI="$BUILD_DIR/bin/bitcoin-cli"
CONF="$DATA_DIR/pcoin.conf"
PIDFILE="$PCOIN_HOME/bitcoind.pid"
BOOT_LOG="$PCOIN_HOME/bitcoind-stdout.log"

c_info()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()     { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 环境检查 ----------

[ "$(uname -s)" = "Darwin" ] || die "此脚本仅用于 macOS。"

physical_cores() { sysctl -n hw.physicalcpu; }

# 挖矿默认线程数:
#   Intel                -> 物理核数 (RandomX 在超线程/SMT 上是负收益, 不用逻辑核)
#   Apple Silicon arm64  -> 只数性能核 hw.perflevel0.physicalcpu;
#                           能效核 (perflevel1) 会拖慢这种重型 ALU/内存带宽负载, 不划算。
# 取性能核失败时回退到物理核总数。
mine_threads() {
    if [ "$(uname -m)" = "arm64" ]; then
        local p
        p="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)"
        if [ -n "$p" ] && [ "$p" -gt 0 ] 2>/dev/null; then
            echo "$p"
            return
        fi
    fi
    physical_cores
}

setup_path() {
    if [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"          # Intel Mac
    elif [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"        # Apple Silicon (也兼容)
    fi
}

ensure_xcode_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        c_ok "Xcode Command Line Tools 已安装"
    else
        c_warn "未安装 Xcode Command Line Tools，正在弹出安装窗口……"
        xcode-select --install || true
        die "请在弹窗中完成安装（可能需要几分钟），然后重新运行本脚本。"
    fi
}

ensure_brew() {
    setup_path
    if command -v brew >/dev/null 2>&1; then
        c_ok "Homebrew 已存在: $(command -v brew)"
        return
    fi
    c_info "安装 Homebrew（过程中会要求输入 Mac 登录密码）……"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    setup_path
    command -v brew >/dev/null 2>&1 || die "Homebrew 安装失败，请按 https://brew.sh 手动安装后重试。"
}

ensure_deps() {
    ensure_xcode_clt
    ensure_brew
    c_info "检查/安装编译依赖: cmake pkgconf boost libevent ……"
    local pkgs="cmake pkgconf boost libevent"
    # 已装的包不重复装
    local missing=""
    for p in $pkgs; do
        brew list --versions "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        brew install $missing
    fi
    c_ok "依赖就绪"

    # Bitcoin Core v29.x 需要较新 clang (C++20)。老系统给个明确提示。
    local macos_major
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$macos_major" -lt 12 ] 2>/dev/null; then
        c_warn "macOS 版本低于 12 (Monterey)，自带 clang 可能编不过 v29 系代码。"
        c_warn "若编译失败: brew install llvm，然后重跑: PCOIN_CC='$(brew --prefix llvm)/bin/clang' $0 build"
    fi
}

# ---------- 源码 ----------

fetch_source() {
    if [ -d "$SRC_DIR/.git" ]; then
        c_info "更新源码到 $PCOIN_TAG ……"
        git -C "$SRC_DIR" fetch --tags --quiet
        git -C "$SRC_DIR" checkout --quiet "$PCOIN_TAG"
    else
        c_info "克隆 pcoin 源码 ($PCOIN_TAG) ……"
        mkdir -p "$PCOIN_HOME"
        git clone --quiet --branch "$PCOIN_TAG" --depth 1 \
            https://github.com/pars5555/pcoin.git "$SRC_DIR"
    fi
    c_ok "源码就绪: $SRC_DIR @ $PCOIN_TAG"
}

# ---------- 编译 ----------

do_build() {
    ensure_deps
    fetch_source

    local cc_flags=""
    [ -n "${PCOIN_CC:-}" ]  && cc_flags="$cc_flags -DCMAKE_C_COMPILER=${PCOIN_CC}"
    [ -n "${PCOIN_CXX:-}" ] && cc_flags="$cc_flags -DCMAKE_CXX_COMPILER=${PCOIN_CXX}"

    c_info "CMake 配置（headless，无 GUI / 无测试，编译产物: build/bin/）……"
    cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
        -DBUILD_GUI=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_BENCH=OFF \
        -DBUILD_FUZZ_BINARY=OFF \
        $cc_flags

    c_info "开始编译，使用 $(physical_cores) 个物理核（约 20–50 分钟，取决于机型）……"
    cmake --build "$BUILD_DIR" -j "$(physical_cores)" --target bitcoind bitcoin-cli
    c_ok "编译完成: $BITCOIND"
    "$BITCOIND" --version 2>/dev/null | head -1 || true
    "$BITCOINCLI" --version 2>/dev/null | head -1 || true
}

# ---------- 节点配置 / 进程 ----------

init_data() {
    mkdir -p "$DATA_DIR"
    if [ ! -f "$CONF" ]; then
        c_info "首次运行，生成 $CONF ……"
        local rpcpw
        rpcpw="$(openssl rand -hex 24)"
        cat > "$CONF" <<EOF
server=1
rpcuser=pcoinrpc
rpcpassword=${rpcpw}
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
listen=0
upnp=0
natpmp=0
EOF
        chmod 600 "$CONF"
        c_ok "配置已生成（随机 RPC 密码，仅本机可访问）"
    fi
}

rpc() { "$BITCOINCLI" -datadir="$DATA_DIR" "$@"; }

node_pid() {
    [ -f "$PIDFILE" ] || return 1
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

wait_rpc() {
    local i
    for i in $(seq 1 120); do
        if rpc getblockcount >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_node() {
    [ -x "$BITCOIND" ] || die "还没编译，先运行: $0 build"
    init_data
    if node_pid >/dev/null 2>&1; then
        c_ok "节点已在运行 (pid $(node_pid))"
        return
    fi
    c_info "后台启动 bitcoind（数据目录 ${DATA_DIR}）……"
    nohup "$BITCOIND" -datadir="$DATA_DIR" >>"$BOOT_LOG" 2>&1 &
    echo $! > "$PIDFILE"
    c_info "等待 RPC 就绪（最多 120 秒）……"
    if wait_rpc; then
        c_ok "节点已启动，当前区块高度: $(rpc getblockcount)"
        c_warn "首次运行需要同步整条链（数小时），同步期间矿机会等待，不影响已提交的挖矿任务。"
    else
        echo "----- 节点启动日志 $BOOT_LOG -----" >&2
        tail -40 "$BOOT_LOG" 2>/dev/null >&2 || true
        if [ -f "$DATA_DIR/debug.log" ]; then
            echo "----- debug.log 尾部 -----" >&2
            tail -40 "$DATA_DIR/debug.log" >&2
        fi
        die "节点 RPC 120 秒内未就绪，报错见上方日志。"
    fi
}

# ---------- 挖矿 ----------

do_mine() {
    local addr="${1:-$PCOIN_ADDRESS}"
    local threads="${2:-$(mine_threads)}"
    case "$addr" in
        *REPLACE_WITH_YOUR_OWN_ADDRESS*)
            die "还没有设置收款地址！请用: $0 mine <你的pc1q地址> [线程数]  或  export PCOIN_ADDRESS=pc1q... 后再运行。"
            ;;
    esac
    start_node
    c_info "连接矿池 $PCOIN_POOL"
    c_info "收款地址: $addr"
    if [ "$(uname -m)" = "arm64" ]; then
        c_info "架构: Apple Silicon (arm64)，挖矿线程默认只取性能核 $(mine_threads) 个（不含能效核）"
    else
        c_info "架构: $(uname -m)，挖矿线程默认取物理核 $(mine_threads) 个（不含超线程）"
    fi
    c_info "挖矿线程: $threads（RandomX 上超线程 / 能效核都是负收益，勿手动调高）"
    # 重复调用 startpoolmining 会重启矿机并清零计数，属正常
    rpc startpoolmining "$PCOIN_POOL" "$addr" "$threads"
    sleep 3
    show_status
    c_ok "已在后台挖矿。关闭终端不影响；查看: $0 status | 日志: $0 logs | 停止: $0 stop"
}

show_status() {
    if ! node_pid >/dev/null 2>&1; then
        c_warn "节点未运行，用 $0 start 启动"
        return
    fi
    c_info "区块高度: $(rpc getblockcount 2>/dev/null || echo '?')"
    rpc getcpuminerinfo 2>/dev/null || c_warn "矿机未启动: $0 mine"
}

do_stop() {
    if node_pid >/dev/null 2>&1; then
        c_info "停止矿机 ……"
        rpc stopmining >/dev/null 2>&1 || true
        c_info "关闭节点 ……"
        rpc stop >/dev/null 2>&1 || kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
        c_ok "已停止"
    else
        c_warn "节点本来就没在运行"
        rm -f "$PIDFILE"
    fi
}

# ---------- 入口 ----------

case "${1:-all}" in
    all)
        do_build
        do_mine
        ;;
    build)   do_build ;;
    start)   start_node ;;
    mine)    shift; do_mine "$@" ;;
    status)  show_status ;;
    logs)
        init_data
        exec tail -F "$DATA_DIR/debug.log"
        ;;
    stop)    do_stop ;;
    restart) do_stop; start_node ;;
    *)
        grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
        die "未知子命令: $1"
        ;;
esac
