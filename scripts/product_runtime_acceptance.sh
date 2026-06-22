#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
PORT="${PORT:-18765}"
TOKEN="${GHW_ADMIN_TOKEN:-ghw-acceptance-token}"
STATE="${STATE:-/tmp/ghw-product-acceptance-state.json}"
CONFIG="${CONFIG:-/tmp/ghw-product-acceptance-config.json}"
INTENT="${INTENT:-product_intent.example.crm.json}"

rm -f "$STATE" "$STATE.db" "$CONFIG"

echo "[acceptance] build tests"
"$ZIG" build test

echo "[acceptance] build binaries"
"$ZIG" build

if ! command -v curl >/dev/null 2>&1; then
  echo "[acceptance] curl not found; compile-only acceptance passed"
  exit 0
fi

curl_status() {
  curl -sS -o /tmp/ghw-product-curl-body.json -w '%{http_code}' "$@"
}

echo "[acceptance] start ui_server on :$PORT"
GHW_ADMIN_TOKEN="$TOKEN" ./zig-out/bin/ui_server \
  --host 127.0.0.1 \
  --port "$PORT" \
  --state "$STATE" \
  --ui-dir ui \
  --product-intent "$INTENT" \
  --product-config "$CONFIG" \
  --admin-token-env GHW_ADMIN_TOKEN > /tmp/ghw-product-acceptance.log 2>&1 &
PID=$!
trap 'kill "$PID" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:$PORT/api/product/intent" >/tmp/ghw-product-intent.json; then
    break
  fi
  sleep 0.25
done

grep -q '"enabled":true' /tmp/ghw-product-intent.json
grep -q '"manifest_hash":"' /tmp/ghw-product-intent.json

echo "[acceptance] auth rejects protected writes without token"
NO_TOKEN_STATUS="$(
  curl_status -X POST "http://127.0.0.1:$PORT/api/product/propose-crm-followup" \
    -d 'tenant_id=blocked&affected_users=1&expected_delta_k=0.01'
)"
test "$NO_TOKEN_STATUS" = "401"
grep -q '"admin token required"' /tmp/ghw-product-curl-body.json

echo "[acceptance] propose -> approve -> apply -> rollback"
PROPOSED="$(
  curl -fsS -X POST "http://127.0.0.1:$PORT/api/product/propose-crm-followup" \
    -H "X-GHW-Admin-Token: $TOKEN" \
    -d 'tenant_id=acceptance&affected_users=45&expected_delta_k=0.05'
)"
CHANGE_ID="$(printf '%s' "$PROPOSED" | sed -n 's/.*"change_id":\([0-9][0-9]*\).*/\1/p')"
test -n "$CHANGE_ID"

curl -fsS "http://127.0.0.1:$PORT/api/product/approvals" >/tmp/ghw-product-approvals.json
grep -q "\"id\":$CHANGE_ID" /tmp/ghw-product-approvals.json
grep -q '"required_approvers":"' /tmp/ghw-product-approvals.json

curl -fsS -X POST "http://127.0.0.1:$PORT/api/product/approve" \
  -H "X-GHW-Admin-Token: $TOKEN" \
  -d "change_id=$CHANGE_ID&approver=acceptance&note=ok" >/dev/null

curl -fsS -X POST "http://127.0.0.1:$PORT/api/product/apply" \
  -H "X-GHW-Admin-Token: $TOKEN" \
  -d "change_id=$CHANGE_ID" >/dev/null

grep -q '"status":"applied"' "$CONFIG"
grep -q "\"change_id\":$CHANGE_ID" "$CONFIG"

curl -fsS -X POST "http://127.0.0.1:$PORT/api/product/rollback" \
  -H "X-GHW-Admin-Token: $TOKEN" \
  -d "change_id=$CHANGE_ID" >/dev/null

grep -q '"status":"rolled_back"' "$CONFIG"

curl -fsS -X POST "http://127.0.0.1:$PORT/api/product/kpi" \
  -H "X-GHW-Admin-Token: $TOKEN" \
  -d 'nrr_quarterly=0.88&deal_win_rate=0.24&sales_cycle_days_p50=48&weekly_active_sales_pct=0.71&csat=0.92&incident_rate=0.01' \
  >/tmp/ghw-product-kpi.json
grep -q '"ok":true' /tmp/ghw-product-kpi.json
grep -q '"refreshed":true' /tmp/ghw-product-kpi.json
grep -q '"kpi_last_feed_unix":' /tmp/ghw-product-kpi.json

curl -fsS "http://127.0.0.1:$PORT/api/product/audit" >/tmp/ghw-product-audit.json
grep -q '"previous_hash":"' /tmp/ghw-product-audit.json
grep -q '"current_hash":"' /tmp/ghw-product-audit.json
grep -q '"kind":"kpi_refreshed"' /tmp/ghw-product-audit.json

echo "[acceptance] passed"
