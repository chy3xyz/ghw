#!/usr/bin/env bash
# check_dark_tests.sh — 暗测试回归防护
#
# Zig 0.17 只收集「被分析文件」的 test 块: 新模块若未在 ghw.zig 引用块接线,
# 其测试会静默不运行 (见 AGENTS.md「测试接线约定」)。本脚本:
#   1. 收集 src/ 下所有声明的 test 名
#   2. 在独立 cache 目录跑 zig build test (复用全局 cache, 不污染工程缓存)
#   3. 逐个执行该目录产出的测试二进制, 确认每个声明名都真的出现
# 任何声明名未出现 ⇒ 非零退出并列出 (即"暗测试")。
#
# 用法: ZIG=~/.local/bin/zig bash scripts/check_dark_tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
CACHE="${CACHE:-/tmp/ghw-darkcheck-cache}"
OUT="${OUT:-/tmp/ghw-darkcheck-out.txt}"
DECL="${DECL:-/tmp/ghw-darkcheck-declared.txt}"

grep -rh '^test "' src --include='*.zig' | sed 's/^test "//;s/".*//' | sort -u > "$DECL"
declared=$(wc -l < "$DECL" | tr -d ' ')

echo "[dark-check] 声明 test 数: $declared"
echo "[dark-check] zig build test (独立 cache: $CACHE)"
# 必须从空 cache 开始: 上次运行留下的陈旧测试二进制会掩盖本次的接线回归
rm -rf "$CACHE"
"$ZIG" build test --cache-dir "$CACHE"

: > "$OUT"
find "$CACHE/o" -name test -type f 2>/dev/null | while IFS= read -r b; do
    # 失败的测试也要留下名字 (census 不因测试失败而中止)
    "$b" --cache-dir="$CACHE" >> "$OUT" 2>&1 || true
done

dark=0
while IFS= read -r t; do
    if ! grep -qF "$t..." "$OUT"; then
        echo "[dark-test] $t"
        dark=$((dark + 1))
    fi
done < "$DECL"

if [ "$dark" -gt 0 ]; then
    echo "[dark-check] FAIL: $dark 个声明的 test 从未运行 (缺 mod.zig 导出或 ghw.zig 引用?)"
    exit 1
fi
echo "[dark-check] OK: $declared/$declared 全部可达"
