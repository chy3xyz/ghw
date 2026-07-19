#!/usr/bin/env bash
# reset_ghw_daemon_state.sh — 备份并重置 ghw-daemon 持久化状态 (agent_tick / WAL / loop_state)
#
# 用法:
#   scripts/reset_ghw_daemon_state.sh
#   scripts/reset_ghw_daemon_state.sh /path/to/state.json
#   GHW_STATE_DIR=/custom/dir scripts/reset_ghw_daemon_state.sh
#
# 注意: 请先停止 ghw-daemon, 再运行本脚本。

set -euo pipefail

STATE_DIR="${GHW_STATE_DIR:-$HOME/.local/share/ghw}"
STATE_FILE="${1:-$STATE_DIR/state.json}"
BACKUP_SUFFIX="$(date +%Y%m%d_%H%M%S)"

echo "GHW daemon state reset"
echo "  state file: $STATE_FILE"

if [[ -f "$STATE_FILE" ]]; then
  cp "$STATE_FILE" "${STATE_FILE}.bak.${BACKUP_SUFFIX}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$STATE_FILE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
old = data.get("tick", 0)
data["tick"] = 0
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"  agent_tick: {old} -> 0")
PY
  else
    echo "  warning: python3 not found; manually set \"tick\": 0 in $STATE_FILE"
  fi
else
  echo "  (no state file, skip)"
fi

for extra in "${STATE_FILE}.wal" "$STATE_DIR/loop_state.json"; do
  if [[ -f "$extra" ]]; then
    mv "$extra" "${extra}.bak.${BACKUP_SUFFIX}"
    echo "  archived: $extra -> ${extra}.bak.${BACKUP_SUFFIX}"
  fi
done

echo "Done. Rebuild/install daemon and restart ghw-daemon."
