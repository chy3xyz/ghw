#!/usr/bin/env bash
# Watchdog: 检测 8765/8766/8767 ui_server, 不可达则重启.
# 用法: scripts/watch_ui_servers.sh
# 后台: nohup scripts/watch_ui_servers.sh >>/tmp/ui_watchdog.log 2>&1 &
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START="$ROOT/scripts/start_ui_servers.sh"
PORTS=(8765 8766 8767)
INTERVAL="${GHW_UI_WATCH_INTERVAL:-30}"

check_port() {
  local p="$1"
  curl -sf -m 3 -o /dev/null "http://127.0.0.1:${p}/" >/dev/null 2>&1
}

echo "[watch] 启动 ui_server watchdog (interval=${INTERVAL}s)"
while true; do
  need_restart=0
  for p in "${PORTS[@]}"; do
    if ! check_port "$p"; then
      echo "[watch] $(date -Iseconds) :${p} 不可达, 触发重启"
      need_restart=1
      break
    fi
  done
  if [[ "$need_restart" -eq 1 ]]; then
    "$START" || echo "[watch] start_ui_servers.sh 失败"
  fi
  sleep "$INTERVAL"
done
