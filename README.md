# claude-config

我的 Claude Code 設定，同時是一個 **plugin marketplace**（`sam-tools`）。

大部分東西以 plugin 形式分發，更新走 `/plugin marketplace update`；plugin 管不到的那幾樣才靠 `install.sh`。

## 安裝

```bash
git clone git@github.com:hansamlin/claude-config.git ~/project/claude-config
cd ~/project/claude-config
./install.sh
```

`install.sh` 會註冊 marketplace、安裝三個 plugin、還原 tsgo 的 TypeScript、並把 `CLAUDE.md` / `statusline.sh` / settings 個人設定套進 `~/.claude`。需要 `jq`。

也可以只裝 plugin 而不碰其他設定：

```
/plugin marketplace add hansamlin/claude-config
/plugin install context-handoff@sam-tools
/plugin install tsgo-lsp@sam-tools
/plugin install context-usage@sam-tools
```

private repo 可以直接當 marketplace source——Claude Code 用 SSH clone，有金鑰就拉得到。

## 內容

### Plugin（marketplace `sam-tools`）

| Plugin | 提供 |
| --- | --- |
| `context-handoff` | `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `PostCompact` hook + `handoff` skill |
| `tsgo-lsp` | TypeScript 7 native (tsgo) LSP server |
| `context-usage` | `context-usage` 指令 + 同名 skill：查當前 session 的 context 用量與百分比 |

⚠️ `context-usage` 的**百分比**需要 `statusline.sh` 配合（見下一節）——context window 大小只出現在
Claude Code 餵給 statusline hook 的 payload 裡，transcript 沒記。只裝 plugin 不跑 `install.sh` 的話，
指令仍可用，但只會給 token 數、沒有百分比。這是本 repo 唯一一個跨兩條分發管道的功能。

### install.sh 負責的（plugin 管不到）

| 檔案 | 用途 |
| --- | --- |
| `CLAUDE.md` | user scope 全域指示 |
| `statusline.sh` | 路徑 / 分支 / 模型 / context 用量 / 5 小時額度，另把 `context_window` 落檔給 `context-usage` plugin 讀 |
| `settings.fragment.json` | permissions、env、theme、language 等個人設定 |

`skills/`（`handoff` 與 `context-usage` 以外）刻意不收，內含公司專案相關內容。

**這個 repo 只適合維持 private**：`CLAUDE.md` 帶有公司脈絡（GitLab / `glab` 工作流程），要轉 public 前必須重新逐檔稽核。

## 更新

| 改了什麼 | 怎麼生效 |
| --- | --- |
| plugin 內容（hook、skill、LSP 設定） | `/plugin marketplace update` |
| `CLAUDE.md` / `statusline.sh` / settings | 重跑 `./install.sh` |

⚠️ `context-usage` 橫跨兩列：skill 與指令走 marketplace，百分比所需的快取走 `statusline.sh`。
只做其中一邊會得到「能跑但沒有百分比」的半殘狀態，`context-usage` 的輸出會標明是哪一種來源。

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

`install.sh` 會逐一安裝 fragment `enabledPlugins` 裡列出的**每一個** plugin，不只本 repo 的三個——`enabledPlugins` 只是啟用旗標，沒真的 install 過的話 plugin 不會落地，hook 不觸發而且毫無錯誤訊息。

`CLAUDE_DIR` 只對檔案複製與 settings 合併有效。`claude plugin install` 一律操作真實 `~/.claude`，所以 `CLAUDE_DIR` 指到別處時那兩步會被略過——那個變數是給測試用的，不是完整的沙箱。

## context 門檻自動 handoff

長 session 的 context 會無聲無息地漲，等到發現時往往已經來不及好好交接。這個 plugin 讓它在固定門檻自動停下來、把進度寫進記憶、提醒你換 session。

### 運作方式

Claude Code 的 hook payload **不含任何 token 欄位**（只有 statusline 拿得到 `.context_window`），所以用量得自己從 `transcript_path` 那份 JSONL 算：取最後一筆非 sidechain 的 assistant 訊息，把 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens` 相加。這個公式已對照 statusline 的 `total_input_tokens + total_output_tokens` 實測相等。

`UserPromptSubmit` hook 在**你每次送出訊息時**跑，邏輯分三階段（2.5.0）：

1. 當下用量 < `CC_HANDOFF_THRESHOLD`（提醒起點）→ 靜默放行
2. 提醒區間（起點 ≤ 用量 < `CC_HANDOFF_HARD_LIMIT`）→ **里程碑提醒**：`level = (用量 - 起點) / CC_HANDOFF_NAG_STEP`，**跨 level 才**用 `systemMessage` 提醒一次（不注入指示、不 block，你這則訊息照常執行）。第一次達起點、以及每跨過 20k（320k、340k…）各提醒一次。`/handoff` 逃生口照舊放行；這個階段即使交接過也不 block——它只是提醒，不中斷任何事
3. 用量 ≥ `CC_HANDOFF_HARD_LIMIT`（硬上限）→ 沿用舊的強制交接機制：未交接過就注入 `additionalContext` 要 Claude 先跑 `handoff` skill 把進度寫進記憶、**不要動你這則訊息交派的工作**，同時用 `systemMessage` 讓你也看到；transcript 尾端查得到 `handoff` skill 真的被呼叫過 → 改用 `decision: "block"` 硬中斷後續的 prompt（交接完就該開新 session，繼續做下去 context 只會再長）。**沒有降級**——2.4.0 的「催滿 `CC_HANDOFF_MAX_NAGS` 就只提醒」已隨里程碑機制移除

強制交接那段的判準是「transcript 說 handoff 跑過了」而不是「我提醒過」。`additionalContext` 只是注入指示，沒有任何機制保證 Claude 一定照做；要是依賴記帳收手，模型忽略一次，這個 session 就再也不會交接，而且完全靜默。掃描只看尾端 `CC_HANDOFF_LOOKBACK` 筆——compact 之後 context 會塌回去，先前那次 handoff 早就過期，掃全檔會讓舊記錄永遠壓住後續觸發。sidechain 裡的 handoff 不算數，那是 subagent 的事。里程碑的記帳（`nag-level-<session_id>`，存的是 level 不是次數）同理：compact 之後 level 過期，由 `PostCompact` 清掉重算。

hook 與 skill 放在同一個 plugin 裡是必要的：hook 觸發時會叫 Claude 執行 `handoff`，兩者分開的話，裝了 hook 卻沒有 skill 就會指向一個不存在的東西。

`PostCompact` hook 只做清理：壓縮後 context 會塌回去，先前「已交接過」與里程碑 level 的記錄都過期了。

