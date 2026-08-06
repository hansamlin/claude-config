#!/usr/bin/env bash
# subagent-check.sh / subagent-stop.sh 的分支驗證。
#
# 全程在 mktemp 目錄裡跑，用 CC_HANDOFF_STATE_DIR 隔離，不會碰到
# ~/.claude/handoff-state 的真實狀態。直接執行即可：
#   bash plugins/context-handoff/scripts/subagent-check.test.sh
#
# 這裡「假的」只有 payload 與 transcript 的形狀；被測的是真的腳本。
# transcript 形狀對齊實測樣本
# （~/.claude/projects/<slug>/<session>/subagents/agent-<id>.jsonl：
#  每一行都有 isSidechain:true 與 agentId，assistant 行帶 message.usage）。
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/subagent-check.sh"
STOP="$HERE/subagent-stop.sh"

TMP=$(mktemp -d)
export CC_HANDOFF_STATE_DIR="$TMP/state"
trap 'rm -rf "$TMP"' EXIT

# 假 sub agent transcript：一筆 assistant，usage 總和 = $2。
# 刻意保留 isSidechain:true —— 真實檔案就是這樣，而且這正是「不可套用
# check.sh 那個 isSidechain != true 過濾」的回歸證據：套了就全被濾光。
make_sa_transcript() { # make_sa_transcript <out> <total> <agent_id>
    mkdir -p "$(dirname "$1")"
    jq -n --argjson t "$2" --arg a "$3" \
        '{type:"assistant", isSidechain:true, agentId:$a,
          message:{usage:{input_tokens:$t, cache_creation_input_tokens:0,
                          cache_read_input_tokens:0, output_tokens:0}}}' > "$1"
}

run() { # run <transcript> [agent_id] [agent_type] [tool_name] [file_path]
    jq -n --arg t "$1" --arg a "${2:-}" --arg ty "${3:-}" \
          --arg tn "${4:-Read}" --arg fp "${5:-/tmp/whatever}" \
        '{session_id:"sess-x", transcript_path:$t, cwd:"/tmp",
          hook_event_name:"PreToolUse", tool_name:$tn,
          tool_input:{file_path:$fp}, tool_use_id:"toolu_1"}
         + (if $a == "" then {} else {agent_id:$a} end)
         + (if $ty == "" then {} else {agent_type:$ty} end)' \
        | bash "$HOOK"
}

run_stop() { # run_stop [agent_id] [agent_type]
    jq -n --arg a "${1:-}" --arg ty "${2:-}" \
        '{session_id:"sess-x", transcript_path:"/tmp/t.jsonl",
          hook_event_name:"SubagentStop",
          last_assistant_message:"做完了", stop_reason:"end_turn"}
         + (if $a == "" then {} else {agent_id:$a} end)
         + (if $ty == "" then {} else {agent_type:$ty} end)' \
        | bash "$STOP"
}

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }
reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
ctx()      { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }

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

export CC_HANDOFF_SUBAGENT_THRESHOLD=300000

echo "── 1. 主 agent 的工具呼叫（payload 無 agent_id）→ 必須完全靜默"
# 這條路徑每一次工具呼叫都會走到，任何輸出或副作用都是全域成本
make_sa_transcript "$TMP/main/sess/subagents/agent-aaa.jsonl" 999999 aaa
check "無 agent_id → 無輸出" EMPTY "$(run "$TMP/main/sess.jsonl")"
check "無 agent_id → 完全沒建立 state 目錄" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR" 2>/dev/null)"

echo "── 2. 有 agent_id、用量未達門檻 → 靜默放行"
make_sa_transcript "$TMP/p2/sess/subagents/agent-bbb.jsonl" 299999 bbb
check "未達門檻 → 無輸出" EMPTY "$(run "$TMP/p2/sess.jsonl" bbb general-purpose)"
check "未達門檻 → 不留狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-bbb" 2>/dev/null)"

echo "── 3. 達門檻 → deny + 指示"
make_sa_transcript "$TMP/p3/sess/subagents/agent-ccc.jsonl" 310000 ccc
out3=$(run "$TMP/p3/sess.jsonl" ccc general-purpose)
check "hookEventName 正確" "PreToolUse" \
    "$(printf '%s' "$out3" | jq -r '.hookSpecificOutput.hookEventName // ""')"
check "permissionDecision=deny" "deny" "$(decision "$out3")"
check "reason 含交接檔絕對路徑" "$CC_HANDOFF_STATE_DIR/subagent-handoff-ccc.md" \
    "$(reason "$out3")"
