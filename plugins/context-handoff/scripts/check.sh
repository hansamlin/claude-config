#!/usr/bin/env bash
# Stop hook：監看 session context 用量，接近門檻時自動觸發 handoff。
#
# 為什麼要自己算 token：hook 的 stdin payload 不含任何 context/token 欄位
# （只有 statusline 拿得到 .context_window），所以唯一來源是 transcript_path
# 裡最後一筆 assistant 訊息的 message.usage。
#
# 行為（對應「下一輪會超過就在下一輪完成後 handoff」）：
#   本輪結束 → 預測下一輪用量 > 門檻 → 寫 armed marker，本輪不打斷
#   下一輪結束 → 看到 marker → 回 decision:block，要求 Claude 跑 handoff skill
#   已經超過門檻 → 不等下一輪，立刻觸發
#
# 可調環境變數：
#   CC_HANDOFF_THRESHOLD  觸發門檻（token），預設 300000
#   CC_HANDOFF_MIN_DELTA  預測下一輪成長量的下限，預設 20000
#   CC_HANDOFF_DISABLE    設為 1 完全停用
#   CC_HANDOFF_STATE_DIR  狀態目錄，預設 ~/.claude/handoff-state（測試用來隔離）
#   CC_HANDOFF_TRACE      設成檔案路徑則附加寫入收到的 payload，除錯用

set -uo pipefail

THRESHOLD="${CC_HANDOFF_THRESHOLD:-300000}"
MIN_DELTA="${CC_HANDOFF_MIN_DELTA:-20000}"
STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"
jq_in() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# 本 hook 讓 Claude 續跑時不可再次觸發，否則無限迴圈
[ "$(jq_in '.stop_hook_active // false')" = "true" ] && exit 0

# subagent 的 context 與主 session 無關
[ -n "$(jq_in '.agent_id // ""')" ] && exit 0

transcript=$(jq_in '.transcript_path // ""')
session_id=$(jq_in '.session_id // ""')
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ -n "$session_id" ] || exit 0

# 背景 job 不觸發：使用者不會去「換 session」，自動寫記憶反而是副作用
if [ "$(jq -r 'select(.sessionKind != null) | .sessionKind' "$transcript" 2>/dev/null | head -1)" = "bg" ]; then
    exit 0
fi

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

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
marker="$STATE_DIR/armed-$session_id"
state="$STATE_DIR/used-$session_id"
fired="$STATE_DIR/fired-$session_id"

# 順手清掉 7 天前的殘留狀態檔
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

prev=$(cat "$state" 2>/dev/null)
case "$prev" in
    '' | *[!0-9]*) prev=0 ;;
esac
printf '%s' "$used" > "$state" 2>/dev/null

fire() {
    rm -f "$marker" 2>/dev/null
    : > "$fired"
    jq -n --argjson used "$used" --argjson threshold "$THRESHOLD" '
    {
      decision: "block",
      reason: (
        "【context 門檻自動交接】本 session 已用約 \($used) tokens，達到設定門檻 \($threshold)。\n"
        + "請立刻依序做完這三件事，然後停止，不要再繼續原本的工作：\n"
        + "1. 用 Skill 工具呼叫 handoff skill（可用技能清單裡是 `handoff` 或 "
        + "`context-handoff:handoff`，兩者同一支），把目前進度與關鍵決策寫進專案記憶。\n"
        + "2. 用一段話告訴使用者：context 已達門檻、進度已寫入記憶、請開新 session 接續。\n"
        + "3. 結束回合。若使用者原本的任務尚未完成，交接內容要寫清楚下一步從哪裡接。"
      )
    }'
    exit 0
}

# 一個 session 只強制交接一次。使用者選擇繼續用就尊重他，
# 之後只給不阻斷的提醒，否則每輪都被 block 會沒辦法工作。
if [ -f "$fired" ]; then
    jq -n --argjson used "$used" '
    { systemMessage: "⚠️ context 已達交接門檻（目前約 \($used) tokens），建議盡快開新 session。" }'
    exit 0
fi

# armed 過了 → 這輪就是「下一輪」，開火
[ -f "$marker" ] && fire

# 已經超過門檻 → 不等了，立刻開火
[ "$used" -ge "$THRESHOLD" ] && fire

# 預測下一輪：用本輪實際成長量，設下限避免成長極小時拖到爆掉才觸發
delta=$((used - prev))
[ "$delta" -lt "$MIN_DELTA" ] && delta="$MIN_DELTA"

if [ $((used + delta)) -ge "$THRESHOLD" ]; then
    : > "$marker"
    jq -n --argjson used "$used" --argjson next "$((used + delta))" --argjson threshold "$THRESHOLD" '
    {
      systemMessage: "⚠️ context \($used) tokens，預估下一輪約 \($next) 會達門檻 \($threshold)；下一輪結束後將自動 handoff。"
    }'
fi

exit 0
