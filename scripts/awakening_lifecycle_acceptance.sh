#!/usr/bin/env bash
# awakening_lifecycle_acceptance.sh — P0–P2 求存×进化验收
# 覆盖: laws / awaken / host-profile / shortfall / evolution_acceptance / peer-inbox / state_meta
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
PORT="${PORT:-18766}"
STATE="${STATE:-/tmp/ghw-awakening-acceptance-state.json}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-cache}"

rm -f "$STATE" "$STATE.db" "${STATE}.tmp"

echo "[acceptance] zig build test"
"$ZIG" build test

echo "[acceptance] zig build"
"$ZIG" build

if ! command -v curl >/dev/null 2>&1; then
  echo "[acceptance] curl missing — compile-only pass"
  exit 0
fi

curl_code() {
  curl -sS -o /tmp/ghw-awaken-body.json -w '%{http_code}' "$@"
}

echo "[acceptance] start ui_server :$PORT"
./zig-out/bin/ui_server \
  --host 127.0.0.1 \
  --port "$PORT" \
  --state "$STATE" \
  --ui-dir ui \
  --auto-tick-ms 0 \
  > /tmp/ghw-awakening-acceptance.log 2>&1 &
PID=$!
trap 'kill "$PID" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$PORT/api/laws" >/tmp/ghw-awaken-laws.json 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if ! [[ -s /tmp/ghw-awaken-laws.json ]]; then
  echo "[acceptance] ui_server failed to start; log:"
  tail -40 /tmp/ghw-awakening-acceptance.log || true
  exit 1
fi

echo "[acceptance] GET /api/laws"
grep -q '"version"' /tmp/ghw-awaken-laws.json
grep -q '"laws"' /tmp/ghw-awaken-laws.json

echo "[acceptance] POST /api/host-profile (mobile low battery)"
CODE="$(
  curl_code -X POST "http://127.0.0.1:$PORT/api/host-profile" \
    -H 'Content-Type: application/json' \
    -d '{"battery_pct":10,"thermal_hot":true,"bg_restricted":false}'
)"
test "$CODE" = "200"
grep -q '"kind":"mobile"' /tmp/ghw-awaken-body.json
grep -q '"battery_low":true' /tmp/ghw-awaken-body.json
grep -q '"host_crisis":true' /tmp/ghw-awaken-body.json

echo "[acceptance] GET /api/state provenance"
curl -fsS "http://127.0.0.1:$PORT/api/state" >/tmp/ghw-awaken-state.json
python3 -c 'import json; json.load(open("/tmp/ghw-awaken-state.json"))' || {
  echo "[acceptance] /api/state is not valid JSON"
  exit 1
}
grep -q '"existence_phase"' /tmp/ghw-awaken-state.json
grep -q '"evolution_acceptance"' /tmp/ghw-awaken-state.json
grep -q '"host_profile"' /tmp/ghw-awaken-state.json
grep -q '"peer_inbox"' /tmp/ghw-awaken-state.json
grep -q '"state_contract"' /tmp/ghw-awaken-state.json
grep -q '"kind":"mobile"' /tmp/ghw-awaken-state.json
grep -q '"crisis_lock":true\|"existence_phase":"crisis"' /tmp/ghw-awaken-state.json

echo "[acceptance] GET /api/peer-inbox"
curl -fsS "http://127.0.0.1:$PORT/api/peer-inbox" >/tmp/ghw-awaken-inbox.json
grep -q '"entries"' /tmp/ghw-awaken-inbox.json

echo "[acceptance] POST /api/peer-inbox/share"
SHARE_CODE="$(
  curl_code -X POST "http://127.0.0.1:$PORT/api/peer-inbox/share" \
    -H 'Content-Type: application/json' \
    -d '{"peer_id":"acc-peer","host_crisis":true,"favored_dim":1,"material":0.55,"disk_hot":true}'
)"
test "$SHARE_CODE" = "200"
grep -q '"accepted":true' /tmp/ghw-awaken-body.json
curl -fsS "http://127.0.0.1:$PORT/api/peer-inbox" >/tmp/ghw-awaken-inbox2.json
grep -q 'acc-peer' /tmp/ghw-awaken-inbox2.json

echo "[acceptance] POST /api/awaken (idempotent)"
AWAKEN_CODE="$(curl_code -X POST "http://127.0.0.1:$PORT/api/awaken")"
# 200 if sample ok, 503 if no sample yet — both acceptable if JSON shaped
test "$AWAKEN_CODE" = "200" -o "$AWAKEN_CODE" = "503"
grep -q '"awaken"' /tmp/ghw-awaken-body.json

echo "[acceptance] GET /api/tasks by_dimension"
curl -fsS "http://127.0.0.1:$PORT/api/tasks" >/tmp/ghw-awaken-tasks.json
grep -q '"by_dimension"' /tmp/ghw-awaken-tasks.json

echo "[acceptance] state.json has state_meta after save"
# force a tick so saveState runs
curl -fsS -X POST "http://127.0.0.1:$PORT/api/tick" >/dev/null || true
sleep 0.5
if [[ -f "$STATE" ]]; then
  grep -q '"state_meta"' "$STATE" || grep -q '"host_profile"' "$STATE"
fi

echo "[acceptance] OK — awakening lifecycle P0–P2 HTTP checks passed"
