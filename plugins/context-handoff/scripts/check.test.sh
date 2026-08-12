#!/usr/bin/env bash
# check.sh / reset.sh 的分支驗證。
#
# 2.5.0 起驗證的是三階段門檻：
#   used < THRESHOLD                靜默
#   THRESHOLD ≤ used < HARD_LIMIT   里程碑提醒（跨 level 才提醒，不 block）
#   used ≥ HARD_LIMIT               強制交接（未交接 → 注入指示；已交接 → block）
# 舊的 MAX_NAGS 催告計數已移除（nags-* 只剩 reset.sh 的舊殘留清理）。
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

# 使用者輸入文字的欄位名：實測 2026-08-06（Claude Code 2.1.223）線上攔到的
# UserPromptSubmit payload 帶的是 `prompt`。官方文件寫的 `prompt_text` 與本檔
# 舊版 run() 用的 `user_message` 都不符實際——舊版那條等於一直在測一個不存在
# 的欄位（vacuous）。故 run() 一律送 `prompt`，另有專門的 case 覆蓋 check.sh
# 保留的兩個防禦性 fallback。
run() { # run <session_id> <transcript> [agent_id] [agent_type] [prompt]
    jq -n --arg s "$1" --arg t "$2" --arg a "${3:-}" --arg ty "${4:-}" \
          --arg p "${5:-接下來幫我改 X}" \
        '{session_id:$s, transcript_path:$t, cwd:"/tmp",
          hook_event_name:"UserPromptSubmit", prompt:$p}
         + (if $a == "" then {} else {agent_id:$a} end)
         + (if $ty == "" then {} else {agent_type:$ty} end)' \
        | bash "$HOOK"
}

# 只填指定的某一個 prompt 候選欄位，用來驗 fallback 順位
run_field() { # run_field <session_id> <transcript> <field> <prompt>
    jq -n --arg s "$1" --arg t "$2" --arg f "$3" --arg p "$4" \
        '{session_id:$s, transcript_path:$t, cwd:"/tmp",
          hook_event_name:"UserPromptSubmit"} + {($f): $p}' \
        | bash "$HOOK"
}

ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""'; }
sysmsg() { printf '%s' "$1" | jq -r '.systemMessage // ""'; }
decision() { printf '%s' "$1" | jq -r '.decision // ""'; }

# 實測：背景任務跑完的通知也是走 UserPromptSubmit 進來的，不是只有真人打字。
# 這則是線上攔到的原樣（縮短過）。
TASK_NOTIF='<task-notification>
<task-id>b54w7e7k5</task-id>
<status>completed</status>
<summary>Background command "Run full unit test suite" completed (exit code 0)</summary>
</task-notification>'

# 「不該出現的字串」檢查：命中就回傳整段輸出（交給 check ... EMPTY 判定失敗）
lacks() { # lacks <needle> <haystack>
    case "$2" in *"$1"*) printf '%s' "$2" ;; esac
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
export CC_HANDOFF_HARD_LIMIT=400000
export CC_HANDOFF_NAG_STEP=20000

echo "── 1. subagent 不觸發，但 --agent 啟動的主 session 要觸發"
make_transcript 999999 "" "$TMP/t1.jsonl"
check "payload 帶 agent_id → 靜默" EMPTY "$(run sess-1 "$TMP/t1.jsonl" subagent-uuid)"
check "未留下任何主 session 狀態檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-1 "$CC_HANDOFF_STATE_DIR"/nag-level-sess-1 2>/dev/null)"
# agent_id 只在 subagent 內出現；`claude --agent foo` 的主 session 只帶
# agent_type，連它一起擋會讓那種 session 永遠不交接
check "只帶 agent_type（--agent 主 session）→ 照常觸發" "handoff" \
    "$(ctx "$(run sess-1b "$TMP/t1.jsonl" "" Explore)")"

echo "── 2. transcript 不存在"
check "靜默不觸發" EMPTY "$(run sess-2 "$TMP/nope.jsonl")"

echo "── 3. 用量低於門檻"
make_transcript 299999 "" "$TMP/t3.jsonl"
check "靜默不觸發" EMPTY "$(run sess-3 "$TMP/t3.jsonl")"
check "未留下 nags 狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-3 2>/dev/null)"
check "未留下 nag-level 狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-3 2>/dev/null)"

