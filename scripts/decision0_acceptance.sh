#!/usr/bin/env bash
# decision0_acceptance.sh — System-0 (zjev) 决策核集成验收 (P0)
#
# 覆盖:
#   1. sidecar 起服 (zjev-serve mock, ../zjev 构建产物; 缺失则 SKIP)
#   2. 开态: ui_server --zjev-endpoint → 推 tick ≥ 8 → 制造危机 (host-profile)
#      → provenance.survival.decision0 出现且 consults ≥ 1
#   3. 关态: 不带 endpoint → provenance 无 decision0 块 (零行为变化)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-$HOME/.local/share/zigup/0.17.0-dev.2151+2ec5523d5/files/zig}"
[ -x "$ZIG" ] || ZIG="zig"

ZJEV_SERVE="$ROOT/../zjev/zig-out/bin/zjev-serve"
PORT_UI=18990
PORT_UI_OFF=18989
PORT_ZJEV=19377
STATE=/tmp/ghw-decision0-state.json
STATE_OFF=/tmp/ghw-decision0-off-state.json
PIDS=()

cleanup() {
  for p in "${PIDS[@]:-}"; do kill -9 "$p" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

if [ ! -x "$ZJEV_SERVE" ]; then
  echo "[decision0] SKIP: 未找到 $ZJEV_SERVE (克隆并构建 https://github.com/chy3xyz/zjev 后重跑)"
  exit 0
fi

echo "[decision0] build"
"$ZIG" build

echo "[decision0] start zjev-serve (mock/peaked) :$PORT_ZJEV"
"$ZJEV_SERVE" --port "$PORT_ZJEV" --mock-mode peaked > /tmp/ghw-zjev-accept.log 2>&1 &
PIDS+=($!)

echo "[decision0] start ui_server :$PORT_UI (endpoint ON)"
rm -f "$STATE" "$STATE.db"
./zig-out/bin/ui_server --host 127.0.0.1 --port "$PORT_UI" --state "$STATE" --ui-dir ui \
  --zjev-endpoint "http://127.0.0.1:$PORT_ZJEV" --no-autocli > /tmp/ghw-decision0-ui.log 2>&1 &
PIDS+=($!)

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT_UI/api/laws" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

# 推 tick ≥ CONSULT_INTERVAL_TICKS(8): 每 POST /api/tick 1 cycle
# (chat 仅在有 LLM 时才走 cycle worker; 无 LLM 部署用 /api/tick)
for i in $(seq 1 9); do
  curl -fsS -X POST "http://127.0.0.1:$PORT_UI/api/tick" >/dev/null
done

# 制造危机 (mobile 低电量)。注意 refreshLifecycle 里 world_sensor(含 System-0 咨询)
# 在 assessWithProfile 之前 — 第一轮 state 让 last_shortfall 更新为危机,
# 第二轮才触发咨询 (tick=9 ≥ CONSULT_INTERVAL_TICKS=8)。
curl -fsS -X POST "http://127.0.0.1:$PORT_UI/api/host-profile" \
  -d '{"kind":"mobile","battery_pct":5,"thermal_hot":true,"bg_restricted":true}' >/dev/null
# host-profile 的 refreshLifecycle 更新 shortfall 为危机; 下一条 chat 的
# refreshLifecycle 携带危机 shortfall 走到 System-0 咨询点
curl -fsS -X POST "http://127.0.0.1:$PORT_UI/api/tick" >/dev/null
sleep 0.3
curl -fsS "http://127.0.0.1:$PORT_UI/api/state" > /tmp/ghw-decision0-state-api.json

python3 - "$PORT_UI" <<'PYEOF'
import json, sys
d = json.load(open('/tmp/ghw-decision0-state-api.json'))
d0 = d.get('provenance', {}).get('survival', {}).get('decision0')
assert d0 is not None, "开态缺少 provenance.survival.decision0 块"
assert d0.get('enabled') is True, "decision0.enabled != true"
assert d0.get('consults', 0) >= 1, f"consults={d0.get('consults')} < 1 (咨询未发生)"
assert d0.get('gate') in ('above', 'below', 'abstain'), f"gate 非法: {d0.get('gate')}"
assert d0.get('action') in ('proceed', 'diagnose', 'handoff'), f"action 非法: {d0.get('action')}"
print(f"[decision0] ON 态 ✓ consults={d0['consults']} gate={d0['gate']} action={d0['action']} conf={d0['confidence']:.3f}")
PYEOF

echo "[decision0] start ui_server :$PORT_UI_OFF (endpoint OFF)"
rm -f "$STATE_OFF" "$STATE_OFF.db"
./zig-out/bin/ui_server --host 127.0.0.1 --port "$PORT_UI_OFF" --state "$STATE_OFF" --ui-dir ui \
  --no-autocli > /tmp/ghw-decision0-off.log 2>&1 &
PIDS+=($!)

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT_UI_OFF/api/laws" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

curl -fsS "http://127.0.0.1:$PORT_UI_OFF/api/state" > /tmp/ghw-decision0-off-api.json

python3 - <<'PYEOF'
import json
d = json.load(open('/tmp/ghw-decision0-off-api.json'))
d0 = d.get('provenance', {}).get('survival', {}).get('decision0')
assert d0 is None, f"关态不应有 decision0 块, got: {d0}"
print("[decision0] OFF 态 ✓ 无 decision0 块 (零行为变化)")
PYEOF

echo "[decision0] OK — System-0 集成验收通过"
