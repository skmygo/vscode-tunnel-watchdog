#!/usr/bin/env bash
#
# 安裝 code-tunnel watchdog。
# systemd/ 底下是模板（@REPO@ 佔位符），這裡代入本機實際路徑後
# 產生到 user unit 目錄，所以 repo 放哪裡都能裝。
# 改了模板之後重跑本腳本即可套用。
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

mkdir -p "$UNIT_DIR"
chmod +x "$REPO/bin/tunnel-watchdog.sh"

for unit in code-tunnel-watchdog.service code-tunnel-watchdog.timer; do
	# 舊版安裝是 symlink 指回模板，直接重導向會穿透 symlink 蓋掉模板，先移除
	rm -f "$UNIT_DIR/$unit"
	sed "s|@REPO@|$REPO|g" "$REPO/systemd/$unit" > "$UNIT_DIR/$unit"
	echo "generated $UNIT_DIR/$unit (REPO=$REPO)"
done

systemctl --user daemon-reload
systemctl --user enable --now code-tunnel-watchdog.timer

# 服務本體要撐過登出、開機自動起，靠 linger
if [[ "$(loginctl show-user "$USER" -p Linger --value)" != "yes" ]]; then
	echo "啟用 linger（讓 user service 在未登入時也能跑）"
	loginctl enable-linger "$USER"
fi

echo
systemctl --user list-timers code-tunnel-watchdog.timer --no-pager
