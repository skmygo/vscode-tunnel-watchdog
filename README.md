# VS Code Tunnel + watchdog（可部署到任何機器）

用瀏覽器從外面任何一台電腦連進目標機器，得到完整 VS Code：檔案樹、編輯器、
整合終端機（＝該使用者的 shell）、擴充套件。

**入口**：`https://vscode.dev/tunnel/<機器名>`（機器名是部署時自己取的，每台要不同）

不開任何對外 port、不需要公網 IP 或 DNS。機器主動 outbound 連到 Microsoft 的 relay
（自動挑就近節點，log 裡看得到落在哪個 cluster）。跟機器上其他服務（如 cloudflared）
完全獨立，互不影響。

tunnel 本體是 VS Code 官方 CLI 的功能。這個 repo 附帶的是**讓它不會因為 CLI
自我更新而斷線**的兩層機制（見下方事故紀錄）：

1. **釘住 binary ＋ 受控更新** — `chattr +i ~/code` 讓 CLI 換不動自己，
   更新改走 `update-cli.sh` 的「停 → 換 → 起」，僵局在物理上不可能形成
2. **watchdog** — 萬一還是出事（沒釘住、手動裝了新版…）能自動收拾

---

## 部署到新機器

> 這一節是寫給「照著做就能裝完」的對象用的（包括 AI 代理人）：
> 先跑前置檢查 → 部署 → 逐項驗收。每一步都附了預期輸出，對不上就停下來問人。

### 0. 前置檢查

```bash
uname -m                            # 支援 x86_64 / aarch64，其他架構要自己找 CLI
df -T "$HOME" | tail -1             # ext4 / xfs / btrfs 可以釘住 binary；zfs、overlayfs 不行
sudo -n true && echo "sudo 免密碼 OK" || echo "sudo 需要密碼 → 見下方「沒有 sudo 的機器」"
systemctl --user is-system-running  # user systemd 要能動（running 或 degraded 都算可以）
```

### 1. 部署

```bash
git clone https://github.com/skmygo/vscode-tunnel-watchdog.git
cd vscode-tunnel-watchdog
./deploy.sh <機器名>     # 機器名 = 網址最後一段，每台要唯一，不能跟現有的重複
```

`deploy.sh` 做的事（也可以自己逐步跑）：

1. 沒有 `~/code` 就下載 VS Code CLI（依架構挑 x64 / arm64 靜態版）
2. 沒登入就走 GitHub device-code 登入
3. `~/code tunnel service install --accept-server-license-terms --name <機器名>`
4. `./install.sh` 裝 watchdog ＋ 受控更新 timer ＋ 釘住 `~/code` ＋ 啟用 linger

> **第 2 步需要真人。** device-code 登入會印出一組網址和代碼，要人去瀏覽器貼。
> AI 代理人跑到這裡請把畫面上的網址與代碼原樣交給使用者，等對方完成再繼續。
> 用哪個 GitHub 帳號登入，之後就只有那個帳號能連進來；建議開 2FA（見安全邊界）。

### 2. 驗收

五項全過才算裝好：

```bash
~/code tunnel status
#   → "tunnel":"Connected"

lsattr -d ~/code
#   → 屬性欄要有 i（例：----i---------e------- /home/sk/code）

<repo>/bin/tunnel-watchdog.sh --dry-run
#   → host_count=1 session_active=0 pinned=yes
#   → 不動作：正常

systemctl --user is-active code-tunnel-watchdog.path
#   → active

systemctl --user list-timers code-tunnel-watchdog.timer code-tunnel-update.timer
#   → 兩個 timer 都列得出來，NEXT 有時間
```

完成後入口就是 `https://vscode.dev/tunnel/<機器名>`。
之後想改名：`~/code tunnel rename <新名稱>`（網址跟著變）。

### 已經裝過舊版的機器

```bash
cd <repo> && git pull && ./install.sh
```

`install.sh` 是冪等的：重跑會重新產生 unit、重新啟用 timer/path、把 `~/code` 釘住。
改過 `systemd/` 底下的模板之後也是重跑它來套用。跑完一樣照上面第 2 節驗收。

### 沒有 sudo 的機器

釘不住 binary（`chattr +i` 需要 root），`install.sh` 會印警告然後繼續 —— watchdog
和 timer 照裝，只是少了「不讓它發生」那一層，退回成「發生後秒級收拾」。
想明確跳過釘住這步：`./install.sh --no-pin`。

### 部署完成後這台機器上的東西

