#!/usr/bin/env bash
# SubagentStop hook：sub agent 收工時，如果它是「因為 context 達門檻被要求交接」
# 才收工的，就對**主 agent** 明說任務沒完成、交接檔在哪、要怎麼重派。
#
# 為什麼需要這一支（subagent-check.sh 明明已經下過指示了）：
#   那道指示只是寫給模型看的字串，sub agent 會不會照著回報「我沒做完」純粹是
#   模型順從性。它完全可能把半成品寫得像成品交出去，主 agent 就會採信。
#   這支 hook 讀的是狀態檔——「超標過」是 subagent-check.sh 落地的事實，
#   不是模型的自述——所以它是這整套機制真正的保險，也是唯一能讓主 agent
#   在 sub agent 不合作時仍然知道實情的管道。
#
# 為什麼用 additionalContext 而不是 decision:"block"：
#   block 的語意是「不准結束，繼續做」。但這個 sub agent 之所以被攔下來就是
#   因為 context 已經滿了，逼它繼續只會更快撞牆、而且會把交接檔寫好之後
#   累積的成果再賠進去。要接手的是**新的** sub agent，不是這一個。
#   additionalContext 會出現在父對話裡（主 agent 看得到），正好是要下指示的對象。
#
# 為什麼清掉 sa-<agent_id> 但絕不刪交接檔：
#   狀態檔的用途只到「這一輪要不要通知主 agent」為止，留著只會在 agent_id
#   萬一被重用時重複觸發。交接檔則是主 agent 接下來要餵給續作 sub agent 的
#   唯一輸入，刪掉整套機制就白做了。
#
# 可調環境變數：見 subagent-check.sh 檔頭，兩支共用同一組。

set -uo pipefail

[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"

# 分隔字元與 subagent-check.sh 同理，用 \001 避開 IFS whitespace 吃掉空欄的問題
agent_id=""; agent_type=""
IFS=$'\001' read -r agent_id agent_type <<EOF
$(printf '%s' "$input" | jq -r '[.agent_id // "", .agent_type // ""] | join("\u0001")' 2>/dev/null)
EOF

[ -n "$agent_id" ] || exit 0
case "$agent_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

state="$STATE_DIR/sa-$agent_id"
handoff_file="$STATE_DIR/subagent-handoff-$agent_id.md"

# 沒有狀態檔＝這個 sub agent 從頭到尾沒超標，是正常收工。絕不能干擾——
# 絕大多數 sub agent 都走這條路，這裡多說一句話就是對每一次派工的雜訊稅。
[ -e "$state" ] || exit 0

# agent_type 以 payload 為準，payload 沒有才退回 subagent-check.sh 當時記下來的。
# 兩邊都沒有時不要編一個出來——寧可叫主 agent 自己回想，也不要給錯的等級。
[ -n "$agent_type" ] || agent_type=$(cat "$state" 2>/dev/null)
case "$agent_type" in
    '' | unknown) agent_type="（payload 未提供，請沿用你原本指派的 agent_type）" ;;
esac

# 交接檔到底有沒有被寫出來，是唯一能機械查證「sub agent 有沒有照指示做」的點。
# 沒寫出來的話主 agent 必須知道——不然它會拿著一個不存在的路徑去 briefing 續作者。
if [ -f "$handoff_file" ]; then
    written="交接檔已寫出。"
else
    written="⚠️ 交接檔不存在——該 sub agent 沒有照指示寫出來，重派時只能靠它的最終回覆重建 context。"
fi

rm -f "$state" 2>/dev/null

jq -n --arg f "$handoff_file" --arg t "$agent_type" --arg w "$written" '
{
  hookSpecificOutput: {
    hookEventName: "SubagentStop",
    additionalContext: (
      "【sub agent context 達上限，任務尚未完成】\n"
      + "剛結束的這個 sub agent 是因為 context 用量達到門檻而被強制中止的，"
      + "**不是因為任務做完了**。請不要把它這次的回傳當成任務成果，也不要據此判定驗收。\n"
      + "- 交接檔：\($f)\n"
      + "- \($w)\n"
      + "- 原本的 agent_type：\($t)\n\n"
      + "接下來請以**相同**的 agent_type（\($t)）與**相同**的模型等級重新派一個 sub agent，"
      + "briefing 裡要明確要求它**先讀 \($f)**，再從交接檔的「進行中／下一步」續作。\n"
      + "續作的 sub agent 若再次達到門檻，會再產生一份新的交接檔並再次由這個機制通知你；"
      + "重複這個循環，直到某次 sub agent 是正常完成收工（不會再出現這則訊息）為止，"
      + "才可以採信它的任務結果。"
    )
  }
}'

exit 0