echo "── 3b. 7 天清掃必須排在所有早退之前（每一則 prompt 都跑）"
# 舊版把這個 find 排在三個早退之後（未達門檻 / `/handoff` 逃生口 / 已交接就
# block），於是它只在「已達門檻 **且** 這則不是 handoff **且** 尚未交接過」這條
# 窄路徑上跑：一旦該 session 交接過就再也不跑，主 session 從沒破過門檻的機器上
# 等於完全不跑。受害的不只 1 byte 的 sa-*，還有可能數 KB 的 subagent-handoff-*.md。
#
# SubagentStop 註冊移除之後（2.3.0）這條從「殘留垃圾」升級成 sa-* 的**唯一**
# 回收路徑，所以每一條早退路徑都要單獨驗一次，不能只驗 happy path。
# 2.5.0 多了 stage-2 里程碑分支（提醒後 exit 0），它也要走得到這行 find。
mkdir -p "$CC_HANDOFF_STATE_DIR"
stale_probe() { # stale_probe <tag> — 造一個 8 天前的舊檔與一個剛剛的新檔
    touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" \
        "$CC_HANDOFF_STATE_DIR/sa-stale-$1" 2>/dev/null
    printf 'x' > "$CC_HANDOFF_STATE_DIR/sa-fresh-$1"
}
# (a) 未達門檻——最常走、也是舊版完全掃不到的一條
stale_probe a
run sess-3b "$TMP/t3.jsonl" >/dev/null
check "未達門檻路徑也清掉 8 天前的舊檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-stale-a" 2>/dev/null)"
check "未達門檻路徑不誤刪新檔" "sa-fresh-a" \
    "$(ls "$CC_HANDOFF_STATE_DIR" | grep sa-fresh-a)"
# (b) `/handoff` 逃生口
make_transcript 310000 "" "$TMP/t3b.jsonl"
stale_probe b
run sess-3b2 "$TMP/t3b.jsonl" "" "" "/handoff" >/dev/null
check "/handoff 逃生口路徑也清掉舊檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-stale-b" 2>/dev/null)"
# (c) 已交接過 → block（stage-3 路徑）
make_transcript 420000 "" "$TMP/t3c.jsonl"
append_handoff_call "$TMP/t3c.jsonl"
stale_probe c
run sess-3b3 "$TMP/t3c.jsonl" >/dev/null
check "已交接過（block）路徑也清掉舊檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-stale-c" 2>/dev/null)"
# (d) 交接檔本身也在清掃範圍內——它有內容，才是真正佔空間的那個
touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" \
    "$CC_HANDOFF_STATE_DIR/subagent-handoff-old.md" 2>/dev/null
run sess-3b4 "$TMP/t3.jsonl" >/dev/null
check "8 天前的交接檔也被清掉" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/subagent-handoff-old.md" 2>/dev/null)"
# (e) stage-2 里程碑提醒路徑（2.5.0 新增的早退）
make_transcript 310000 "" "$TMP/t3e.jsonl"
stale_probe e
run sess-3b5 "$TMP/t3e.jsonl" >/dev/null
check "stage-2 提醒路徑也清掉舊檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/sa-stale-e" 2>/dev/null)"

echo "── 4. 用量達提醒區間 → systemMessage 提醒、不阻擋"
# 2.5.0：310000 落在 stage-2（300000 ≤ used < 400000），只提醒不強制交接。
# 舊版同一用量是「注入 handoff 指示 + 記催告」，這裡全部改成驗證提醒語意。
make_transcript 310000 "" "$TMP/t4.jsonl"
out4=$(run sess-4 "$TMP/t4.jsonl")
check "無 hookSpecificOutput（不注入指示）" EMPTY "$(ctx "$out4")"
check "無 decision（不阻擋）" EMPTY "$(decision "$out4")"
check "systemMessage 含提醒語意" "提醒" "$(sysmsg "$out4")"
check "systemMessage 帶目前用量" "310000" "$(sysmsg "$out4")"
check "提醒語意（不含強制交接句）" EMPTY "$(lacks "本次請求已改為" "$out4")"
check "nag-level 記為 0（level 0）" "0" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4 2>/dev/null)"

