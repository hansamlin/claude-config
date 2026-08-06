#!/usr/bin/env bash
# SubagentStop hook：唯一的作用是把 subagent-check.sh 落地的 `sa-<agent_id>`
# 狀態檔清掉。除此之外什麼都不做——而且**在任何路徑下 stdout 與 stderr 都必須
# 是空的，exit code 必須是 0**。
#
# 這條規格為什麼是這三件事全都要（binary 反查，Claude Code 2.1.223）：
#   SubagentStop 的消費端判定長這樣：
#     if (U.stdout && U.stdout.trim() || U.stderr && U.stderr.trim()) H = !0;
#     if (U.type === "hook_non_blocking_error") ... H = !0;
#   `H` 就是「讓 sub agent 繼續跑」。判定條件是**有沒有輸出**，不是輸出的形狀：
#   stderr 一樣算、非零 exit（走 hook_non_blocking_error）一樣算。
#   所以「換個欄位、換個措辭」不會有幫助——`systemMessage` 會不會同樣造成續跑，
#   這題已經結案：**會**。唯一安全的規格是「什麼都不輸出」。
#   為此第一行就 `exec >/dev/null 2>&1`，把慣例變成結構保證（見下方）。
#
# 為什麼 2.2.0 會炸（線上缺陷，2.2.1 修正）：
#   2.2.0 這支 hook 會輸出 `hookSpecificOutput.additionalContext`，想藉此通知
#   主 agent「這個 sub agent 沒做完、去重派」。根因**不是**「harness 不認得這個
#   形狀」——恰恰相反，harness 完全認得，而且它的規格語意就是「餵回 sub agent
#   並讓它繼續跑」。schema 的 .describe() 原文：
#     "non-error feedback delivered to the subagent; the subagent continues
#      so it can act on it"
#   也就是說我們**選錯了欄位**，不是形狀不對：想講話的對象是主 agent，用的卻是
#   一個規格上就寫明「講給 sub agent 聽並讓它續跑」的通道。
#   而這支 hook 又剛好把 `sa-<agent_id>` 刪掉了，於是被續跑的 sub agent 下一次
#   工具呼叫時，subagent-check.sh 的「只 deny 一次」記帳不存在 → 重新 deny →
#   再結束 → 再被續跑，滾成無限迴圈。
#
#   對照實驗（唯一變因是 stdout，`rm -f "$state"` 兩版都保留）：
#     有 stdout → SubagentStop 觸發約 30 次、deny **32 次**，整輪跑不完，
#                 sub agent 自己在 transcript 最後寫下「System failure: Context loop infinite」。
#     無 stdout → 每個 sub agent 各 1 次 SubagentStop、各 **1 次** deny，乾淨結束。
#   所以元凶是輸出，不是 `rm`；`rm` 只是把迴圈放大。`rm` 必須保留（見下）。
#
#   附帶證實：原版迴圈裡那些「sub agent 自己去呼叫 Agent 工具派下一層」的怪象，
#   也是同一個根因——additionalContext 被注回 **sub agent 自己**，而那段文字寫的是
#   「請以相同的 agent_type 重新派一個 sub agent」，本來是要給主 agent 看的。
#   拿掉 stdout 之後，exp1 的 trace 裡一次 `Agent` 呼叫都沒有。
#
# 為什麼「通知主 agent」不需要這支 hook：
#   同一次對照實驗證明，這條通道本來就不必要。拿掉 stdout 之後，主 agent 從
#   sub agent 自己的最終回覆就完整拿到了：因 context 達上限中止、任務未完成、
#   agentId、subagent_tokens，以及交接檔的內容摘要；而且**主動**照著 deny 訊息的
#   指示重派了同 agent_type / 同模型等級的續作 agent 去讀交接檔。
#   subagent-check.sh 的 deny reason 已經把該說的話說完了，這裡再說一次沒有增益。
#
# ⚠️ 未來若要加回「機械保證的主 agent 通知」：
#   **不可以**走 SubagentStop 的任何輸出——消費端只看「有沒有輸出」，換欄位、
#   換措辭都繞不過（`systemMessage` 同樣會造成續跑，見上）。
#   有 schema 佐證的候選有兩條，但**都還沒做過線上實測**：
#     1. `Agent` 工具的 PostToolUse（sub agent 回到父對話那一刻）。它的
#        `hookSpecificOutput` 帶 `updatedToolOutput`，.describe() 原文
#        "Replaces the tool output before it is sent to the model"——語意正好
#        可以取代 sub agent 回傳給主 agent 的內容。PostToolUse 的執行器帶
#        agent context，matchQuery 是 tool_name，所以能用 `"matcher": "Agent"`
#        精準掛上去，不會波及其他工具。
#     2. `SubagentStart`（事件表裡有，帶 `additionalContext`）——那是「對即將
#        開始的 sub agent 說話」的通道，方向與 1 相反，適合用來預先交代。
#   兩條都必須先做一次線上實測才可採用；另外改 hooks.json 要重啟 session 才生效。
#
# 為什麼還是要清 sa-<agent_id>，又為什麼絕不刪交接檔：
#   狀態檔的用途只到「這一次派工已經 deny 過了」為止，留著會在 agent_id 萬一被
#   重用時吃掉新一輪的交接機會（而且 STATE_DIR 的 7 天清掃不一定跑得到）。
#   交接檔則是主 agent 接下來要餵給續作 sub agent 的唯一輸入，刪掉整套機制就白做了。
#
# 可調環境變數：見 subagent-check.sh 檔頭，兩支共用同一組。

