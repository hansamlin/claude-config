#!/usr/bin/env bash
# subagent-check.sh 的分支驗證。
#
# 2.3.0 起本檔不再測 subagent-stop.sh——那支 hook 連同整條 SubagentStop 註冊
# 已經移除（理由見 subagent-check.sh 檔頭「為什麼沒有任何人刪 sa-<agent_id>」）。
# 原本第 10~13、17、20、20b 組已改寫成「hook 不存在時機制仍完整」的驗證。
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
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)

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

decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // ""'; }
reason()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }

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

echo "── 10. SubagentStop 這條風險面必須整條消失（結構斷言）"
# 2.2.0 的事故根因是「SubagentStop 只要有任何輸出就會讓 sub agent 續跑」
# （stdout / stderr / 非零 exit 三者皆算，binary 反查已結案）。2.2.1 靠
# `exec >/dev/null 2>&1` 把它壓住，2.3.0 直接把整個事件拿掉——沒有註冊就
# 沒有輸出，風險面歸零。
#
# 這兩條刻意驗檔案與註冊本身而不是行為：行為斷言驗不出「hook 還在但恰好靜默」
# 與「hook 已經不存在」的差別，而這個 PR 要保證的正是後者。
check "plugin 不再提供 subagent-stop.sh" "MISSING" \
    "$([ -e "$HERE/subagent-stop.sh" ] && echo PRESENT || echo MISSING)"
# 用 EMPTY 而不是空字串當期望值：check() 的 substring 分支對空字串是恆真的
# （`case "$actual" in *""*)` 一律命中），寫成 "" 會是第四個 vacuous test。
check "hooks.json 不得註冊 SubagentStop" EMPTY \
    "$(jq -r 'if (.hooks.SubagentStop | type) == "array" then "REGISTERED" else "" end' \
        "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)"
# 反證：其餘三條註冊必須還在，否則上一條會因為「整份 hooks.json 壞掉」而假綠
check "UserPromptSubmit 註冊仍在（證明上一條非 vacuous）" "check.sh" \
    "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // ""' "$PLUGIN_ROOT/hooks/hooks.json")"
check "PreToolUse 註冊仍在" "subagent-check.sh" \
    "$(jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$PLUGIN_ROOT/hooks/hooks.json")"
check "PostCompact 註冊仍在" "reset.sh" \
    "$(jq -r '.hooks.PostCompact[0].hooks[0].command // ""' "$PLUGIN_ROOT/hooks/hooks.json")"

echo "── 11. 核心：同一個 sub agent 被續跑 → 絕不可第二次 deny"
# 這是拿掉 SubagentStop 的**主要理由**，也是 2.2.x 完全沒被覆蓋的路徑。
#
# agent_id 被「重用」最現實的場景不是碰撞，是**同一個 sub agent 被續跑**：
# 主 agent 用 SendMessage 續接既有 agent，或任何 resume 路徑。binary 的
# SubagentStop payload 帶 stop_hook_active 且可以為 true → 續跑後再次觸發
# SubagentStop 是被設計進去的情境；過去實驗也實際觀察到同一個 agent_id 出現
# 兩次 SubagentStop（a31a2b30ca89831ff）。
#
# 續跑時 sub agent 的 context **還是滿的**（transcript 沒有縮水），舊版卻已經
# 在收工時把 sa-<agent_id> 刪掉 → 下一次工具呼叫重新 deny → 再要求寫一次交接檔。
# 所以這一組模擬的就是「收工之後又發工具呼叫」，用的是同一份超標 transcript。
mkdir -p "$CC_HANDOFF_STATE_DIR"
make_sa_transcript "$TMP/p11/sess/subagents/agent-resume1.jsonl" 400000 hot
check "第 1 次：超標 → deny" "deny" \
    "$(decision "$(run "$TMP/p11/sess.jsonl" resume1 general-purpose)")"
check "記帳落地" "sa-resume1" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-resume1)"
# ── 這裡是 sub agent 收工的時間點。2.2.x 的 SubagentStop 會在此 rm 掉 sa-resume1。──
check "續跑後第 1 次工具呼叫 → 放行" EMPTY "$(run "$TMP/p11/sess.jsonl" resume1 general-purpose)"
check "續跑後第 2 次（換工具）→ 放行" EMPTY \
    "$(run "$TMP/p11/sess.jsonl" resume1 general-purpose Bash "")"