echo "── 4c. 這則 prompt 本身就是 handoff 呼叫 → 仍介入，但不重複叫它去 handoff"
# 使用者自己看到 context 爆了主動打 /handoff。再注入「先不要執行使用者要求的
# 工作，去呼叫 handoff skill」對這種 prompt 毫無意義，也不該動用里程碑配額。
out4c=$(run sess-4c "$TMP/t4.jsonl" "" "" "/handoff")
check "給 systemMessage 且點明是回應使用者自己的 handoff" "已收到你的 handoff 請求" \
    "$(sysmsg "$out4c")"
check "不注入 handoff 指示" EMPTY "$(ctx "$out4c")"
check "不 block（要讓 handoff skill 有 turn 可跑）" EMPTY "$(decision "$out4c")"
check "走逃生口 → 不寫 nag-level 檔（stage-2 在其後）" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4c 2>/dev/null)"
check "訊息不含「本次請求已改為」" EMPTY "$(lacks "本次請求已改為" "$out4c")"

out4d=$(run sess-4d "$TMP/t4.jsonl" "" "" "/context-handoff:handoff 順便記一下 X")
check "帶 plugin 前綴與參數也認得" "已收到你的 handoff 請求" \
    "$(sysmsg "$out4d")"
check "同樣不注入指示" EMPTY "$(ctx "$out4d")"
check "同樣不寫 nag-level 檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4d 2>/dev/null)"

check "整則就是「交接」兩字也認得" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4e "$TMP/t4.jsonl" "" "" "  交接  ")")"

# 實測使用者 shell history：句尾附加才是他最常見的用法，只認行首會漏掉一大半
check "句尾 /handoff（前面接中文）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4h "$TMP/t4.jsonl" "" "" "MR #846 #847 都合併了，更新記憶然後 /handoff")")"
check "句尾 /handoff（前面接全形逗號）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4i "$TMP/t4.jsonl" "" "" "develop pipeline 也全部綠，/handoff")")"
check "句尾 /handoff（極短句）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4j "$TMP/t4.jsonl" "" "" "已合併 /handoff")")"
check "句尾 /handoff 不寫 nag-level 檔" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4j 2>/dev/null)"

# 比對必須收斂：寬鬆 substring 會讓下面這些「在談論 handoff」的句子命中，
# 門檻機制等於被使用者一句閒聊關掉。這幾條是防寬鬆比對回歸的守門測試。
check "含 handoff 字樣但不是呼叫 → 照常提醒" "提醒" \
    "$(sysmsg "$(run sess-4f "$TMP/t4.jsonl" "" "" "以後不要再自動 handoff 了")")"
check "含 handoff 字樣的一般 prompt 照常記里程碑" "0" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4f 2>/dev/null)"
check "句中談論 handoff skill → 照常提醒" "提醒" \
    "$(sysmsg "$(run sess-4k "$TMP/t4.jsonl" "" "" "hook 會在上下文超過 300k 時，會觸發 handoff skill")")"
check "/handoffxyz 不是完整指令 → 照常提醒" "提醒" \
    "$(sysmsg "$(run sess-4l "$TMP/t4.jsonl" "" "" "/handoffxyz 這是什麼")")"

# 未達門檻時不因為 prompt 是 handoff 就多嘴
check "未達門檻 + /handoff → 完全靜默" EMPTY \
    "$(run sess-4g "$TMP/t3.jsonl" "" "" "/handoff")"

echo "── 4d. prompt 欄位：實測為 .prompt，另兩個候選僅作防禦性 fallback"
check "只給 .prompt → 認得（實測欄位）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run_field sess-4m "$TMP/t4.jsonl" prompt "/handoff")")"
check "只給 .prompt_text → fallback 認得" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run_field sess-4n "$TMP/t4.jsonl" prompt_text "/handoff")")"
check "只給 .user_message → fallback 認得" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run_field sess-4o "$TMP/t4.jsonl" user_message "/handoff")")"
check "完全沒有 prompt 欄位 → 照常提醒（不誤判）" "提醒" \
    "$(sysmsg "$(run_field sess-4p "$TMP/t4.jsonl" unrelated "/handoff")")"

echo "── 5. 同 level 連發 → 靜默（state 檔已存 level，不重複提醒）"
# 310000 是 level 0，sess-4 在第 4 組已提醒過並記下 level 0。
check "同 level（level 0）連發 → 靜默" EMPTY "$(run sess-4 "$TMP/t4.jsonl")"
check "nag-level 維持 0（沒有多催的痕跡）" "0" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4 2>/dev/null)"

