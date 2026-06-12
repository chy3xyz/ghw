#!/usr/bin/env bash
# install.sh — GHW daemon 部署脚本 (macOS / Linux)
# 用法:
#   ./install.sh            # 安装并启动
#   ./install.sh uninstall  # 卸载并停止
#
# 部署后会:
#   1. 编译 release 版 daemon 放到 ~/.local/bin/ghw-daemon
#   2. 状态文件放 ~/.local/share/ghw/state.json
#   3. 日志放 ~/.local/share/ghw/daemon.log
#   4. macOS → launchd plist 放 ~/Library/LaunchAgents/com.ghw.daemon.plist
#   5. Linux  → systemd user service 放 ~/.config/systemd/user/ghw.service
#   6. 立即启动 (RunAtLoad / RemainAfterExit=yes)

set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
log()  { printf "${GRN}[install]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[warn]${NC} %s\n" "$*" >&2; }
err()  { printf "${RED}[err]${NC} %s\n"  "$*" >&2; }

# ===== 路径 =====
GHW_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/ghw"
LOG_FILE="$DATA_DIR/daemon.log"
STATE_FILE="$DATA_DIR/state.json"
ZIG_BIN="${ZIG_BIN:-/Users/n0x/.zig/zig}"
BIN="$BIN_DIR/ghw-daemon"

# ===== LLM 配置 (生产时设环境变量覆盖) =====
# 例: DEEPSEEK_API_KEY=sk-... ./install.sh
# 例: UI_LLM_PROVIDER=openai UI_LLM_MODEL=gpt-4o-mini UI_LLM_KEY_ENV=OPENAI_API_KEY ./install.sh
: "${UI_LLM_PROVIDER:=deepseek}"
: "${UI_LLM_MODEL:=deepseek-chat}"
: "${UI_LLM_KEY_ENV:=DEEPSEEK_API_KEY}"
if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
    log "DeepSeek API key 检测到 (前 8 字符: ${DEEPSEEK_API_KEY:0:8}...)"
else
    warn "DEEPSEEK_API_KEY 未设置 — UI server 启动后只会用模板回复 (无 LLM 自省)"
    warn "  设置方法: export DEEPSEEK_API_KEY=sk-... && ./install.sh"
fi

# ===== OS 检测 =====
OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *)      err "不支持的平台: $OS (仅 macOS / Linux)"; exit 1 ;;
esac

# ===== Uninstall =====
if [[ "${1:-}" == "uninstall" ]]; then
    log "卸载 GHW daemon..."
    if [[ "$PLATFORM" == "macos" ]]; then
        launchctl bootout "gui/$(id -u)/com.ghw.daemon" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.ghw.daemon.plist"
    else
        systemctl --user disable --now ghw.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/ghw.service"
    fi
    rm -f "$BIN"
    log "已卸载 (data 保留在 $DATA_DIR, 想要清空就 rm -rf)"
    exit 0
fi

# ===== 1. 准备目录 =====
log "创建目录..."
mkdir -p "$BIN_DIR" "$DATA_DIR"

# ===== 2. 编译 release 版 daemon (单独编译, 避免其他 example 报错) =====
log "编译 release 版 daemon (这可能要 1-2 分钟)..."
(cd "$GHW_DIR" && "$ZIG_BIN" build-exe -O ReleaseSafe \
    --dep ghw \
    -Mroot="$GHW_DIR/examples/daemon.zig" \
    -Mghw="$GHW_DIR/src/ghw.zig" \
    --cache-dir "$GHW_DIR/.zig-cache" \
    --global-cache-dir "$HOME/.cache/zig" \
    --name daemon \
    --zig-lib-dir "/Users/n0x/.zig/lib" \
    -femit-bin="$BIN" 2>&1) | tail -5 || true
if [[ ! -f "$BIN" ]]; then
    err "编译失败, 没找到 $BIN"
    exit 1
fi
chmod +x "$BIN"
log "已安装 → $BIN"