### 為什麼掛 UserPromptSubmit 而不是 Stop

早期版本掛 `Stop`，在每輪對話結束時算用量、預測下一輪會不會破門檻、先 arm 再 fire。換掉的三個理由：

- **不用猜 session 是不是有人在用**。`Stop` 版本靠 `sessionKind == "bg"` 排除背景 job，前提是「背景 job 沒有換 session 這回事」。實際上透過背景 job 開的 session 一樣會在裡面來回對話（實測一個 26 輪、338k tokens 的工作 session 就標成 `bg`），這條排除等於把日常用的 session 全部靜默擋掉，門檻永遠不觸發。`UserPromptSubmit` 只在人真的送出訊息時才觸發，事件本身就是「有人在互動」的證據，不必再猜。
- **不用預測下一輪**。攔截點落在你交派新任務的當下，直接比對當前用量就夠，`armed` marker、`delta` 下限、上一輪用量的狀態檔全部可以砍掉。
- **攔在動工前而不是動工後**。`Stop` 最快也只能在 Claude 做完一整輪之後才打斷，那輪的 token 已經燒掉了。

必須用 `additionalContext` 而不是 `decision: "block"`：`UserPromptSubmit` 的 block 會把 prompt 直接作廢且**不產生任何 turn**，Claude 根本不會被呼叫，也就沒機會執行 `handoff` skill，結果只剩一句提醒而沒有真的交接。`additionalContext` 是把指示連同你的訊息一起送進去，Claude 照常有 turn，才能實際動用工具寫記憶。

### compact 邊界必須尊重

換到 `UserPromptSubmit` 之後多了一個 `Stop` 時代不存在的坑：這個 hook 在**使用者送出訊息的當下**跑，而 transcript 是 append-only，使用者的 prompt 一定排在 compact 後第一筆 assistant 訊息**之前**。所以那一刻直接取最後一筆 usage，讀到的是 compact **前**的舊數字。

配上 `PostCompact` 剛把狀態清掉，後果是：使用者為了繼續工作才去 `/compact`，實際 context 已經從 315k 掉到 48k，卻在下一則訊息被劫持去做一次完全多餘的交接。

所以 `used` 的計算遇到 `isCompactSummary == true` 就歸零重算；邊界之後還沒有任何 usage 就視為未達門檻、靜默放行。同一個邊界也套用在「handoff 跑過了沒」的掃描上——compact 前那次交接的內容已經過期，不該壓住後續觸發。

（舊版 `Stop` 天然免疫：它在整輪結束後才跑，那時新數字已經寫進 transcript 了。）

### 為什麼不掛 PreCompact

`PreCompact` 的語意是「壓縮**嘗試**前」而非「壓縮確定發生」。實測 `/compact` 因訊息太少而失敗（`Not enough messages to compact.`）時它照樣觸發，掛上去會在壓縮根本沒發生時誤清狀態。`PostCompact` 才代表真的壓縮完成。

### 幾個必要的防呆

- payload 帶 `agent_id` 直接退出——subagent 送出的 prompt 也會觸發這個事件，但它的 context 與主 session 無關。**只認 `agent_id` 不認 `agent_type`**：文件寫 `agent_id`「present only when the hook fires inside a subagent call」，而 `claude --agent foo` 啟動的**主** session 帶的是 `agent_type`，連它一起擋會讓那種 session 永遠不交接——正是 bg 排除那個 bug 的翻版
- transcript 過濾 `isSidechain != true`——不過濾的話，只要派過一次 subagent，最後一筆就是 subagent 的小 context，門檻永遠到不了且**完全靜默**
- 用量從最後一個 compact 邊界（頂層 `isCompactSummary == true`）之後重算——見上面〈compact 邊界必須尊重〉

### sub agent 的 context 也會爆（`PreToolUse`）

主 session 的機制對 sub agent 完全無效——`check.sh` 看到 `agent_id` 就退出，而且 sub agent 有自己的 transcript。實際上 sub agent 一樣會衝破 300k，然後帶著一個做到一半、卻寫得像做完的結論回報給主 agent。

sub agent 的生命週期裡沒有「使用者送出訊息」可攔，`Stop` 類事件又太晚（那時半成品已經交出去了）。唯一每一輪都會經過的關卡是**工具呼叫**，所以用 `PreToolUse`（三階段與主 session 相同，2.5.0）：

1. payload 沒有 `agent_id`（＝主 agent 的工具呼叫）→ 立刻退出。這條路徑每一次工具呼叫都會走到，判定放在最前面
2. 有 `agent_id` → 推導 sub agent 專屬 transcript，算最後一筆 assistant 的 usage 總和，未達提醒起點就放行
3. 提醒區間 → 里程碑提醒：跨 level 注入 `additionalContext`（PreToolUse 的 schema 沒有 systemMessage，實測明載 `additionalContext`），**不 deny**、工具照跑
4. 用量 ≥ 硬上限 → `permissionDecision: "deny"`，用 `permissionDecisionReason` 告訴這個 sub agent：停止原本的工作、把交接內容寫進 `$STATE_DIR/subagent-handoff-<agent_id>.md`、最終回覆只回報「沒做完 + 交接檔路徑 + 請主 agent 以相同 agent_type/模型重派」

**寫不出交接檔的情境一律不攔**——deny 的 reason 要求的是「用 `Write` 把交接內容寫進交接檔」，對一個根本寫不了檔的 sub agent 發這道指令，等於白白吃掉一次工具呼叫又什麼都沒留下，**比不攔更糟**。目前有兩條互相獨立的跳過條件：

- **agent_type 的工具集裡沒有 `Write`**。內建的 `Explore` 與 `Plan` 排除了 `Edit / Write / NotebookEdit`。清單用 `CC_HANDOFF_SUBAGENT_SKIP_TYPES` 控制（空白分隔，預設 `Explore Plan`）；做成可覆寫是因為使用者自訂 agent 遲早會讓寫死的清單腐爛
- **permission mode 是 `plan`**。plan mode 下寫檔不是全面禁止而是**白名單制**，白名單只有 plan 檔、workflow script、scratchpad、job tmp 這幾類（binary 原文：`Plan files for current session are allowed for writing`、`Workflow script files for current session are allowed for writing`、`Scratchpad files for current session are allowed for writing`、`Job tmp/ subtree for current bg session is allowed for writing`）。交接檔寫的是 `$STATE_DIR`，不在任何一條裡，必定收到 `Cannot write to <path> while in plan mode`。判定直接讀 `PreToolUse` payload 的 `permission_mode`（合法值 `"default","acceptEdits","bypassPermissions","plan"`）

