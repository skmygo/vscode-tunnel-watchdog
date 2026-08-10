# VS Code Tunnel + watchdog（可部署到任何機器）

用瀏覽器從外面任何一台電腦連進目標機器，得到完整 VS Code：檔案樹、編輯器、
整合終端機（＝該使用者的 shell）、擴充套件。

**入口**：`https://vscode.dev/tunnel/<機器名>`（機器名是部署時自己取的，每台要不同）

不開任何對外 port、不需要公網 IP 或 DNS。機器主動 outbound 連到 Microsoft 的 relay
（自動挑就近節點，log 裡看得到落在哪個 cluster）。跟機器上其他服務（如 cloudflared）
完全獨立，互不影響。

這個 repo 附帶一個 **watchdog**，修復 VS Code CLI 自我更新造成的斷線僵局
（見下方事故紀錄）。tunnel 本體是 VS Code 官方 CLI 的功能，watchdog 是自己加的保險。

---

## 部署到新機器

```bash
git clone https://github.com/skmygo/vscode-tunnel-watchdog.git
cd vscode-tunnel-watchdog
./deploy.sh <機器名>     # 機器名 = 網址最後一段，每台要唯一
```

`deploy.sh` 做的事（也可以自己逐步跑）：

1. 沒有 `~/code` 就下載 VS Code CLI（依架構挑 x64 / arm64 靜態版）
2. 沒登入就走 GitHub device-code 登入，照畫面指示操作
   （用哪個 GitHub 帳號登入，之後就只有那個帳號能連進來；建議開 2FA — 見安全邊界）
3. `~/code tunnel service install --accept-server-license-terms --name <機器名>`
4. `./install.sh` 裝 watchdog ＋ 啟用 linger

完成後入口就是 `https://vscode.dev/tunnel/<機器名>`。
之後想改名：`~/code tunnel rename <新名稱>`（網址跟著變）。

### 部署完成後這台機器上的東西

| 項目 | 值 |
|---|---|
| CLI binary | `~/code` |
| CLI 資料目錄 | `~/.vscode/cli/` |
| 註冊檔（名稱、tunnel ID 都在這） | `~/.vscode/cli/code_tunnel.json` |
| systemd unit | `code-tunnel.service`（user scope，`code tunnel service install` 產生） |
| 認證 token | 系統 keyring；keyring 鎖住時自動退回 `~/.vscode/cli/token.json`（600） |
| Linger | `yes` — 未登入、重開機後服務照樣起來（install.sh 會設） |
| Watchdog | `code-tunnel-watchdog.timer`，每 15 分鐘一次 |

### 安全邊界

進來就是該使用者的完整 shell，`~/.ssh` 等所有東西都拿得到。
存取控制只有「GitHub 帳號本人」這一層 — 沒有 IP 限制、沒有第二道驗證可設。
**那個 GitHub 帳號的 2FA 就是唯一一道門。**

如果哪天需要更嚴的控管，替代路線是自架 code-server + 自有網域 + CF Access
（入口和驗證都在自己手上）。

---

## 三個容易搞混的 "code-server"

`ps` 裡可能同時看到好幾個叫 `code-server` 的行程，它們是不同東西：

| 路徑 | 是什麼 | 誰裝的 |
|---|---|---|
| `~/.vscode/cli/servers/*/bin/code-server` | **本 tunnel** 用的 VS Code remote server | tunnel 首次連線時自動下載 |
| `~/.vscode-server/cli/servers/*/bin/code-server` | Remote-SSH 用的 remote server | VS Code 桌面版 SSH 進來時自動下載 |
| `/usr/lib/code-server` | coder.com 的 code-server（獨立產品） | 與本方案無關 |

前兩者都只 listen `127.0.0.1`，不對外開 port。

---

## 日常操作

以下 `<repo>` 指這個 repo 在該機器上的路徑。

```bash
# 健康檢查（一行看完）
~/code tunnel status

# watchdog 說了算的完整判斷，不會動到任何東西
<repo>/bin/tunnel-watchdog.sh --dry-run

# 看 log
journalctl --user -u code-tunnel.service -f
journalctl --user -u code-tunnel-watchdog.service --no-pager -n 50

# 萬用修復（不需要重新授權）
systemctl --user restart code-tunnel.service

# watchdog 開關
systemctl --user list-timers code-tunnel-watchdog.timer
<repo>/install.sh      # 安裝／重新套用
<repo>/uninstall.sh    # 移除（不影響 tunnel 本身）

# 徹底停用 tunnel
~/code tunnel service uninstall      # 停服務，保留這台的註冊
~/code tunnel unregister             # 註銷這台的機器名
```

`systemd/` 底下是模板（`@REPO@` 佔位符），install.sh 會代入實際路徑產生到
`~/.config/systemd/user/`。**改了模板要重跑 `install.sh` 才會套用。**

---

## 故障排除

### 症狀：瀏覽器卡在 "Opening Remote..." 或連不進去

依序做：

