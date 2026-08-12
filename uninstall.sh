#!/usr/bin/env bash
#
# 移除 watchdog 與受控更新機制，並解開 ~/code 的釘住狀態
# （解開之後 CLI 會恢復自我更新，也就恢復撞上雙 host 僵局的可能）。
# 不會動 code-tunnel.service 本身，tunnel 照常運作。
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

# shellcheck source=bin/tunnel-state.sh
source "$REPO/bin/tunnel-state.sh"

for unit in code-tunnel-watchdog.timer code-tunnel-watchdog.path code-tunnel-update.timer; do
	systemctl --user disable --now "$unit" 2>/dev/null || true
done

rm -f \
	"$UNIT_DIR/code-tunnel-watchdog.service" \
	"$UNIT_DIR/code-tunnel-watchdog.timer" \
	"$UNIT_DIR/code-tunnel-watchdog.path" \
	"$UNIT_DIR/code-tunnel-update.service" \
	"$UNIT_DIR/code-tunnel-update.timer"

systemctl --user daemon-reload

if cli_pinned; then
	if sudo -n chattr -i -- "$CLI" 2>/dev/null || { [[ -t 0 ]] && sudo chattr -i -- "$CLI"; }; then
		echo "已解開 $CLI 的 chattr +i"
	else
		echo "警告：解不開 $CLI 的 chattr +i，之後 CLI 會一直更新失敗。"
		echo "      請手動執行：sudo chattr -i $CLI"
	fi
fi

echo "watchdog 與更新 timer 已移除（code-tunnel.service 未受影響）"
systemctl --user is-active code-tunnel.service