echo "── 6. 跨 level 才提醒：320000 → level 1；319999 仍是 level 0"
make_transcript 320000 "" "$TMP/t6.jsonl"
out6=$(run sess-6 "$TMP/t6.jsonl")
check "跨到 level 1 → 提醒" "提醒" "$(sysmsg "$out6")"
check "nag-level 記為 1" "1" "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-6 2>/dev/null)"
make_transcript 319999 "" "$TMP/t6.jsonl"
check "回落 level 0（已存 level 1）→ 靜默" EMPTY "$(run sess-6 "$TMP/t6.jsonl")"
make_transcript 300000 "" "$TMP/t6b.jsonl"
check "恰在 300000（level 0）→ 首次提醒" "提醒" \
    "$(sysmsg "$(run sess-6b "$TMP/t6b.jsonl")")"
check "300000 → nag-level 記為 0" "0" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-6b 2>/dev/null)"

echo "── 7. transcript 顯示 handoff 真的跑過（≥ 硬上限）→ 立刻收手 block"
# 310000 已不是 stage-3，block 斷言改用 420000（≥ HARD_LIMIT）才測得到。
make_transcript 420000 "" "$TMP/t7.jsonl"
append_handoff_call "$TMP/t7.jsonl"
out7=$(run sess-7 "$TMP/t7.jsonl")
check "不再注入指示" EMPTY "$(ctx "$out7")"
check "只給已交接的提醒" "已交接過" "$out7"
check "未寫 nag-level（stage-3 不走里程碑）" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-7 2>/dev/null)"
# 這個分支要真正中斷：只給 systemMessage 的話 Claude 照樣有 turn 去做事，
# 使用者已經交接完了卻還在這個 session 裡繼續累積 context。
# 與 4c 不同——那個分支還需要 turn 去跑 handoff skill，這個分支已經跑完了。
check "已交接分支 decision=block" "block" "$(decision "$out7")"
check "reason 帶提示文字" "已交接過" "$(printf '%s' "$out7" | jq -r '.reason // ""')"
check "reason 帶目前用量" "420000" "$(printf '%s' "$out7" | jq -r '.reason // ""')"

# 逃生口：交接後又多做了些事想再交接一次，不可被 block 永久鎖死。
# 這也是為什麼 handoff-prompt 判定必須排在這個 block 分支「之前」。
out7c=$(run sess-7c "$TMP/t7.jsonl" "" "" "/handoff")
check "已交接過 + /handoff → 不被 block" EMPTY "$(decision "$out7c")"
check "已交接過 + /handoff → 走 handoff-prompt 分支" "已收到你的 handoff 請求" \
    "$(sysmsg "$out7c")"

# 實測發現：UserPromptSubmit 不等於「真人送出訊息」——背景任務跑完的通知也走
# 同一條路。block 會 erase 掉這則 prompt，主 agent 就永遠收不到自己派出去的
# 背景工作結果。使用者要的是「已交接後不要再執行新任務」，不是讓已經在跑的
# 背景工作結果人間蒸發。這是本次改動風險最高的一處。
out7d=$(run sess-7d "$TMP/t7.jsonl" "" "" "$TASK_NOTIF")
check "已交接過 + 背景任務通知 → 絕不可 block" EMPTY "$(decision "$out7d")"
check "已交接過 + 背景任務通知 → 仍給提醒" "已交接過" "$(sysmsg "$out7d")"
check "系統注入訊息不被當成 handoff 呼叫" EMPTY \
    "$(lacks "已收到你的 handoff 請求" "$out7d")"
# <system-reminder> 這類注入同樣不可被 block
check "已交接過 + system-reminder 注入 → 不被 block" EMPTY \
    "$(decision "$(run sess-7e "$TMP/t7.jsonl" "" "" "<system-reminder>foo</system-reminder>")")"
make_transcript 420000 "" "$TMP/t7b.jsonl"
append_handoff_call "$TMP/t7b.jsonl" handoff
check "skill 名寫成 handoff（未加 plugin 前綴）也認得" "已交接過" \
    "$(run sess-7b "$TMP/t7b.jsonl")"

