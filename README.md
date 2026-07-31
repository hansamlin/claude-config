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
| `context-handoff` | `UserPromptSubmit` / `PostCompact` hook + `handoff` skill |
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

合併是**只加不減**：從 fragment 拿掉一個 key，不會讓目標機器上那個 key 消失。要真正移除某項設定，得在本機刪掉再 `./pull.sh` 同步回來。

`install.sh` 會逐一安裝 fragment `enabledPlugins` 裡列出的**每一個** plugin，不只本 repo 的兩個——`enabledPlugins` 只是啟用旗標，沒真的 install 過的話 plugin 不會落地，hook 不觸發而且毫無錯誤訊息。

`CLAUDE_DIR` 只對檔案複製與 settings 合併有效。`claude plugin install` 一律操作真實 `~/.claude`，所以 `CLAUDE_DIR` 指到別處時那兩步會被略過——那個變數是給測試用的，不是完整的沙箱。

## context 門檻自動 handoff

長 session 的 context 會無聲無息地漲，等到發現時往往已經來不及好好交接。這個 plugin 讓它在固定門檻自動停下來、把進度寫進記憶、提醒你換 session。

### 運作方式

Claude Code 的 hook payload **不含任何 token 欄位**（只有 statusline 拿得到 `.context_window`），所以用量得自己從 `transcript_path` 那份 JSONL 算：取最後一筆非 sidechain 的 assistant 訊息，把 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` 相加。這個公式已對照 statusline 的 `total_input_tokens + total_output_tokens` 實測相等。

`UserPromptSubmit` hook 在**你每次送出訊息時**跑，邏輯只有一條：

1. 當下用量 < 門檻 → 靜默放行
2. 當下用量 ≥ 門檻 → 注入 `additionalContext`，要 Claude 先跑 `handoff` skill 把進度寫進記憶、告訴你換 session，並**不要動你這則訊息交派的工作**；同時用 `systemMessage` 讓你也看到
3. transcript 尾端查得到 `handoff` skill 真的被呼叫過 → 收手，只留一行提醒
4. 催了 `CC_HANDOFF_MAX_NAGS` 次仍沒交接 → 當你是刻意要繼續用，降級為不打斷的提醒

第 3 點的判準是「transcript 說 handoff 跑過了」而不是「我催過了」。`additionalContext` 只是注入指示，沒有任何機制保證 Claude 一定照做；催一次就記帳收手的話，模型忽略一次，這個 session 就再也不會交接，而且完全靜默。掃描只看尾端 `CC_HANDOFF_LOOKBACK` 筆——compact 之後 context 會塌回去，先前那次 handoff 早就過期，掃全檔會讓舊記錄永遠壓住後續觸發。sidechain 裡的 handoff 不算數，那是 subagent 的事。

hook 與 skill 放在同一個 plugin 裡是必要的：hook 觸發時會叫 Claude 執行 `handoff`，兩者分開的話，裝了 hook 卻沒有 skill 就會指向一個不存在的東西。

`PostCompact` hook 只做清理：壓縮後 context 會塌回去，先前「已交接過」的記錄就過期了。

### 為什麼掛 UserPromptSubmit 而不是 Stop

早期版本掛 `Stop`，在每輪對話結束時算用量、預測下一輪會不會破門檻、先 arm 再 fire。換掉的三個理由：

- **不用猜 session 是不是有人在用**。`Stop` 版本靠 `sessionKind == "bg"` 排除背景 job，前提是「背景 job 沒有換 session 這回事」。實際上透過背景 job 開的 session 一樣會在裡面來回對話（實測一個 26 輪、338k tokens 的工作 session 就標成 `bg`），這條排除等於把日常用的 session 全部靜默擋掉，門檻永遠不觸發。`UserPromptSubmit` 只在人真的送出訊息時才觸發，事件本身就是「有人在互動」的證據，不必再猜。
- **不用預測下一輪**。攔截點落在你交派新任務的當下，直接比對當前用量就夠，`armed` marker、`delta` 下限、上一輪用量的狀態檔全部可以砍掉。
- **攔在動工前而不是動工後**。`Stop` 最快也只能在 Claude 做完一整輪之後才打斷，那輪的 token 已經燒掉了。

必須用 `additionalContext` 而不是 `decision: "block"`：`UserPromptSubmit` 的 block 會把 prompt 直接作廢且**不產生任何 turn**，Claude 根本不會被呼叫，也就沒機會執行 `handoff` skill，結果只剩一句提醒而沒有真的交接。`additionalContext` 是把指示連同你的訊息一起送進去，Claude 照常有 turn，才能實際動用工具寫記憶。

### 為什麼不掛 PreCompact

`PreCompact` 的語意是「壓縮**嘗試**前」而非「壓縮確定發生」。實測 `/compact` 因訊息太少而失敗（`Not enough messages to compact.`）時它照樣觸發，掛上去會在壓縮根本沒發生時誤清狀態。`PostCompact` 才代表真的壓縮完成。

### 幾個必要的防呆

- payload 帶 `agent_id` **或** `agent_type` 直接退出——subagent 送出的 prompt 也會觸發這個事件，但它的 context 與主 session 無關。兩個欄位都認：只認一個的話，萬一實際帶的是另一個，就會在 subagent 裡誤觸發、把主 session 的催告額度用掉且完全靜默
- transcript 過濾 `isSidechain != true`——不過濾的話，只要派過一次 subagent，最後一筆就是 subagent 的小 context，門檻永遠到不了且**完全靜默**

### 設定

| 環境變數 | 預設 | 說明 |
| --- | --- | --- |
| `CC_HANDOFF_THRESHOLD` | `300000` | 觸發門檻（token）。1M context window 的 30% |
| `CC_HANDOFF_MAX_NAGS` | `3` | 最多主動要求交接幾次，超過就只提醒 |
| `CC_HANDOFF_LOOKBACK` | `300` | 往回掃幾筆 transcript 找 handoff 執行記錄 |
| `CC_HANDOFF_DISABLE` | — | 設 `1` 完全停用 |
| `CC_HANDOFF_TRACE` | — | 設成檔案路徑，把收到的 hook payload 附加寫入，除錯用 |
| `CC_HANDOFF_STATE_DIR` | `~/.claude/handoff-state` | 狀態目錄，測試用來隔離 |

要永久改門檻就寫進 `settings.json` 的 `env` 區塊。想看一次完整流程：

```bash
CC_HANDOFF_THRESHOLD=5000 claude
```

第一次送出訊息就會轉去做 handoff，跑完之後只提醒不打斷。

想確認 hook 真的有被觸發（而不是註冊了卻靜默），加上 trace：

```bash
CC_HANDOFF_THRESHOLD=5000 CC_HANDOFF_TRACE=/tmp/upst.jsonl claude
```

`/tmp/upst.jsonl` 有 payload 但沒交接＝指示沒被照做；檔案空的＝hook 根本沒註冊到。

### 測試

```bash
bash plugins/context-handoff/scripts/check.test.sh
```

12 組案例、29 條斷言，涵蓋 subagent 排除（`agent_id` / `agent_type` 兩種）、sidechain 過濾、未達門檻靜默、達門檻注入指示、模型忽略時繼續催、催滿上限降級、handoff 跑過就收手、bg session 必須觸發的回歸、PostCompact reset、停用開關與輸出合法性。全程在 `mktemp` 目錄裡用 `CC_HANDOFF_STATE_DIR` 隔離，不會動到真實狀態。

### 已知限制

- **讀到的是上一輪的數字**：hook 觸發時最新的 usage 就是上一輪 assistant 訊息，也就是你送出訊息當下的實際 context 大小——這正是要比的量，但你這則訊息本身的 token 不算在內。在 1M window 用 30 萬當門檻餘裕充足。
- **注入的是指示不是強制**：`additionalContext` 讓 Claude 看到並據此行動，但沒有機制能保證它一定照做。Hook 無法直接呼叫工具或 skill，這是 hooks 的設計邊界。所以才用「transcript 查得到 handoff 執行記錄」當收手條件，而不是「我催過了」。
- `trigger: "auto"`（自動壓縮）未實測，只驗過 `manual`。reset script 不讀 `trigger` 欄位，行為應該一致。

## tsgo-lsp

`vendor/node_modules` 是平台專屬二進位（`@typescript/typescript-darwin-arm64`），不能進版控，所以 repo 只收 `package.json` + `package-lock.json`（版本鎖在 7.0.2），由 `install.sh` 在 plugin 的實際安裝位置跑 `npm ci` 還原。

因此 **`/plugin marketplace update` 之後若 LSP 失效，重跑一次 `./install.sh`** 即可——它會找出所有 tsgo-lsp vendor 目錄補裝依賴。

確認生效：`ps aux | grep -- '--lsp'` 應該看到 plugin 目錄底下的 tsc。
