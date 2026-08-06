#!/usr/bin/env bash
# PostToolUse hook（matcher: Agent）：sub agent 回到父對話的那一刻，如果它有寫出
# 交接檔，就在它回傳給主 agent 的內容**後面附加**一段「這個 sub agent 沒做完 +
# 交接檔路徑」的警示，把「主 agent 得知要重派」從模型順從性升級成機械保證。
#
# 為什麼需要這條通道：
#   `subagent-check.sh` 的 deny reason 要求 sub agent 的最終回覆回報三點
#   （沒做完 / 交接檔路徑 / 請以相同 agent_type 與模型等級重派）。實測上這條
#   通道是夠用的，但它終究是**模型順從性**：sub agent 若漏講交接檔路徑、或把
#   半成品包裝成成品，主 agent 就接不上，而且**沒有任何備援**——2.2.0 靠
#   SubagentStop 兜底的設計已被證實有害而移除（見 README 的事故紀錄）。
#
# 為什麼是 PostToolUse 而不是 SubagentStop：
#   SubagentStop 的消費端只看「有沒有輸出」，任何輸出（stdout / stderr / 非零
#   exit）都等於「讓 sub agent 繼續跑」，換欄位換措辭都繞不過。PostToolUse 的
#   消費端則完全不同（binary 反查，Claude Code 2.1.223）：
#     if(p.updatedToolOutput!==void 0)yield{updatedToolOutput:p.updatedToolOutput};
#     if(p.preventContinuation){...yield hook_stopped_continuation...;return}
#     if(p.additionalContexts&&p.additionalContexts.length>0)...
#   **沒有任何「續跑」旗標**——恰恰相反，它有一個明示的 `preventContinuation`
#   用來「停止」。所以 2.2.0 那條「用了一條沒驗過的通道結果造成續跑」的風險
#   在結構上不存在。schema 對 updatedToolOutput 的 .describe() 原文：
#     "Replaces the tool output before it is sent to the model"
#   取代的正是 sub agent 回傳給主 agent 的那段內容。
#
# 為什麼是 `"matcher": "Agent"`：
#   PostToolUse 的 matchQuery 比對的是 tool_name，而實測 payload 顯示派工工具的
#   tool_name 是 **Agent**（不是 Task——`--allowedTools` 才寫 Task）。掛上
#   matcher 之後這支 hook 只在派工工具收工時跑，不波及其他工具的效能。
#
# ⚠️ 被派出去那個 sub agent 的 id 在 `tool_response.agentId`，**不是**頂層的
#   `agent_id`。實測 payload（2.1.223）頂層欄位只有：
#     cwd, duration_ms, effort, hook_event_name, permission_mode, prompt_id,
#     session_id, tool_input, tool_name, tool_response, tool_use_id,
#     transcript_path
#   ——**完全沒有 agent_id / agent_type**。這支 hook 跑在**父**對話的工具管線
#   裡（`Agent` 工具是在主 agent 那一側執行的），所以帶的 agent context 是父的。
#   `tool_response` 則帶 `agentId / agentType / status / resolvedModel /
#   totalTokens / totalToolUseCount / usage / content`，其中 agentId 實測與
#   `<session>/subagents/agent-<id>.jsonl` 的檔名逐字相同，正是我們要的 key。
#
# ⚠️ 一定要**附加**而不是取代：sub agent 的回覆裡可能有已完成的部分結論，
#   丟掉會損失資訊。`tool_response.content` 是 content block 陣列
#   （實測 `[{"type":"text","text":"…"}]`），所以做法是在陣列尾端多推一個
#   text block，原本的元素原封不動。
#
# ⚠️⚠️ `updatedToolOutput` 送的必須是**整個 tool_response 物件**，不是字串、
#   也不是單獨的 content 陣列。套用端會拿**工具自己的 outputSchema** 驗證
#   （binary 反查 + 實測雙重確認）：
#     if(nt){ let Ke=e.outputSchema?.safeParse(He);
#       let st=(err)=>{ …He=se.data /* 退回原輸出 */,
#                       Fe.push({message:bl({type:"hook_error_during_execution",
#                         content:`…does not match ${e.name}'s output shape;
#                                  using original output. ${err}`…})}) };
#       if(Ke&&!Ke.success) st(Ke.error.message); … }
#   實測送純字串與送 content 陣列**都失敗**，transcript 裡各留下一筆
#   `hook_error_during_execution`、訊息是 `does not match Agent's output shape;
#   using original output`，工具結果原封不動。失敗是**靜默降級**（原輸出照送、
#   只多一則 attachment），不會壞掉主流程——但也等於這個 hook 白做了。
#   所以這裡的做法是：原封不動接住 `.tool_response`，只把 `.content` 加長。
#
# 什麼都不做的情況（一律靜默 exit 0，不輸出任何東西）：
#   - 交接檔不存在 → 這個 sub agent 沒被攔過，是正常收工，最常見的路徑
#   - 取不到 agentId、agentId 不是純識別字、tool_name 不是 Agent
#   - content 不是陣列（形狀變了）→ 寧可不注入，也不要把回傳內容弄壞
#
# 可調環境變數：見 subagent-check.sh 檔頭，三支共用同一組。

