#!/usr/bin/env bash
# PreToolUse hook：sub agent 的 context 達門檻時，把它從原本的工作上攔下來，
# 要它先寫交接檔、只回報「請重派」，不要把半成品當成果交出去。
#
# 為什麼是 PreToolUse 而不是別的事件：
#   sub agent 沒有「使用者送出訊息」這個事件可攔（它整段生命週期只有一個
#   prompt），Stop 類事件又太晚——那時 context 早就爆了、任務也已經被當成
#   完成回報出去。工具呼叫是 sub agent 迴圈裡唯一每一輪都會經過的關卡。
#
# 為什麼用 permissionDecision:"deny"：
#   PreToolUse 沒有 additionalContext 這種「不擋、只注入」的管道（那是
#   UserPromptSubmit 才有的）。deny 的 permissionDecisionReason 是唯一能在
#   sub agent 迴圈中途對它下達指示、而且模型看得到的通道。代價是這次工具
#   呼叫會被取消——所以指示裡必須明講「原本的工作不用做了」，否則模型會
#   以為只是這一步被擋、換個工具再試一次。
#
# 為什麼只 deny 一次（見 sa-<agent_id> 狀態檔）：
#   deny 是無差別的，擋掉的是「這次工具呼叫」而不是「某類工具」。持續 deny
#   的話，sub agent 連寫交接檔要用的 Write 都會被擋掉，它會陷入
#   「想寫→被擋→再試→被擋」的死鎖，最後帶著滿的 context 空手而回。
#   所以發過一次指示就記帳，之後一律放行。
#
# 為什麼不叫 sub agent 去跑 handoff skill：
#   那支 skill 寫的是**專案長期記憶**，而且會按任務主題去重、就地更新既有的
#   `type: project` 記憶檔。sub agent 手上的東西是任務內的接力棒（只在這一次
#   派工的上下文有意義），混進專案記憶會汙染主線，最糟的情況是覆蓋掉主 session
#   辛苦寫的專案記憶。所以交接檔獨立放在 STATE_DIR，格式自由、生命週期綁 agent。
#
# 為什麼不做 compact 邊界（isCompactSummary）歸零：
#   sub agent transcript 是否會出現 compact 邊界沒有樣本可驗，而且就算真的出現，
#   最壞情況只是誤觸發一次 deny——deny 對同一個 agent_id 只會發生一次，是
#   自限的。相對地，主 session 那邊誤觸發的代價是「使用者為了繼續工作才
#   compact，卻換來下一則訊息被劫持」，那才值得為它加邏輯。
#
# 為什麼不做 isSidechain 過濾：
#   check.sh 需要那個過濾是因為主 transcript 裡混著 subagent 的小 context。
#   這裡讀的是 sub agent 專屬檔，整個檔每一行都是 isSidechain:true，套用過濾
#   會把全部資料濾光、門檻永遠不觸發且完全靜默。
#
# 為什麼不在這裡順手清 7 天前的狀態檔：
#   check.sh 已經在每次使用者送出訊息時掃過 STATE_DIR 了。這支 hook 是
#   **每一次工具呼叫**都跑（最多 20 個 sub agent 並發），多跑一個 find 就是
#   把成本乘上工具呼叫次數。清掃交給 check.sh。
#
# hooks.json 為什麼給 timeout 5（比 check.sh 的 15 短）：
#   JSON 不能寫註解，理由記在這裡。這支是**每一次工具呼叫**都跑，而且會擋在
#   工具真正執行之前——逾時上限就是每個工具呼叫最壞情況要多等的秒數，乘上
#   最多 20 個並發 sub agent。正常路徑只有 1~2 個 jq，5 秒綽綽有餘；真的卡住
#   時 hook 逾時＝放行，損失一次交接，遠比拖慢每個工具呼叫划算。
#
# 可調環境變數：
#   CC_HANDOFF_SUBAGENT_THRESHOLD  sub agent 的觸發門檻（token），預設 300000。
#                                  與主 session 的 CC_HANDOFF_THRESHOLD 分開，
#                                  因為兩者調整的動機不同（主 session 是使用者
#                                  體感，sub agent 是任務切段粒度）。
#   CC_HANDOFF_DISABLE             設為 1 完全停用（與 check.sh 共用同一個開關）
#   CC_HANDOFF_STATE_DIR           狀態目錄，預設 ~/.claude/handoff-state
#   CC_HANDOFF_TRACE               設成檔案路徑則附加寫入收到的 payload，除錯用。
#                                  這支 hook 最大的失敗模式是「靜默地永遠不觸發」
#                                  （路徑推導錯、payload 沒有 agent_id 之類），
#                                  trace 是唯一能便宜證實它有在跑的手段。

