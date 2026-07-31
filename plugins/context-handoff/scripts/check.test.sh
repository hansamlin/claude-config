#!/usr/bin/env bash
# check.sh / reset.sh 的分支驗證。
#
# 全程在 mktemp 目錄裡跑，用 CC_HANDOFF_STATE_DIR 隔離，不會碰到
# ~/.claude/handoff-state 的真實狀態。直接執行即可：
#   bash plugins/context-handoff/scripts/check.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/check.sh"
RESET="$HERE/reset.sh"

TMP=$(mktemp -d)
export CC_HANDOFF_STATE_DIR="$TMP/state"
trap 'rm -rf "$TMP"' EXIT

# 產生假 transcript：一筆非 sidechain assistant 訊息，usage 總和 = $1
make_transcript() {
    local total="$1" kind="${2:-}" out="$3" body
    if [ -n "$kind" ]; then
        body=$(jq -n --argjson t "$total" --arg k "$kind" \
            '{type:"assistant", isSidechain:false, sessionKind:$k,
              message:{usage:{input_tokens:$t, cache_creation_input_tokens:0,
                              cache_read_input_tokens:0, output_tokens:0}}}')
    else
        body=$(jq -n --argjson t "$total" \
            '{type:"assistant", isSidechain:false,
              message:{usage:{input_tokens:$t, cache_creation_input_tokens:0,
                              cache_read_input_tokens:0, output_tokens:0}}}')
    fi
    printf '%s\n' "$body" > "$out"
}

run() { # run <session_id> <transcript> [agent_id]
    jq -n --arg s "$1" --arg t "$2" --arg a "${3:-}" \
        '{session_id:$s, transcript_path:$t, cwd:"/tmp",
          hook_event_name:"UserPromptSubmit", user_message:"接下來幫我改 X"}
         + (if $a == "" then {} else {agent_id:$a, agent_type:"Explore"} end)' \
        | bash "$HOOK"
}

pass=0; fail=0
check() { # check <label> <expected-substring|EMPTY> <actual>
    if [ "$2" = "EMPTY" ]; then
        if [ -z "$3" ]; then echo "  ✅ $1"; pass=$((pass+1));
        else echo "  ❌ $1 — 預期無輸出，實得: $3"; fail=$((fail+1)); fi
    else
        case "$3" in
            *"$2"*) echo "  ✅ $1"; pass=$((pass+1)) ;;
            *) echo "  ❌ $1 — 預期含 '$2'，實得: $3"; fail=$((fail+1)) ;;
        esac
    fi
}

export CC_HANDOFF_THRESHOLD=300000

echo "── 1. subagent（payload 帶 agent_id）不觸發"
make_transcript 999999 "" "$TMP/t1.jsonl"
check "靜默不觸發" EMPTY "$(run sess-1 "$TMP/t1.jsonl" subagent-uuid)"
check "未建立 fired 記錄" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/fired-sess-1 2>/dev/null)"

echo "── 2. transcript 不存在"
check "靜默不觸發" EMPTY "$(run sess-2 "$TMP/nope.jsonl")"

echo "── 3. 用量低於門檻"
make_transcript 299999 "" "$TMP/t3.jsonl"
check "靜默不觸發" EMPTY "$(run sess-3 "$TMP/t3.jsonl")"
check "未建立 fired 記錄" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/fired-sess-3 2>/dev/null)"

echo "── 4. 用量達門檻 → 注入 handoff 指示"
make_transcript 310000 "" "$TMP/t4.jsonl"
out4=$(run sess-4 "$TMP/t4.jsonl")
ctx4=$(printf '%s' "$out4" | jq -r '.hookSpecificOutput.additionalContext // ""')
check "hookEventName 正確" "UserPromptSubmit" \
    "$(printf '%s' "$out4" | jq -r '.hookSpecificOutput.hookEventName // ""')"
check "指名 handoff skill" "handoff" "$ctx4"
check "叫模型先別做使用者要求的工作" "先不要執行" "$ctx4"
check "叫使用者換 session" "開新 session" "$ctx4"
check "同時給使用者 systemMessage" "systemMessage" "$out4"
check "留下 fired 記錄" "fired-sess-4" "$(ls "$CC_HANDOFF_STATE_DIR"/fired-sess-4 2>/dev/null)"

echo "── 4b. 不可用 decision:block（block 不產生 turn，Claude 沒機會跑 skill）"
check "沒有 decision 欄位" EMPTY "$(printf '%s' "$out4" | jq -r '.decision // ""')"

echo "── 5. 同 session 第二次送出 → 只提醒不再注入指示"
make_transcript 340000 "" "$TMP/t5.jsonl"
out5=$(run sess-4 "$TMP/t5.jsonl")
check "仍給 systemMessage 提醒" "systemMessage" "$out5"
check "不再注入 additionalContext" EMPTY \
    "$(printf '%s' "$out5" | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "── 6. 回歸：sessionKind=bg 也必須觸發"
# 舊版 Stop hook 把 bg 一律排除，導致使用者日常在用的背景 session 永遠不交接
make_transcript 310000 bg "$TMP/t6.jsonl"
check "bg session 照樣注入指示" "handoff" \
    "$(run sess-6 "$TMP/t6.jsonl" | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "── 7. isSidechain 過濾（subagent 小 context 不可蓋過主 session）"
make_transcript 310000 "" "$TMP/t7.jsonl"
jq -n '{type:"assistant", isSidechain:true,
        message:{usage:{input_tokens:500, cache_creation_input_tokens:0,
                        cache_read_input_tokens:0, output_tokens:0}}}' >> "$TMP/t7.jsonl"
check "仍以主 session 用量判定 → 觸發" "handoff" \
    "$(run sess-7 "$TMP/t7.jsonl" | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "── 8. PostCompact reset → 清掉記錄可重新觸發"
jq -n '{session_id:"sess-4", hook_event_name:"PostCompact", trigger:"manual"}' | bash "$RESET"
check "fired 記錄已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/fired-sess-4 2>/dev/null)"
check "清除後再次送出會重新注入指示" "handoff" \
    "$(run sess-4 "$TMP/t5.jsonl" | jq -r '.hookSpecificOutput.additionalContext // ""')"

echo "── 9. CC_HANDOFF_DISABLE=1"
check "完全停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run sess-9 "$TMP/t4.jsonl")"

echo "── 10. 輸出為合法 JSON"
check "觸發時輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run sess-10 "$TMP/t4.jsonl" | jq -r 'keys | join(",")')"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
