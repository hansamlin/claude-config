# claude-config

`~/.claude` 的 user scope 設定版控。只收「換機器時想還原的東西」，不收任何執行期產物。

## 收了什麼

| 路徑 | 用途 |
| --- | --- |
| `CLAUDE.md` | user scope 全域指示（sub agent 派工原則、模型路由、git 環境前提） |
| `settings.json` | 權限、env、hooks、statusline、啟用的 plugin 與 marketplace |
| `statusline.sh` | 狀態列：路徑 / 分支 / 模型 / context 用量 / 5 小時額度 |
| `hooks/context-handoff-check.sh` | context 達門檻時自動觸發 handoff（見下） |
| `hooks/context-handoff-reset.sh` | 壓縮後清掉上面那支的狀態 |
| `local-plugins/` | 自製 tsgo LSP plugin（TypeScript 7 native），只收設定與 lockfile |

## 沒收什麼，為什麼

`.gitignore` 採「先擋全部（`*`），再逐項 `!` 放行」。這樣 Claude Code 日後在 `~/.claude` 新增的任何檔案預設都不會被 commit——這個目錄同時是執行目錄，放任 `git add -A` 遲早會把對話記錄帶上去。

明確排除的大宗：

- `projects/` — 所有專案的對話 transcript 與 memory，500MB 以上
- `history.jsonl`、`file-history/`、`shell-snapshots/` — 執行歷史
- `plugins/` — 從 marketplace 安裝的，重裝即可
- `jobs/`、`sessions/`、`daemon.log`、各種 `*cache*` — 執行期狀態
- `skills/` — 刻意不收，內含公司專案相關內容

新增要版控的檔案時，記得在 `.gitignore` 補一條 `!` 規則，否則會被靜默忽略。

> **⚠️ 絕對不要在 `~/.claude` 執行 `git clean -fdx`**
>
> 白名單模式下，除了上表那幾個檔案以外的東西——包含 `projects/` 全部的對話
> transcript、`history.jsonl`、`plugins/`——在 git 眼中都是「被忽略的檔案」。
> `-x` 會連同被忽略的檔案一起刪除，等於一次清空整個 Claude Code 的資料目錄，
> 而且這些內容不在版控裡，救不回來。
>
> 同理，`git stash -u` / `git stash -a` 在這裡也要小心。

## 新機器安裝

```bash
git clone <this-repo> ~/.claude-config
cd ~/.claude-config

# 若 ~/.claude 尚不存在，直接搬過去；已存在則逐檔複製，注意不要蓋掉現有設定
cp -r CLAUDE.md settings.json statusline.sh hooks local-plugins ~/.claude/
chmod +x ~/.claude/hooks/*.sh ~/.claude/statusline.sh

# 還原 tsgo LSP 的 TypeScript（版本由 package-lock.json 鎖定在 7.0.2）
cd ~/.claude/local-plugins/plugins/tsgo-lsp/vendor && npm ci
```

**注意**：`local-plugins/plugins/tsgo-lsp/.claude-plugin/plugin.json` 裡的 `command` 是硬編碼絕對路徑（`/Users/sam_lin/.claude/...`），換使用者或換機器要改成對應路徑。

裝完在 Claude Code 裡用 `/hooks` 確認兩個 hook 有出現，`ps aux | grep -- '--lsp'` 確認 LSP 跑的是這份 tsc。

## context 門檻自動 handoff

長 session 的 context 會無聲無息地漲，等到發現時往往已經來不及好好交接。這兩支 hook 讓它在固定門檻自動停下來、把進度寫進記憶、提醒你換 session。

### 運作方式

Claude Code 的 hook payload **不含任何 token 欄位**（只有 statusline 拿得到 `.context_window`），所以用量得自己從 `transcript_path` 那份 JSONL 算：取最後一筆非 sidechain 的 assistant 訊息，把 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` 相加。這個公式已對照 statusline 的 `total_input_tokens + total_output_tokens` 實測相等。

`Stop` hook 每輪對話結束都會跑：

1. 預測下一輪會破門檻 → 寫 armed marker、給一行預警，**不打斷本輪**
2. 下一輪結束看到 marker → 回 `decision: "block"`，要求 Claude 呼叫 `handoff` skill、告知使用者換 session、然後停手
3. 已經破門檻 → 不等下一輪，當場觸發
4. 觸發過一次後降級為不阻斷的提醒——使用者選擇繼續用就尊重他，否則每輪被 block 沒辦法工作

`PostCompact` hook 只做清理：壓縮後 context 會塌回去，先前 armed 的判斷就過期了。

### 為什麼不掛 PreCompact

`PreCompact` 的語意是「壓縮**嘗試**前」而非「壓縮確定發生」。實測 `/compact` 因訊息太少而失敗（`Not enough messages to compact.`）時它照樣觸發，掛上去會在壓縮根本沒發生時誤清狀態。`PostCompact` 才代表真的壓縮完成。

### 幾個必要的防呆

- `stop_hook_active` 為 true 直接退出——否則 hook 觸發 Claude 續跑、續跑又觸發 hook，無限迴圈
- transcript 過濾 `isSidechain != true`——不過濾的話，只要派過一次 subagent，最後一筆就是 subagent 的小 context，門檻永遠到不了且**完全靜默**
- `sessionKind == "bg"` 跳過——背景 job 沒有「換 session」這回事，自動寫記憶只是副作用

### 設定

| 環境變數 | 預設 | 說明 |
| --- | --- | --- |
| `CC_HANDOFF_THRESHOLD` | `300000` | 觸發門檻（token）。1M context window 的 30% |
| `CC_HANDOFF_MIN_DELTA` | `20000` | 預測下一輪成長量的下限 |
| `CC_HANDOFF_DISABLE` | — | 設 `1` 完全停用 |
| `CC_HANDOFF_TRACE` | — | 設成檔案路徑，把收到的 hook payload 附加寫入，除錯用 |
| `CC_HANDOFF_STATE_DIR` | `~/.claude/handoff-state` | 狀態目錄，測試用來隔離 |

要永久改門檻就寫進 `settings.json` 的 `env` 區塊。想看一次完整流程：

```bash
CC_HANDOFF_THRESHOLD=5000 claude
```

第一輪出現預警，第二輪結束時執行 handoff，第三輪之後只提醒不打斷。

### 測試

```bash
bash ~/.claude/hooks/context-handoff-check.test.sh
```

22 個分支案例，涵蓋防迴圈、bg 排除、sidechain 過濾、arm 不打斷本輪、fire、不重複
fire、PostCompact reset、停用開關與輸出合法性。全程在 `mktemp` 目錄裡用
`CC_HANDOFF_STATE_DIR` 隔離，不會動到真實狀態。

### 已知限制

- **一輪延遲**：Stop hook 執行時本輪最後一筆 usage 可能還沒寫進 transcript，讀到的通常是上一輪的數字。加上 arm→fire 本身再延一輪，最壞約兩輪滯後。誤差偏安全邊（漏讀那輪會讓下次 delta 變大、提早觸發），在 1M window 用 30 萬當門檻餘裕充足。
- `trigger: "auto"`（自動壓縮）未實測，只驗過 `manual`。reset script 不讀 `trigger` 欄位，行為應該一致。