check "reason 叫它停止原本的工作" "立刻停止原本的工作" "$(reason "$out3")"
check "reason 帶「相同」的重派語意" "相同" "$(reason "$out3")"
check "reason 提到 agent_type 要一樣" "agent_type" "$(reason "$out3")"
check "reason 禁止把半成品當成品回報" "把未完成的工作當成完成品回報" "$(reason "$out3")"
# handoff skill 寫的是專案長期記憶且會就地覆蓋既有記憶檔，
# sub agent 的接力棒混進去會汙染主線
check "reason 明講不要用 handoff skill" "不要呼叫 handoff skill" "$(reason "$out3")"
check "建立了 state 檔 sa-ccc" "sa-ccc" \
    "$(ls "$CC_HANDOFF_STATE_DIR" 2>/dev/null | grep sa-ccc)"

echo "── 4. 回歸（最重要）：第二次工具呼叫必須放行，否則死鎖"
# deny 是無差別的——持續 deny 的話，sub agent 連寫交接檔用的 Write 都會被擋，
# 會卡在「想交接→被擋→再試→被擋」，帶著滿的 context 空手而回
check "state 已存在 → 第 2 次無輸出" EMPTY "$(run "$TMP/p3/sess.jsonl" ccc general-purpose)"
check "state 已存在 → 第 3 次仍無輸出" EMPTY \
    "$(run "$TMP/p3/sess.jsonl" ccc general-purpose Write /some/other/file)"

echo "── 5. 達門檻但這次就是要寫交接檔 → 放行"
make_sa_transcript "$TMP/p5/sess/subagents/agent-ddd.jsonl" 310000 ddd
check "Write 到交接檔 → 不 deny" EMPTY \
    "$(run "$TMP/p5/sess.jsonl" ddd general-purpose Write \
        "$CC_HANDOFF_STATE_DIR/subagent-handoff-ddd.md")"
check "放行時也不記帳（下一個工具呼叫才是攔截點）" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-ddd" 2>/dev/null)"
check "Write 到別的檔 → 照樣 deny" "deny" \
    "$(decision "$(run "$TMP/p5/sess.jsonl" ddd general-purpose Write /tmp/other.md)")"

echo "── 6. transcript_path 給主 session 檔 → 要能推導到 subagent 專屬檔"
# 規則：主檔 <dir>/<session_id>.jsonl 去掉副檔名當目錄，底下 subagents/agent-<id>.jsonl
mkdir -p "$TMP/p6"
jq -n '{type:"assistant", isSidechain:false,
        message:{usage:{input_tokens:1000, cache_creation_input_tokens:0,
                        cache_read_input_tokens:0, output_tokens:0}}}' > "$TMP/p6/sess.jsonl"
make_sa_transcript "$TMP/p6/sess/subagents/agent-eee.jsonl" 320000 eee
check "主檔用量才 1000，仍以 subagent 專屬檔判定 → deny" "deny" \
    "$(decision "$(run "$TMP/p6/sess.jsonl" eee general-purpose)")"

echo "── 7. transcript_path 直接給 subagent 專屬檔 → 同樣正確"
make_sa_transcript "$TMP/p7/sess/subagents/agent-fff.jsonl" 320000 fff
check "basename 已是 agent-<id>.jsonl → deny" "deny" \
    "$(decision "$(run "$TMP/p7/sess/subagents/agent-fff.jsonl" fff general-purpose)")"

echo "── 8. 推導不到檔案 → 靜默 exit 0，不可噴錯"
check "專屬檔不存在 → 無輸出" EMPTY "$(run "$TMP/p8/nope.jsonl" ggg general-purpose 2>&1)"
check "未建立狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-ggg" 2>/dev/null)"

echo "── 9. 並發：不同 agent_id 的狀態互不干擾"
# 本機 settings 允許 20 個並發 sub agent，state 用 session_id 當 key 會互相汙染
make_sa_transcript "$TMP/p9/sess/subagents/agent-hot.jsonl" 400000 hot
make_sa_transcript "$TMP/p9/sess/subagents/agent-cold.jsonl" 1000 cold
check "hot 超標 → deny" "deny" "$(decision "$(run "$TMP/p9/sess.jsonl" hot Explore)")"
check "cold 同 session 但未超標 → 靜默" EMPTY "$(run "$TMP/p9/sess.jsonl" cold Explore)"
check "hot 有狀態檔" "sa-hot" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-hot)"
check "cold 沒有狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-cold" 2>/dev/null)"
check "hot 被記帳後 cold 仍照常判定" EMPTY "$(run "$TMP/p9/sess.jsonl" cold Explore)"

echo "── 10. SubagentStop：沒超標過 → 完全靜默"
check "無 state 檔 → 無輸出" EMPTY "$(run_stop cold Explore)"
check "無 agent_id → 無輸出" EMPTY "$(run_stop)"

