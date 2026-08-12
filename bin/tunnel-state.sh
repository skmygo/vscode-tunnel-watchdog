#!/usr/bin/env bash
#
# 共用函式庫（給 tunnel-watchdog.sh 與 update-cli.sh source 用，不直接執行）。
#
# 這裡集中處理「tunnel 現在是什麼狀態」的判定。判定一律以
# **服務自己的 cgroup 裡有哪些行程** 為準，不用 cmdline 比對 —
# cgroup 是 systemd 的記帳來源，裡面只會有這個服務 fork 出來的東西，
# 任何碰巧提到這些路徑的指令（例如你排錯時自己下的 pgrep）都混不進來。
#

UNIT=code-tunnel.service
CLI="$HOME/code"
SERVER_PREFIX="$HOME/.vscode/cli/servers/"
HOST_PATTERN='tunnel service internal-run' # 只在讀不到 cgroup 時當備援

argv0() { tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | head -1; }
exe_of() { readlink "/proc/$1/exe" 2>/dev/null; }

# 服務 cgroup 內的所有 pid（讀不到就退回 cmdline 比對，仍會用 argv[0] 過濾）
service_pids() {
	local cg
	cg=$(systemctl --user show "$UNIT" -p ControlGroup --value 2>/dev/null)
	if [[ -n "$cg" && -r "/sys/fs/cgroup${cg}/cgroup.procs" ]]; then
		cat "/sys/fs/cgroup${cg}/cgroup.procs"
		return 0
	fi
	pgrep -f -- "$HOST_PATTERN" 2>/dev/null
}

# 掃描服務狀態，結果放進兩個全域變數：
#   host_count      host 行程數，正常恆為 1；> 1 就是雙 host 僵局
#   session_active  目前有沒有人連著
#
# host 認定用 argv[0] 而不是 /proc/<pid>/exe：CLI 自我更新時會把舊 binary
# 搬去 /tmp/.tmpXXXX/old-code-cli 再刪掉，卡死的那個舊 host 的 exe 早就
# 不是 ~/code 了 — 用 exe 認會剛好漏掉唯一該抓的對象。argv[0] 不受影響。
#
# session 認定看 exe 是否落在 servers/ 底下（真正在跑的 node server），
# 這個路徑不可能被冒充。
scan_service() {
	host_count=0
	session_active=0
	local p
	while read -r p; do
		[[ -n "$p" ]] || continue
		if [[ "$(argv0 "$p")" == "$CLI" ]]; then
			((++host_count))
			continue
		fi
		[[ "$(exe_of "$p")" == "$SERVER_PREFIX"* ]] && session_active=1
	done < <(service_pids)
}

# binary 是否被釘住（chattr +i），只取屬性欄避免比對到路徑裡的字元
cli_pinned() {
	local attrs
	attrs=$(lsattr -d -- "$CLI" 2>/dev/null | awk '{print $1}')
	[[ "$attrs" == *i* ]]
}

# ~/code 的 commit hash（40 位 hex），拿來比對版本
cli_commit() {
	"$1" --version 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1
}
