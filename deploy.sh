#!/usr/bin/env bash
#
# 一鍵在新機器部署 VS Code Tunnel + watchdog。
#
# 用法：./deploy.sh <機器名>
# 機器名會成為入口網址的最後一段：https://vscode.dev/tunnel/<機器名>
# 同一個帳號下每台機器要取不同的名字。
#
set -euo pipefail

NAME="${1:?用法：./deploy.sh <機器名>（將成為 vscode.dev/tunnel/<機器名>）}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. CLI — 沒有 ~/code 才下載，依架構挑靜態版
if [[ ! -x "$HOME/code" ]]; then
	case "$(uname -m)" in
		x86_64)  os=cli-alpine-x64 ;;
		aarch64) os=cli-alpine-arm64 ;;
		*) echo "不支援的架構：$(uname -m)，請自行下載 CLI 放到 ~/code" >&2; exit 1 ;;
	esac
	echo "下載 VS Code CLI（$os）到 ~/code ..."
	curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=$os" | tar -xz -C "$HOME"
fi

# 2. 登入 — 已登入就跳過；沒登入會走 GitHub device-code 流程，照畫面指示操作
if ! "$HOME/code" tunnel user show >/dev/null 2>&1; then
	"$HOME/code" tunnel user login --provider github
fi

# 3. 註冊成 systemd user service 並命名
"$HOME/code" tunnel service install --accept-server-license-terms --name "$NAME"

# 4. watchdog + linger
"$REPO/install.sh"

echo
"$HOME/code" tunnel status
echo
echo "完成。入口：https://vscode.dev/tunnel/$NAME"
