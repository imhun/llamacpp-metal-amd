#!/usr/bin/env bash
#
# 自检：确认补丁真的生效、Metal 后端接管的确实是那张独显。
#
# 不需要模型——llama.cpp 启动时会先探测设备并打印一行，补丁版会多打印
# SIMD 组宽。官方构建里连这个字符串都不存在。
#
#   ./scripts/verify.sh                                   # 默认查 tmp/llama.cpp
#   ./scripts/verify.sh path/to/llama-mtmd-cli
#   ./scripts/verify.sh --model m.gguf --mmproj p.gguf    # 顺便跑一次真实推理

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="tmp/llama.cpp/build-metal/bin/llama-mtmd-cli"
MODEL=""
MMPROJ=""

while [ $# -gt 0 ]; do
    case "$1" in
        --model)  MODEL="$2"; shift 2 ;;
        --mmproj) MMPROJ="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "未知参数：$1" >&2; exit 1 ;;
        *)  BIN="$1"; shift ;;
    esac
done

fail() { printf '\033[31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }
pass() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }

[ -x "$BIN" ] || fail "找不到可执行文件：$BIN（先跑 scripts/build.sh）"

# llama.cpp 把设备信息写在 stderr
TMPDIR_VERIFY="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_VERIFY"' EXIT
LOG="$TMPDIR_VERIFY/stderr.log"
"$BIN" --help >/dev/null 2>"$LOG" || true

if ! grep -q "ggml_metal: device 0:" "$LOG"; then
    printf '%s\n' "$(head -5 "$LOG")" >&2
    fail "没有检测到 Metal 设备。可能编译时没开 GGML_METAL，或者这台机器没有可用 GPU"
fi
pass "Metal 设备：$(grep -m1 'ggml_metal: device 0:' "$LOG" | sed 's/^.*device 0: //')"

if ! grep -q "probed SIMD-group width" "$LOG"; then
    fail "Metal 起来了，但缺少 ToshLLM 的 SIMD 组宽探测——补丁没生效。
     官方 llama.cpp 也能打印设备行，所以这一项才是补丁的判据"
fi
pass "补丁生效：$(grep -m1 'probed SIMD-group width' "$LOG" | sed 's/^.*probed/probed/')"

if grep -q "not bridged" "$LOG"; then
    pass "识别为独立显卡（not bridged），不会被当成 Apple 统一内存 GPU"
fi

if [ -n "$MODEL" ] || [ -n "$MMPROJ" ]; then
    [ -n "$MODEL" ] && [ -n "$MMPROJ" ] || fail "--model 和 --mmproj 要一起给"
    [ -f "$MODEL" ] || fail "模型不存在：$MODEL"
    [ -f "$MMPROJ" ] || fail "mmproj 不存在：$MMPROJ"

    IMG="$TMPDIR_VERIFY/probe.png"
    python3 - "$IMG" <<'PY'
import sys
try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("需要 Pillow 生成测试图：pip install pillow")
img = Image.new("RGB", (900, 400), "white")
ImageDraw.Draw(img).text((50, 80), "llama.cpp metal verify 12345", fill="black")
img.save(sys.argv[1])
PY

    echo "     跑一次真实推理"
    if "$BIN" -m "$MODEL" --mmproj "$MMPROJ" --image "$IMG" \
        -p "Extract all readable content in reading order." -n 64 -ngl 99 \
        >/dev/null 2>>"$LOG"; then
        pass "推理跑通（没有触发 GPU timeout）"
    else
        fail "推理失败，日志：$LOG"
    fi
fi

echo
pass "自检通过"
