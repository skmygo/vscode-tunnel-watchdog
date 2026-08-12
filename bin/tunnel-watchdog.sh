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
#   規則 1（預防）binary 已不是磁碟上的 ~/code 且目前沒人連線 → 趁空檔 restart
#   規則 2（搶救）出現一個以上 host 行程 → 已經壞了，直接 restart
#
# 觸發來源有兩個（見 systemd/）：
#   code-tunnel-watchdog.path    ~/code 一被動就秒級觸發，這是主力
#   code-tunnel-watchdog.timer   每 5 分鐘兜底，補 path unit 可能漏掉的事件
#
# 正常情況下 install.sh 會把 ~/code 釘住（chattr +i），CLI 根本換不動自己，
# 這支就只是保險。更新請走 update-cli.sh。
#
# 用法：
#   tunnel-watchdog.sh              檢查並在必要時 restart
#   tunnel-watchdog.sh --dry-run    只報告狀態，不動作
#
set -uo pipefail

# shellcheck source=bin/tunnel-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel-state.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '%s\n' "$*"; }

# --- 收集狀態 -------------------------------------------------------------

pid=$(systemctl --user show "$UNIT" -p MainPID --value 2>/dev/null)
if [[ -z "$pid" || "$pid" == "0" ]]; then
	log "服務未執行（MainPID=0），交給 systemd 處理，不介入"
	exit 0
fi

exe=$(exe_of "$pid")
if [[ -z "$exe" ]]; then
	log "讀不到 /proc/$pid/exe（行程剛結束？），跳過這輪"
	exit 0
fi

# binary 被就地換掉後，常駐行程的 exe 就不再指向 ~/code，實際看過兩種形式：
#   ~/code (deleted)                      直接被 unlink
#   /tmp/.tmpXXXX/old-code-cli (deleted)  先搬走再刪（1.132 系列是這個）
# 所以判準是「不等於 ~/code」，只看有沒有 (deleted) 會漏掉後者。
stale_binary=0
[[ "${exe% (deleted)}" != "$CLI" ]] && stale_binary=1

scan_service
pinned=no
cli_pinned && pinned=yes

log "MainPID=$pid exe=$exe host_count=$host_count session_active=$session_active pinned=$pinned"

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
scan_service
log "重啟完成：MainPID=$new_pid host_count=$host_count"
"$CLI" tunnel status 2>&1 | head -1
