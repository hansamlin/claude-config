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

run() { # run <session_id> <transcript> [stop_hook_active]
    jq -n --arg s "$1" --arg t "$2" --argjson a "${3:-false}" \
        '{session_id:$s, transcript_path:$t, hook_event_name:"Stop", stop_hook_active:$a}' \
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
export CC_HANDOFF_MIN_DELTA=20000

echo "── 1. stop_hook_active=true（防迴圈）"
make_transcript 999999 "" "$TMP/t1.jsonl"
check "靜默不觸發" EMPTY "$(run sess-1 "$TMP/t1.jsonl" true)"

echo "── 2. sessionKind=bg（背景 job 排除）"
make_transcript 999999 bg "$TMP/t2.jsonl"
check "靜默不觸發" EMPTY "$(run sess-2 "$TMP/t2.jsonl")"

echo "── 3. transcript 不存在"
check "靜默不觸發" EMPTY "$(run sess-3 "$TMP/nope.jsonl")"

echo "── 4. 用量低、預測不超過門檻"
make_transcript 100000 "" "$TMP/t4.jsonl"
check "靜默不觸發" EMPTY "$(run sess-4 "$TMP/t4.jsonl")"
check "未建立 armed marker" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/armed-sess-4 2>/dev/null)"

echo "── 5. 預測下一輪超過門檻 → arm（不打斷本輪）"
make_transcript 285000 "" "$TMP/t5.jsonl"
out5=$(run sess-5 "$TMP/t5.jsonl")
check "回 systemMessage 預警" "systemMessage" "$out5"
check "不是 block" EMPTY "$(printf '%s' "$out5" | jq -r '.decision // ""')"
check "建立 armed marker" "armed-sess-5" "$(ls "$CC_HANDOFF_STATE_DIR"/armed-sess-5 2>/dev/null)"

echo "── 6. 已 armed 的下一輪 → fire"
make_transcript 290000 "" "$TMP/t6.jsonl"
out6=$(run sess-5 "$TMP/t6.jsonl")
check "decision=block" "block" "$(printf '%s' "$out6" | jq -r '.decision // ""')"
check "reason 指名 handoff skill" "handoff" "$(printf '%s' "$out6" | jq -r '.reason')"
check "reason 叫使用者換 session" "開新 session" "$(printf '%s' "$out6" | jq -r '.reason')"
check "marker 已清除（不會重複開火）" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/armed-sess-5 2>/dev/null)"

echo "── 7. fire 過後同 session 不再重複 block（連兩輪）"
make_transcript 295000 "" "$TMP/t7.jsonl"
out7=$(run sess-5 "$TMP/t7.jsonl")
check "第 1 輪不 block" EMPTY "$(printf '%s' "$out7" | jq -r '.decision // ""')"
check "第 1 輪仍給提醒" "systemMessage" "$out7"
make_transcript 340000 "" "$TMP/t7b.jsonl"
check "第 2 輪（用量再升）仍不 block" EMPTY \
    "$(run sess-5 "$TMP/t7b.jsonl" | jq -r '.decision // ""')"

echo "── 8. 已超過門檻 → 立刻 fire 不等下一輪"
rm -rf "$CC_HANDOFF_STATE_DIR"
make_transcript 310000 "" "$TMP/t8.jsonl"
check "decision=block" "block" "$(run sess-8 "$TMP/t8.jsonl" | jq -r '.decision // ""')"
check "留下 fired 記錄" "fired-sess-8" "$(ls "$CC_HANDOFF_STATE_DIR"/fired-sess-8 2>/dev/null)"

echo "── 8b. PostCompact reset → 狀態清空可重新計算"
jq -n '{session_id:"sess-8", hook_event_name:"PostCompact", trigger:"manual"}' | bash "$RESET"
check "fired 記錄已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/fired-sess-8 2>/dev/null)"
check "armed 記錄已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/armed-sess-8 2>/dev/null)"

echo "── 9. isSidechain 過濾（subagent 小 context 不可蓋過主 session）"
make_transcript 310000 "" "$TMP/t9.jsonl"
jq -n '{type:"assistant", isSidechain:true,
        message:{usage:{input_tokens:500, cache_creation_input_tokens:0,
                        cache_read_input_tokens:0, output_tokens:0}}}' >> "$TMP/t9.jsonl"
rm -rf "$CC_HANDOFF_STATE_DIR"
check "仍以主 session 用量判定 → block" "block" \
    "$(run sess-9 "$TMP/t9.jsonl" | jq -r '.decision // ""')"

echo "── 10. CC_HANDOFF_DISABLE=1"
rm -rf "$CC_HANDOFF_STATE_DIR"
check "完全停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run sess-10 "$TMP/t8.jsonl")"

echo "── 11. 輸出為合法 JSON"
rm -rf "$CC_HANDOFF_STATE_DIR"
check "arm 輸出可被 jq 解析" "systemMessage" "$(run sess-11 "$TMP/t5.jsonl" | jq -r 'keys[0]')"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