echo "── 8. 回歸：sessionKind=bg 也必須觸發"
# 舊版 Stop hook 把 bg 一律排除，導致使用者日常在用的背景 session 永遠不交接
make_transcript 310000 bg "$TMP/t8.jsonl"
check "bg session 照樣提醒" "提醒" "$(sysmsg "$(run sess-8 "$TMP/t8.jsonl")")"

echo "── 9. isSidechain 過濾（subagent 小 context 不可蓋過主 session）"
make_transcript 310000 "" "$TMP/t9.jsonl"
jq -n '{type:"assistant", isSidechain:true,
        message:{usage:{input_tokens:500, cache_creation_input_tokens:0,
                        cache_read_input_tokens:0, output_tokens:0}}}' >> "$TMP/t9.jsonl"
check "仍以主 session 用量判定 → 提醒" "提醒" \
    "$(sysmsg "$(run sess-9 "$TMP/t9.jsonl")")"
# subagent 在 sidechain 裡跑 handoff 不算主 session 交接過
make_transcript 310000 "" "$TMP/t9b.jsonl"
jq -n '{type:"assistant", isSidechain:true,
        message:{content:[{type:"tool_use", name:"Skill", input:{skill:"handoff"}}]}}' \
    >> "$TMP/t9b.jsonl"
check "sidechain 裡的 handoff 不算數 → 仍是提醒" "提醒" \
    "$(sysmsg "$(run sess-9b "$TMP/t9b.jsonl")")"

echo "── 10. compact 邊界：用量必須從邊界之後重算"
# 這個 hook 在使用者送出訊息當下跑，那時 transcript 還沒有任何 compact 之後的
# assistant 訊息。直接取最後一筆會讀到 compact 前的舊數字，害使用者為了繼續
# 工作而 compact，卻換來下一則訊息被劫持去做多餘的交接。
make_transcript 310000 "" "$TMP/t10.jsonl"
append_compact_boundary "$TMP/t10.jsonl"
out10=$(run sess-10 "$TMP/t10.jsonl")
check "邊界後還沒有 usage → 靜默放行" EMPTY "$out10"
check "未留下 nag-level 狀態檔" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-10 2>/dev/null)"

make_transcript 310000 "" "$TMP/t10b.jsonl"
append_compact_boundary "$TMP/t10b.jsonl"
append_usage "$TMP/t10b.jsonl" 48714
check "邊界後用量已塌回 48k → 靜默放行" EMPTY "$(run sess-10b "$TMP/t10b.jsonl")"

make_transcript 310000 "" "$TMP/t10c.jsonl"
append_compact_boundary "$TMP/t10c.jsonl"
append_usage "$TMP/t10c.jsonl" 320000
check "邊界後又漲回 320k → 照常提醒" "提醒" \
    "$(sysmsg "$(run sess-10c "$TMP/t10c.jsonl")")"

make_transcript 310000 "" "$TMP/t10d.jsonl"
append_handoff_call "$TMP/t10d.jsonl"
append_compact_boundary "$TMP/t10d.jsonl"
append_usage "$TMP/t10d.jsonl" 320000
check "邊界前的 handoff 不算數，邊界後要重新提醒" "提醒" \
    "$(sysmsg "$(run sess-10d "$TMP/t10d.jsonl")")"

# sidechain 裡的 compact 邊界不是主 session 的邊界，不可拿來歸零
make_transcript 310000 "" "$TMP/t10e.jsonl"
jq -n '{type:"user", isSidechain:true, isCompactSummary:true,
        message:{role:"user", content:"subagent 的 compact"}}' >> "$TMP/t10e.jsonl"
check "sidechain 的 compact 邊界不算數 → 照常提醒" "提醒" \
    "$(sysmsg "$(run sess-10e "$TMP/t10e.jsonl")")"

echo "── 11. PostCompact reset → 清掉里程碑記錄可重新提醒"
jq -n '{session_id:"sess-4", hook_event_name:"PostCompact", trigger:"manual"}' | bash "$RESET"
check "nag-level 記錄已清除" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4 2>/dev/null)"
check "清除後重新提醒" "提醒" "$(sysmsg "$(run sess-4 "$TMP/t4.jsonl")")"
check "重新提醒後 nag-level 記回 0" "0" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-4 2>/dev/null)"