# context 續跑後只會更大，不會變小——用更大的用量再驗一次，確認放行不是靠
# 「用量剛好沒再超過」這種巧合
make_sa_transcript "$TMP/p11/sess/subagents/agent-resume1.jsonl" 900000 hot
check "續跑且用量再翻倍 → 仍然放行" EMPTY "$(run "$TMP/p11/sess.jsonl" resume1 general-purpose)"
check "記帳全程沒有被任何人刪掉" "sa-resume1" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-resume1)"

echo "── 12. 交接檔在整個生命週期裡都不可被動到"
# 交接檔是主 agent 要餵給續作 sub agent 的唯一輸入。2.2.x 的 stop hook 明文
# 只刪 state 不刪交接檔，那條保證在 hook 移除後由「沒有人會刪」自動成立，
# 但仍要有回歸斷言——日後若有人在 subagent-check.sh 裡加清理邏輯就會被抓到。
printf 'handoff-content' > "$CC_HANDOFF_STATE_DIR/subagent-handoff-resume1.md"
run "$TMP/p11/sess.jsonl" resume1 general-purpose >/dev/null 2>&1
check "交接檔內容原封不動" "handoff-content" \
    "$(cat "$CC_HANDOFF_STATE_DIR/subagent-handoff-resume1.md" 2>/dev/null)"
# 未超標的 agent 走的是另一條早退路徑，一樣不可碰任何檔案
make_sa_transcript "$TMP/p12/sess/subagents/agent-cool.jsonl" 1000 cool
run "$TMP/p12/sess.jsonl" cool general-purpose >/dev/null 2>&1
check "未超標路徑也不動交接檔" "handoff-content" \
    "$(cat "$CC_HANDOFF_STATE_DIR/subagent-handoff-resume1.md" 2>/dev/null)"

echo "── 13. sa-<agent_id> 的回收完全依賴 check.sh 的 7 天清掃"
# 拿掉 stop hook 的代價就是這個：沒有任何人會主動刪 sa-*。這條驗的是
# 「清掃機制構得到它」，清掃時機本身由 check.test.sh 第 3b 組負責。
printf '%s\n' general-purpose > "$CC_HANDOFF_STATE_DIR/sa-ancient"
touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" \
    "$CC_HANDOFF_STATE_DIR/sa-ancient" 2>/dev/null
find "$CC_HANDOFF_STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
check "sa-* 是普通檔案，find -type f 掃得到" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-ancient" 2>/dev/null)"
check "同一次清掃不會誤刪還在用的 sa-resume1" "sa-resume1" \
    "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-resume1)"

echo "── 14. CC_HANDOFF_DISABLE=1 → 完全靜默、且不留任何副作用"
make_sa_transcript "$TMP/p14/sess/subagents/agent-off.jsonl" 999999 off
check "check 停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run "$TMP/p14/sess.jsonl" off general-purpose 2>&1)"
check "停用時不留狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR/sa-off" 2>/dev/null)"
# 停用是「什麼都不做」，不是「做別的事」——既有的狀態檔一個都不可以被動到
printf '%s\n' Explore > "$CC_HANDOFF_STATE_DIR/sa-off2"
CC_HANDOFF_DISABLE=1 run "$TMP/p14/sess.jsonl" off2 general-purpose >/dev/null 2>&1
check "停用時不清既有狀態檔" "sa-off2" "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-off2)"

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

echo "── 16. 輸出為合法 JSON（deny 是這支 hook 唯一會輸出的路徑）"
make_sa_transcript "$TMP/p16/sess/subagents/agent-json.jsonl" 999999 json
check "deny 輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run "$TMP/p16/sess.jsonl" json general-purpose | jq -r 'keys | join(",")')"
check "deny 之外的路徑不吐任何東西（含 stderr）" EMPTY \
    "$(run "$TMP/p16/sess.jsonl" json general-purpose 2>&1)"

