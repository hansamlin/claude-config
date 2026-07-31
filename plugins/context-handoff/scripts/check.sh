#!/usr/bin/env bash
# UserPromptSubmit hook：使用者送出訊息時檢查 context 用量，超過門檻就先交接。
#
# 為什麼掛在 UserPromptSubmit 而不是 Stop：
#   1. 這個事件只在「使用者實際送出訊息」時觸發，本身就證明有人在互動，
#      不必再猜 session 是不是無人值守的背景 job（舊版用 sessionKind=="bg"
#      排除，結果把使用者日常在用的 bg session 全擋掉了，門檻永遠不觸發）。
#   2. 攔截點落在使用者交派新任務的當下，Claude 還沒開始動工就先交接，
#      不會出現「做到一半被打斷」。
#   3. 因此也不需要預測下一輪成長量——直接看當下用量夠不夠門檻即可。
#
# 為什麼要自己算 token：hook 的 stdin payload 不含任何 context/token 欄位
# （只有 statusline 拿得到 .context_window），所以唯一來源是 transcript_path
# 裡最後一筆 assistant 訊息的 message.usage。
#
# 可調環境變數：
#   CC_HANDOFF_THRESHOLD  觸發門檻（token），預設 300000
#   CC_HANDOFF_MAX_NAGS   最多主動要求交接幾次，預設 3
#   CC_HANDOFF_LOOKBACK   往回掃幾筆 transcript 找 handoff 執行記錄，預設 300
#   CC_HANDOFF_DISABLE    設為 1 完全停用
#   CC_HANDOFF_STATE_DIR  狀態目錄，預設 ~/.claude/handoff-state（測試用來隔離）
#   CC_HANDOFF_TRACE      設成檔案路徑則附加寫入收到的 payload，除錯用

set -uo pipefail

THRESHOLD="${CC_HANDOFF_THRESHOLD:-300000}"
MAX_NAGS="${CC_HANDOFF_MAX_NAGS:-3}"
LOOKBACK="${CC_HANDOFF_LOOKBACK:-300}"
STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"
jq_in() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# subagent 也會收到 UserPromptSubmit，但它的 context 與主 session 無關，
# 交接要等主 agent 接手才有意義。agent_id / agent_type 兩個都認：文件說
# subagent 的 payload 會帶這兩個欄位，只認一個的話萬一另一個才是實際帶的，
# 就會在 subagent 裡誤觸發、把主 session 的交接額度用掉且完全靜默。
[ -n "$(jq_in '.agent_id // ""')$(jq_in '.agent_type // ""')" ] && exit 0

transcript=$(jq_in '.transcript_path // ""')
session_id=$(jq_in '.session_id // ""')
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ -n "$session_id" ] || exit 0

# 目前 context 大小＝最後一筆「非 sidechain」assistant 訊息的 usage 總和。
# isSidechain 過濾是必要的：一旦跑過 subagent，最後一筆會是 subagent 的小
# context，門檻就永遠不會到。
used=$(jq -r '
    select(.type == "assistant" and (.isSidechain != true) and .message.usage != null)
    | (.message.usage.input_tokens // 0)
    + (.message.usage.cache_creation_input_tokens // 0)
    + (.message.usage.cache_read_input_tokens // 0)
    + (.message.usage.output_tokens // 0)
' "$transcript" 2>/dev/null | tail -1)

case "$used" in
    '' | *[!0-9]*) exit 0 ;;
esac

[ "$used" -lt "$THRESHOLD" ] && exit 0

# handoff 到底跑了沒，以 transcript 為準而不是「我催過了」為準。
# additionalContext 只是注入指示，沒有任何機制保證 Claude 一定照做；
# 催一次就記帳收手的話，模型忽略一次就等於這個 session 再也不會交接。
# 只看尾端一段：compact 之後 context 會塌回去，先前那次 handoff 早就過期，
# 掃全檔會讓舊記錄永遠壓住後續的觸發。
if tail -n "$LOOKBACK" "$transcript" 2>/dev/null | jq -r '
    select(.type == "assistant" and (.isSidechain != true))
    | .message.content[]?
    | select(.type == "tool_use" and .name == "Skill")
    | .input.skill // ""
' 2>/dev/null | grep -q 'handoff'; then
    jq -n --argjson used "$used" '
    { systemMessage: "⚠️ 已交接過，context 目前約 \($used) tokens，建議盡快開新 session。" }'
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
nags="$STATE_DIR/nags-$session_id"

# 順手清掉 7 天前的殘留狀態檔
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

count=$(cat "$nags" 2>/dev/null)
case "$count" in
    '' | *[!0-9]*) count=0 ;;
esac

# 催過上限次數還是沒交接，就當使用者是刻意要繼續用，只留不打斷的提醒。
if [ "$count" -ge "$MAX_NAGS" ]; then
    jq -n --argjson used "$used" '
    { systemMessage: "⚠️ context 已達交接門檻（目前約 \($used) tokens），建議盡快開新 session。" }'
    exit 0
fi

printf '%s' "$((count + 1))" > "$nags" 2>/dev/null

# 用 additionalContext 而非 decision:"block"：block 會讓這次 prompt 直接作廢，
# Claude 沒有 turn 可以執行 handoff skill，就只剩一句提醒而沒有真的交接。
# additionalContext 把指示連同使用者的訊息一起送進去，Claude 照常有 turn，
# 才能實際呼叫 skill 把進度寫進記憶。
jq -n --argjson used "$used" --argjson threshold "$THRESHOLD" '
{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: (
      "【context 門檻自動交接】本 session 已用約 \($used) tokens，達到設定門檻 \($threshold)。\n"
      + "**先不要執行使用者這則訊息要求的工作。**請依序做完這三件事，然後結束回合：\n"
      + "1. 用 Skill 工具呼叫 handoff skill（可用技能清單裡是 `handoff` 或 "
      + "`context-handoff:handoff`，兩者同一支），把目前進度與關鍵決策寫進專案記憶。\n"
      + "2. 使用者這則訊息的內容本身也要寫進交接記錄，當作下一個 session 的第一件待辦。\n"
      + "3. 用一段話告訴使用者：context 已達門檻、進度已寫入記憶、請開新 session 接續。"
    )
  },
  systemMessage: "⚠️ context 已達門檻 \($threshold)（目前約 \($used) tokens），本次請求已改為先執行 handoff，請開新 session 接續。"
}'

exit 0