echo "── 12. CC_HANDOFF_DISABLE=1"
check "完全停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run sess-11 "$TMP/t4.jsonl")"

echo "── 13. 輸出為合法 JSON"
make_transcript 500000 "" "$TMP/t13.jsonl"
check "stage-3 觸發時輸出可被 jq 解析" "hookSpecificOutput" \
    "$(run sess-12 "$TMP/t13.jsonl" | jq -r 'keys | join(",")')"
check "stage-2 輸出僅 systemMessage（無 hookSpecificOutput/decision）" "systemMessage" \
    "$(run sess-13s "$TMP/t4.jsonl" | jq -r 'keys | join(",")')"

echo "── 13b. session_id 消毒：不是純識別字就不可拼進路徑"
# session_id 會被拼進 `nag-level-$session_id` 並**寫檔**，reset.sh 再拿同一個值去
# `rm -f`。實務上它一律是 UUID，但「實務上長這樣」不是防禦——agent_id 早就有
# 白名單，這裡沒有，是防禦深度的不對稱。
make_transcript 310000 "" "$TMP/t13b.jsonl"
before13b=$(ls -A "$CC_HANDOFF_STATE_DIR" 2>/dev/null | sort)
out13b=$(run '../../etc/evil' "$TMP/t13b.jsonl" 2>&1)
after13b=$(ls -A "$CC_HANDOFF_STATE_DIR" 2>/dev/null | sort)
check "含 ../ 的 session_id → 靜默放行（連 systemMessage 都不給）" EMPTY "$out13b"
check "STATE_DIR 內容完全沒變（一個檔都不可寫）" EMPTY \
    "$([ "$before13b" = "$after13b" ] && : || printf 'before=[%s] after=[%s]' "$before13b" "$after13b")"