set -uo pipefail

[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

STATE_DIR="${CC_HANDOFF_STATE_DIR:-${HOME:-}/.claude/handoff-state}"

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE" 2>/dev/null

# 一次 jq 取完，分隔字元用 \001（理由同 subagent-check.sh：tab 會被 read 併掉）。
# agentId 過 `strings`：join 遇到非字串元素會整個 jq 失敗。
tool_name=""; sa_id=""
IFS=$'\001' read -r tool_name sa_id <<EOF
$(printf '%s' "$input" | jq -r '[(.tool_name // ""),
    ((.tool_response.agentId | strings) // "")] | join("")' 2>/dev/null)
EOF

# 防禦性：matcher 已經只讓 Agent 進來，但 matcher 的語意日後可能改成前綴比對，
# 而這支 hook 的注入文字對其他工具是完全錯的訊息。
[ "$tool_name" = "Agent" ] || exit 0

[ -n "$sa_id" ] || exit 0

# agentId 會被拼進檔名。不是純識別字就當作沒收到——與其冒著把 ../ 拼進路徑的
# 風險，不如放棄這次通知。字元集刻意與 subagent-check.sh 那條同一套。
case "$sa_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

handoff_file="$STATE_DIR/subagent-handoff-$sa_id.md"

# 交接檔不存在＝這個 sub agent 從頭到尾沒超標，正常收工。絕大多數派工走這條路。
[ -f "$handoff_file" ] || exit 0

# content 必須是陣列才附加得上去。不是陣列就靜默放棄——把回傳內容的形狀弄壞
# 的代價遠大於少一次通知。
[ "$(printf '%s' "$input" | jq -r '.tool_response.content | type' 2>/dev/null)" = "array" ] || exit 0

# 用 `.content += [...]` 而不是重建物件：tool_response 還帶 agentId / agentType /
# status / resolvedModel / usage / toolStats 等欄位，逐一列舉的話 schema 一改就
# 靜默失效（退回原輸出、只留一則 attachment，沒有人會發現）。整個接住最耐腐。
printf '%s' "$input" | jq --arg f "$handoff_file" '
{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    updatedToolOutput: (.tool_response | .content += [{
      type: "text",
      text: ("\n\n---\n\n⚠️ **【context 門檻自動交接】這個 sub agent 因 context 達上限被中止，"
             + "任務尚未完成。** 上面的回覆可能只涵蓋一部分，也可能被包裝得像是完成品。\n\n"
             + "交接檔：\($f)\n\n"
             + "請以**相同**的 agent_type 與**相同**的模型等級重新派一個 sub agent，"
             + "並在 briefing 裡要求它**先讀該交接檔**再續作。\n\n"
             + "（這段是 context-handoff plugin 的 PostToolUse hook 附加的，"
             + "不是 sub agent 自己寫的。）")
    }])
  }
}' 2>/dev/null

exit 0
