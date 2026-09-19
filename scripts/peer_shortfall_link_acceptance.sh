#!/usr/bin/env bash
# peer_shortfall_link_acceptance.sh — 双 ui_server Link query_shortfall → inbox
# 覆盖: POST /api/peer-inbox/share (单机) + 双实例 Unix Link query_shortfall
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
PORT_A="${PORT_A:-18771}"
PORT_B="${PORT_B:-18772}"
STATE_A="${STATE_A:-/tmp/ghw-peer-sf-a.json}"
STATE_B="${STATE_B:-/tmp/ghw-peer-sf-b.json}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-cache}"

rm -f "$STATE_A" "$STATE_B" "$STATE_A.db" "$STATE_B.db"
rm -f /tmp/ghw_peer-sf-a.sock /tmp/ghw_peer-sf-b.sock /tmp/ghw_ghw-ui.sock

echo "[peer-sf] zig build"
"$ZIG" build

if ! command -v curl >/dev/null 2>&1; then
  echo "[peer-sf] curl missing — compile-only pass"
  exit 0
fi

curl_code() {
  curl -sS -o /tmp/ghw-peer-sf-body.json -w '%{http_code}' "$@"
}

echo "[peer-sf] start ui_server A :$PORT_A (peer-sf-a)"
./zig-out/bin/ui_server \
  --host 127.0.0.1 \
  --port "$PORT_A" \
  --state "$STATE_A" \
  --ui-dir ui \
  --auto-tick-ms 0 \
  --id peer-sf-a \
  > /tmp/ghw-peer-sf-a.log 2>&1 &
PID_A=$!

echo "[peer-sf] start ui_server B :$PORT_B (peer-sf-b)"
./zig-out/bin/ui_server \
  --host 127.0.0.1 \
  --port "$PORT_B" \
  --state "$STATE_B" \
  --ui-dir ui \
  --auto-tick-ms 0 \
  --id peer-sf-b \
  > /tmp/ghw-peer-sf-b.log 2>&1 &
PID_B=$!

cleanup() {
  kill -9 "$PID_A" "$PID_B" >/dev/null 2>&1 || true  # -9: ui_server 无 SIGTERM handler
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT_A/api/laws" >/dev/null 2>&1 \
    && curl -fsS "http://127.0.0.1:$PORT_B/api/laws" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

if ! curl -fsS "http://127.0.0.1:$PORT_A/api/laws" >/dev/null 2>&1; then
  echo "[peer-sf] A failed; log:"; tail -40 /tmp/ghw-peer-sf-a.log || true
  exit 1
fi
if ! curl -fsS "http://127.0.0.1:$PORT_B/api/laws" >/dev/null 2>&1; then
  echo "[peer-sf] B failed; log:"; tail -40 /tmp/ghw-peer-sf-b.log || true
  exit 1
fi

echo "[peer-sf] POST /api/peer-inbox/share on A (local inject)"
CODE="$(
  curl_code -X POST "http://127.0.0.1:$PORT_A/api/peer-inbox/share" \
    -H 'Content-Type: application/json' \
    -d '{"peer_id":"inject-peer","host_crisis":true,"favored_dim":1,"material":0.6,"disk_hot":true}'
)"
test "$CODE" = "200"
grep -q '"accepted":true' /tmp/ghw-peer-sf-body.json
grep -q '"inbox_count":1' /tmp/ghw-peer-sf-body.json

curl -fsS "http://127.0.0.1:$PORT_A/api/peer-inbox" >/tmp/ghw-peer-sf-inbox.json
grep -q '"inject-peer"' /tmp/ghw-peer-sf-inbox.json
grep -q '"host_crisis":true' /tmp/ghw-peer-sf-inbox.json

echo "[peer-sf] force B into mobile crisis (host-profile)"
CODE="$(
  curl_code -X POST "http://127.0.0.1:$PORT_B/api/host-profile" \
    -H 'Content-Type: application/json' \
    -d '{"battery_pct":8,"thermal_hot":true,"bg_restricted":false}'
)"
test "$CODE" = "200"
grep -q '"host_crisis":true' /tmp/ghw-peer-sf-body.json

SOCK_B="/tmp/ghw_peer-sf-b.sock"
for _ in $(seq 1 30); do
  [[ -S "$SOCK_B" ]] && break
  sleep 0.5
done
if [[ ! -S "$SOCK_B" ]]; then
  echo "[peer-sf] missing sock $SOCK_B; B log:"; tail -40 /tmp/ghw-peer-sf-b.log || true
  exit 1
fi

echo "[peer-sf] A → B query_shortfall via Link"
CODE="$(
  curl_code -X POST "http://127.0.0.1:$PORT_A/api/peer/query?path=${SOCK_B}&method=query_shortfall"
)"
if [[ "$CODE" != "200" ]]; then
  echo "[peer-sf] query failed HTTP $CODE body=$(cat /tmp/ghw-peer-sf-body.json)"
  exit 1
fi
grep -q 'query_shortfall' /tmp/ghw-peer-sf-body.json
grep -q 'host_crisis' /tmp/ghw-peer-sf-body.json

curl -fsS "http://127.0.0.1:$PORT_A/api/peer-inbox" >/tmp/ghw-peer-sf-inbox2.json
grep -q 'inject-peer' /tmp/ghw-peer-sf-inbox2.json
# parsePeerId 通常从 sock 名推出 peer-sf-b
grep -q 'peer-sf-b' /tmp/ghw-peer-sf-inbox2.json

echo "[peer-sf] tasks on A should include peer assist"
curl -fsS "http://127.0.0.1:$PORT_A/api/tasks" >/tmp/ghw-peer-sf-tasks.json
grep -q 'shortfall assist' /tmp/ghw-peer-sf-tasks.json

echo "[peer-sf] OK"
