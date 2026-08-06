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

# permission_mode 預設帶 "auto"：實測 trace（trace-sa.jsonl 66 筆 +
# trace-acc.jsonl 16 筆）裡每一筆 PreToolUse 都有這個欄位，值都是 auto。
# 讓預設 fixture 貼近實測形狀，才不會讓「非 plan 一律照常 deny」變成只在
# 「欄位不存在」時才被驗到。傳空字串可模擬完全沒有這個欄位的 payload。
run() { # run <transcript> [agent_id] [agent_type] [tool_name] [file_path] [permission_mode]
    jq -n --arg t "$1" --arg a "${2:-}" --arg ty "${3:-}" \
          --arg tn "${4:-Read}" --arg fp "${5:-/tmp/whatever}" \
          --arg pm "${6-auto}" \
        '{session_id:"sess-x", transcript_path:$t, cwd:"/tmp",
          hook_event_name:"PreToolUse", tool_name:$tn,
          tool_input:{file_path:$fp}, tool_use_id:"toolu_1"}
         + (if $a == "" then {} else {agent_id:$a} end)
         + (if $ty == "" then {} else {agent_type:$ty} end)
         + (if $pm == "" then {} else {permission_mode:$pm} end)' \
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
# 刻意沒有 ctx() helper：subagent-stop.sh 在任何路徑下 stdout 都必須是空的，
# 「解析 stop 的輸出」這件事本身就是壞規格（見第 11 組）。

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
#
# 這裡（以及底下每一條「期望 deny」的案例）刻意用 general-purpose 而不是 Explore：
# 2.2.1 起 Explore / Plan 進了 CC_HANDOFF_SUBAGENT_SKIP_TYPES 預設清單，用它們
# 當 fixture 會讓斷言變成 vacuous——靜默是因為被跳過，不是因為被測的分支對了。
make_sa_transcript "$TMP/p9/sess/subagents/agent-hot.jsonl" 400000 hot
make_sa_transcript "$TMP/p9/sess/subagents/agent-cold.jsonl" 1000 cold
check "hot 超標 → deny" "deny" "$(decision "$(run "$TMP/p9/sess.jsonl" hot general-purpose)")"
check "cold 同 session 但未超標 → 靜默" EMPTY "$(run "$TMP/p9/sess.jsonl" cold general-purpose)"
check "hot 有狀態檔" "sa-hot" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-hot)"
check "cold 沒有狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-cold" 2>/dev/null)"
check "hot 被記帳後 cold 仍照常判定" EMPTY "$(run "$TMP/p9/sess.jsonl" cold general-purpose)"

echo "── 10. SubagentStop：沒超標過 → 完全靜默"
check "無 state 檔 → 無輸出" EMPTY "$(run_stop cold Explore 2>&1)"
check "無 agent_id → 無輸出" EMPTY "$(run_stop 2>&1)"

echo "── 11. SubagentStop：超標過 → 只清 state，stdout/stderr 都必須是空的"
# 這是 2.2.1 修掉的線上缺陷：舊版在這條路徑吐 hookSpecificOutput.additionalContext。
# 根因不是「harness 不認得那個形狀」——它完全認得，schema 的 .describe() 原文是
# "non-error feedback delivered to the subagent; the subagent continues so it can
# act on it"，規格語意就是「餵回 sub agent 並讓它續跑」。我們選錯了欄位。
# 已結束的 sub agent 被續跑，下一次工具呼叫時 state 已被 rm 掉 → 重新 deny → 無限迴圈。
# 對照實驗（唯一變因是 stdout）：有 stdout → 32 次 deny、跑不完；無 stdout → 1 次 deny、正常結束。
#
# 所有 run_stop 斷言一律帶 2>&1：消費端的判定是
#   if (U.stdout && U.stdout.trim() || U.stderr && U.stderr.trim()) 續跑
# ——**stderr 一樣算**。只看 stdout 的話，`set -u` unbound variable、重導向失敗
# 這類洩漏會整批漏掉。斷言的是「沒有輸出」本身，不是輸出的內容。
#
# 這裡開始自己備妥 state 目錄，不要靠前面案例的副作用——否則實作一旦不建目錄，
# 這幾條就會因為 fixture 沒寫成功而以錯誤的理由變紅
mkdir -p "$CC_HANDOFF_STATE_DIR"
printf 'x' > "$CC_HANDOFF_STATE_DIR/subagent-handoff-hot.md"
out11=$(run_stop hot Explore 2>&1)
check "stdout 完全為空（任何輸出都會讓 sub agent 被續跑）" EMPTY "$out11"
check "事後 state 檔已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-hot" 2>/dev/null)"
check "交接檔絕不可被刪" "subagent-handoff-hot.md" \
    "$(ls "$CC_HANDOFF_STATE_DIR" | grep subagent-handoff-hot.md)"
