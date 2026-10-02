#!/usr/bin/env bash
#
# 把编译好的 llama-mtmd-cli 装到全局，供多个项目共用。
#
# 装出来的命令叫 llama-mtmd-cli-amd，不会碰 brew 装的 llama-mtmd-cli
# （那个是官方版，覆盖它会破坏 brew 的记录）。
#
#   ./scripts/install.sh                 # 装到 /usr/local
#   ./scripts/install.sh --prefix ~/.local
#   ./scripts/install.sh --dry-run       # 只看会做什么
#   ./scripts/install.sh --uninstall     # 卸掉

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../versions.env
. "$ROOT/versions.env"

PREFIX="/usr/local"
NAME="llama-mtmd-cli-amd"
DRY_RUN=0
UNINSTALL=0

if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s  ✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s  ✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)    PREFIX="$2"; shift 2 ;;
        --name)      NAME="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)   usage ;;
        *)           die "未知参数：$1（用 --help 看用法）" ;;
    esac
done

# 前缀一律转成绝对路径：符号链接的目标要写绝对路径，否则相对前缀会指歪
case "$PREFIX" in
    /*) ;;
    *)  PREFIX="$(cd "$PREFIX" 2>/dev/null && pwd || printf '%s/%s' "$PWD" "$PREFIX")" ;;
esac

LIB_DIR="$PREFIX/lib/llamacpp-metal-amd"
BIN_SRC="$ROOT/tmp/llama.cpp/build-metal/bin/llama-mtmd-cli"
BIN_DST="$LIB_DIR/llama-mtmd-cli"
INFO_DST="$LIB_DIR/BUILD-INFO"
LINK_DST="$PREFIX/bin/$NAME"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '     [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------- 卸载

if [ "$UNINSTALL" -eq 1 ]; then
    step "卸载 $NAME"
    if [ -L "$LINK_DST" ]; then
        run rm -f "$LINK_DST"
        ok "已删除链接 $LINK_DST"
    else
        warn "$LINK_DST 不是符号链接，没动它"
    fi
    if [ -d "$LIB_DIR" ]; then
        run rm -rf "$LIB_DIR"
        ok "已删除 $LIB_DIR"
    fi
    exit 0
fi

# ---------------------------------------------------------------- 检查

step "检查待安装的二进制"

[ -x "$BIN_SRC" ] || die "找不到 $BIN_SRC，先跑 ./scripts/build.sh"

# 只有通过自检的二进制才值得装到全局：否则等于把一个跑不出正确结果的
# 命令塞进 PATH，别的项目会被带偏。
if [ "$DRY_RUN" -eq 1 ]; then
    warn "--dry-run，跳过自检"
else
    "$ROOT/scripts/verify.sh" "$BIN_SRC" >/dev/null || die "自检没过，不安装"
    ok "自检通过（Metal 可用，补丁生效）"
fi

# 装的必须是打补丁的版本，别把官方构建装进来。
# 注意别写成 `strings ... | grep -q`：grep -q 找到就退出，strings 收到 SIGPIPE
# 会以非零状态结束，配上 set -o pipefail 会把整条管道判成失败。
if ! grep -aq "probed SIMD-group" "$BIN_SRC"; then
    die "$BIN_SRC 不含 ToshLLM 的 SIMD 探测代码，像是官方构建，不安装"
fi
ok "二进制确认是补丁版"

if [ -e "$LINK_DST" ] && [ ! -L "$LINK_DST" ]; then
    die "$LINK_DST 已经存在且不是符号链接，怕覆盖别的东西，先自己处理它"
fi
if [ -L "$LINK_DST" ] && [ "$(readlink "$LINK_DST")" != "$BIN_DST" ]; then
    warn "$LINK_DST 指向别处（$(readlink "$LINK_DST")），会被改成 $BIN_DST"
fi

REPO_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DATE="$(date +%Y-%m-%dT%H:%M:%S%z)"

step "安装到 $PREFIX"
run mkdir -p "$LIB_DIR" "$PREFIX/bin"
run install -m 755 "$BIN_SRC" "$BIN_DST"

INFO="llama.cpp ${LLAMA_COMMIT}
toshllm   ${TOSHLLM_COMMIT}
patches   ${PATCH_COUNT} files, series sha256 ${PATCH_SERIES_SHA256}
repo      https://github.com/imhun/llamacpp-metal-amd @ ${REPO_COMMIT}
arch      $(uname -m)
built     ${DATE}
selfcheck ./scripts/verify.sh ${BIN_DST}
"
if [ "$DRY_RUN" -eq 1 ]; then
    printf '     [dry-run] 写 %s:\n%s\n' "$INFO_DST" "$INFO"
else
    printf '%s' "$INFO" > "$INFO_DST"
fi
ok "二进制与元数据就位"

run ln -sf "$BIN_DST" "$LINK_DST"
ok "链接 $LINK_DST → $BIN_DST"

step "完成"
if [ "$DRY_RUN" -eq 1 ]; then
    warn "这是 dry-run，什么都没改"
    exit 0
fi

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) warn "$PREFIX/bin 不在 PATH 里，用的时候要写全路径" ;;
esac

cat <<EOF
  命令:  $NAME
  元数据: $INFO_DST

  别的项目直接调用即可，不需要再各自编译：
    $NAME -m 模型.gguf --mmproj mmproj.gguf --image 页面.png -p "提示词"

  版本对不上时重装覆盖，卸载用 ./scripts/install.sh --uninstall
EOF