**plan mode 這條比 agent_type 那條常見得多**：sub agent 繼承主 session 的 permission mode，所以只要你在 plan mode 下派工，**任何 agent_type 都會中招**，包含 `general-purpose`。兩條走的是同一條 skip 路徑——不 deny、也不寫 `sa-` 記帳檔（沒發過 deny 就不該佔用「只 deny 一次」的配額）。

**skip 只守 deny、不守提醒（2.5.0）**：上面兩條跳過的理由是「攔了它也寫不出交接檔」——那對 deny 成立（deny 的 reason 要求它寫檔），對 stage-2 的里程碑提醒不成立（提醒只是說一句話，不叫人寫檔）。所以 skip / plan mode 的判定在實作上排在提醒分支**之後**、deny 之前：Explore / Plan / plan mode 底下照樣收得到提醒，越過硬上限時才被跳過。代價是這些 agent 在提醒區間內每次工具呼叫多付一次掃 transcript 的 jq（實測個位數毫秒）。

`PreToolUse` 其實**也有** `additionalContext` 這條「不擋、只注入」的管道，schema 明列在 `hookSpecificOutput` 裡：

```
hookEventName:E.literal("PreToolUse"),permissionDecision:...,permissionDecisionReason:E.string().optional(),updatedInput:...,additionalContext:E.string().optional()
```

消費端對它的處理與權限決定無關：不給 `permissionDecision`、只給 `additionalContext`，工具照常執行，文字照樣進模型。這裡刻意選 `deny` 而不是「只注入」，要的是「**立刻停止原本的工作**」那份語意強度——deny 以「這次工具呼叫被擋下」的形式呈現，模型難以忽略。代價是損失一次工具呼叫，所以 reason 必須明講「原本的工作不用做了」，否則模型會以為只是這一步被擋、換個工具再試。日後若想省掉那次工具呼叫，`allow` + `additionalContext` 是有 schema 佐證的實驗方向（記帳仍要保留，否則每次工具呼叫都會再注入一遍）。

**只 deny 一次**，以 `$STATE_DIR/sa-<agent_id>` 記帳。deny 是無差別的——擋的是「這次工具呼叫」而不是「某類工具」。持續 deny 的話，sub agent 連寫交接檔要用的 `Write` 都會被擋，直接死鎖。記帳一定要在 deny **之前**且失敗就整個放棄（fail open）：整套保證都建立在那個檔存在上，先 deny 後記帳等於把死鎖賭在檔案系統上。

記帳的寫入是**原子的**（`noclobber`），不是 check-then-act。因為 **PreToolUse hook 確實會並行執行**——這是實測結論，不是推測：

> 讓一個 sub agent 在同一則訊息裡發出三個平行 `Read`，hook 內寫入帶微秒時間戳的 start/end、中間 `sleep 1`。結果三個 hook 行程**兩兩重疊**（第 2 個在第 1 個 end 之前 start，第 3 個在第 2 個 end 之前 start）。runtime 不序列化這批 hook。

binary 解釋了原因：工具排程器的 `processQueue` 對每個 queued 工具呼叫 `executeTool`，而 `executeTool` 只把狀態設成 `executing`、啟動一個**不被 `await` 的** async IIFE 就返回；`canExecuteTool` 在「目前執行中的全是 concurrency-safe」時允許下一個直接開跑。每個工具完整的生命週期（含權限判定與 hook）都在那個 IIFE 裡，所以會重疊。`Read`/`Grep`/`Glob` 這類 `readOnlyHint` 工具是 concurrency-safe，**`Bash` 不是**——這正是為什麼過去所有驗收 trace（清一色是序列的 `Bash`）從沒觸發過這條路徑。

若記帳是 check-then-act（讀 `[ -e ]` → 掃 transcript → 寫），同一批的多個 hook 會全部判定「還沒記過」→ **全部 deny** → 那一批工具呼叫全被取消，sub agent 收到 N 份重複的交接指示。用 8 個並行行程重現，check-then-act 穩定跑出 8 次 deny，`noclobber` 是 1 次。

⚠️ 但這是「保證有例外」而不是「機制會壞」。第二個實驗（hook 只跑 50ms、七個平行 `Read`）**完全沒有重疊**：工具呼叫的起始間隔是 500~900ms，由模型串流出 `tool_use` block 的節奏決定，比競態窗口大兩個數量級。之所以還是修，是因為代價近乎為零——那行排在**所有**早退之後，一個 sub agent 的一生只會走到一次，多出來的只有一個 subshell fork。`[ -e "$state" ]` 那行仍然留著當**便宜快取**（原子寫入是**權威**），把它拿掉會讓每次工具呼叫都付掃 transcript 的錢。實測熱路徑成本未變：主 agent 路徑 12.0 ms/次、記帳已存在的 sub agent 路徑 11.7 ms/次。

**記帳一旦寫下就沒有任何人會刪**（2.3.0 起）。2.2.x 有一支 `SubagentStop` hook 專門在 sub agent 收工時 `rm` 掉 `sa-<agent_id>`，理由是「`agent_id` 萬一被重用，不要吃掉新一輪的交接機會」。那條註冊已經**整條移除**，因為它與「只 deny 一次」的保證互相衝突：

`agent_id` 被「重用」最現實的場景不是碰撞，是**同一個 sub agent 被續跑**——主 agent 用 `SendMessage` 續接既有 agent，或任何 resume 路徑。binary 裡 `SubagentStop` 的 payload 帶 `stop_hook_active` 且可以為 `true`，代表「續跑後再次觸發 SubagentStop」是被設計進去的情境；過去實驗也實際觀察到同一個 `agent_id` 出現兩次 `SubagentStop`。續跑時 sub agent 的 context **還是滿的**，記帳卻已經被刪掉，於是它下一次工具呼叫會**再被 deny 一次**、再被要求寫一次交接檔。

用 2.2.1 的兩支腳本直接重現（同一份超標 transcript，唯一變因是中間有沒有跑 `subagent-stop.sh`）：

| 版本 | 呼叫 1 | 呼叫 2 | 收工 | 續跑後呼叫 3 | 續跑後呼叫 4 |
| --- | --- | --- | --- | --- | --- |
| 2.2.1（stop hook 會 `rm`） | **deny** | 放行 | `rm sa-<id>` | **deny**（第二次！） | 放行 |
| 2.3.0（無 stop hook） | **deny** | 放行 | — | 放行 | 放行 |