check "清掉之後再跑一次仍然靜默" EMPTY "$(run_stop hot Explore 2>&1)"

echo "── 12. SubagentStop：sub agent 沒照指示寫交接檔 → 照樣靜默，只清 state"
# 舊版會在這裡吐「⚠️ 交接檔不存在」的警告；那條通道已證實有害，
# 「交接檔沒寫出來」現在只能由主 agent 從 sub agent 的最終回覆看出來。
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-lazy"
out12=$(run_stop lazy Explore 2>&1)
check "交接檔不存在時也不可有輸出" EMPTY "$out12"
check "state 仍然被清掉" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-lazy" 2>/dev/null)"

echo "── 13. SubagentStop：payload 沒帶 agent_type → 不可噴錯，仍靜默清理"
# agent_type 對這支 hook 已經完全沒有用途（不再組任何訊息），
# 但缺欄位不能讓 set -u 之類的東西把腳本弄爛。
mkdir -p "$CC_HANDOFF_STATE_DIR"
printf '%s\n' code-simplifier > "$CC_HANDOFF_STATE_DIR/sa-noty"
check "無 agent_type → 無輸出" EMPTY "$(run_stop noty 2>&1)"
check "無 agent_type → state 仍被清掉" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-noty" 2>/dev/null)"

echo "── 14. CC_HANDOFF_DISABLE=1 → 兩支都完全靜默"
make_sa_transcript "$TMP/p14/sess/subagents/agent-off.jsonl" 999999 off
check "check 停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run "$TMP/p14/sess.jsonl" off general-purpose)"
check "停用時不留狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-off" 2>/dev/null)"
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-off2"
check "stop 停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run_stop off2 Explore 2>&1)"
check "停用時不清狀態檔" "sa-off2" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-off2)"

echo "── 15. 惡意 agent_id 不可拼進路徑"
make_sa_transcript "$TMP/p15/sess/subagents/agent-x.jsonl" 999999 x
check "含 ../ 的 agent_id → 靜默退出" EMPTY \
    "$(run "$TMP/p15/sess.jsonl" '../../etc/x' general-purpose)"

echo "── 15b. tool_input.file_path 不是字串（MCP 工具自訂 schema）→ 機制不可整個垮掉"
# jq 的 join 遇到非字串元素會整段失敗，五個變數全空、agent_id 也空 → 靜默放行，
# 等於這個 sub agent 從此不再受監控
make_sa_transcript "$TMP/p15b/sess/subagents/agent-weird.jsonl" 999999 weird
check "非字串 file_path 仍能 deny" "deny" "$(decision "$(jq -n --arg t "$TMP/p15b/sess.jsonl" \
    '{transcript_path:$t, hook_event_name:"PreToolUse", tool_name:"WeirdMcp",
      tool_input:{file_path:{nested:1}}, agent_id:"weird", agent_type:"general-purpose"}' \
    | bash "$HOOK")")"

echo "── 16. 輸出為合法 JSON（只有 check 會輸出；stop 一律不輸出）"
make_sa_transcript "$TMP/p16/sess/subagents/agent-json.jsonl" 999999 json
check "deny 輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run "$TMP/p16/sess.jsonl" json general-purpose | jq -r 'keys | join(",")')"
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-json2"
check "stop 沒有任何 stdout 可解析" EMPTY "$(run_stop json2 Explore 2>&1)"

echo "── 17. 跨檔回歸：check 建 state → stop 收工，全程 stop 不可吐 stdout"
# 這個 bug 在 52 條斷言全綠的情況下仍然漏掉，就是因為它出在兩支腳本的互動上：
# 單看 subagent-check.sh 沒問題、單看 subagent-stop.sh 也「照規格」輸出，
# 合起來才變成「stop 吐 stdout → sub agent 被續跑 → state 已被 rm → 重新 deny」的迴圈。
# 所以這裡不手工造 state，一律讓 subagent-check.sh 自己把它寫出來。
make_sa_transcript "$TMP/p17/sess/subagents/agent-xfile.jsonl" 400000 xfile
check "第 1 步：check 超標 → deny" "deny" \
    "$(decision "$(run "$TMP/p17/sess.jsonl" xfile general-purpose)")"
check "第 1 步的副作用：state 由 check 真的寫出來了" "sa-xfile" \
    "$(ls "$CC_HANDOFF_STATE_DIR" 2>/dev/null | grep sa-xfile)"
check "第 2 步：check 的第二次呼叫已放行（沒有第二次 deny）" EMPTY \
    "$(run "$TMP/p17/sess.jsonl" xfile general-purpose)"