check "沒有把 nags- 檔寫到 STATE_DIR 之外" EMPTY \
    "$(find "$TMP" -name 'nags-*' ! -path "$CC_HANDOFF_STATE_DIR/*" 2>/dev/null)"
# 真的解析得成功的穿越路徑（中間段必須是存在的目錄，理由見 13c 的長註解）：
#   $STATE_DIR/nag-level-d/../../pwned.txt  →  $TMP/pwned.txt
mkdir -p "$CC_HANDOFF_STATE_DIR/nag-level-d"
run 'd/../../pwned.txt' "$TMP/t13b.jsonl" >/dev/null 2>&1
check "會穿越的 session_id 不可在 STATE_DIR 之外建檔" EMPTY \
    "$(ls "$TMP/pwned.txt" 2>/dev/null)"
# 其他非白名單字元同樣要擋（空白、$、/）
check "含空白的 session_id → 靜默放行" EMPTY "$(run 'sess x' "$TMP/t13b.jsonl" 2>&1)"
check "含 / 的 session_id → 靜默放行" EMPTY "$(run 'a/b' "$TMP/t13b.jsonl" 2>&1)"
# 正常的 UUID 形態必須不被誤殺
check "正常 UUID session_id → 照常提醒" "提醒" \
    "$(sysmsg "$(run '0f9a1c2d-3e4b-5a6f-8901-abcdef012345' "$TMP/t13b.jsonl")")"

echo "── 13c. reset.sh：DISABLE 開關與 session_id 消毒"
# 2.2.1 之前四支腳本只有 reset.sh 漏了 CC_HANDOFF_DISABLE，
# 「完全停用」之下 PostCompact 仍會刪 nags-*
mkdir -p "$CC_HANDOFF_STATE_DIR"
printf '2' > "$CC_HANDOFF_STATE_DIR/nags-sess-dis"
jq -n '{session_id:"sess-dis", hook_event_name:"PostCompact", trigger:"manual"}' \
    | CC_HANDOFF_DISABLE=1 bash "$RESET"
check "DISABLE=1 → 不可清狀態" "2" "$(cat "$CC_HANDOFF_STATE_DIR/nags-sess-dis" 2>/dev/null)"
jq -n '{session_id:"sess-dis", hook_event_name:"PostCompact", trigger:"manual"}' | bash "$RESET"
check "未停用 → 照常清掉（證明上一條不是因為 reset 本來就沒作用）" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/nags-sess-dis" 2>/dev/null)"

# rm -f 是整個 plugin 唯一會刪檔的地方，風險最高。
#
# 這裡刻意造一個**真的會解析成功**的穿越路徑，而不是隨便丟個 "../../etc/evil"：
# `rm -f "$STATE_DIR/nag-level-../../etc/evil"` 中間那段 `nag-level-..` 不是目錄，
# 路徑解析不到、rm -f 靜默成功、STATE_DIR 也沒變——那樣的斷言不論有沒有消毒都會
# 綠，是 vacuous test。要讓穿越真的發生，中間必須是存在的目錄：
#   session_id = "d/../../victim.txt"
#   → $STATE_DIR/nag-level-d/../../victim.txt  →  $TMP/victim.txt
# 也就是 STATE_DIR 之外的檔案會被刪掉。
mkdir -p "$CC_HANDOFF_STATE_DIR/nag-level-d"
printf 'do-not-delete' > "$TMP/victim.txt"
out13c=$(jq -n '{session_id:"d/../../victim.txt", hook_event_name:"PostCompact"}' \
    | bash "$RESET" 2>&1)
check "reset 收到會穿越的 session_id → 靜默" EMPTY "$out13c"
check "STATE_DIR 之外的檔案沒有被刪掉" "do-not-delete" "$(cat "$TMP/victim.txt" 2>/dev/null)"
# 證明上面那條不是因為 rm 本來就構不到：拿掉穿越、只留合法 id，reset 必須真的刪得動
printf '1' > "$CC_HANDOFF_STATE_DIR/nags-real"
jq -n '{session_id:"nags-real-probe", hook_event_name:"PostCompact"}' | bash "$RESET"
printf '1' > "$CC_HANDOFF_STATE_DIR/nags-real"
jq -n '{session_id:"real", hook_event_name:"PostCompact"}' | bash "$RESET"
check "合法 session_id → reset 確實刪得動（證明上一條非 vacuous）" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR/nags-real" 2>/dev/null)"

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
#
# 檢查分兩層，因為單靠 `-n` 不夠：`-n` 只剖析不執行，抓得到 process
# substitution 這種「剖析期」錯誤，卻放過 `set -o pipefail`、
# `${BASH_SOURCE[0]}` 這種「執行期」才炸的 bashism（pull.sh 曾經就是
# 通過 dash -n、實際用 dash 跑卻死在第 18 行）。
#   第 1 層 dash -n        —— 剖析期
#   第 2 層 已知 bashism 的 grep —— 執行期
# 第 2 層是列舉式的，不宣稱窮盡；裝了 shellcheck 的話 `shellcheck -s sh`
# 更完整，但這裡不強制依賴它。
if command -v dash >/dev/null 2>&1; then POSIX_SH=dash; else POSIX_SH=sh; fi
REPO_ROOT=$(cd "$HERE/../../.." && pwd)
# 逐項說明：process substitution / [[ ]] / here-string / 陣列指派 /
# declare / BASH_SOURCE / 行首無條件的 set ... pipefail / ${v,,} 大小寫轉換
BASHISM='done <[[:space:]]*<\(|\[\[|<<<|^[[:space:]]*[A-Za-z_]+=\(|declare |BASH_SOURCE|^set .*pipefail|\$\{[A-Za-z_]+[,^]'
for s in install.sh pull.sh; do
    if [ ! -f "$REPO_ROOT/$s" ]; then
        echo "  ⏭️  $s 不在此處，略過（非 repo 內執行）"
        continue
    fi
    if err=$("$POSIX_SH" -n "$REPO_ROOT/$s" 2>&1); then
        echo "  ✅ $s 可被 $POSIX_SH 剖析"; pass=$((pass+1))
    else
        echo "  ❌ $s 剖析期 bashism，$POSIX_SH -n 失敗：$(printf '%s' "$err" | head -2)"
        fail=$((fail+1))
    fi
    # 先取行號再濾掉註解行——否則檔頭那段「不要用 XXX」的說明會自己命中，
    # 而且順序反過來的話 grep -n 會給出濾掉註解後的行號，對不上原檔
    hits=$(grep -nE "$BASHISM" "$REPO_ROOT/$s" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    if [ -z "$hits" ]; then
        echo "  ✅ $s 無已知的執行期 bashism"; pass=$((pass+1))
    else
        echo "  ❌ $s 有執行期 bashism：$(printf '%s' "$hits" | head -3 | tr '\n' ' ')"
        fail=$((fail+1))
    fi
done

echo "── 15. 250000 → 370000 跳躍 → 單次提醒、level 3（證明不是逐 level 補催）"
make_transcript 250000 "" "$TMP/t15.jsonl"
check "250000 未達門檻 → 靜默" EMPTY "$(run sess-15 "$TMP/t15.jsonl")"
make_transcript 370000 "" "$TMP/t15.jsonl"
out15=$(run sess-15 "$TMP/t15.jsonl")
check "跳到 370000 → 單次提醒" "提醒" "$(sysmsg "$out15")"
check "nag-level 直接記 3（不逐 level 補催）" "3" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-15 2>/dev/null)"

echo "── 16. stage-2 已交接過 → 不 block、仍是提醒"
# 2.5.0 的 stage-2 分支排在「已交接 scan」之前：提醒區間內即使已經交接過，
# 也只是提醒，不會像 stage-3 那樣 block。
make_transcript 350000 "" "$TMP/t16.jsonl"
append_handoff_call "$TMP/t16.jsonl"
out16=$(run sess-16 "$TMP/t16.jsonl")
check "stage-2 已交接 → 不 block" EMPTY "$(decision "$out16")"
check "stage-2 已交接 → 仍是提醒" "提醒" "$(sysmsg "$out16")"

echo "── 17. 400000 恰等 → 進 stage-3（未交接 → 注入指示；已交接 → block）"
make_transcript 400000 "" "$TMP/t17.jsonl"
check "400000 恰等未交接 → 注入指示" "先不要執行" \
    "$(ctx "$(run sess-17 "$TMP/t17.jsonl")")"
append_handoff_call "$TMP/t17.jsonl"
check "400000 恰等已交接 → block" "block" \
    "$(decision "$(run sess-17b "$TMP/t17.jsonl")")"

echo "── 18. stage-3 連四則 prompt → 每則都注入指示、無降級（MAX_NAGS 已移除）"
# 舊版催滿 CC_HANDOFF_MAX_NAGS=3 次就降級為純提醒；2.5.0 里程碑機制取代後，
# stage-3 沒有降級，也不再有 nags-* 計數檔。第 4 則與 nags 檔是區分新舊的紅點。
make_transcript 500000 "" "$TMP/t18.jsonl"
check "stage-3 第 1 則 → 注入指示" "先不要執行" "$(ctx "$(run sess-18 "$TMP/t18.jsonl")")"
check "stage-3 第 2 則 → 注入指示" "先不要執行" "$(ctx "$(run sess-18 "$TMP/t18.jsonl")")"
check "stage-3 第 3 則 → 注入指示" "先不要執行" "$(ctx "$(run sess-18 "$TMP/t18.jsonl")")"
check "stage-3 第 4 則 → 仍注入指示（無降級）" "先不要執行" \
    "$(ctx "$(run sess-18 "$TMP/t18.jsonl")")"
check "nags 檔從未被寫入" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-18 2>/dev/null)"

echo "── 19. NAG_STEP=0 → 退回 20000（不除零、行為如常）"
make_transcript 350000 "" "$TMP/t19.jsonl"
out19=$(CC_HANDOFF_NAG_STEP=0 run sess-19 "$TMP/t19.jsonl")
check "NAG_STEP=0 → 退回 20000 照常提醒" "提醒" "$(sysmsg "$out19")"
check "NAG_STEP=0 → level 2（(350000-300000)/20000）" "2" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nag-level-sess-19 2>/dev/null)"

echo "── 20. HARD_LIMIT=THRESHOLD → 還原舊單門檻行為（遷移逃生口）"
# 300000 直接進 stage-3（無提醒區間），systemMessage 用「硬上限」文案而非門檻。
make_transcript 300000 "" "$TMP/t20.jsonl"
out20=$(CC_HANDOFF_HARD_LIMIT=300000 run sess-20 "$TMP/t20.jsonl")
check "HARD_LIMIT=THRESHOLD → 300000 直接注入指示" "先不要執行" "$(ctx "$out20")"
check "HARD_LIMIT=THRESHOLD → systemMessage 用硬上限文案" "硬上限" "$(sysmsg "$out20")"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
