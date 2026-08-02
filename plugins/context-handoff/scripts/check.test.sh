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

# 附加一筆 compact 邊界（實測是頂層 isCompactSummary，掛在 user 訊息上）
append_compact_boundary() {
    jq -n '{type:"user", isSidechain:false, isCompactSummary:true,
            message:{role:"user", content:"This session is being continued..."}}' >> "$1"
}

# 附加一筆主線 assistant usage
append_usage() { # append_usage <transcript> <total>
    jq -n --argjson t "$2" \
        '{type:"assistant", isSidechain:false,
          message:{usage:{input_tokens:$t, cache_creation_input_tokens:0,
                          cache_read_input_tokens:0, output_tokens:0}}}' >> "$1"
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

echo "── 1. subagent 不觸發，但 --agent 啟動的主 session 要觸發"
make_transcript 999999 "" "$TMP/t1.jsonl"
check "payload 帶 agent_id → 靜默" EMPTY "$(run sess-1 "$TMP/t1.jsonl" subagent-uuid)"
check "未動用主 session 的催告額度" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-1 2>/dev/null)"
# agent_id 只在 subagent 內出現；`claude --agent foo` 的主 session 只帶
# agent_type，連它一起擋會讓那種 session 永遠不交接
check "只帶 agent_type（--agent 主 session）→ 照常觸發" "handoff" \
    "$(ctx "$(run sess-1b "$TMP/t1.jsonl" "" Explore)")"

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

echo "── 10. compact 邊界：用量必須從邊界之後重算"
# 這個 hook 在使用者送出訊息當下跑，那時 transcript 還沒有任何 compact 之後的
# assistant 訊息。直接取最後一筆會讀到 compact 前的舊數字，害使用者為了繼續
# 工作而 compact，卻換來下一則訊息被劫持去做多餘的交接。
make_transcript 310000 "" "$TMP/t10.jsonl"
append_compact_boundary "$TMP/t10.jsonl"
out10=$(run sess-10 "$TMP/t10.jsonl")
check "邊界後還沒有 usage → 靜默放行" EMPTY "$out10"
check "未動用催告額度" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-10 2>/dev/null)"

make_transcript 310000 "" "$TMP/t10b.jsonl"
append_compact_boundary "$TMP/t10b.jsonl"
append_usage "$TMP/t10b.jsonl" 48714
check "邊界後用量已塌回 48k → 靜默放行" EMPTY "$(run sess-10b "$TMP/t10b.jsonl")"

make_transcript 310000 "" "$TMP/t10c.jsonl"
append_compact_boundary "$TMP/t10c.jsonl"
append_usage "$TMP/t10c.jsonl" 320000
check "邊界後又漲回 320k → 照常觸發" "handoff" "$(ctx "$(run sess-10c "$TMP/t10c.jsonl")")"

make_transcript 310000 "" "$TMP/t10d.jsonl"
append_handoff_call "$TMP/t10d.jsonl"
append_compact_boundary "$TMP/t10d.jsonl"
append_usage "$TMP/t10d.jsonl" 320000
check "邊界前的 handoff 不算數，邊界後要重新催" "handoff" \
    "$(ctx "$(run sess-10d "$TMP/t10d.jsonl")")"

# sidechain 裡的 compact 邊界不是主 session 的邊界，不可拿來歸零
make_transcript 310000 "" "$TMP/t10e.jsonl"
jq -n '{type:"user", isSidechain:true, isCompactSummary:true,
        message:{role:"user", content:"subagent 的 compact"}}' >> "$TMP/t10e.jsonl"
check "sidechain 的 compact 邊界不算數" "handoff" \
    "$(ctx "$(run sess-10e "$TMP/t10e.jsonl")")"

echo "── 11. PostCompact reset → 清掉催告記錄可重新催"
jq -n '{session_id:"sess-4", hook_event_name:"PostCompact", trigger:"manual"}' | bash "$RESET"
check "nags 記錄已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-4 2>/dev/null)"
check "清除後重新注入指示" "handoff" "$(ctx "$(run sess-4 "$TMP/t4.jsonl")")"

echo "── 12. CC_HANDOFF_DISABLE=1"
check "完全停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run sess-11 "$TMP/t4.jsonl")"

echo "── 13. 輸出為合法 JSON"
check "觸發時輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run sess-12 "$TMP/t4.jsonl" | jq -r 'keys | join(",")')"

echo "── 14. 頂層腳本維持 POSIX sh 相容"
# install.sh / pull.sh 是使用者手動執行的腳本。有人打 `sh install.sh` 時，
# bash 是「逐段剖析、逐段執行」——bashism 造成的 syntax error 會等到前面
# 幾步都跑完、半套設定已經寫進 ~/.claude 之後才炸，訊息只有 syntax error，
# 不會說已經做了什麼。這種錯誤無法用執行期守衛防禦（開頭的檢查攔不到後面
# 才發生的剖析錯誤），唯一的辦法是保證整份檔案在 POSIX sh 底下剖析得過。
# 所以那兩支不能出現 process substitution、[[ ]]、陣列、${BASH_SOURCE[0]}、
# set -o pipefail 等 bash 專屬語法。
# statusline.sh 與 check.sh / reset.sh 不列入：它們只由 Claude Code 以指定的
# 直譯器呼叫，人不會手打 sh，沒必要為此限制它們能用的語法。
if command -v dash >/dev/null 2>&1; then POSIX_SH=dash; else POSIX_SH=sh; fi
REPO_ROOT=$(cd "$HERE/../../.." && pwd)
for s in install.sh pull.sh; do
    if [ ! -f "$REPO_ROOT/$s" ]; then
        echo "  ⏭️  $s 不在此處，略過（非 repo 內執行）"
        continue
    fi
    if err=$("$POSIX_SH" -n "$REPO_ROOT/$s" 2>&1); then
        echo "  ✅ $s 可被 $POSIX_SH 剖析"; pass=$((pass+1))
    else
        echo "  ❌ $s 引入了 bashism，$POSIX_SH -n 失敗：$(printf '%s' "$err" | head -2)"
        fail=$((fail+1))
    fi
done

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
