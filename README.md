# claude-config

我的 Claude Code 設定，同時是一個 **plugin marketplace**（`sam-tools`）。

大部分東西以 plugin 形式分發，更新走 `/plugin marketplace update`；plugin 管不到的那幾樣才靠 `install.sh`。

## 安裝

```bash
git clone git@github.com:hansamlin/claude-config.git ~/project/claude-config
cd ~/project/claude-config
./install.sh
```

`install.sh` 會註冊並更新 marketplace、安裝 `enabledPlugins` 列出的每一個 plugin、還原 tsgo 的 TypeScript、並把 `AGENTS.md`（裝成 `~/.claude/CLAUDE.md`）/ `statusline.sh` / settings 個人設定套進 `~/.claude`。需要 `jq`。

`enabledPlugins` 裡值為 `false` 的 plugin **照樣安裝，但裝完會被 `claude plugin disable` 關掉**——目前沒有任何項目是 `false`。

⚠️ `CLAUDE.md` 刻意排在 plugin 安裝**之後**，且有 plugin 沒裝成就跳過它——因為 `CLAUDE.md` 若指名 plugin skill，指到不存在的名字不報錯、只靜默跳過流程。

也可以只裝 plugin 而不碰其他設定：

```
/plugin marketplace add hansamlin/claude-config
/plugin install tsgo-lsp@sam-tools
/plugin install context-usage@sam-tools
/plugin install language-reminder@sam-tools
```

private repo 可以直接當 marketplace source——Claude Code 用 SSH clone，有金鑰就拉得到。

## 內容

### Plugin（marketplace `sam-tools`）

| Plugin | 提供 |
| --- | --- |
| `tsgo-lsp` | TypeScript 7 native (tsgo) LSP server |
| `context-usage` | `context-usage` 指令 + 同名 skill：查當前 session 的 context 用量與百分比 |
| `language-reminder` | `PostToolUse` hook：每次工具呼叫後注入一句繁中提醒，避免回覆漂成英文 |

⚠️ `context-usage` 的**百分比**需要 `statusline.sh` 配合（見下一節）——context window 大小只出現在
Claude Code 餵給 statusline hook 的 payload 裡，transcript 沒記。只裝 plugin 不跑 `install.sh` 的話，
指令仍可用，但只會給 token 數、沒有百分比。這是本 repo 幾個跨兩條分發管道的功能之一。

### install.sh 負責的（plugin 管不到）

| 檔案 | 用途 |
| --- | --- |
| `AGENTS.md` | user scope 全域指示（sub agent 派工、驗證規則、本機 Git 環境）。裝成 `~/.claude/CLAUDE.md`——Claude Code 全域層級只讀 `CLAUDE.md`，不讀 `~/.claude/AGENTS.md` |
| `statusline.sh` | 路徑 / 分支 / session id 前 8 碼 / 模型 / context 用量 / 5 小時額度，另把 `context_window` 落檔給 `context-usage` plugin 讀 |
| `settings.fragment.json` | permissions、env、theme、language 等個人設定 |

`skills/`（`context-usage` 以外）刻意不收，內含公司專案相關內容。

**這個 repo 只適合維持 private**：`AGENTS.md` 帶有公司脈絡（GitLab / `glab` 工作流程），要轉 public 前必須重新逐檔稽核。

## 更新

| 改了什麼 | 怎麼生效 |
| --- | --- |
| plugin 內容（hook、skill、LSP 設定） | `/plugin marketplace update` |
| `AGENTS.md` / `statusline.sh` / settings | 重跑 `./install.sh` |

⚠️ `context-usage` 橫跨兩列：skill 與指令走 marketplace，百分比所需的快取走 `statusline.sh`。
只做其中一邊會得到「能跑但沒有百分比」的半殘狀態，`context-usage` 的輸出會標明是哪一種來源。

反向（本機改動抓回 repo）：

```bash
./pull.sh --dry-run   # 先看差異
./pull.sh
```

`pull.sh` 只同步 `~/.claude/CLAUDE.md`（寫回 `AGENTS.md`）、`statusline.sh`、以及 `settings.json` 的個人設定。**plugin 內容請直接在 repo 裡改**——`~/.claude/plugins/` 底下是 Claude Code 的快取，改那裡會被下次更新蓋掉。

## `settings.json` 是合併不是覆蓋

repo 不收 `settings.json` 本體（它會被 Claude Code 執行期改寫，`/config` 調整、`feedbackSurveyState` 都會直接寫回檔案），只收 `settings.fragment.json`。

