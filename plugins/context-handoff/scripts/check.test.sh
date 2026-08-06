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

echo "── 4c. 這則 prompt 本身就是 handoff 呼叫 → 仍介入，但不重複叫它去 handoff"
# 使用者自己看到 context 爆了主動打 /handoff。再注入「先不要執行使用者要求的
# 工作，去呼叫 handoff skill」對這種 prompt 毫無意義，也不該吃掉催告額度。
out4c=$(run sess-4c "$TMP/t4.jsonl" "" "" "/handoff")
check "給 systemMessage 且點明是回應使用者自己的 handoff" "已收到你的 handoff 請求" \
    "$(sysmsg "$out4c")"
check "不注入 handoff 指示" EMPTY "$(ctx "$out4c")"
check "不 block（要讓 handoff skill 有 turn 可跑）" EMPTY \
    "$(printf '%s' "$out4c" | jq -r '.decision // ""')"
check "未動用催告額度" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-4c 2>/dev/null)"
check "訊息不含「本次請求已改為」" EMPTY "$(lacks "本次請求已改為" "$out4c")"

out4d=$(run sess-4d "$TMP/t4.jsonl" "" "" "/context-handoff:handoff 順便記一下 X")
check "帶 plugin 前綴與參數也認得" "已收到你的 handoff 請求" \
    "$(sysmsg "$out4d")"
check "同樣不注入指示" EMPTY "$(ctx "$out4d")"
check "同樣不動用催告額度" EMPTY "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-4d 2>/dev/null)"

check "整則就是「交接」兩字也認得" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4e "$TMP/t4.jsonl" "" "" "  交接  ")")"

# 實測使用者 shell history：句尾附加才是他最常見的用法，只認行首會漏掉一大半
check "句尾 /handoff（前面接中文）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4h "$TMP/t4.jsonl" "" "" "MR #846 #847 都合併了，更新記憶然後 /handoff")")"
check "句尾 /handoff（前面接全形逗號）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4i "$TMP/t4.jsonl" "" "" "develop pipeline 也全部綠，/handoff")")"
check "句尾 /handoff（極短句）" "已收到你的 handoff 請求" \
    "$(sysmsg "$(run sess-4j "$TMP/t4.jsonl" "" "" "已合併 /handoff")")"
check "句尾 /handoff 不動用催告額度" EMPTY \
    "$(ls "$CC_HANDOFF_STATE_DIR"/nags-sess-4j 2>/dev/null)"

# 比對必須收斂：寬鬆 substring 會讓下面這些「在談論 handoff」的句子命中，
# 門檻機制等於被使用者一句閒聊關掉。這幾條是防寬鬆比對回歸的守門測試。
check "含 handoff 字樣但不是呼叫 → 照常注入指示" "先不要執行" \
    "$(ctx "$(run sess-4f "$TMP/t4.jsonl" "" "" "以後不要再自動 handoff 了")")"
check "含 handoff 字樣的一般 prompt 照常記催告" "1" \
    "$(cat "$CC_HANDOFF_STATE_DIR"/nags-sess-4f 2>/dev/null)"
check "句中談論 handoff skill → 照常注入指示" "先不要執行" \
    "$(ctx "$(run sess-4k "$TMP/t4.jsonl" "" "" "hook 會在上下文超過 300k 時，會觸發 handoff skill")")"
check "/handoffxyz 不是完整指令 → 照常注入指示" "先不要執行" \
    "$(ctx "$(run sess-4l "$TMP/t4.jsonl" "" "" "/handoffxyz 這是什麼")")"

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
check "完全沒有 prompt 欄位 → 照常注入指示（不誤判）" "先不要執行" \
    "$(ctx "$(run_field sess-4p "$TMP/t4.jsonl" unrelated "/handoff")")"

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
# 這個分支要真正中斷：只給 systemMessage 的話 Claude 照樣有 turn 去做事，
# 使用者已經交接完了卻還在這個 session 裡繼續累積 context。
# 與 4b 不同——那個分支還需要 turn 去跑 handoff skill，這個分支已經跑完了。
check "已交接分支 decision=block" "block" \
    "$(printf '%s' "$out7" | jq -r '.decision // ""')"