```bash
# 1. host 行程數 — 正常恆為 1，出現 2 就是雙 host 僵局
pgrep -af 'tunnel service internal-run'
#   多出來的那行如果不是 ~/code，是 pgrep 匹配到你自己這條指令，不算數
#   （watchdog 是用 /proc/<pid>/exe 認的，不會被這種假象騙到）

# 2. 跑的映像跟磁碟上是否一致
P=$(systemctl --user show code-tunnel.service -p MainPID --value)
readlink /proc/$P/exe
#   ~/code            → 正常
#   ~/code (deleted)  → binary 被就地換掉了，該 restart

# 3. log 裡有沒有這個
journalctl --user -u code-tunnel.service --no-pager -n 200 | grep NoAttachedServer
```

以上任一中了 → `systemctl --user restart code-tunnel.service`，
然後在瀏覽器 **hard refresh（Ctrl+Shift+R）**，vscode.dev 會快取上一次失敗的連線狀態。

第一次連進來會停在 "Opening Remote..." 約 30–60 秒，那是在裝／啟動 server，正常。

### 其他

- log 裡零星的 `NoAttachedServerError` 如果緊接在 `client has disconnected gracefully`
  後面，那是關分頁／重整時的正常收尾，不是問題。
- `Extension Host Process exited with code: 0` 同理，是 `--enable-remote-auto-shutdown`
  在沒人連線時收掉 server。下次連線會自動重開。
- 登入時的 `Failed to update keyring with new credentials: ... IsLocked` 不是問題。
  沒有桌面 session 的機器 keyring 本來就是鎖著的，CLI 會自動改存
  `~/.vscode/cli/token.json`，功能完全一樣（對 headless 機器反而更穩，
  不必為了讀 token 去解 keyring）。

---

## 事故紀錄：2026-08-10 的卡死

發生在第一台部署的機器上。留著當參考，watchdog 就是為了這個而寫的，
同樣的機制在任何一台裝了 tunnel 的機器都會發生。

```
16:13:10  服務啟動，行程 1917739 載入 v1.129.1
16:14:xx  首次連線 → 觸發下載 server（227 MB）
16:14:58  info  Updating CLI to 1.132.0     ← CLI 就地把 ~/code 換掉
16:14:59  binary mtime 更新，磁碟上已是 1.132.0
          ...但 1917739 記憶體裡跑的還是 1.129.1
17:02:15  Extension Host exited code 0      ← 關分頁，auto-shutdown 收掉 server
17:02:16  warn  respawn requested, starting new server
          → exec 磁碟上的 binary，這次是 1.132.0
          → 新版看到 tunnel-stable.lock 還被活著的 1917739 握著
          → "An existing tunnel is running on this machine, connecting to it..."
          → 不接管，改成附掛 = 兩個 host 並存
17:02:16  warn  NoAttachedServerError       ← 從此每次連線都 attach 不到 server
17:07:21  systemctl --user restart          ← 恢復，單一行程 v1.132.0
```

**根因**：CLI 在執行中自我更新，常駐行程仍跑舊映像；47 分鐘後的 respawn 撞上
新舊版本交界，新版退化成附掛模式，形成雙 host 僵局。

觸發點是 respawn，而 respawn 由「閒置關閉 server」引起 — 所以症狀會延遲很久才出現，
而且看起來像是「昨天還好好的，今天就連不上」。

---

## Watchdog 怎麼運作

`bin/tunnel-watchdog.sh`，由 timer 每 15 分鐘叫一次。兩條規則：

| 規則 | 條件 | 動作 |
|---|---|---|
| 1 預防 | `/proc/<pid>/exe` 帶 `(deleted)` **且** 目前沒有 tunnel session | 趁空檔 restart |
| 2 搶救 | host 行程數 > 1 | 已經壞了，直接 restart |

host 行程數是逐一比對 `/proc/<pid>/exe` 是不是 `~/code` 算出來的，不是只看 cmdline —
否則任何提到 `tunnel service internal-run` 這串字的指令都會被算成一個 host，
誤判成僵局而白白 restart（規則 2 不看有沒有人連線，會直接把你踢掉）。

規則 1 的「沒人連線」判斷是看 `~/.vscode/cli/servers/*/bin/code-server` 有沒有在跑。
**有 session 在用時不會打斷你**，只記一行 log 等下一輪。
如果連續 24 小時都掛著沒斷線、規則 1 一直沒機會執行，那條 tunnel 遲早會撞上
respawn 而失效 — 這時規則 2 會在 15 分鐘內收拾。

正常情況下 watchdog 什麼都不做，log 只有一行 `不動作：正常`。

---

## 檔案

```
<repo>/
├── README.md                              這份文件
├── deploy.sh                              一鍵部署（CLI + 登入 + 命名 + watchdog）
├── install.sh                             安裝 watchdog（產生 unit + 啟用 timer + linger）
├── uninstall.sh                           移除 watchdog
├── bin/
│   └── tunnel-watchdog.sh                 檢查邏輯，支援 --dry-run
└── systemd/
    ├── code-tunnel-watchdog.service       oneshot（模板，@REPO@ 由 install.sh 代入）
    └── code-tunnel-watchdog.timer         每 15 分鐘（模板）
```

`code-tunnel.service` 本身是 `code tunnel service install` 產生的，
放在 `~/.config/systemd/user/code-tunnel.service`，不歸這個 repo 管。