`install.sh` 用 `jq` 的 `*` 深度合併：對 object 遞迴合併，所以目標機器上其他設定原封不動；對陣列右側取代，所以重複執行不會讓陣列愈疊愈長。寫入前備份成 `.bak`，內容無變化時完全不動檔案。

fragment 裡的路徑寫成 `__CLAUDE_DIR__` 佔位符，安裝時填成實際路徑，`pull.sh` 再正規化回去，個人路徑不會進版控。

合併是**只加不減**：從 fragment 拿掉一個 key，不會讓目標機器上那個 key 消失。要真正移除某項設定，得在本機刪掉再 `./pull.sh` 同步回來。

`autoMode`（auto mode 的信任邊界：GitLab 主機、內網服務、機敏檔案位置）刻意不同步，`pull.sh` 會把它濾掉。那份描述講的是「這台機器接得到什麼」，家裡的機器連不到公司環境，同步過去只會是錯的；合併只加不減，公司機器上既有的 `autoMode` 也不會被 `install.sh` 動到。

`pull.sh` 落檔一律用 `jq -S`，把**所有層級**的 object key 排成升冪。Claude Code 會自行重寫 `settings.json`，key 順序隨它高興——啟用／停用 plugin 會重排 `enabledPlugins`，從 `/config` 改一個開關則可能讓新 key 落在中間而不是尾端。順序沒有語意，但會在 `git diff` 上炸出一整片假異動、把真正的設定變更埋掉。固定順序後 diff 只會剩下真的加減了什麼。

（只排 `enabledPlugins` 與 `extraKnownMarketplaces` 是舊作法，治不到頂層；更糟的是「比較」用 `jq -S` 無序、「落檔」用 `jq .` 保留來源順序，於是順序變動本身不觸發寫檔，但只要有任何真實變動觸發了寫檔，整份就按本機順序重寫——真假異動混在同一個 diff 裡。陣列不排，`permissions.allow` 之類的順序可能有語意。）

`install.sh` 會逐一安裝 fragment `enabledPlugins` 裡列出的**每一個** plugin，不只 `sam-tools` 這幾個——`enabledPlugins` 只是啟用旗標，沒真的 install 過的話 plugin 不會落地，hook 不觸發而且毫無錯誤訊息。

安裝迴圈**不看 value**，`true` 和 `false` 一律照裝；`false` 的那些在迴圈跑完之後才逐一 `claude plugin disable`。順序不能反：`claude plugin install` 會【無條件】把 `enabledPlugins[<p>]` 寫回 `true`，即使 settings 合併時已經寫成 `false`，而且它沒有 `--disabled` 這種旗標。所以「fragment 寫 false」單獨是無效的，一定會被後面的 install 蓋掉——想標記「裝但預設關」就只能靠這道補打的 disable。這段跟 marketplace／install 兩段一樣，`CLAUDE_DIR` 不是 `~/.claude` 時整段略過。

`CLAUDE_DIR` 只對檔案複製與 settings 合併有效。`claude plugin install` 一律操作真實 `~/.claude`，所以 `CLAUDE_DIR` 指到別處時那兩步會被略過——那個變數是給測試用的，不是完整的沙箱。

## language-reminder

`settings.fragment.json` 的 `language` 只出現在 system prompt。長時間連續工具呼叫的回合裡，每次工具呼叫後都有英文系統提醒貼在最新 context，遙遠的 language 指示被蓋過，回覆就漂成英文。

`remind.sh` 掛在 `PostToolUse`（不設 matcher，所有工具都觸發），經 `hookSpecificOutput.additionalContext` 在每個工具結果旁注入一句繁中提醒，讓指示永遠貼近最新 context。輸出是固定字串，不讀 stdin 內容、不依賴 `jq`。sub agent 裡的工具呼叫同樣會觸發，提醒一併生效。

代價是每次工具呼叫多幾十 token，所以提醒刻意寫短。

## tsgo-lsp

`vendor/node_modules` 是平台專屬二進位（`@typescript/typescript-darwin-arm64`），不能進版控，所以 repo 只收 `package.json` + `package-lock.json`（版本鎖在 7.0.2），由 `install.sh` 在 plugin 的實際安裝位置跑 `npm ci` 還原。

因此 **`/plugin marketplace update` 之後若 LSP 失效，重跑一次 `./install.sh`** 即可——它會找出所有 tsgo-lsp vendor 目錄補裝依賴。

確認生效：`ps aux | grep -- '--lsp'` 應該看到 plugin 目錄底下的 tsc。