真正的 `agent_id` 碰撞機率極低（隨機十六進位識別字），殘留檔本身也無害（deny 已經發過，不會死鎖）。取捨明確：不刪。**附帶好處是整條 `SubagentStop` 註冊可以拿掉——少一個事件、少一個會吐輸出的風險面**，而「任何輸出都會讓 sub agent 續跑」正是 2.2.0 那場事故的根源。代價是 `sa-*` 的回收完全依賴 `check.sh` 的 7 天清掃，所以那行 `find` 同時被移到所有早退**之前**（見下）。

以下這段歷史仍然值得留著，因為它是「為什麼絕不可以再往 `SubagentStop` 送任何東西」的一手證據。2.2.0 曾經讓這支 hook 輸出 `hookSpecificOutput.additionalContext` 去通知主 agent，線上實測是災難：已經結束的 sub agent 被**續跑**；而這支 hook 又剛好把 `sa-<agent_id>` 刪了，所以它下一次工具呼叫時「只 deny 一次」的記帳不存在 → 重新 deny → 再結束 → 再被續跑，滾成無限迴圈。對照實驗（唯一變因是 stdout，`rm` 兩版都保留）：

| stdout | SubagentStop 次數 | deny 次數 | 結果 |
| --- | --- | --- | --- |
| 有 | ~30 | **32** | 跑不完，sub agent 自己在 transcript 最後寫下「System failure: Context loop infinite」 |
| 無 | 每次派工 1 | **1** | 主 agent 正常收到回報並重派，整輪乾淨結束 |

元凶是 hook 的輸出本身，不是 `rm`（`rm` 只是放大器）。2.3.0 把兩者都拿掉了。

**根因不是「harness 不認得那個形狀」，而是我們選了一個語意本來就等於「繼續跑」的欄位。** SubagentStop 的 `additionalContext` 是合法欄位，schema 上的 `.describe()` 寫得非常清楚：

```
non-error feedback delivered to the subagent; the subagent continues so it can act on it
```

「delivered to the **subagent**」——那段文字是注回 sub agent 自己，不是父對話。這順帶解釋了原版迴圈裡「sub agent 自己去呼叫 `Agent` 工具派下一層」的怪象：它讀到了本來寫給主 agent 看的「請以相同 `agent_type` 重新派一個 sub agent」，於是就照做了；拿掉 stdout 之後那條 trace 裡一次 `Agent` 呼叫都沒有。

更關鍵的是**續跑的判定條件是「有沒有輸出」，不是「輸出的形狀」**。消費端：

```
if(U.stdout&&U.stdout.trim()||U.stderr&&U.stderr.trim())H=!0
```

外加 `U.type==="hook_non_blocking_error"`（hook 非零 exit）也會設同一個旗標。所以：換成 `systemMessage` 一樣會續跑（換欄位、換措辭都繞不過去）、**寫到 stderr 也算**、hook 自己 crash 也算。這就是為什麼規格是「stdout 與 stderr 全空、exit 0」而不只是「不要輸出 JSON」。

> 上面這些引文都來自本機執行中的 CLI 建置產物（`~/.local/share/claude/versions/<version>`），用 `rg -a --fixed-strings -o '<字串>' <binary>` 就能自己重跑，**秒級**（慢的是複雜 regex 與 `strings` 全檔掃）。這比攔 payload 更完整：payload 只看得到實際發生過的，schema 看得到所有可能的。

**「通知主 agent」不需要這支 hook。** 同一次實驗證明，拿掉 stdout 之後主 agent 從 sub agent 自己的最終回覆就完整拿到了：因 context 達上限中止、任務未完成、`agentId`、`subagent_tokens`、交接檔內容摘要，而且**主動**照著 deny 訊息的指示重派了同 `agent_type` / 同模型等級的續作 agent 去讀交接檔。deny 的 reason 已經把該說的話說完了。

⚠️ 旁路通知**不可以**走 `SubagentStop`——它任何形式的輸出都等於「讓 sub agent 繼續跑」，換欄位、換措辭都繞不過去（理由見上）。對症的是 `Agent` 工具的 `PostToolUse`，2.4.0 已經做進來了，見下一節。

也不用 `decision: "block"`：block 的語意是「不准結束、繼續做」，但這個 sub agent 就是因為 context 滿了才被攔下來的，逼它繼續只會更糟。要接手的是**新的** sub agent。

幾個刻意不做的事：

- **不叫 sub agent 去跑 `handoff` skill**。那支寫的是專案長期記憶，而且會按任務主題去重、就地更新既有 `type: project` 記憶檔。sub agent 手上的是任務內的接力棒，混進去會汙染甚至覆蓋主線專案記憶
- **不套 `isSidechain != true` 過濾**。那是給主 transcript 用的；sub agent 專屬檔整份都是 `isSidechain: true`，套上去會把資料濾光、門檻永遠不觸發且完全靜默
- **不做 compact 邊界歸零**。sub agent transcript 會不會出現 `isCompactSummary` 沒有樣本可驗，就算出現，最壞只是誤觸發一次 deny——deny 對同一個 `agent_id` 只會發生一次，是自限的
- **`PostCompact` 不清 `sa-*`**。那講的是主 session 被壓縮，與任何 sub agent 的 context 無關；清掉等於對一個 context 仍然滿的 sub agent 重新武裝 deny
- **不在 `PreToolUse` 裡掃過期狀態檔**。`check.sh` 已經在掃了；這支是每次工具呼叫都跑，多一個 `find` 就是把成本乘上工具呼叫次數

### 機械保證的旁路通知（`PostToolUse` + `matcher: Agent`，2.4.0）

上面那條「主 agent 從 sub agent 的最終回覆得知」的通道實測夠用，但它終究是**模型順從性**：sub agent 若漏講交接檔路徑、或把半成品包裝成成品，主 agent 就接不上，而且沒有備援。`subagent-post.sh` 補上機制層：sub agent 回到父對話的那一刻，如果它有寫出交接檔，就在回傳內容**後面附加**一段警示。

**為什麼 `PostToolUse` 沒有 `SubagentStop` 那個風險。** 消費端完全不同：

```js
if(p.updatedToolOutput!==void 0)yield{updatedToolOutput:p.updatedToolOutput};
if(p.preventContinuation){...yield hook_stopped_continuation...;return}
if(p.additionalContexts&&p.additionalContexts.length>0)...
```

**沒有任何「續跑」旗標**——恰恰相反，它有一個明示的 `preventContinuation` 用來「停止」。2.2.0 那條「用了一條沒驗過的通道結果造成續跑」的風險在結構上不存在。端到端實測也確認：sub agent 交接完直接收尾，主 agent 側 `Agent` 工具恰好呼叫 1 次。