| 項目 | 值 |
|---|---|
| CLI binary | `~/code` |
| CLI 資料目錄 | `~/.vscode/cli/` |
| 註冊檔（名稱、tunnel ID 都在這） | `~/.vscode/cli/code_tunnel.json` |
| systemd unit | `code-tunnel.service`（user scope，`code tunnel service install` 產生） |
| 認證 token | 系統 keyring；keyring 鎖住時自動退回 `~/.vscode/cli/token.json`（600） |
| Linger | `yes` — 未登入、重開機後服務照樣起來（install.sh 會設） |
| CLI binary 狀態 | `chattr +i`（釘住，CLI 不能就地換掉自己）— `lsattr ~/code` 看得到 `i` |
| Watchdog | `code-tunnel-watchdog.path`（`~/code` 一變動就秒級觸發）＋ `.timer`（每 5 分鐘兜底） |
| CLI 更新 | `code-tunnel-update.timer`，每週日 04:30 跑 `update-cli.sh` |

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

# 更新 CLI（唯一該用的更新方式，詳見下一節）
<repo>/bin/update-cli.sh --check    # 只比對版本
<repo>/bin/update-cli.sh            # 有新版就更新（停 → 換 → 起）

# watchdog／更新機制開關
systemctl --user list-timers code-tunnel-watchdog.timer code-tunnel-update.timer
systemctl --user status code-tunnel-watchdog.path
<repo>/install.sh      # 安裝／重新套用（含釘住 ~/code）
<repo>/uninstall.sh    # 移除（解開釘住，不影響 tunnel 本身）

# 徹底停用 tunnel
~/code tunnel service uninstall      # 停服務，保留這台的註冊
~/code tunnel unregister             # 註銷這台的機器名
```

`systemd/` 底下是模板（`@REPO@` 佔位符），install.sh 會代入實際路徑產生到
`~/.config/systemd/user/`。**改了模板要重跑 `install.sh` 才會套用。**

---

## 更新 VS Code CLI

**重點：問題從來不是「新版有 bug」，而是「更新發生在服務執行中」。**
只要順序變成 **停 → 換 → 起**，舊映像在新 binary 落地前就已經結束，
雙 host 僵局在物理上不可能形成。

所以這裡做兩件事：

**1. 釘住 binary，讓 CLI 沒辦法偷換自己**

```bash
sudo chattr +i ~/code      # install.sh 會自動做
```

immutable 屬性連 rename 都擋 —— CLI 就是靠「把舊檔搬去 `/tmp/.tmpXXXX/old-code-cli`
再寫新檔」更新的，這一步會直接失敗。CLI 本來就要應付唯讀／離線機器，
更新失敗只會在 log 留一行錯誤然後繼續跑現行版本。

**2. 更新走 `update-cli.sh`**

```bash
<repo>/bin/update-cli.sh --check    # 只比對版本，什麼都不動
<repo>/bin/update-cli.sh            # 有新版就更新
<repo>/bin/update-cli.sh --force    # 不比對版本、也不管有沒有人連線，直接重裝
```

它做的事，以及每一步為什麼在那個位置：

| 步驟 | 為什麼 |
|---|---|
| 比對 commit，一樣就結束 | 沒事不要動服務 |
| **有人連線中就跳過** | 換 binary 必須重啟，會踢掉 tunnel 裡所有終端機。寧可這週不更新 |
| 下載、解壓、跑新 binary 驗 commit —— **全部在停服務之前** | 網路失敗／檔案損毀時，服務根本沒被碰過（實測撞過 429 限流，tunnel 毫髮無傷） |
| 停服務 → 解鎖 → 備份 → 換檔 → 重新釘住 → 啟動 | 唯一安全的順序 |
| 等 relay 連上 ＋ 確認 host 數為 1 才算成功 | 「服務起來了」不等於「連得進去」 |
| 任何一步失敗 → 還原 `~/.vscode/cli/code.prev` 並把服務拉回來 | 寧可停在舊版，不要停在沒有服務 |

實測一次完整更新（1.132.1 → 1.133.0）從頭到尾 **11.7 秒**。

**自動更新**：`code-tunnel-update.timer` 每週日 04:30 跑一次（帶 `Persistent=true`，
關機錯過會在開機後補跑；有人連線時腳本自己會跳過）。

```bash
systemctl --user list-timers code-tunnel-update.timer
journalctl --user -u code-tunnel-update.service --no-pager -n 30
```

**為什麼不乾脆永遠不更新**：哪天微軟改了 relay 協定，太舊的 CLI 會連不上，
而你不會收到任何預告。定期在安全時機更新，比「凍在某一版」健康。

---

## 故障排除

### 症狀：瀏覽器卡在 "Opening Remote..." 或連不進去

依序做：

```bash
# 1. 一次看完 watchdog 的完整判斷（不會動到任何東西）
<repo>/bin/tunnel-watchdog.sh --dry-run
#   host_count=1        正常；> 1 就是雙 host 僵局
#   session_active=0/1  目前有沒有人連著
#   pinned=yes          ~/code 已釘住，CLI 換不動自己

# 2. 跑的映像跟磁碟上是否一致
P=$(systemctl --user show code-tunnel.service -p MainPID --value)
readlink /proc/$P/exe
#   ~/code                                 → 正常
#   ~/code (deleted)                       → binary 被就地換掉了，該 restart
#   /tmp/.tmpXXXX/old-code-cli (deleted)   → 同上（1.132 系列是這個形式）

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