echo "── 11. SubagentStop：超標過 → 通知主 agent 重派"
# 這裡開始自己備妥 state 目錄，不要靠前面案例的副作用——否則實作一旦不建目錄，
# 這幾條就會因為 fixture 沒寫成功而以錯誤的理由變紅
mkdir -p "$CC_HANDOFF_STATE_DIR"
printf 'x' > "$CC_HANDOFF_STATE_DIR/subagent-handoff-hot.md"
out11=$(run_stop hot Explore)
check "hookEventName 正確" "SubagentStop" \
    "$(printf '%s' "$out11" | jq -r '.hookSpecificOutput.hookEventName // ""')"
check "明說任務尚未完成" "任務尚未完成" "$(ctx "$out11")"
check "叫主 agent 別把回傳當成果" "不要把它這次的回傳當成任務成果" "$(ctx "$out11")"
check "含交接檔絕對路徑" "$CC_HANDOFF_STATE_DIR/subagent-handoff-hot.md" "$(ctx "$out11")"
check "含「重新派」語意" "重新派一個 sub agent" "$(ctx "$out11")"
check "含「相同」語意" "相同" "$(ctx "$out11")"
check "含 agent_type 值" "Explore" "$(ctx "$out11")"
check "要求續作者先讀交接檔" "先讀" "$(ctx "$out11")"
check "偵測到交接檔存在" "交接檔已寫出" "$(ctx "$out11")"
# block 會逼 sub agent 繼續跑，但它的 context 已經滿了，繼續只會更糟
check "沒有 decision:block" EMPTY "$(printf '%s' "$out11" | jq -r '.decision // ""')"
check "事後 state 檔已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-hot" 2>/dev/null)"
check "交接檔絕不可被刪" "subagent-handoff-hot.md" \
    "$(ls "$CC_HANDOFF_STATE_DIR" | grep subagent-handoff-hot.md)"
check "清掉之後不再重複通知" EMPTY "$(run_stop hot Explore)"

echo "── 12. SubagentStop：sub agent 沒照指示寫交接檔 → 要警告主 agent"
# 「有沒有寫出交接檔」是這整套機制裡唯一能機械查證模型順從性的點
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-lazy"
out12=$(run_stop lazy Explore)
check "警告交接檔不存在" "交接檔不存在" "$(ctx "$out12")"

echo "── 13. SubagentStop：payload 沒帶 agent_type → 退回 state 檔記錄的值"
mkdir -p "$CC_HANDOFF_STATE_DIR"
printf '%s\n' code-simplifier > "$CC_HANDOFF_STATE_DIR/sa-noty"
check "用 subagent-check 當時記下的 agent_type" "code-simplifier" "$(ctx "$(run_stop noty)")"

echo "── 14. CC_HANDOFF_DISABLE=1 → 兩支都完全靜默"
make_sa_transcript "$TMP/p14/sess/subagents/agent-off.jsonl" 999999 off
check "check 停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run "$TMP/p14/sess.jsonl" off Explore)"
check "停用時不留狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-off" 2>/dev/null)"
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-off2"
check "stop 停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run_stop off2 Explore)"
check "停用時不清狀態檔" "sa-off2" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-off2)"

echo "── 15. 惡意 agent_id 不可拼進路徑"
make_sa_transcript "$TMP/p15/sess/subagents/agent-x.jsonl" 999999 x
check "含 ../ 的 agent_id → 靜默退出" EMPTY \
    "$(run "$TMP/p15/sess.jsonl" '../../etc/x' Explore)"

echo "── 15b. tool_input.file_path 不是字串（MCP 工具自訂 schema）→ 機制不可整個垮掉"
# jq 的 join 遇到非字串元素會整段失敗，五個變數全空、agent_id 也空 → 靜默放行，
# 等於這個 sub agent 從此不再受監控
make_sa_transcript "$TMP/p15b/sess/subagents/agent-weird.jsonl" 999999 weird
check "非字串 file_path 仍能 deny" "deny" "$(decision "$(jq -n --arg t "$TMP/p15b/sess.jsonl" \
    '{transcript_path:$t, hook_event_name:"PreToolUse", tool_name:"WeirdMcp",
      tool_input:{file_path:{nested:1}}, agent_id:"weird", agent_type:"Explore"}' \
    | bash "$HOOK")")"

echo "── 16. 輸出為合法 JSON"
make_sa_transcript "$TMP/p16/sess/subagents/agent-json.jsonl" 999999 json
check "deny 輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run "$TMP/p16/sess.jsonl" json Explore | jq -r 'keys | join(",")')"
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-json2"
check "stop 輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run_stop json2 Explore | jq -r 'keys | join(",")')"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