set -uo pipefail

# ⚠️ 必須是 set 之後的第一個指令，早於任何變數展開。
# 「不輸出」在這支 hook 是正確性條件（見檔頭），不能只靠每一行都小心。已知的
# 洩漏路徑至少兩條，而且都繞過人的注意力：
#   1. 下面 `STATE_DIR=...$HOME/...` 在 HOME 未設定時，`set -u` 會噴
#      "unbound variable" 到 stderr **並且**非零退出——續跑的兩個觸發條件同時滿足。
#   2. `printf ... >> "$CC_HANDOFF_TRACE"` 若 TRACE 指到不可寫路徑，bash 會把
#      重導向錯誤寫到 stderr。
# 這一行把「stdout/stderr 全空」從慣例變成結構保證。
# 不影響 trace：那行是 `>>` 到檔案，走的不是 stdout。
exec >/dev/null 2>&1

[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

# `${HOME:-}` 而不是 `$HOME`：`exec` 已經把 stderr 塞住，但 `set -u` 的 unbound
# variable 還會讓腳本以非零狀態結束——而非零 exit 走 hook_non_blocking_error，
# 一樣會讓 sub agent 續跑。三個條件（stdout / stderr / exit code）要一起守住。
# HOME 沒設定時 STATE_DIR 會變成 "/.claude/handoff-state"，底下不會有狀態檔，
# 下面的 `[ -e "$state" ] || exit 0` 自然收尾。
STATE_DIR="${CC_HANDOFF_STATE_DIR:-${HOME:-}/.claude/handoff-state}"

input=$(cat)
# trace 寫的是檔案不是 stdout，與上面的「不可吐 stdout」不衝突。
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"

agent_id=$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)

[ -n "$agent_id" ] || exit 0

# agent_id 會被拼進檔名，不是純識別字就當作沒收到——與其冒著把 ../ 拼進路徑的
# 風險，不如放著讓 STATE_DIR 的定期清掃收尾。
case "$agent_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

state="$STATE_DIR/sa-$agent_id"

# 沒有狀態檔＝這個 sub agent 從頭到尾沒超標，是正常收工。絕大多數派工走這條路，
# 這裡連 rm 都不必發。
[ -e "$state" ] || exit 0

rm -f "$state" 2>/dev/null

exit 0