**⚠️ 被派出去那個 sub agent 的 id 在 `tool_response.agentId`，不是頂層 `agent_id`。** 實測 payload 的頂層欄位是 `cwd / duration_ms / effort / hook_event_name / permission_mode / prompt_id / session_id / tool_input / tool_name / tool_response / tool_use_id / transcript_path`——**完全沒有 `agent_id` / `agent_type`**。這支 hook 跑在**父**對話的工具管線裡（`Agent` 工具是在主 agent 那一側執行的），所以帶的 agent context 是父的。`tool_response` 則帶 `agentId / agentType / status / resolvedModel / totalTokens / totalToolUseCount / usage / content`，其中 `agentId` 與 `<session>/subagents/agent-<id>.jsonl` 的檔名逐字相同。

**⚠️⚠️ `updatedToolOutput` 送的必須是整個 `tool_response` 物件。** 這條踩過兩次才確定。套用端會拿**工具自己的 `outputSchema`** 驗：

```js
if(nt){ let Ke=e.outputSchema?.safeParse(He);
  let st=(err)=>{ …He=se.data /* 退回原輸出 */,
                  Fe.push({message:bl({type:"hook_error_during_execution",
                    content:`…does not match ${e.name}'s output shape;
                             using original output. ${err}`…})}) };
  if(Ke&&!Ke.success) st(Ke.error.message); … }
```

實測送**純字串**與送**單獨的 content 陣列**都失敗，主 transcript 裡各留下一筆 `hook_error_during_execution`、訊息是 `does not match Agent's output shape; using original output`，工具結果原封不動。**失敗是靜默降級**——原輸出照送、只多一則 attachment，不會壞掉主流程，但也等於這個 hook 白做了。所以實作是 `.tool_response | .content += [新 block]`：整個接住，只把 content 加長。逐一列舉欄位會在 schema 一改時靜默失效。

**一定要附加不是取代。** `.describe()` 寫的是 *Replaces*，但 sub agent 的回覆裡可能有已完成的部分結論，丟掉會損失資訊。實測結果是主 agent 同時收到 sub agent 原本的回覆**和**注入的警示。

**⚠️ 續接路徑（`SendMessage`）不走這支 hook。** matcher 綁的是 `Agent`，而主 agent 用 `SendMessage` 續接既有 sub agent 時 `tool_name` 是 `SendMessage`——實測一次「派工 → `SendMessage` 續接」的完整流程，PostToolUse 只在 `Agent` 那次觸發。這條路徑很現實：harness 自己就在每則 sub agent 回覆結尾廣告它（`use SendMessage with to: '<agentId>' to continue this agent`），而「同一個 sub agent 被續跑」正是拿掉 SubagentStop 的核心理由。續接後那個 agent 的 context 只會更滿，交接檔也還在 `$STATE_DIR`，但主 agent 不會再收到機械保證的提醒——**那條仍是順從性**。要不要把 matcher 擴到 `SendMessage` 是未決問題：得先確認它的 PostToolUse payload 有沒有帶得到 `agentId`，還沒驗。

事件表裡還有 `SubagentStart`（帶 `additionalContext`），那是「對即將開始的 sub agent 說話」的通道——日後要做「續作 agent 必須先讀交接檔」的機械保證，那才是對的事件，目前仍是順從性。

### 7 天清掃必須排在所有早退之前

`check.sh` 的 `find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete` 在 2.2.x 排在三個 early exit **之後**（未達門檻早退、`/handoff` 逃生口、已交接就 block），所以它只在「已達門檻 **且** 這則不是 handoff **且** 尚未交接過」這條窄路徑上跑：**一旦該 session 交接過就再也不跑**，主 session 從沒破過門檻的機器上等於完全不跑。受害的不只 1 byte 的 `sa-*`，還有可能好幾 KB 的 `subagent-handoff-*.md`。

2.3.0 起它排在所有早退之前（只落後於 `CC_HANDOFF_DISABLE` 與讀 stdin），每一則使用者訊息都跑一次。對十幾個檔的單層目錄，`find` 是微秒級。這在 `SubagentStop` 移除之後從「殘留垃圾」升級成 `sa-*` 的**唯一**回收路徑，所以四條早退路徑在測試裡各驗一次。

所有狀態一律以 `agent_id` 當 key，不可用 `session_id`——本機允許 20 個並發 sub agent，用 session 當 key 會互相汙染。

### 設定

| 環境變數 | 預設 | 說明 |
| --- | --- | --- |
| `CC_HANDOFF_THRESHOLD` | `300000` | 主 session 的提醒起點（token）。1M context window 的 30%。在此之上先提醒、不阻擋 |
| `CC_HANDOFF_HARD_LIMIT` | `400000` | 主 session 的硬上限（token）。超過才強制交接 |
| `CC_HANDOFF_NAG_STEP` | `20000` | 主 session 里程碑提醒間距（token）。設 `0` 或非數字退回 `20000` |
| `CC_HANDOFF_SUBAGENT_THRESHOLD` | `300000` | sub agent 的提醒起點。與主 session 分開，因為兩者調整的動機不同（一個是使用者體感，一個是任務切段粒度） |
| `CC_HANDOFF_SUBAGENT_HARD_LIMIT` | `400000` | sub agent 的硬上限（token）。超過才 deny |
| `CC_HANDOFF_SUBAGENT_NAG_STEP` | `20000` | sub agent 里程碑提醒間距（token）。設 `0` 或非數字退回 `20000` |
| `CC_HANDOFF_SUBAGENT_SKIP_TYPES` | `Explore Plan` | 這些 `agent_type` 的 sub agent 一律不 **deny**（空白分隔）。預設兩個內建 agent 的工具集沒有 `Write`，攔了也寫不出交接檔。⚠️ **只守 deny、不守提醒**（2.5.0）：提醒區間內這些 agent 照樣收得到里程碑提醒。注意 plan mode 是**另一條獨立的**跳過條件，不受這個變數控制（清空它也不會讓 plan mode 下的派工被 deny） |
| `CC_HANDOFF_LOOKBACK` | `300` | 往回掃幾筆 transcript 找 handoff 執行記錄 |
| `CC_HANDOFF_DISABLE` | — | 設 `1` 完全停用。四支 hook 都吃這個開關（包含 `PostCompact` 的清理——停用狀態下它連狀態檔都不會刪） |
| `CC_HANDOFF_TRACE` | — | 設成檔案路徑，把收到的 hook payload 附加寫入，除錯用 |
| `CC_HANDOFF_STATE_DIR` | `~/.claude/handoff-state` | 狀態目錄，測試用來隔離 |

