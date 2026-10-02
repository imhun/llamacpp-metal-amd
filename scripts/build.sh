#!/usr/bin/env bash
#
# 在 macOS 上为 AMD / Intel 独显构建 Metal 加速的 llama.cpp。
#
# 流程：环境检查 -> 取补丁（submodule）-> clone llama.cpp 并切到 pin 的 commit
#       -> 依次打补丁 -> 编译 llama-mtmd-cli -> 自检
#
# 可以反复执行，每一步做完就会跳过。从头再来加 --clean。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../versions.env
. "$ROOT/versions.env"

WORK_DIR="tmp/llama.cpp"
BUILD_SUBDIR="build-metal"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
PATCH_SUBMODULE="third_party/toshllm"
PATCH_DIR="$PATCH_SUBMODULE/patches/llama"
PATCH_MARKER=".patch-series"

DO_CLEAN=0
FORCE=0
SKIP_VERIFY=0
PATCHES_ONLY=0

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
    cat <<'EOF'
为 AMD / Intel 独显构建 Metal 加速的 llama.cpp

用法:
  ./scripts/build.sh [选项]

选项:
  --work-dir DIR   llama.cpp 源码与构建目录（默认 tmp/llama.cpp）
  -j, --jobs N     并行编译数（默认 CPU 核数）
  --rebuild        删掉构建目录重新编译（保留源码与补丁）
  --clean          删掉整个工作目录，从 clone 开始重来
  --patches-only   只准备源码并打完补丁，不编译（适合先验证补丁链）
  --skip-verify    编译完不做自检
  -h, --help       显示这段帮助

pin 的版本在 versions.env 里，包含 llama.cpp commit 与 ToshLLM commit。
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --work-dir)    WORK_DIR="$2"; shift 2 ;;
        -j|--jobs)     JOBS="$2"; shift 2 ;;
        --rebuild)     FORCE=1; shift ;;
        --clean)       DO_CLEAN=1; shift ;;
        --patches-only) PATCHES_ONLY=1; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help)     usage ;;
        *)             die "未知参数：$1（用 --help 看用法）" ;;
    esac
done

BUILD_PATH="$WORK_DIR/$BUILD_SUBDIR"
LLAMA_BIN="$BUILD_PATH/bin/llama-mtmd-cli"

# 注意用不带 ./ 前缀的 glob：文件名会进哈希，前缀一变整串就变了。
# 重新生成的方式写在 versions.env 里。
series_hash() {
    (cd "$PATCH_DIR" && shasum -a 256 *.patch | shasum -a 256 | awk '{print $1}')
}

# ---------------------------------------------------------------- 0. 环境

step "0/5 环境检查"

for tool in git cmake curl shasum; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool"
done
[ "$(uname -s)" = "Darwin" ] || die "这个脚本只针对 macOS"
xcode-select -p >/dev/null 2>&1 || die "缺少 Xcode 命令行工具，先跑 xcode-select --install"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|arm64) ok "架构 $ARCH，Xcode: $(xcode-select -p)" ;;
    *)            die "不认识的架构：$ARCH" ;;
esac

if [ "$DO_CLEAN" -eq 1 ]; then
    step "清理 $WORK_DIR"
    [ -e "$WORK_DIR" ] && mv "$WORK_DIR" "$WORK_DIR.removed-$(date +%s)"
    ok "已移走旧工作目录（保留在同级目录，确认没问题后可以删）"
fi

# ---------------------------------------------------------------- 1. 补丁来源

step "1/5 补丁来源（ToshLLM submodule）"

if [ ! -e "$PATCH_DIR" ] || [ -z "$(ls -A "$PATCH_DIR" 2>/dev/null)" ]; then
    warn "补丁不在，拉取 submodule"
    git submodule update --init --depth 1 "$PATCH_SUBMODULE" \
        || die "submodule 拉取失败。GitHub 直连不通时先设代理：
     export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897"
fi
[ -d "$PATCH_DIR" ] || die "找不到 $PATCH_DIR"

SUBMODULE_HEAD="$(git -C "$PATCH_SUBMODULE" rev-parse HEAD)"
COUNT="$(ls "$PATCH_DIR"/*.patch | wc -l | tr -d ' ')"
HASH="$(series_hash)"

if [ "$COUNT" != "$PATCH_COUNT" ] || [ "$HASH" != "$PATCH_SERIES_SHA256" ]; then
    die "补丁和 versions.env 记录的对不上
     期望 $PATCH_COUNT 个 / $PATCH_SERIES_SHA256
     实际 $COUNT 个 / $HASH
     submodule 现在在 ${SUBMODULE_HEAD:0:12}，期望 ${TOSHLLM_COMMIT:0:12}
     跑 git submodule update --init --depth 1 恢复"
fi
ok "$COUNT 个补丁，校验和一致（ToshLLM ${SUBMODULE_HEAD:0:12}）"

# ---------------------------------------------------------------- 2. 源码

step "2/5 llama.cpp 源码"

if [ ! -d "$WORK_DIR/.git" ]; then
    mkdir -p "$(dirname "$WORK_DIR")"
    echo "     clone $LLAMA_REPO"
    git clone -q --filter=blob:none "$LLAMA_REPO" "$WORK_DIR" \
        || die "clone 失败。GitHub 直连不通时先设代理：
     export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897"
    ok "源码已就位"
else
    ok "源码目录已存在"
fi

