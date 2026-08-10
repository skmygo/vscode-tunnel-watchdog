#!/usr/bin/env bash
#
# code-tunnel watchdog
#
# 解決的問題：VS Code CLI 會在執行中就地把 ~/code 換成新版，
# 但常駐的 code-tunnel.service 行程仍跑著記憶體裡的舊映像。等到 server
# 因閒置關閉、觸發 respawn 時，它 exec 到的是新版 binary，新版偵測到舊
# 行程還握著 tunnel-stable.lock，就退化成「附掛到既有 tunnel」而不是接管，
# 形成兩個 host 並存 → 之後每次連線都拿到 NoAttachedServerError。
#
# 對策：
#   規則 1（預防）binary 被換掉且目前沒人連線 → 趁空檔 restart
#   規則 2（搶救）出現一個以上 host 行程 → 已經壞了，直接 restart
#
# 用法：
#   tunnel-watchdog.sh              檢查並在必要時 restart
#   tunnel-watchdog.sh --dry-run    只報告狀態，不動作
#
set -uo pipefail

UNIT=code-tunnel.service
HOST_PATTERN='tunnel service internal-run'
SERVER_PATTERN="$HOME/.vscode/cli/servers/.*/bin/code-server"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '%s\n' "$*"; }

# --- 收集狀態 -------------------------------------------------------------

pid=$(systemctl --user show "$UNIT" -p MainPID --value 2>/dev/null)
if [[ -z "$pid" || "$pid" == "0" ]]; then
	log "服務未執行（MainPID=0），交給 systemd 處理，不介入"
	exit 0
fi

exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
if [[ -z "$exe" ]]; then
	log "讀不到 /proc/$pid/exe（行程剛結束？），跳過這輪"
	exit 0
fi

# binary 被就地替換後，原 inode 被 unlink，symlink 會標記 (deleted)
stale_binary=0
[[ "$exe" == *"(deleted)" ]] && stale_binary=1

# host 行程數；正常恆為 1
host_count=$(pgrep -fc -- "$HOST_PATTERN" 2>/dev/null) || host_count=0

# 目前是否有人連著（tunnel 的 code-server 有在跑就代表有 session）
if pgrep -f -- "$SERVER_PATTERN" >/dev/null 2>&1; then
	session_active=1
else
	session_active=0
fi

log "MainPID=$pid exe=$exe host_count=$host_count session_active=$session_active"

# --- 判斷 -----------------------------------------------------------------

action=""
reason=""

if ((host_count > 1)); then
	action="restart"
	reason="偵測到 $host_count 個 host 行程（雙 host 僵局，tunnel 已失效）"
elif ((stale_binary == 1)); then
	if ((session_active == 0)); then
		action="restart"
		reason="binary 已被就地更新且目前無人連線，趁空檔重啟"
	else
		reason="binary 已被就地更新，但有連線中的 session，本輪不打斷，下次再看"
	fi
else
	reason="正常"
fi

if [[ -z "$action" ]]; then
	log "不動作：$reason"
	exit 0
fi

if ((DRY_RUN == 1)); then
	log "[dry-run] 會執行 restart：$reason"
	exit 0
fi

log "restart $UNIT：$reason"
systemctl --user restart "$UNIT"
sleep 5

new_pid=$(systemctl --user show "$UNIT" -p MainPID --value 2>/dev/null)
new_count=$(pgrep -fc -- "$HOST_PATTERN" 2>/dev/null) || new_count=0
log "重啟完成：MainPID=$new_pid host_count=$new_count"
"$HOME/code" tunnel status 2>&1 | head -1
