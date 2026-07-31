# claude-config

Claude Code 的 user scope 設定版控。repo 放在 `~/project/claude-config`，用 `install.sh` 單向套用到 `~/.claude`。

## 為什麼不直接把 repo 開在 `~/.claude`

試過，然後放棄了——`~/.claude` 同時是 Claude Code 的執行目錄，把 repo 疊上去有兩個治不好的問題：

- **`git clean -fdx` 會清空整個資料目錄。** 白名單式 `.gitignore` 下，`projects/`（500MB 以上的對話 transcript）、`history.jsonl` 在 git 眼中全是「被忽略的檔案」，`-x` 會連它們一起刪，而且不在版控裡救不回來。
- **`settings.json` 會被執行期改寫。** `/config` 調整、`feedbackSurveyState.lastShownTime` 之類會直接寫回檔案，工作區永遠是髒的，`git checkout` 還會悄悄回捲當下生效的設定。

分開放之後這兩個風險都不存在：`~/.claude` 就是單純的執行目錄，repo 是乾淨的來源。

## 用法

```bash
./install.sh              # repo → ~/.claude
./install.sh --dry-run    # 只看會做什麼

./pull.sh                 # ~/.claude → repo（把本機改動抓回來）
./pull.sh --dry-run       # 只列出有差異的檔案
```

兩支互為反向，都可重複執行。`CLAUDE_DIR` 環境變數可指定目標目錄（預設 `~/.claude`），測試用。

需要 `jq`。

首次安裝後要還原 tsgo LSP 的 TypeScript：

```bash
(cd ~/.claude/local-plugins/plugins/tsgo-lsp/vendor && npm ci)
```

## 收了什麼

| 路徑 | 用途 |
| --- | --- |
| `CLAUDE.md` | user scope 全域指示（sub agent 派工原則、模型路由、git 環境前提） |
| `statusline.sh` | 狀態列：路徑 / 分支 / 模型 / context 用量 / 5 小時額度 |
| `hooks/context-handoff-check.sh` | context 達門檻時自動觸發 handoff（見下） |
| `hooks/context-handoff-reset.sh` | 壓縮後清掉上面那支的狀態 |
| `hooks/context-handoff-check.test.sh` | 22 案分支測試 |
| `settings.fragment.json` | 上述功能在 `settings.json` 裡需要的那幾個 key |
| `local-plugins/` | 自製 tsgo LSP plugin（TypeScript 7 native），只收設定與 lockfile |

`skills/` 刻意不收，內含公司專案相關內容。

**這個 repo 只適合維持 private**：`CLAUDE.md` 帶有公司脈絡（GitLab / `glab` 工作流程），要轉 public 前必須重新逐檔稽核。另外 `CLAUDE.md` 提到的 `git-remote-troubleshoot` skill 屬於未收錄的 `skills/`，新機器上會是個指不到東西的引用。

## `settings.json` 是合併不是覆蓋

repo **不收** `settings.json` 本體，只收 `settings.fragment.json`——裡面僅有本 repo 真正提供的那幾個 key（`statusLine`、`hooks.Stop`、`hooks.PostCompact`、tsgo-lsp 的 marketplace 與啟用旗標）。

`install.sh` 用 `jq` 的 `*` 運算子深度合併進目標機器現有的 `settings.json`：對 object 是遞迴合併，所以你的 `permissions`、`env`、`theme`、其他 hook 全部保留；對陣列是右側取代，所以重複執行不會讓 `hooks.Stop` 愈疊愈長。寫入前會備份成 `settings.json.bak`，內容無變化時完全不動檔案。

fragment 裡的路徑寫成 `__CLAUDE_DIR__` 佔位符，安裝時填成目標機器的實際絕對路徑。同理 `plugin.json` 的 `lspServers.command`——它必須是絕對路徑，不吃 `~` 或環境變數，所以 repo 存佔位符、`install.sh` 填實際值、`pull.sh` 再正規化回去，個人路徑不會進版控。

如果你在 `~/.claude/settings.json` 裡改了 hooks / statusLine / 這個 marketplace 的設定，`pull.sh` **不會**幫你抓回來，要手動反映到 fragment。

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
bash hooks/context-handoff-check.test.sh
```

22 個分支案例，涵蓋防迴圈、bg 排除、sidechain 過濾、arm 不打斷本輪、fire、不重複 fire、PostCompact reset、停用開關與輸出合法性。全程在 `mktemp` 目錄裡用 `CC_HANDOFF_STATE_DIR` 隔離，不會動到真實狀態。

### 已知限制

- **一輪延遲**：Stop hook 執行時本輪最後一筆 usage 可能還沒寫進 transcript，讀到的通常是上一輪的數字。加上 arm→fire 本身再延一輪，最壞約兩輪滯後。誤差偏安全邊（漏讀那輪會讓下次 delta 變大、提早觸發），在 1M window 用 30 萬當門檻餘裕充足。
- `trigger: "auto"`（自動壓縮）未實測，只驗過 `manual`。reset script 不讀 `trigger` 欄位，行為應該一致。