HEAD_COMMIT="$(git -C "$WORK_DIR" rev-parse HEAD)"
if [ "$HEAD_COMMIT" != "$LLAMA_COMMIT" ]; then
    # patch 建立的文件是 untracked，切 commit 不会清掉，下一次 apply 会失败
    [ -f "$WORK_DIR/$PATCH_MARKER" ] && mv "$WORK_DIR/$PATCH_MARKER" "$WORK_DIR/$PATCH_MARKER.stale"
    git -C "$WORK_DIR" fetch -q origin "$LLAMA_COMMIT" 2>/dev/null || git -C "$WORK_DIR" fetch -q origin
    git -C "$WORK_DIR" checkout -qf "$LLAMA_COMMIT"
    git -C "$WORK_DIR" clean -qfd
    ok "已切到 ${LLAMA_COMMIT:0:12}（工作树已清理）"
else
    ok "commit 正确：${LLAMA_COMMIT:0:12}"
fi

# ---------------------------------------------------------------- 3. 打补丁

step "3/5 打补丁"

MARKER_PATH="$WORK_DIR/$PATCH_MARKER"
MARKER_VALUE="$LLAMA_COMMIT $TOSHLLM_COMMIT $COUNT"

if [ -f "$MARKER_PATH" ] && [ "$(cat "$MARKER_PATH")" = "$MARKER_VALUE" ]; then
    ok "已经打过这批补丁，跳过"
else
    FIRST_PATCH="$(ls "$PATCH_DIR"/*.patch | head -1)"
    if ! git -C "$WORK_DIR" apply --check "$ROOT/$FIRST_PATCH" 2>/dev/null; then
        DIRTY="$(git -C "$WORK_DIR" status --porcelain | wc -l | tr -d ' ')"
        die "源码树不是 $LLAMA_COMMIT 的干净副本，补丁打不上去（$DIRTY 个改动）
     可能是之前手动打过补丁。用 ./scripts/build.sh --clean 重来"
    fi

    applied=0
    for p in "$PATCH_DIR"/*.patch; do
        git -C "$WORK_DIR" apply "$ROOT/$p" >/dev/null 2>&1 \
            || die "补丁失败：$(basename "$p")，用 --clean 重来"
        applied=$((applied + 1))
    done
    printf '%s' "$MARKER_VALUE" > "$MARKER_PATH"
    ok "$applied 个补丁全部应用成功"
fi

# ---------------------------------------------------------------- 4. 编译

step "4/5 编译 llama-mtmd-cli"

if [ "$PATCHES_ONLY" -eq 1 ]; then
    warn "--patches-only，编译与自检都跳过"
    step "完成"
    echo "  源码与补丁就绪：$ROOT/$WORK_DIR"
    exit 0
fi

if [ "$FORCE" -eq 1 ] && [ -d "$BUILD_PATH" ]; then
    mv "$BUILD_PATH" "$BUILD_PATH.removed-$(date +%s)"
    ok "已移走旧构建目录"
fi

# 只看二进制存在与否是不够的：目录里可能躺着别人（或更早的官方构建）编出来的
# 同名文件。用补丁标记做凭据，对不上就当它不存在。
BUILD_STAMP="$BUILD_PATH/.patch-series"
if [ -x "$LLAMA_BIN" ] && [ -f "$BUILD_STAMP" ] && [ "$(cat "$BUILD_STAMP")" = "$MARKER_VALUE" ]; then
    ok "已有构建产物，跳过（重编加 --rebuild）"
else
    if [ -e "$BUILD_PATH" ]; then
        mv "$BUILD_PATH" "$BUILD_PATH.stale-$(date +%s)"
        warn "旧构建目录没有对应的补丁标记，已移开（$BUILD_PATH.stale-*），重新编译"
    fi

    if [ "$ARCH" = "x86_64" ]; then
        SIMD_FLAGS=(
            -DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES=x86_64
            -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
            -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON
            -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON
            -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF
        )
    else
        SIMD_FLAGS=(-DGGML_NATIVE=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0)
    fi

    mkdir -p tmp
    echo "     配置"
    cmake -S "$WORK_DIR" -B "$BUILD_PATH" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
        -DTOSH_ENABLE_DYNAMIC_MOE=ON -DLLAMA_OPENSSL=OFF \
        "${SIMD_FLAGS[@]}" > tmp/cmake-configure.log 2>&1 \
        || die "配置失败，日志：tmp/cmake-configure.log"
    ok "配置完成"

    echo "     编译 -j $JOBS，首次大约 5-15 分钟"
    cmake --build "$BUILD_PATH" -j "$JOBS" -t llama-mtmd-cli > tmp/cmake-build.log 2>&1 \
        || die "编译失败，日志尾部：
$(tail -20 tmp/cmake-build.log)"
    printf '%s' "$MARKER_VALUE" > "$BUILD_STAMP"
    ok "编译完成"
fi

# ---------------------------------------------------------------- 5. 自检

step "5/5 自检"

if [ "$SKIP_VERIFY" -eq 1 ]; then
    warn "跳过自检"
elif [ -x scripts/verify.sh ]; then
    scripts/verify.sh "$LLAMA_BIN" || exit 1
else
    warn "scripts/verify.sh 缺失，跳过"
fi

step "完成"
cat <<EOF
  产物:  $ROOT/$LLAMA_BIN

  用法（llama.cpp 自带的多模态 CLI）:
    $LLAMA_BIN -m 模型.gguf --mmproj mmproj.gguf --image 页面.png -p "提示词"

  改 pin 的版本: 编辑 versions.env，然后 ./scripts/build.sh --clean
EOF
