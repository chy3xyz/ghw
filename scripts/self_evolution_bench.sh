#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
LOG="${LOG:-/tmp/ghw-self-evolution-bench.log}"
rm -f "$LOG"

echo "[bench] build"
"$ZIG" build

echo "[bench] run self-evolution A/B benchmark (deterministic, no network)"
if ! ./zig-out/bin/bench_self_evolution 2>&1 | tee "$LOG"; then
  echo "[bench] FAIL — benchmark reported failure (see $LOG)" >&2
  exit 1
fi

grep -q '"passed":true' "$LOG"
echo "[bench] OK — self-evolution raised E (A/B, deterministic; see $LOG)"