check "reason 帶提示文字" "已交接過" "$(printf '%s' "$out7" | jq -r '.reason // ""')"
check "reason 帶目前用量" "310000" "$(printf '%s' "$out7" | jq -r '.reason // ""')"

# 逃生口：交接後又多做了些事想再交接一次，不可被 block 永久鎖死。
# 這也是為什麼 handoff-prompt 判定必須排在這個 block 分支「之前」。
out7c=$(run sess-7c "$TMP/t7.jsonl" "" "" "/handoff")
check "已交接過 + /handoff → 不被 block" EMPTY \
    "$(printf '%s' "$out7c" | jq -r '.decision // ""')"
check "已交接過 + /handoff → 走 handoff-prompt 分支" "已收到你的 handoff 請求" \
    "$(sysmsg "$out7c")"

# 實測發現：UserPromptSubmit 不等於「真人送出訊息」——背景任務跑完的通知也走
# 同一條路。block 會 erase 掉這則 prompt，主 agent 就永遠收不到自己派出去的
# 背景工作結果。使用者要的是「已交接後不要再執行新任務」，不是讓已經在跑的
# 背景工作結果人間蒸發。這是本次改動風險最高的一處。
out7d=$(run sess-7d "$TMP/t7.jsonl" "" "" "$TASK_NOTIF")
check "已交接過 + 背景任務通知 → 絕不可 block" EMPTY \
    "$(printf '%s' "$out7d" | jq -r '.decision // ""')"
check "已交接過 + 背景任務通知 → 仍給提醒" "已交接過" "$(sysmsg "$out7d")"
check "系統注入訊息不被當成 handoff 呼叫" EMPTY \
    "$(lacks "已收到你的 handoff 請求" "$out7d")"
# <system-reminder> 這類注入同樣不可被 block
check "已交接過 + system-reminder 注入 → 不被 block" EMPTY \
    "$(printf '%s' "$(run sess-7e "$TMP/t7.jsonl" "" "" "<system-reminder>foo</system-reminder>")" \
       | jq -r '.decision // ""')"
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

echo "── 13b. session_id 消毒：不是純識別字就不可拼進路徑"
# session_id 會被拼進 `nags-$session_id` 並**寫檔**，reset.sh 再拿同一個值去
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
#   $STATE_DIR/nags-d/../../pwned.txt  →  $TMP/pwned.txt
mkdir -p "$CC_HANDOFF_STATE_DIR/nags-d"
run 'd/../../pwned.txt' "$TMP/t13b.jsonl" >/dev/null 2>&1
check "會穿越的 session_id 不可在 STATE_DIR 之外建檔" EMPTY \
    "$(ls "$TMP/pwned.txt" 2>/dev/null)"
# 其他非白名單字元同樣要擋（空白、$、/）
check "含空白的 session_id → 靜默放行" EMPTY "$(run 'sess x' "$TMP/t13b.jsonl" 2>&1)"
check "含 / 的 session_id → 靜默放行" EMPTY "$(run 'a/b' "$TMP/t13b.jsonl" 2>&1)"
# 正常的 UUID 形態必須不被誤殺
check "正常 UUID session_id → 照常注入指示" "先不要執行" \
    "$(ctx "$(run '0f9a1c2d-3e4b-5a6f-8901-abcdef012345' "$TMP/t13b.jsonl")")"

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
# `rm -f "$STATE_DIR/nags-../../etc/evil"` 中間那段 `nags-..` 不是目錄，路徑解析
# 不到、rm -f 靜默成功、STATE_DIR 也沒變——那樣的斷言不論有沒有消毒都會綠，
# 是 vacuous test。要讓穿越真的發生，中間必須是存在的目錄：
#   session_id = "d/../../victim.txt"
#   → $STATE_DIR/nags-d/../../victim.txt  →  $TMP/victim.txt
# 也就是 STATE_DIR 之外的檔案會被刪掉。
mkdir -p "$CC_HANDOFF_STATE_DIR/nags-d"
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

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