### 復發：2026-08-12（watchdog 沒接住）

```
16:11:19  watchdog：exe=/home/sk/code，正常
16:15     CLI 就地更新 1.132.0 → 1.132.1
16:16:31  Extension Host exited code 0 → respawn → 雙 host
          瀏覽器：The VS Code gateway is not currently running.
```

跟 08-10 同一個機制，但這次暴露了兩個問題：

1. **規則 2 認不出卡死的舊 host** — 當時 host 計數比對的是 `/proc/<pid>/exe == ~/code`，
   而舊 host 的 exe 已經變成 `/tmp/.tmppqOTE4/old-code-cli (deleted)`，
   `host_count` 只算到 1，規則 2 永遠不會開火。改用 `argv[0]` 判定後才抓得到。
2. **15 分鐘的 timer 追不上 1.5 分鐘的窗口** — 更新到 respawn 只隔 1.5 分鐘，
   規則 1 根本沒機會預防。改用 inotify（path unit）事件驅動才來得及。

這次修完之後又多了一層：**乾脆讓 CLI 換不動自己**（`chattr +i`），
更新走 `update-cli.sh`。上面兩條規則從此只是保險。

---

## Watchdog 怎麼運作

釘住 binary 之後 watchdog 只是保險，但保險要能保。`bin/tunnel-watchdog.sh`
有兩個觸發來源：

| 觸發來源 | 時機 |
|---|---|
| `code-tunnel-watchdog.path` | inotify 盯著 `~/code`，一被動就秒級觸發 —— **主力** |
| `code-tunnel-watchdog.timer` | 每 5 分鐘兜底，補 path unit 可能漏掉的事件 |

為什麼非要 inotify：實測的時間差是「更新 16:15 → respawn 16:16:31」只隔 **1.5 分鐘**，
任何以分鐘計的 timer 都追不上，只有事件驅動來得及在僵局形成前介入。

兩條規則：

| 規則 | 條件 | 動作 |
|---|---|---|
| 1 預防 | 常駐行程的 exe 已不是 `~/code` **且** 目前沒有 tunnel session | 趁空檔 restart |
| 2 搶救 | host 行程數 > 1 | 已經壞了，直接 restart |

### 狀態判定為什麼不用 cmdline 比對

判定一律以 **服務自己 cgroup 裡有哪些行程** 為準
（`systemctl show -p ControlGroup` → `/sys/fs/cgroup/.../cgroup.procs`）。
cgroup 是 systemd 的記帳來源，裡面只會有這個服務 fork 出來的東西，
你排錯時自己下的 `pgrep` 混不進去。在這個前提下：

- **host 行程**認 `argv[0] == ~/code`。**不能認 `/proc/<pid>/exe`** ——
  CLI 自我更新時會把舊 binary 搬去 `/tmp/.tmpXXXX/old-code-cli` 再刪掉，
  卡死的那個舊 host 的 exe 早就不是 `~/code`，用 exe 認會剛好漏掉唯一該抓的對象，
  規則 2 形同虛設（這是 2026-08-12 那次踩到的坑）。
- **有沒有人連線**認 exe 落在 `~/.vscode/cli/servers/` 底下的行程（真正在跑的 node server），
  這個路徑不可能被冒充。

規則 1 **有 session 在用時不會打斷你**，只記一行 log 等下一輪。
但僵局其實只在 respawn 那一刻形成，而 respawn 的前提是 server 因閒置關閉 ——
也就是**僵局形成的當下必定沒人連線**，規則 1 下一輪就會收拾。
規則 2 是給「僵局形成後你又搶先連上來」這種順序準備的。

正常情況下 watchdog 什麼都不做，log 只有一行 `不動作：正常`。

---

## 檔案

```
<repo>/
├── README.md                              這份文件
├── deploy.sh                              一鍵部署（CLI + 登入 + 命名 + watchdog）
├── install.sh                             安裝（產生 unit + 啟用 timer/path + 釘住 ~/code + linger）
├── uninstall.sh                           移除（含解開釘住）
├── bin/
│   ├── tunnel-state.sh                    共用狀態判定（cgroup 掃描），被下面兩支 source
│   ├── tunnel-watchdog.sh                 檢查邏輯，支援 --dry-run
│   └── update-cli.sh                      受控更新（停 → 換 → 起），支援 --check / --force
└── systemd/
    ├── code-tunnel-watchdog.service       oneshot（模板，@REPO@ 由 install.sh 代入）
    ├── code-tunnel-watchdog.timer         每 5 分鐘兜底
    ├── code-tunnel-watchdog.path          inotify 盯著 ~/code
    ├── code-tunnel-update.service         oneshot，跑 update-cli.sh
    └── code-tunnel-update.timer           每週日 04:30
```

`code-tunnel.service` 本身是 `code tunnel service install` 產生的，
放在 `~/.config/systemd/user/code-tunnel.service`，不歸這個 repo 管。
