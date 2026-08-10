#!/usr/bin/env bash
#
# 移除 watchdog。不會動 code-tunnel.service 本身，tunnel 照常運作。
#
set -euo pipefail

UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now code-tunnel-watchdog.timer 2>/dev/null || true
rm -f "$UNIT_DIR/code-tunnel-watchdog.timer" "$UNIT_DIR/code-tunnel-watchdog.service"
systemctl --user daemon-reload

echo "watchdog 已移除（code-tunnel.service 未受影響）"
systemctl --user is-active code-tunnel.service