**遷移**（2.5.0）：`CC_HANDOFF_MAX_NAGS` 已移除（催告計數被里程碑機制取代，stage-3 不再降級）。要把行為還原成 2.4.0 以前的單門檻——沒有提醒區間、一過起點就強制交接——把 `CC_HANDOFF_HARD_LIMIT` 設成與 `CC_HANDOFF_THRESHOLD` 相同即可。

要永久改門檻就寫進 `settings.json` 的 `env` 區塊。想看一次完整流程：

```bash
CC_HANDOFF_THRESHOLD=5000 claude
```

用量一過 5000 就進提醒區間（5000～400000），第一次送出訊息會收到里程碑提醒、不阻擋。要示範**強制交接**得把硬上限也設小：

```bash
CC_HANDOFF_THRESHOLD=5000 CC_HANDOFF_HARD_LIMIT=10000 claude
```

小數字版的三段式範例（預設步距 20000 對小數字太大，把 `NAG_STEP` 一起縮小）：

```bash
CC_HANDOFF_THRESHOLD=3000 CC_HANDOFF_HARD_LIMIT=9000 CC_HANDOFF_NAG_STEP=1000 claude
# 用量 3000 提醒（level 0）→ 4000、5000…8000 每跨 1000 提醒一次 → 9000 起強制交接
```

想確認 hook 真的有被觸發（而不是註冊了卻靜默），加上 trace：

```bash
CC_HANDOFF_THRESHOLD=5000 CC_HANDOFF_TRACE=/tmp/upst.jsonl claude
```

`/tmp/upst.jsonl` 有 payload 但沒提醒／沒交接＝指示沒被照做；檔案空的＝hook 根本沒註冊到。

### 測試

```bash
bash plugins/context-handoff/scripts/check.test.sh
bash plugins/context-handoff/scripts/subagent-check.test.sh
bash plugins/context-usage/scripts/context-usage.test.sh
```

`subagent-check.test.sh` 有 31 組案例、99 條斷言，涵蓋主 agent 工具呼叫必須零副作用、未達提醒起點靜默、提醒區間跨 level 注入 `additionalContext` 提醒且不 deny（300000 恰等 / 320000 level 1 / 399999 level 4 / 同 level 連發靜默）、**skip 與 plan mode 只守 deny、不守提醒**（Explore 在 320000 收得到提醒、在 999999 仍完全靜默）、達硬上限 deny 且 reason 含交接檔絕對路徑與重派語意、**第二次工具呼叫必須放行的死鎖回歸**、寫交接檔本身不可被擋、`transcript_path` 給主檔或給專屬檔都要算得到量、推導不到檔案要靜默、並發 `agent_id` 狀態互不干擾、**`SubagentStop` 這條風險面必須整條消失**（檔案不存在 + `hooks.json` 不得註冊，另驗其餘三條註冊仍在，以免整份 JSON 壞掉時假綠）、**續跑不可二次 deny**、**兩條 skip 條件的正反向**（清單命中就不 deny、比對必須是整個 token 相等而不能寫成 substring/prefix、`CC_HANDOFF_SUBAGENT_SKIP_TYPES` 必須真的可覆寫；`permission_mode=plan` 不 deny、其餘 mode 一律照常 deny）、`agent_id` 路徑注入防護與停用開關、`NAG_STEP=0` 退回預設，以及 **350000 提醒 → 420000 deny 一次 → 續跑放行、`sa-` 與 `sa-nag-` 兩 state 共存**的生命周期。`sa-nag-*` 與 `sa-*` 一樣靠 check.sh 的 7 天清掃回收，有專組驗證。

壓軸是一組**端到端**斷言：讓 `subagent-check.sh` 自己寫出 `sa-<agent_id>`，然後在六次工具呼叫裡換工具、換 `permission_mode`、把用量再翻倍、跨過「收工 → 被續跑」的分界，斷言**合計恰好 1 次 deny**。它取代了 2.2.x 那組跨檔回歸（`subagent-stop.sh` 已不存在），驗的性質也更強——不是「兩支腳本互動正確」，而是「不論中途發生什麼，deny 只發生一次」。

`subagent-post.test.sh` 有 12 組、37 條斷言，涵蓋交接檔不存在時完全靜默、存在時注入且**是附加不是取代**（原 content block 原封不動、數量從 1 變 2）、`tool_response` 的七個欄位必須原封帶回（`outputSchema` 驗證的回歸）、取不到 `agentId` 靜默、`agentId` 路徑注入防護、`tool_name` 不是 `Agent` 靜默（含 `AgentSomething` 這種前綴誤命中）、`content` 不是陣列靜默、停用開關、`CC_HANDOFF_TRACE`，以及 `hooks.json` 的 matcher 必須是 `Agent` 的結構斷言。

**每一條新斷言都要有 red 證據**——恆綠是缺陷，不是通過。2.3.0 那批的 mutation 紀錄：把 `SubagentStop` 註冊加回 `hooks.json` → FAIL=1；把 `subagent-stop.sh` 檔案放回來 → FAIL=1；把記帳那行 `printf ... > "$state"` 換成 no-op → FAIL=13（其中「六次呼叫恰好 1 次 deny」變成 6）；把 `check.sh` 的 `find` 移回早退之後 → `check.test.sh` FAIL=4。

2.4.0 那批（`subagent-post.sh`）：改用頂層 `agent_id`（issue 原本的猜測）→ FAIL=21；取代而非附加 → FAIL=3；只送 content 陣列 → FAIL=19；拿掉 `tool_name` 守衛 → FAIL=2；拿掉 `content` 型別守衛 → FAIL=1；拿掉 `agentId` 消毒 → FAIL=1；`hooks.json` 的 matcher 改成 `Task` → FAIL=1。

2.5.0 那批（三階段門檻）先做了「改測試 → 對舊 code 跑出預期紅（`check.test.sh` FAIL=34、`subagent-check.test.sh` FAIL=23，全落在新機制斷言）→ 改 code 轉綠」，再補 mutation：刪 stage-2 記帳寫入 → FAIL=10；stage-2 改發 `decision:"block"` → FAIL=2；stage-3 改成純 `systemMessage` → FAIL=8；`subagent-check.sh` 的 skip 移回 stage-2 之前 → FAIL=1；`reset.sh` 漏清 `nag-level-` → FAIL=2；拿掉 `NAG_STEP` 消毒 → FAIL=2+2。獨立驗證者另外補了四次：`prev=-1` 改成 `prev=0`（level 0 永遠不提醒）→ FAIL=19 / FAIL=7；`-lt "$HARD_LIMIT"` 改成 `-le` → FAIL=4；stage-2 區塊移到「已交接 scan」之後 → FAIL=2；`/handoff` 逃生口移到 stage-2 之後 → FAIL=10。**三個「位置錯就出事」的分支（stage-2 相對於逃生口、相對於已交接 scan，skip 相對於 stage-2）各有紅證據守著。**

