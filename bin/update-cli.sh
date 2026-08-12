#!/usr/bin/env bash
#
# 受控更新 VS Code CLI。
#
# 為什麼需要這支：CLI 平常會在執行中就地把 ~/code 換掉，常駐行程卻還跑著
# 記憶體裡的舊映像，等 respawn 時新舊版對撞就形成雙 host 僵局
# （見 README 事故紀錄）。這支把更新改成 **先停 → 再換 → 再起**：
# 舊映像在新 binary 落地之前就已經結束，僵局在物理上不可能形成。
#
# 搭配 install.sh 的 chattr +i（把 ~/code 釘住）使用 — CLI 自己換不動，
# 更新就只會從這支走，時機由你決定而不是隨機發生在你連線的當下。
#
# 用法：
#   update-cli.sh            有新版才更新，沒有就直接結束
#   update-cli.sh --check    只比對版本，不動任何東西
#   update-cli.sh --force    不比對版本，直接重裝目前 stable
#
# 由 code-tunnel-update.timer 每週凌晨自動叫一次。
#
set -uo pipefail

# shellcheck source=bin/tunnel-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tunnel-state.sh"

STATE_DIR="$HOME/.vscode/cli"
BACKUP="$STATE_DIR/code.prev"
LOCK="$STATE_DIR/update-cli.lock"

MODE=update
case "${1:-}" in
	--check) MODE=check ;;
	--force) MODE=force ;;
	"") ;;
	*)
		echo "未知參數：$1（可用：--check / --force）" >&2
		exit 2
		;;
esac

log() { printf '%s\n' "$*"; }

# 微軟的下載端點會限流（短時間內多打幾次就回 429），curl --retry 認得這類
# 暫時性錯誤，會自己退讓重試 — 每週自動跑時撞上就不必等下一週。
CURL=(curl -fsSL --retry 4 --retry-delay 15 --retry-max-time 180)

service_stopped=0
restore_needed=0
was_pinned=no
tmp=""

cleanup() {
	[[ -n "$tmp" && -d "$tmp" ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT

pin() { sudo -n chattr +i -- "$CLI" 2>/dev/null; }
unpin() { sudo -n chattr -i -- "$CLI" 2>/dev/null; }

# 出錯時盡力把機器留在「連得進去」的狀態：能還原就還原舊 binary，
# 至少也要把服務拉回來 — 寧可停在舊版，不要停在沒有服務。
die() {
	log "錯誤：$*"
	if ((restore_needed == 1)) && [[ -f "$BACKUP" ]]; then
		log "還原舊 binary：$BACKUP → $CLI"
		unpin
		cp -p -- "$BACKUP" "$CLI" && log "已還原"
	fi
	[[ "$was_pinned" == yes ]] && pin
	if ((service_stopped == 1)); then
		log "重新啟動 $UNIT"
		systemctl --user start "$UNIT"
	fi
	exit 1
}

mkdir -p -- "$STATE_DIR"
exec 9>"$LOCK"
if ! flock -n 9; then
	log "已有另一個更新在進行中，本次結束"
	exit 0
fi

# --- 1. 這台要抓哪個變體 --------------------------------------------------

case "$(uname -m)" in
	x86_64) VARIANT=cli-alpine-x64 ;;
	aarch64) VARIANT=cli-alpine-arm64 ;;
	*) die "不支援的架構：$(uname -m)" ;;
esac
LATEST_URL="https://update.code.visualstudio.com/latest/$VARIANT/stable"

# --- 2. 比對版本 ----------------------------------------------------------

[[ -x "$CLI" ]] || die "找不到 $CLI"
current=$(cli_commit "$CLI")
[[ -n "$current" ]] || die "讀不到目前版本（$CLI --version 沒有輸出 commit）"

# latest 端點會 302 到帶著 commit 的實際下載位址，用它判斷最新版是哪個 commit
resolved=$("${CURL[@]}" -I -o /dev/null -w '%{url_effective}' "$LATEST_URL") ||
	die "查不到最新版（連不上 update.code.visualstudio.com？）"