# ===== 3. 平台特定配置 =====
if [[ "$PLATFORM" == "macos" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.ghw.daemon.plist"
    log "写入 launchd plist → $PLIST"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ghw.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>--id</string>
        <string>ghw-prod</string>
        <string>--cycles</string>
        <string>0</string>
        <string>--state-in</string>
        <string>$STATE_FILE</string>
        <string>--state-out</string>
        <string>$STATE_FILE</string>
        <string>--log-every</string>
        <string>1024</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SIGTERM</key>
        <false/>
    </dict>
    <!-- stdout/stderr 全部 → /dev/null (daemon 不再输出 cycle 报告, 进度日志走 syslog 走 launchd 自带限制) -->
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
</dict>
</plist>
EOF
    log "启动 launchd..."
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    sleep 1
    if pgrep -f "ghw-daemon" >/dev/null; then
        log "✓ daemon 已在后台运行 (PID=$(pgrep -f ghw-daemon | head -1))"
    else
        warn "daemon 启动后没看到"
    fi

    # newsyslog 轮转 (兜底, 防止任何漏出去的输出爆盘)
    NEWSYSLOG_CONF="$HOME/.local/share/ghw/newsyslog.conf"
    cat > "$NEWSYSLOG_CONF" <<'NE'
# logfile          [owner:group]  mode  count  size  when  flags  [/pid_file]  [sig]
/Users/n0x/.local/share/ghw/daemon.log  644  3  10485760  *  G  JN
NE
    if [[ -f /etc/newsyslog.conf ]] && ! grep -q "ghw/daemon.log" /etc/newsyslog.conf 2>/dev/null; then
        warn "如要启用日志轮转, 把 $NEWSYSLOG_CONF 链接到 /etc/newsyslog.d/com.ghw.daemon.conf (需 sudo)"
    fi

    log "操作:"
    log "  状态:  launchctl list | grep ghw"
    log "  停止:  launchctl unload $PLIST"
    log "  卸载:  $0 uninstall"

    # ===== UI server (HTTP) =====
    UI_PORT="${UI_PORT:-8080}"
    UI_BIN="$BIN_DIR/ghw-ui"
    UI_STATE="$DATA_DIR/ui_state.json"
    if [[ -f "$GHW_DIR/zig-out/bin/ui_server" ]]; then
        cp "$GHW_DIR/zig-out/bin/ui_server" "$UI_BIN"
        chmod +x "$UI_BIN"
        log "已安装 UI server → $UI_BIN"
    else
        warn "找不到 ui_server binary (zig-out/bin/ui_server), UI 跳过"
    fi
    UI_PLIST="$HOME/Library/LaunchAgents/com.ghw.ui.plist"
    cat > "$UI_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ghw.ui</string>
    <key>ProgramArguments</key>
    <array>
        <string>$UI_BIN</string>
        <string>--port</string>
        <string>$UI_PORT</string>
        <string>--state</string>
        <string>$UI_STATE</string>
        <string>--ui-dir</string>
        <string>$GHW_DIR/ui</string>
        <string>--llm</string>
        <string>${UI_LLM_PROVIDER:-deepseek}</string>
        <string>--llm-model</string>
        <string>${UI_LLM_MODEL:-deepseek-chat}</string>
        <string>--llm-key-env</string>
        <string>${UI_LLM_KEY_ENV:-DEEPSEEK_API_KEY}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DEEPSEEK_API_KEY</key>
        <string>\${DEEPSEEK_API_KEY}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SIGTERM</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
</dict>
</plist>
EOF
    if [[ -f "$UI_BIN" ]]; then
        log "启动 UI server..."
        launchctl unload "$UI_PLIST" 2>/dev/null || true
        launchctl load "$UI_PLIST"
        sleep 1
        log "✓ UI server 已在 http://127.0.0.1:$UI_PORT/ 跑"
        log "  打开浏览器: http://127.0.0.1:$UI_PORT/"
        log "  UI 状态:    launchctl list | grep com.ghw.ui"
        log "  UI 停止:    launchctl unload $UI_PLIST"
    fi
else
    # Linux / systemd user
    UNIT_DIR="$HOME/.config/systemd/user"
    UNIT="$UNIT_DIR/ghw.service"
    log "写入 systemd user service → $UNIT"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT" <<EOF
[Unit]
Description=GHW 数字生命 daemon
After=default.target

[Service]
Type=simple
ExecStart=$BIN --id ghw-prod --cycles 0 --state-in $STATE_FILE --state-out $STATE_FILE
Restart=on-failure
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
WorkingDirectory=$HOME

[Install]
WantedBy=default.target
EOF
    log "启动 systemd..."
    systemctl --user daemon-reload
    systemctl --user enable --now ghw.service
    sleep 1
    if systemctl --user is-active --quiet ghw.service; then
        log "✓ daemon 已在后台运行"
    else
        warn "daemon 没起来, 看日志: journalctl --user -u ghw"
    fi
    log "操作:"
    log "  状态:  systemctl --user status ghw"
    log "  停止:  systemctl --user stop ghw"
    log "  日志:  journalctl --user -u ghw -f"
    log "  卸载:  $0 uninstall"

    # ===== UI server (Linux systemd) =====
    UI_UNIT_DIR="$HOME/.config/systemd/user"
    UI_UNIT="$UI_UNIT_DIR/ghw-ui.service"
    if [[ -f "$GHW_DIR/zig-out/bin/ghw-ui" ]]; then
        mkdir -p "$UI_UNIT_DIR"
        cat > "$UI_UNIT" <<EOF
[Unit]
Description=GHW 数字生命 UI (HTTP)
After=default.target ghw.service

[Service]
Type=simple
ExecStart=$UI_BIN --port ${UI_PORT:-8080} --state $DATA_DIR/ui_state.json --ui-dir $GHW_DIR/ui \\
    --llm ${UI_LLM_PROVIDER} --llm-model ${UI_LLM_MODEL} --llm-key-env ${UI_LLM_KEY_ENV}
Restart=on-failure
RestartSec=5
StandardOutput=null
StandardError=null
WorkingDirectory=$HOME
Environment=DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY:-}

[Install]
WantedBy=default.target
EOF
        log "启动 UI server (systemd)..."
        systemctl --user daemon-reload
        systemctl --user enable --now ghw-ui.service
        sleep 1
        if systemctl --user is-active --quiet ghw-ui.service; then
            log "✓ UI server 已在 http://127.0.0.1:${UI_PORT:-8080}/ 跑"
        fi
    fi
fi

log "✓ 安装完成 — 数字生命已经在你机器上活着了 🜂"