set -uo pipefail

# DISABLE 先判：純環境變數比較，連 stdin 都不用讀
[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

THRESHOLD="${CC_HANDOFF_SUBAGENT_THRESHOLD:-300000}"
STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"

# 一次 jq 取完所有欄位，不用 check.sh 那種一欄一個 jq 的寫法：
# 那邊一輪對話只跑一次，這邊每一次工具呼叫都跑，行程數要壓到 1。
# 分隔字元用 \001 而不是 tab：tab 屬於 IFS whitespace，read 會把連續的
# tab 併成一個分隔符並吃掉頭尾空欄，空欄位（例如沒有 file_path）就會錯位。
# file_path 過 `strings`：join 遇到非字串元素會整個 jq 失敗，而 tool_input 的
# schema 是各工具自訂的（MCP 工具可能在同名 key 塞物件），不能假設它是字串。
agent_id=""; agent_type=""; transcript=""; tool_name=""; file_path=""
IFS=$'\001' read -r agent_id agent_type transcript tool_name file_path <<EOF
$(printf '%s' "$input" | jq -r '[.agent_id // "", .agent_type // "",
    .transcript_path // "", .tool_name // "",
    ((.tool_input.file_path | strings) // "")] | join("\u0001")' 2>/dev/null)
EOF

# 主 agent 的工具呼叫沒有 agent_id。這條路徑每一次工具呼叫都會走到，
# 必須零成本，所以判定放在能放的最前面（只落後於解析 payload 本身）。
[ -n "$agent_id" ] || exit 0

# agent_id 會變成檔名、也會被印回給模型看。不是純識別字就當作沒收到——
# 與其冒著把 ../ 拼進路徑的風險，不如放棄這次交接。
case "$agent_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

state="$STATE_DIR/sa-$agent_id"
handoff_file="$STATE_DIR/subagent-handoff-$agent_id.md"

# 已經發過指示 → 一律放行。放在讀 transcript 之前：這個分支是超標之後每一次
# 工具呼叫的必經之路，不該為它付 jq 掃整個 transcript 的錢。
[ -e "$state" ] && exit 0

# deny 當下要寫的就是交接檔本身 → 放行，否則第一步就自相矛盾。
# 只認 Write + 完全相同的路徑字串，不做正規化、不放行 Edit：
# 這個例外在實務上近乎 dead code（第一次 deny 之後狀態檔就存在，什麼都放行了），
# 只有「deny 那一瞬間剛好在寫同一個檔」這種巧合會用到，不值得為它擴大開口。
if [ "$tool_name" = "Write" ] && [ "$file_path" = "$handoff_file" ]; then
    exit 0
fi

[ -n "$transcript" ] || exit 0

# sub agent 有獨立的 transcript：主檔 <dir>/<session_id>.jsonl 去掉副檔名當成
# 目錄，底下是 subagents/agent-<agent_id>.jsonl。
#
# payload 的 transcript_path 在 sub agent 內到底指向主檔還是專屬檔沒有實測過，
# 所以兩種都涵蓋：basename 已經是 agent-<agent_id>.jsonl 就直接用，否則照上面
# 的規則推導。兩個候選都不存在就靜默退出——寧可漏掉，也不要因為猜錯路徑而報錯。
sa=""
if [ "${transcript##*/}" = "agent-$agent_id.jsonl" ]; then
    sa="$transcript"
elif [ -f "${transcript%.jsonl}/subagents/agent-$agent_id.jsonl" ]; then
    sa="${transcript%.jsonl}/subagents/agent-$agent_id.jsonl"
fi
[ -n "$sa" ] && [ -f "$sa" ] || exit 0

# 當下 context 用量 ＝ 最後一筆 assistant 的 usage 總和。
used=$(jq -r '
    if (.type == "assistant" and .message.usage != null) then
        ((.message.usage.input_tokens // 0)
        + (.message.usage.cache_creation_input_tokens // 0)
        + (.message.usage.cache_read_input_tokens // 0)
        + (.message.usage.output_tokens // 0) | tostring)
    else empty end
' "$sa" 2>/dev/null | tail -n 1)

# 空字串也走這條：sub agent 的第一次工具呼叫發生在第一筆 assistant 訊息
# 寫進 transcript 之前，那時沒有 usage 可讀，視為未達門檻。
case "$used" in
    '' | *[!0-9]*) exit 0 ;;
esac

[ "$used" -lt "$THRESHOLD" ] && exit 0

# 記帳一定要在 deny 之前，而且失敗就整個放棄（fail open）。
# 理由：整套「只 deny 一次」的保證完全建立在這個檔存在上。如果先 deny 才寫、
# 或寫失敗了還照樣 deny，接下來每一次工具呼叫都會重新 deny，連交接檔的 Write
# 都會被擋——正是上面要避免的死鎖。fail open 最多損失一次交接，fail closed
# 會直接吊死一個 sub agent。
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
printf '%s\n' "${agent_type:-unknown}" > "$state" 2>/dev/null || exit 0

# 註：續作的 sub agent 是新的 agent_id，若它也超標會寫到另一個
# subagent-handoff-<新 id>.md。每一代的 SubagentStop 都會報出自己那一份，
# 接力鏈不會斷；但舊的交接檔不會被合併或刪除，靠 STATE_DIR 的 7 天清掃收尾。
jq -n --arg f "$handoff_file" --argjson used "$used" --argjson threshold "$THRESHOLD" '
{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "【context 門檻自動交接】你這個 sub agent 目前 context 已用約 \($used) tokens，"
      + "達到門檻 \($threshold)。這次工具呼叫已被取消；接下來的工具呼叫不會再被擋，"
      + "你有足夠的額度完成下面的交接。\n\n"
      + "**立刻停止原本的工作**，改做這三件事然後結束回合：\n\n"
      + "1. 用 Write 把交接內容寫進這個絕對路徑：\($f)\n"
      + "   至少要涵蓋：任務目標 / 已完成 / 進行中與下一步 / 關鍵決策與原因 / "
      + "踩過的坑 / 相關檔案與指令。判準是：一個完全沒有這段對話、只讀得到這個檔的"
      + "新 sub agent，能不能正確接續。\n"
      + "2. 不要呼叫 handoff skill。那支寫的是專案長期記憶，你手上的是任務內的"
      + "接力棒，寫進去會汙染甚至覆蓋主線的專案記憶。\n"
      + "3. 結束回合，最終回覆**只**回報這三點：(a) 因 context 達上限已中止、"
      + "任務尚未完成；(b) 交接檔路徑 \($f)；(c) 請主 agent 以**相同**的 "
      + "agent_type 與**相同**的模型等級重新派一個 sub agent，並在 briefing 裡"
      + "要求它先讀該交接檔再續作。\n\n"
      + "**不要**把未完成的工作當成完成品回報，也不要在最終回覆裡塞半成品的結論"
      + "——主 agent 會據此判斷任務是否真的完成。"
    )
  }
}'

exit 0
