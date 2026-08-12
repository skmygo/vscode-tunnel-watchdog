#!/usr/bin/env bash
#
# 安裝 code-tunnel watchdog ＋ 受控更新機制。
#
# systemd/ 底下是模板（@REPO@ 佔位符），這裡代入本機實際路徑後
# 產生到 user unit 目錄，所以 repo 放哪裡都能裝。
# 改了模板之後重跑本腳本即可套用。
#
# 用法：
#   ./install.sh            完整安裝（含把 ~/code 釘住）
#   ./install.sh --no-pin   不釘住 binary，只裝 watchdog 與 timer
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

# shellcheck source=bin/tunnel-state.sh
source "$REPO/bin/tunnel-state.sh"

PIN=1
[[ "${1:-}" == "--no-pin" ]] && PIN=0

UNITS=(
	code-tunnel-watchdog.service
	code-tunnel-watchdog.timer
	code-tunnel-watchdog.path
	code-tunnel-update.service
	code-tunnel-update.timer
)

mkdir -p "$UNIT_DIR"
chmod +x "$REPO/bin/tunnel-watchdog.sh" "$REPO/bin/update-cli.sh"

for unit in "${UNITS[@]}"; do
	# 舊版安裝是 symlink 指回模板，直接重導向會穿透 symlink 蓋掉模板，先移除
	rm -f "$UNIT_DIR/$unit"
	sed "s|@REPO@|$REPO|g" "$REPO/systemd/$unit" >"$UNIT_DIR/$unit"
	echo "generated $UNIT_DIR/$unit (REPO=$REPO)"
done

systemctl --user daemon-reload
systemctl --user enable --now code-tunnel-watchdog.timer
systemctl --user enable --now code-tunnel-watchdog.path
systemctl --user enable --now code-tunnel-update.timer

# --- 把 ~/code 釘住 -------------------------------------------------------
#
# chattr +i 之後 CLI 沒辦法就地把自己換掉（immutable 連 rename 走都擋），
# 自我更新會失敗並繼續跑現行版本 — 雙 host 僵局的成因就此消失。
# 更新改由 update-cli.sh 走「停 → 換 → 起」，時機可控。

if ((PIN == 1)); then
	if [[ ! -x "$CLI" ]]; then
		echo "找不到 $CLI，跳過釘住（先跑 deploy.sh 裝 CLI）"
	elif cli_pinned; then
		echo "$CLI 已經是釘住狀態"
	elif sudo -n chattr +i -- "$CLI" 2>/dev/null || { [[ -t 0 ]] && sudo chattr +i -- "$CLI"; }; then
		echo "已釘住 $CLI（chattr +i）：CLI 不能再就地換掉自己"
	else
		echo "警告：釘不住 $CLI（需要 sudo）。"
		echo "      CLI 仍會自我更新，watchdog 會收拾殘局，但事故窗口還在。"
		echo "      之後可手動補上：sudo chattr +i $CLI"
	fi
fi

# 服務本體要撐過登出、開機自動起，靠 linger
if [[ "$(loginctl show-user "$USER" -p Linger --value)" != "yes" ]]; then
	echo "啟用 linger（讓 user service 在未登入時也能跑）"
	loginctl enable-linger "$USER"
fi

echo
systemctl --user list-timers code-tunnel-watchdog.timer code-tunnel-update.timer --no-pager
echo
systemctl --user is-active code-tunnel-watchdog.path >/dev/null &&
	echo "code-tunnel-watchdog.path: active（~/code 有變動會立刻檢查）"
