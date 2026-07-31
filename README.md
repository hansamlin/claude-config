# claude-config

我的 Claude Code 設定，同時是一個 **plugin marketplace**（`sam-tools`）。

大部分東西以 plugin 形式分發，更新走 `/plugin marketplace update`；plugin 管不到的那幾樣才靠 `install.sh`。

## 安裝

```bash
git clone git@github.com:hansamlin/claude-config.git ~/project/claude-config
cd ~/project/claude-config
./install.sh
```

`install.sh` 會註冊 marketplace、安裝兩個 plugin、還原 tsgo 的 TypeScript、並把 `CLAUDE.md` / `statusline.sh` / settings 個人設定套進 `~/.claude`。需要 `jq`。

也可以只裝 plugin 而不碰其他設定：

```
/plugin marketplace add hansamlin/claude-config
/plugin install context-handoff@sam-tools
/plugin install tsgo-lsp@sam-tools
```

private repo 可以直接當 marketplace source——Claude Code 用 SSH clone，有金鑰就拉得到。

## 內容

### Plugin（marketplace `sam-tools`）

| Plugin | 提供 |
| --- | --- |
| `context-handoff` | `Stop` / `PostCompact` hook + `handoff` skill |
| `tsgo-lsp` | TypeScript 7 native (tsgo) LSP server |

### install.sh 負責的（plugin 管不到）

| 檔案 | 用途 |
| --- | --- |
| `CLAUDE.md` | user scope 全域指示 |
| `statusline.sh` | 路徑 / 分支 / 模型 / context 用量 / 5 小時額度 |
| `settings.fragment.json` | permissions、env、theme、language 等個人設定 |

`skills/`（handoff 以外）刻意不收，內含公司專案相關內容。

**這個 repo 只適合維持 private**：`CLAUDE.md` 帶有公司脈絡（GitLab / `glab` 工作流程），要轉 public 前必須重新逐檔稽核。

## 更新

| 改了什麼 | 怎麼生效 |
| --- | --- |
| plugin 內容（hook、skill、LSP 設定） | `/plugin marketplace update` |
| `CLAUDE.md` / `statusline.sh` / settings | 重跑 `./install.sh` |

反向（本機改動抓回 repo）：

```bash
./pull.sh --dry-run   # 先看差異
./pull.sh
```

`pull.sh` 只同步 `CLAUDE.md`、`statusline.sh`、以及 `settings.json` 的個人設定。**plugin 內容請直接在 repo 裡改**——`~/.claude/plugins/` 底下是 Claude Code 的快取，改那裡會被下次更新蓋掉。

## `settings.json` 是合併不是覆蓋

repo 不收 `settings.json` 本體（它會被 Claude Code 執行期改寫，`/config` 調整、`feedbackSurveyState` 都會直接寫回檔案），只收 `settings.fragment.json`。

`install.sh` 用 `jq` 的 `*` 深度合併：對 object 遞迴合併，所以目標機器上其他設定原封不動；對陣列右側取代，所以重複執行不會讓陣列愈疊愈長。寫入前備份成 `.bak`，內容無變化時完全不動檔案。

fragment 裡的路徑寫成 `__CLAUDE_DIR__` 佔位符，安裝時填成實際路徑，`pull.sh` 再正規化回去，個人路徑不會進版控。

## context 門檻自動 handoff

長 session 的 context 會無聲無息地漲，等到發現時往往已經來不及好好交接。這個 plugin 讓它在固定門檻自動停下來、把進度寫進記憶、提醒你換 session。

### 運作方式

Claude Code 的 hook payload **不含任何 token 欄位**（只有 statusline 拿得到 `.context_window`），所以用量得自己從 `transcript_path` 那份 JSONL 算：取最後一筆非 sidechain 的 assistant 訊息，把 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` 相加。這個公式已對照 statusline 的 `total_input_tokens + total_output_tokens` 實測相等。

`Stop` hook 每輪對話結束都會跑：

1. 預測下一輪會破門檻 → 寫 armed marker、給一行預警，**不打斷本輪**
2. 下一輪結束看到 marker → 回 `decision: "block"`，要求 Claude 呼叫 `handoff` skill、告知使用者換 session、然後停手
3. 已經破門檻 → 不等下一輪，當場觸發
4. 觸發過一次後降級為不阻斷的提醒——使用者選擇繼續用就尊重他，否則每輪被 block 沒辦法工作

hook 與 skill 放在同一個 plugin 裡是必要的：hook 觸發時會叫 Claude 執行 `handoff`，兩者分開的話，裝了 hook 卻沒有 skill 就會指向一個不存在的東西。

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
bash plugins/context-handoff/scripts/check.test.sh
```

22 個分支案例，涵蓋防迴圈、bg 排除、sidechain 過濾、arm 不打斷本輪、fire、不重複 fire、PostCompact reset、停用開關與輸出合法性。全程在 `mktemp` 目錄裡用 `CC_HANDOFF_STATE_DIR` 隔離，不會動到真實狀態。

### 已知限制

- **一輪延遲**：Stop hook 執行時本輪最後一筆 usage 可能還沒寫進 transcript，讀到的通常是上一輪的數字。加上 arm→fire 本身再延一輪，最壞約兩輪滯後。誤差偏安全邊（漏讀那輪會讓下次 delta 變大、提早觸發），在 1M window 用 30 萬當門檻餘裕充足。
- `trigger: "auto"`（自動壓縮）未實測，只驗過 `manual`。reset script 不讀 `trigger` 欄位，行為應該一致。

## tsgo-lsp

`vendor/node_modules` 是平台專屬二進位（`@typescript/typescript-darwin-arm64`），不能進版控，所以 repo 只收 `package.json` + `package-lock.json`（版本鎖在 7.0.2），由 `install.sh` 在 plugin 的實際安裝位置跑 `npm ci` 還原。

因此 **`/plugin marketplace update` 之後若 LSP 失效，重跑一次 `./install.sh`** 即可——它會找出所有 tsgo-lsp vendor 目錄補裝依賴。

確認生效：`ps aux | grep -- '--lsp'` 應該看到 plugin 目錄底下的 tsc。