out17=$(run_stop xfile general-purpose 2>&1)
check "第 3 步：stop 的 stdout 必須為空" EMPTY "$out17"
check "第 3 步：state 檔已被 stop 移除" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-xfile" 2>/dev/null)"

echo "── 18. skip 清單：寫不出交接檔的 agent_type 一律不攔"
# Explore / Plan 的工具集是「All tools except Agent, Artifact, ExitPlanMode,
# Edit, Write, NotebookEdit」——deny 訊息第 1 點叫它用 Write 寫交接檔，它根本
# 執行不了。攔了只是白白吃掉一次工具呼叫、什麼都沒留下，比不攔更糟。
make_sa_transcript "$TMP/p18/sess/subagents/agent-exp.jsonl" 999999 exp
check "Explore 超標 → 完全無輸出" EMPTY "$(run "$TMP/p18/sess.jsonl" exp Explore 2>&1)"
check "Explore 超標 → 不可寫 state 檔（沒發過指示就沒有「已發過」可記）" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-exp" 2>/dev/null)"
make_sa_transcript "$TMP/p18/sess/subagents/agent-pln.jsonl" 999999 pln
check "Plan 超標 → 完全無輸出" EMPTY "$(run "$TMP/p18/sess.jsonl" pln Plan 2>&1)"
check "Plan 超標 → 不可寫 state 檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-pln" 2>/dev/null)"

echo "── 18b. skip 比對必須是整個 token 相等，不可寫成 substring / prefix"
# 寫寬了的後果是靜默失效：使用者自訂的 Explorer 之類會被誤跳過，永遠不交接
make_sa_transcript "$TMP/p18/sess/subagents/agent-expr.jsonl" 999999 expr
check "Explorer（多一個字元）→ 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p18/sess.jsonl" expr Explorer)")"
make_sa_transcript "$TMP/p18/sess/subagents/agent-plan2.jsonl" 999999 plan2
check "Planner → 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p18/sess.jsonl" plan2 Planner)")"
make_sa_transcript "$TMP/p18/sess/subagents/agent-gp.jsonl" 999999 gp
check "general-purpose → 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p18/sess.jsonl" gp general-purpose)")"

echo "── 18c. CC_HANDOFF_SUBAGENT_SKIP_TYPES 必須可覆寫"
# 內建 agent 的工具集會變、使用者也會自訂沒有 Write 的 agent，
# 這份清單必然腐爛。寫死的話唯一修法是改 plugin。
make_sa_transcript "$TMP/p18/sess/subagents/agent-exp2.jsonl" 999999 exp2
check "覆寫後 Explore 不再被跳過 → 照常 deny" "deny" \
    "$(decision "$(CC_HANDOFF_SUBAGENT_SKIP_TYPES='my-agent' \
        run "$TMP/p18/sess.jsonl" exp2 Explore)")"
make_sa_transcript "$TMP/p18/sess/subagents/agent-mine.jsonl" 999999 mine
check "覆寫清單裡新指定的 type 被跳過" EMPTY \
    "$(CC_HANDOFF_SUBAGENT_SKIP_TYPES='my-agent' \
        run "$TMP/p18/sess.jsonl" mine my-agent 2>&1)"
check "被跳過者不寫 state 檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-mine" 2>/dev/null)"
# 空字串必須真的代表「一個都不要跳過」，不可退回預設值——否則使用者沒有任何
# 辦法表達這個意圖（這就是這個變數用 `-` 而不是 `:-` 的原因）
make_sa_transcript "$TMP/p18/sess/subagents/agent-exp3.jsonl" 999999 exp3
check "設成空字串＝空清單，Explore 照常 deny" "deny" \
    "$(decision "$(CC_HANDOFF_SUBAGENT_SKIP_TYPES='' \
        run "$TMP/p18/sess.jsonl" exp3 Explore)")"

echo "── 19. permission_mode=plan → 不攔（plan mode 下寫檔是白名單制，交接檔不在名單內）"
# binary 反查（Claude Code 2.1.223）：plan mode 阻擋訊息是
#   Cannot write to <path> while in plan mode
# 白名單只有 Plan files / Workflow script files / Scratchpad files / Job tmp
# 這幾類；交接檔寫在 $STATE_DIR（預設 ~/.claude/handoff-state/），不在其中。
# 症狀與 Explore/Plan 完全相同：取消一次工具呼叫，然後叫它去寫一個寫不了的檔。
# 而且這條比 agent_type 那條常見得多——sub agent 繼承主 session 的 permission
# mode，使用者在 plan mode 下派工時**任何** agent_type 都會中招。
make_sa_transcript "$TMP/p19/sess/subagents/agent-pm1.jsonl" 999999 pm1
check "plan mode + general-purpose 超標 → 完全無輸出" EMPTY \
    "$(run "$TMP/p19/sess.jsonl" pm1 general-purpose Read /tmp/whatever plan 2>&1)"