`context-usage.test.sh` 有 12 組、49 條斷言，全程以 `HOME` 隔離（腳本的快取目錄與 projects 目錄都從 `$HOME` 推導）。涵蓋快取路徑算得出 used/total/pct、**compact 與 pretty 兩種 JSON 空白風格都要吃**、過期門檻與 7 天 prune 是兩條獨立機制、transcript 回退有數字但 `total`/`pct` 必須是 `null`（不可捏造分母）、**sidechain 訊息不可污染主 session 的數字**、無 `jq` 也無 `python3` 要明確報錯且 exit 1（但同一個極簡 PATH 下快取路徑仍須可用＝主路徑真的零外部依賴）、session 定位的 env var 與 cwd slug 兩條、`--selftest` 在空 `HOME` **必須 FAIL**（跳過檢查卻報綠是最糟的假綠），以及 `statusline.sh` 快取區塊的整合（兩種空白風格都要寫得出可用的快取、且原本的顯示不被破壞）。

mutation 紀錄：round-trip 改成取第一筆 cwd → FAIL=1；腳本端拿掉 sed 的 `[[:space:]]` 容許 → FAIL=1；`statusline.sh` 端拿掉同一個容許 → FAIL=1；拿掉快取過期檢查 → FAIL=2；`selftest` 改成永遠報 PASS → FAIL=4；transcript 模式捏造分母（`TOTAL=200000`）→ FAIL=8；拿掉 `isSidechain` 過濾 → FAIL=2；slug 規則改成保留底線 → FAIL=6。

另外實跑 `--selftest` 抓出第三個真缺陷：round-trip 原本取 transcript **開頭**的 `cwd`，但 session 中途換目錄（`/cd`、`EnterWorktree`）時整段歷史留在同一個檔、檔案卻已被搬到新 cwd 對應的 project 目錄 ⇒ 拿開頭比會**誤判成「slug 規則已漂移」**。改成取最後一筆，並補了對應回歸案例。

過程中被 mutation 抓出另外兩個真缺陷：**（一）** 原本用「把 mtime 調到 2020」測過期，但那種檔案會先被 7 天 prune 掃掉，於是不論過期門檻在不在都會退回 transcript ⇒ 該分支恆綠。改成用 `CC_CONTEXT_USAGE_MAX_AGE` 直接驅動門檻，並把 prune 拆成獨立一組。**（二）** 門檻比較原本寫 `-le`，同一秒內產生的快取 `age=0`、`0 -le 0` 成立仍被採用 ⇒ 該測試看時鐘、會 flaky；改成 `-lt`，門檻設 0 恆定表示不採信。

⚠️ 已知覆蓋缺口：`reset.sh` 若被加上 `rm sa-nag-*`，兩份測試仍全綠（實作正確且註解寫明刻意不清，但沒有斷言守它）。

⚠️ `NAG_STEP` 消毒那條的 red 證據形狀出乎意料，值得記著：bash 5.3 在**腳本檔**模式下遇到算術除零**不會終止整支腳本**，而是放棄當前 `if` 本體、從 `fi` 之後繼續往下跑（rc 仍為 0）。所以拿掉消毒的後果不是「hook 壞掉」而是**跳過 stage-2、直接掉進 stage-3**——在 350000 就發出強制交接指示，比崩潰更難察覺。（`bash -c` 模式則是直接以 rc=1 中止，兩者不同，用 `-c` 驗會得到錯誤結論。）

⚠️ 2.4.0 那條消毒的 red 證據是**第二次**才拿到的：第一版測試用 `d/../../victim`，但沒有先建出 `subagent-handoff-d/` 這個目錄，中間段不是真實目錄、路徑解析不到，**拿掉消毒也照樣綠**。這正是下面記載的第三種 vacuous test 陷阱，寫的人自己又踩了一次。

這個習慣是 2.2.1 的教訓換來的：當時「stdout 要空」的規格漏了 stderr，把 `subagent-stop.sh` 的 `exec >/dev/null 2>&1` 改成只塞 stdout、再往 stderr 寫一行字，加了 `2>&1` 的新測試 FAIL=12，舊測試形態只 FAIL=1。舊的 17 組斷言**一條都抓不到**——斷言只覆蓋你寫進去的東西，規格漏了一半時全綠沒有意義。

同一輪 mutation 還抓出一個原本沒想到的洞：`set -u` 下 `$HOME` 未設定會**同時**噴 stderr 並以 rc=1 結束，而「非零 exit 也算輸出」是續跑判定裡獨立的一條路徑——所以光加 `exec` 不夠（只加 `exec`、保留 `$HOME`：stderr 確實空了，但 rc=1，sub agent 照樣被續跑），`$HOME` 也必須寫成 `${HOME:-}`。

`check.test.sh` 有 25 組案例、108 條斷言，涵蓋 subagent 排除（且 `--agent` 主 session 不可誤殺）、sidechain 過濾、未達提醒起點靜默、提醒區間跨 level 才提醒（310000 level 0 / 320000 level 1 / 300000 恰等 / 250000→370000 跳躍單次提醒直記 level 3，證明不逐級補催）、**stage-3 連四則每則都注入、無降級（MAX_NAGS 已移除）**、handoff 跑過就 block、compact 邊界重算、bg session 必須觸發的回歸、PostCompact reset 清里程碑記錄、停用開關與輸出合法性，以及**這則 prompt 本身就是 handoff 呼叫時不再重複提醒**（含句尾 `/handoff`、純文字整則相等、談論 handoff 的句子不可誤命中）與**已交接後硬中斷**（含背景任務通知不可被 block 的例外）。另有 `NAG_STEP=0` 退回預設、`HARD_LIMIT=THRESHOLD` 還原單門檻兩個遷移相關案例。全程在 `mktemp` 目錄裡用 `CC_HANDOFF_STATE_DIR` 隔離，不會動到真實狀態。

### 已知限制