echo "── 17. 端到端：整段生命週期只能有一次 deny，且沒有任何外力重置記帳"
# 2.2.x 的這一組驗的是兩支腳本的互動（stop 吐 stdout → 續跑 → state 已被 rm →
# 重新 deny 的迴圈）。stop hook 移除後，那個互動面消失了，換成驗更強的性質：
# **從 deny 到 sub agent 生命週期結束為止，deny 恰好發生一次**——不管中途發生
# 什麼（換工具、換 permission_mode、用量繼續長、收工後被續跑）。
# 仍然不手工造 state，一律讓 subagent-check.sh 自己把它寫出來。
make_sa_transcript "$TMP/p17/sess/subagents/agent-xfile.jsonl" 400000 xfile
deny_count=0
tally() { [ "$(decision "$1")" = "deny" ] && deny_count=$((deny_count+1)); return 0; }
tally "$(run "$TMP/p17/sess.jsonl" xfile general-purpose)"
check "第 1 步的副作用：state 由 check 真的寫出來了" "sa-xfile" \
    "$(ls "$CC_HANDOFF_STATE_DIR" 2>/dev/null | grep sa-xfile)"
tally "$(run "$TMP/p17/sess.jsonl" xfile general-purpose Write /some/file)"
tally "$(run "$TMP/p17/sess.jsonl" xfile general-purpose Bash "" default)"
make_sa_transcript "$TMP/p17/sess/subagents/agent-xfile.jsonl" 800000 xfile
tally "$(run "$TMP/p17/sess.jsonl" xfile general-purpose)"
# ── 收工 → 被續跑。2.2.x 在此會 rm 掉 sa-xfile，於是下面這兩次會再 deny。──
tally "$(run "$TMP/p17/sess.jsonl" xfile general-purpose)"
tally "$(run "$TMP/p17/sess.jsonl" xfile general-purpose Read /tmp/x)"
check "六次工具呼叫（含續跑）合計恰好 1 次 deny" "1" "$deny_count"

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

echo "── 20. subagent-check.sh 的 CC_HANDOFF_TRACE"
# trace 是這支 hook 唯一能便宜證實「它真的有在跑」的手段——它最大的失敗模式是
# 靜默地永遠不觸發（路徑推導錯、payload 沒有 agent_id 之類）。
# 原本第 20 組驗的是 subagent-stop.sh 的 trace；那支已移除，覆蓋改掛到這支。
make_sa_transcript "$TMP/p20/sess/subagents/agent-tr1.jsonl" 1000 tr1
trace_out=$(CC_HANDOFF_TRACE="$TMP/trace.jsonl" \
    run "$TMP/p20/sess.jsonl" tr1 general-purpose 2>&1)
check "未達門檻仍然靜默（trace 不是輸出）" EMPTY "$trace_out"
check "TRACE 檔真的被寫入" "PreToolUse" "$(cat "$TMP/trace.jsonl" 2>/dev/null)"
check "TRACE 檔內容是合法 JSON" "tr1" \
    "$(jq -r '.agent_id // ""' < "$TMP/trace.jsonl" 2>/dev/null)"
# trace 寫入必須排在所有早退**之前**，否則「靜默地永遠不觸發」正好是它查不到的
# 那一類。主 agent 的呼叫（無 agent_id）走的是最早的一條早退，用它來驗最嚴格。
: > "$TMP/trace2.jsonl"
CC_HANDOFF_TRACE="$TMP/trace2.jsonl" run "$TMP/p20/sess.jsonl" >/dev/null 2>&1
check "連最早的早退（主 agent、無 agent_id）也已寫進 trace" "PreToolUse" \
    "$(cat "$TMP/trace2.jsonl" 2>/dev/null)"

# TRACE 指到不可寫路徑：`>> "$CC_HANDOFF_TRACE"` 沒有 2>/dev/null，bash 會把
# 重導向錯誤寫到 stderr。這支 hook 沒有 `exec >/dev/null 2>&1`（它必須能吐
# deny 的 JSON），所以驗的是「除錯開關設錯不可污染正常路徑的判定」：
# stdout 仍是乾淨的 deny JSON、exit code 仍為 0。
make_sa_transcript "$TMP/p20/sess/subagents/agent-tr2.jsonl" 999999 tr2
bad_trace=$(CC_HANDOFF_TRACE="$TMP/no-such-dir/trace.jsonl" \
    run "$TMP/p20/sess.jsonl" tr2 general-purpose 2>/dev/null)
bad_trace_rc=$?
check "TRACE 指到不可寫路徑 → deny 仍然正常產出" "deny" "$(decision "$bad_trace")"
check "TRACE 指到不可寫路徑 → exit code 仍為 0" "0" "$bad_trace_rc"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