check "plan mode → 不可寫 state 檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-pm1" 2>/dev/null)"

echo "── 19b. 其餘 permission_mode 一律照常 deny（防判定寫太寬）"
make_sa_transcript "$TMP/p19/sess/subagents/agent-pm2.jsonl" 999999 pm2
check "permission_mode=auto（實測值）→ 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p19/sess.jsonl" pm2 general-purpose Read /tmp/whatever auto)")"
make_sa_transcript "$TMP/p19/sess/subagents/agent-pm3.jsonl" 999999 pm3
check "permission_mode=default → 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p19/sess.jsonl" pm3 general-purpose Read /tmp/whatever default)")"
make_sa_transcript "$TMP/p19/sess/subagents/agent-pm4.jsonl" 999999 pm4
check "permission_mode=acceptEdits → 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p19/sess.jsonl" pm4 general-purpose Read /tmp/whatever acceptEdits)")"
# 欄位不存在時不可誤判成 plan——舊版 payload 或未來欄位改名都會走這條
make_sa_transcript "$TMP/p19/sess/subagents/agent-pm5.jsonl" 999999 pm5
check "完全沒有 permission_mode 欄位 → 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p19/sess.jsonl" pm5 general-purpose Read /tmp/whatever "")")"
# 「plan」只認整個值相等，不可 substring
make_sa_transcript "$TMP/p19/sess/subagents/agent-pm6.jsonl" 999999 pm6
check "permission_mode=planning（多字元）→ 照常 deny" "deny" \
    "$(decision "$(run "$TMP/p19/sess.jsonl" pm6 general-purpose Read /tmp/whatever planning)")"

echo "── 20. subagent-stop.sh：exec 之後 CC_HANDOFF_TRACE 仍必須寫得出來"
# `exec >/dev/null 2>&1` 只塞住 stdout/stderr，trace 是 `>>` 到檔案，不受影響。
# 這條是防「為了不輸出而把 trace 一起弄壞」的回歸——trace 是這支 hook 唯一
# 能便宜證實它有在跑的手段。
printf '%s\n' general-purpose > "$CC_HANDOFF_STATE_DIR/sa-trace1"
trace_out=$(CC_HANDOFF_TRACE="$TMP/trace.jsonl" run_stop trace1 general-purpose 2>&1)
check "帶 TRACE 時仍然完全無輸出" EMPTY "$trace_out"
check "TRACE 檔真的被寫入" "SubagentStop" "$(cat "$TMP/trace.jsonl" 2>/dev/null)"
check "TRACE 檔內容是合法 JSON" "trace1" \
    "$(jq -r '.agent_id // ""' < "$TMP/trace.jsonl" 2>/dev/null)"

# TRACE 指到不可寫路徑是第二條已知的 stderr 洩漏路徑：`>> "$CC_HANDOFF_TRACE"`
# 沒有 2>/dev/null，bash 會把重導向錯誤寫到 stderr，而 stderr 有內容就會讓
# 已結束的 sub agent 被續跑。`exec >/dev/null 2>&1` 是唯一擋得住的地方
# （逐行加 2>/dev/null 擋不住下一個忘記加的人）。
printf '%s\n' general-purpose > "$CC_HANDOFF_STATE_DIR/sa-trace2"
bad_trace=$(CC_HANDOFF_TRACE="$TMP/no-such-dir/trace.jsonl" \
    run_stop trace2 general-purpose 2>&1)
bad_trace_rc=$?
check "TRACE 指到不可寫路徑 → 仍然完全無輸出" EMPTY "$bad_trace"
check "TRACE 指到不可寫路徑 → exit code 仍為 0" "0" "$bad_trace_rc"

echo "── 20b. subagent-stop.sh：HOME 與 STATE_DIR 都沒設定 → stdout/stderr/exit code 三者都要乾淨"
# 這正是 `exec >/dev/null 2>&1` 與 `${HOME:-}` 要擋的情境：`set -u` 下
# `$HOME/.claude/...` 會噴 unbound variable 到 stderr **並且**非零退出，
# 而消費端「有輸出」與「非零 exit（hook_non_blocking_error）」兩條都會讓
# 已結束的 sub agent 被續跑。
naked=$(env -u HOME -u CC_HANDOFF_STATE_DIR -u CC_HANDOFF_TRACE \
    -u CC_HANDOFF_DISABLE bash "$STOP" <<'EOF' 2>&1
{"session_id":"sess-x","hook_event_name":"SubagentStop","agent_id":"nohome"}
EOF
)
naked_rc=$?
check "HOME 未設定 → stdout+stderr 皆空" EMPTY "$naked"
check "HOME 未設定 → exit code 為 0" "0" "$naked_rc"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