- **讀到的是上一輪的數字**：hook 觸發時最新的 usage 就是上一輪 assistant 訊息，也就是你送出訊息當下的實際 context 大小——這正是要比的量，但你這則訊息本身的 token 不算在內。在 1M window 用 30 萬當提醒起點、40 萬當硬上限餘裕充足。
- **stage-2 提醒是 best-effort**（2.5.0）：提醒走 `systemMessage`（主 session）／`additionalContext`（sub agent），與舊的強制交接一樣沒有機制保證 Claude 一定照做。它是提醒不是指令，模型忽略也只是少一句話，跨 level 記帳照常、對機制本身無害。
- **`CC_HANDOFF_MAX_NAGS` 已移除**（2.5.0）：催告計數被里程碑機制取代，stage-3 不再降級——每次超過硬上限的 prompt 都會被要求先做 handoff，直到 transcript 查得到 handoff 呼叫才轉為 block。舊版本留下的 `nags-*` 殘留檔仍由 `PostCompact` 與 7 天清掃收掉，不影響新版本行為。
- **遷移方式**：把 `CC_HANDOFF_HARD_LIMIT` 設成與 `CC_HANDOFF_THRESHOLD` 相同即還原 2.4.0 以前的單門檻（沒有提醒區間、一過起點就強制交接）。stage-2 提醒的文字與舊的降級提醒不同，但阻擋行為一致。
- **compact 後第一則訊息一律放行**：邊界之後還沒有 usage 可讀，寧可漏一次也不要用陳舊數字誤觸發。下一輪就會恢復正常判斷。
- **注入的是指示不是強制**：`additionalContext` 讓 Claude 看到並據此行動，但沒有機制能保證它一定照做。Hook 無法直接呼叫工具或 skill，這是 hooks 的設計邊界。所以才用「transcript 查得到 handoff 執行記錄」當收手條件，而不是「我催過了」。
- `trigger: "auto"`（自動壓縮）未實測，只驗過 `manual`。reset script 不讀 `trigger` 欄位，行為應該一致；但 compact 邊界的偵測靠頂層 `isCompactSummary`，本機能找到的 compact transcript 全是 `manual`，auto 壓縮是否寫入相同標記沒有樣本可驗。若 auto 用了別的形狀，那條路徑會退回「用陳舊數字誤觸發」——不會比修正前更糟，但也不會被擋下。
- **主 agent 得知 sub agent 中止有兩條通道，一條是機制、一條是順從性**。機制那條是 `PostToolUse` + `updatedToolOutput`（2.4.0，見上）；順從性那條是 sub agent 自己的最終回覆。`SubagentStop` **不能**拿來做這件事（它的任何輸出——stdout、stderr、非零 exit——都等於叫已結束的 sub agent 繼續跑，滾成無限 deny 迴圈，見上），2.3.0 起連註冊都不存在了。⚠️ 機制那條的失敗模式是**靜默降級**：`updatedToolOutput` 若不符 `Agent` 的 `outputSchema`，原輸出照送、只在 transcript 留一則 `hook_error_during_execution`，沒有人會發現。日後 `tool_response` 的 schema 一改就可能中招——`subagent-post.test.sh` 第 4 組是為此設的回歸
- **sub agent 的最後一輪沒有工具呼叫**（產生最終回覆的那一輪），所以它若剛好在最後一輪才越過門檻，`PreToolUse` 永遠攔不到，半成品仍會被當成成果回報。這是把攔截點掛在工具呼叫上的結構性代價，無解。
- **sub agent 那條鏈上有三個環節只是模型順從性**：(a) sub agent 收到 deny reason 後有沒有真的去寫交接檔、(b) 交接檔內容夠不夠讓人接手、(c) **它有沒有在最終回覆裡如實說「我沒做完」**——(a) 和 (c) 都不再有 hook 可以兜底，2.2.0 那層兜底已被證實有害而移除
- **`PreToolUse` payload 的 `transcript_path` 在 sub agent 內指向主檔還是專屬檔未實測**，所以兩種形狀都涵蓋；兩個候選都不存在就靜默退出。這條路徑的失敗模式是「永遠不觸發且完全靜默」，要確認它有在跑就掛 `CC_HANDOFF_TRACE`
- **payload 的 `agent_id` 是否等於檔名裡的 `<agent_id>` 未直接實測**：只驗過 transcript 檔內 `agentId` 欄位與檔名一致（`agent-a12a9e71e33f24f4f.jsonl` ↔ `agentId: a12a9e71e33f24f4f`）
- **實測上 sub agent 照著 deny 的 `permissionDecisionReason` 做了**（收到 deny 後寫出交接檔、最終回覆報「未完成、請重派」，主 agent 據此重派）。但這條路一旦失效就**沒有備援**了——2.2.0 靠 `SubagentStop` 兜底的設計已被證實會造成無限迴圈而移除，若哪天 sub agent 只收到「工具呼叫被取消」而看不到理由，主 agent 就無從得知它是被中止的
- **狀態檔一定會殘留，回收完全靠 7 天清掃**。`sa-<agent_id>` 從 2.3.0 起沒有任何人會主動刪（無害：deny 已經發過，不會死鎖），**交接檔 `subagent-handoff-*.md` 也一樣會留**——那是有內容的檔案，可能好幾 KB。唯一的清掃是 `check.sh` 裡那支 7 天 `find`；它已經移到所有早退之前，每一則使用者訊息都會跑一次，但**前提是這台機器上有人在用互動式主 session**。純跑 `claude -p` 的機器沒有 `UserPromptSubmit`，仍然不會清
- **交接過的 session 被硬中斷之後有四條逃生口**：再打一次 `/handoff`（或純文字 `handoff` / `交接`）、`/compact`（compact 邊界之後那次交接就過期了）、`CC_HANDOFF_DISABLE=1`，以及第四條——訊息以 `<tag>` 尖角標籤開頭時會被判定成系統注入（為了不 erase 背景任務完成通知），繞過 block 只拿到提醒。真人打 `<x>繼續做這件事` 就能鑽過去。這是刻意保留的溫和後門（真人幾乎不會這樣開頭），不打算收窄
- **改了 hook 行為記得 bump `plugin.json` 的 `version`**：plugin 快取是按版本號分目錄的（`~/.claude/plugins/cache/sam-tools/context-handoff/<version>/`），版本沒動的話 `/plugin marketplace update` 之後可能仍在跑舊碼——又是一個「裝好了、沒錯誤、行為是舊的」情境。

## tsgo-lsp

`vendor/node_modules` 是平台專屬二進位（`@typescript/typescript-darwin-arm64`），不能進版控，所以 repo 只收 `package.json` + `package-lock.json`（版本鎖在 7.0.2），由 `install.sh` 在 plugin 的實際安裝位置跑 `npm ci` 還原。

因此 **`/plugin marketplace update` 之後若 LSP 失效，重跑一次 `./install.sh`** 即可——它會找出所有 tsgo-lsp vendor 目錄補裝依賴。

確認生效：`ps aux | grep -- '--lsp'` 應該看到 plugin 目錄底下的 tsc。
