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

# 附加一筆「Claude 真的呼叫了 handoff skill」的記錄
append_handoff_call() { # append_handoff_call <transcript> [skill_name]
    jq -n --arg s "${2:-context-handoff:handoff}" \
        '{type:"assistant", isSidechain:false,
          message:{content:[{type:"tool_use", name:"Skill", input:{skill:$s}}]}}' >> "$1"
}

run() { # run <session_id> <transcript> [agent_id] [agent_type]
    jq -n --arg s "$1" --arg t "$2" --arg a "${3:-}" --arg ty "${4:-}" \
        '{session_id:$s, transcript_path:$t, cwd:"/tmp",
          hook_event_name:"UserPromptSubmit", user_message:"接下來幫我改 X"}
         + (if $a == "" then {} else {agent_id:$a} end)
         + (if $ty == "" then {} else {agent_type:$ty} end)' \
        | bash "$HOOK"
}

ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }

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
export CC_HANDOFF_MAX_NAGS=3

echo "── 1. subagent 不觸發（agent_id / agent_type 兩種都要擋）"
make_transcript 999999 "" "$TMP/t1.jsonl"
check "payload 帶 agent_id → 靜默" EMPTY "$(run sess-1 "$TMP/t1.jsonl" subagent-uuid)"
check "只帶 agent_type → 也要靜默" EMPTY "$(run sess-1b "$TMP/t1.jsonl" "" Explore)"
check "未動用主 session 的催告額度" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-1 2>/dev/null)"

echo "── 2. transcript 不存在"
check "靜默不觸發" EMPTY "$(run sess-2 "$TMP/nope.jsonl")"

echo "── 3. 用量低於門檻"
make_transcript 299999 "" "$TMP/t3.jsonl"
check "靜默不觸發" EMPTY "$(run sess-3 "$TMP/t3.jsonl")"
check "未留下狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-3 2>/dev/null)"

echo "── 4. 用量達門檻 → 注入 handoff 指示"
make_transcript 310000 "" "$TMP/t4.jsonl"
out4=$(run sess-4 "$TMP/t4.jsonl")
check "hookEventName 正確" "UserPromptSubmit" \
    "$(printf '%s' "$out4" | jq -r '.hookSpecificOutput.hookEventName // ""')"
check "指名 handoff skill" "handoff" "$(ctx "$out4")"
check "叫模型先別做使用者要求的工作" "先不要執行" "$(ctx "$out4")"
check "叫使用者換 session" "開新 session" "$(ctx "$out4")"
check "同時給使用者 systemMessage" "systemMessage" "$out4"
check "催告次數記為 1" "1" "$(cat "$CC_HANDOFF_STATE_DIR"/nags-sess-4 2>/dev/null)"

echo "── 4b. 不可用 decision:block（block 不產生 turn，Claude 沒機會跑 skill）"
check "沒有 decision 欄位" EMPTY "$(printf '%s' "$out4" | jq -r '.decision // ""')"

echo "── 5. 模型忽略指示（transcript 查無 handoff）→ 必須繼續催"
check "第 2 次仍注入指示" "handoff" "$(ctx "$(run sess-4 "$TMP/t4.jsonl")")"
check "催告次數累加到 2" "2" "$(cat "$CC_HANDOFF_STATE_DIR"/nags-sess-4 2>/dev/null)"

echo "── 6. 催滿 MAX_NAGS 次 → 降級為不打斷的提醒"
out6=$(run sess-4 "$TMP/t4.jsonl")   # 第 3 次，仍注入
check "第 3 次仍注入" "handoff" "$(ctx "$out6")"
out6b=$(run sess-4 "$TMP/t4.jsonl")  # 第 4 次，超過上限
check "第 4 次不再注入" EMPTY "$(ctx "$out6b")"
check "第 4 次仍給提醒" "systemMessage" "$out6b"

echo "── 7. transcript 顯示 handoff 真的跑過 → 立刻收手"
make_transcript 310000 "" "$TMP/t7.jsonl"
append_handoff_call "$TMP/t7.jsonl"
out7=$(run sess-7 "$TMP/t7.jsonl")
check "不再注入指示" EMPTY "$(ctx "$out7")"
check "只給已交接的提醒" "已交接過" "$out7"
check "未動用催告額度" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-7 2>/dev/null)"
make_transcript 310000 "" "$TMP/t7b.jsonl"
append_handoff_call "$TMP/t7b.jsonl" handoff
check "skill 名寫成 handoff（未加 plugin 前綴）也認得" "已交接過" \
    "$(run sess-7b "$TMP/t7b.jsonl")"

echo "── 8. 回歸：sessionKind=bg 也必須觸發"
# 舊版 Stop hook 把 bg 一律排除，導致使用者日常在用的背景 session 永遠不交接
make_transcript 310000 bg "$TMP/t8.jsonl"
check "bg session 照樣注入指示" "handoff" "$(ctx "$(run sess-8 "$TMP/t8.jsonl")")"

echo "── 9. isSidechain 過濾（subagent 小 context 不可蓋過主 session）"
make_transcript 310000 "" "$TMP/t9.jsonl"
jq -n '{type:"assistant", isSidechain:true,
        message:{usage:{input_tokens:500, cache_creation_input_tokens:0,
                        cache_read_input_tokens:0, output_tokens:0}}}' >> "$TMP/t9.jsonl"
check "仍以主 session 用量判定 → 觸發" "handoff" "$(ctx "$(run sess-9 "$TMP/t9.jsonl")")"
# subagent 在 sidechain 裡跑 handoff 不算主 session 交接過
make_transcript 310000 "" "$TMP/t9b.jsonl"
jq -n '{type:"assistant", isSidechain:true,
        message:{content:[{type:"tool_use", name:"Skill", input:{skill:"handoff"}}]}}' \
    >> "$TMP/t9b.jsonl"
check "sidechain 裡的 handoff 不算數" "handoff" "$(ctx "$(run sess-9b "$TMP/t9b.jsonl")")"

echo "── 10. PostCompact reset → 清掉催告記錄可重新催"
jq -n '{session_id:"sess-4", hook_event_name:"PostCompact", trigger:"manual"}' | bash "$RESET"
check "nags 記錄已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-4 2>/dev/null)"
check "清除後重新注入指示" "handoff" "$(ctx "$(run sess-4 "$TMP/t4.jsonl")")"

echo "── 11. CC_HANDOFF_DISABLE=1"
check "完全停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run sess-11 "$TMP/t4.jsonl")"

echo "── 12. 輸出為合法 JSON"
check "觸發時輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run sess-12 "$TMP/t4.jsonl" | jq -r 'keys | join(",")')"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