latest=$(grep -oE '[0-9a-f]{40}' <<<"$resolved" | head -1)
[[ -n "$latest" ]] || die "最新版位址裡解不出 commit：$resolved"

log "目前 commit=$current"
log "最新 commit=$latest"

if [[ "$MODE" == check ]]; then
	if [[ "$current" == "$latest" ]]; then
		log "已是最新版"
	else
		log "有新版可更新（跑 update-cli.sh 套用）"
	fi
	exit 0
fi

if [[ "$current" == "$latest" && "$MODE" != force ]]; then
	log "已是最新版，不動作"
	exit 0
fi

# --- 3. 有人連著就改天再說 ------------------------------------------------

# 換 binary 一定要重啟服務，會踢掉 tunnel 裡所有終端機。
# 寧可這週不更新，也不要在人家做事做到一半時斷線。
scan_service
if ((session_active == 1)) && [[ "$MODE" != force ]]; then
	log "目前有連線中的 session，本次跳過更新（下次 timer 再試；要立刻更新用 --force）"
	exit 0
fi

# --- 4. 先下載驗好，再碰服務 ----------------------------------------------

# 解壓到 $HOME 底下而不是 /tmp：同一個檔案系統，換檔才是原子的 rename；
# 而且有些機器 /tmp 掛 noexec，會沒辦法先跑新 binary 驗版本。
tmp=$(mktemp -d "$STATE_DIR/update.XXXXXX") || die "建不出暫存目錄"

log "下載 $VARIANT ..."
"${CURL[@]}" "$LATEST_URL" -o "$tmp/cli.tar.gz" || die "下載失敗"
tar -xzf "$tmp/cli.tar.gz" -C "$tmp" || die "解壓失敗（下載檔可能不完整）"
[[ -x "$tmp/code" ]] || die "解壓後找不到可執行的 code"

got=$(cli_commit "$tmp/code")
[[ "$got" == "$latest" ]] ||
	die "下載到的 binary commit 不符（預期 $latest，實際 ${got:-讀不到}）"
log "下載完成並驗證通過"

# --- 5. 停 → 換 → 起 ------------------------------------------------------

cli_pinned && was_pinned=yes
if [[ "$was_pinned" == yes ]] && ! sudo -n true 2>/dev/null; then
	die "$CLI 被 chattr +i 釘住，但拿不到免密碼 sudo。請先手動 sudo chattr -i $CLI 再重跑"
fi

log "停止 $UNIT"
systemctl --user stop "$UNIT" || die "停不下 $UNIT"
service_stopped=1

[[ "$was_pinned" == yes ]] && { unpin || die "解不開 chattr +i"; }

cp -p -- "$CLI" "$BACKUP" || die "備份舊 binary 失敗"
restore_needed=1

# 同目錄先落地再 rename，換檔是原子的
cp -- "$tmp/code" "$CLI.new" || die "寫入新 binary 失敗"
chmod 755 "$CLI.new" || die "chmod 失敗"
mv -f -- "$CLI.new" "$CLI" || die "換檔失敗"
log "已換上新 binary（備份在 $BACKUP）"

if [[ "$was_pinned" == yes ]]; then
	pin || log "警告：重新釘住 $CLI 失敗，CLI 之後可能會自己更新"
fi

log "啟動 $UNIT"
systemctl --user start "$UNIT" || die "啟動失敗"

# --- 6. 驗收：連上了才算數 ------------------------------------------------

connected=0
for _ in $(seq 1 20); do
	sleep 2
	if "$CLI" tunnel status 2>/dev/null | grep -q '"tunnel":"Connected"'; then
		connected=1
		break
	fi
done
((connected == 1)) || die "重啟後 40 秒內沒連上 relay"

scan_service
((host_count == 1)) || die "重啟後 host 行程數為 $host_count（預期 1）"

log "更新完成：$current → $latest，tunnel 已連線，host_count=1"
