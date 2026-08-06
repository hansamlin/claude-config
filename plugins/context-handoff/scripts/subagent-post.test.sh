#!/usr/bin/env bash
# subagent-post.sh 的分支驗證。
#
# 全程在 mktemp 目錄裡跑，用 CC_HANDOFF_STATE_DIR 隔離。直接執行即可：
#   bash plugins/context-handoff/scripts/subagent-post.test.sh
#
# payload 形狀對齊實測樣本（Claude Code 2.1.223，PostToolUse + matcher "Agent"）：
#   頂層：cwd, duration_ms, effort, hook_event_name, permission_mode, prompt_id,
#         session_id, tool_input, tool_name, tool_response, tool_use_id,
#         transcript_path
#   —— **完全沒有 agent_id / agent_type**（這支 hook 跑在父對話的工具管線裡）。
#   tool_response：agentId, agentType, content, prompt, resolvedModel, status,
#                  toolStats, totalDurationMs, totalTokens, totalToolUseCount, usage
#   content 是 content block 陣列：[{"type":"text","text":"…"}]
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/subagent-post.sh"
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)

TMP=$(mktemp -d)
export CC_HANDOFF_STATE_DIR="$TMP/state"
trap 'rm -rf "$TMP"' EXIT

# run <agentId> [tool_name] [content-json] —— content 傳 "OMIT" 代表整個 tool_response
# 不帶 content 欄位；傳其他 JSON 字面則原樣塞進去（用來測非陣列的形狀）。
run() {
    local aid="${1:-}" tn="${2:-Agent}" content="${3:-}"
    [ -z "$content" ] && content='[{"type":"text","text":"原本的結論"}]'
    jq -n --arg aid "$aid" --arg tn "$tn" --argjson c "$content" \
        '{session_id:"sess-x", cwd:"/tmp", hook_event_name:"PostToolUse",
          permission_mode:"auto", prompt_id:"p1", tool_name:$tn,
          tool_input:{prompt:"做點事"}, tool_use_id:"toolu_1",
          transcript_path:"/tmp/t.jsonl", duration_ms:8000,
          tool_response:({agentType:"general-purpose", status:"completed",
                          resolvedModel:"claude-haiku-4-5-20251001",
                          totalTokens:18034, totalToolUseCount:1,
                          usage:{input_tokens:1}, content:$c}
                         + (if $aid == "" then {} else {agentId:$aid} end))}' \
        | bash "$HOOK"
}

out()  { printf '%s' "$1" | jq -r '.hookSpecificOutput.updatedToolOutput // empty' 2>/dev/null; }
txt()  { printf '%s' "$1" | jq -r '[.hookSpecificOutput.updatedToolOutput.content[]?.text] | join("\n")' 2>/dev/null; }

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

mkdir -p "$CC_HANDOFF_STATE_DIR"

echo "── 1. 交接檔不存在 → 完全靜默（含 stderr）"
# 絕大多數派工走這條路：sub agent 從頭到尾沒超標，正常收工。
check "無交接檔 → 無輸出" EMPTY "$(run aaa 2>&1)"

echo "── 2. 交接檔存在 → 注入警示"
printf 'handoff' > "$CC_HANDOFF_STATE_DIR/subagent-handoff-bbb.md"
out2=$(run bbb)
check "hookEventName 正確" "PostToolUse" \
    "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.hookEventName // ""')"
check "有 updatedToolOutput" "content" "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.updatedToolOutput | keys | join(",")')"
check "注入文字含中止說明" "context 門檻自動交接" "$(txt "$out2")"
check "注入文字含交接檔絕對路徑" "$CC_HANDOFF_STATE_DIR/subagent-handoff-bbb.md" "$(txt "$out2")"
check "注入文字要求以相同 agent_type 重派" "相同" "$(txt "$out2")"
check "注入文字要求先讀交接檔" "先讀該交接檔" "$(txt "$out2")"
check "注入文字自報來源，免得被當成 sub agent 自己寫的" "PostToolUse hook 附加" "$(txt "$out2")"

echo "── 3. 必須是**附加**不是取代（sub agent 的部分結論不可丟）"
# issue #12 特別點名這條：sub agent 的回覆裡可能有已完成的部分結論。
check "原本的 content 仍在" "原本的結論" "$(txt "$out2")"
check "content block 從 1 個變成 2 個" "2" \
    "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.updatedToolOutput.content | length')"
check "第 1 個 block 原封不動" "原本的結論" \
    "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.updatedToolOutput.content[0].text')"

echo "── 4. tool_response 的其他欄位必須原封帶回（outputSchema 驗證會擋）"
# 套用端拿**工具自己的 outputSchema** 驗 updatedToolOutput，不符就靜默退回原輸出
# （transcript 只留一則 hook_error_during_execution，沒有人會發現這個 hook 白做了）。
# 實測送純字串與送單獨的 content 陣列都失敗，訊息是
# `does not match Agent's output shape; using original output`。
# 所以實作是 `.tool_response | .content += [...]`，逐一列舉欄位會在 schema 一改
# 時靜默失效——這幾條就是那個回歸。
for k in agentId agentType status resolvedModel totalTokens totalToolUseCount usage; do
    check "保留欄位 $k" "true" \
        "$(printf '%s' "$out2" | jq -r --arg k "$k" '.hookSpecificOutput.updatedToolOutput | has($k)')"
done
check "agentId 值未被改動" "bbb" \
    "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.updatedToolOutput.agentId')"

echo "── 5. 輸出必須是合法 JSON"
check "可被 jq 解析" "hookSpecificOutput" \
    "$(printf '%s' "$out2" | jq -r 'keys | join(",")')"

echo "── 6. 取不到 agentId → 靜默"
# 這支 hook 拿的是 tool_response.agentId，**不是**頂層 agent_id（頂層根本沒有）。
printf 'x' > "$CC_HANDOFF_STATE_DIR/subagent-handoff-.md"
check "tool_response 無 agentId → 無輸出" EMPTY "$(run '' 2>&1)"

echo "── 7. agentId 路徑注入防護"
# agentId 會被拼進 `$STATE_DIR/subagent-handoff-<id>.md`。
#
# ⚠️ 中間段必須是**真實存在的目錄**，穿越才會真的發生——這正是 README 記載的
# 第三種 vacuous test 陷阱。`subagent-handoff-../../x` 裡的 `subagent-handoff-..`
# 不是目錄，路徑解析不到、`[ -f ]` 一律為假，**有沒有消毒都會綠**。
# 所以這裡刻意建出 `subagent-handoff-d/` 這個目錄，讓
#   $STATE_DIR/subagent-handoff-d/../../victim.md  ==  $TMP/victim.md
# 真的解析得到一個存在的檔案。拿掉消毒那段 case 之後這條必須變紅。
mkdir -p "$CC_HANDOFF_STATE_DIR/subagent-handoff-d"
printf 'VICTIM' > "$TMP/victim.md"
check "穿越用的 victim 檔確實存在（fixture 自檢）" "VICTIM" "$(cat "$TMP/victim.md")"
check "含 ../ 的 agentId → 靜默退出" EMPTY "$(run 'd/../../victim' 2>&1)"
# 反證：把中間段換成合法 id，同一個位置的檔案要真的讀得到——否則上一條是
# 因為「檔案本來就構不到」而綠，跟消毒無關（vacuous）。
printf 'ok' > "$CC_HANDOFF_STATE_DIR/subagent-handoff-legit.md"
check "合法 agentId → 確實注入（證明上一條非 vacuous）" "context 門檻自動交接" \
    "$(txt "$(run legit)")"

echo "── 8. tool_name 不是 Agent → 靜默"
# matcher 已經只讓 Agent 進來，但 matcher 語意日後可能改成前綴比對，而這段
# 注入文字對其他工具是完全錯的訊息。
check "tool_name=Bash → 無輸出" EMPTY "$(run legit Bash 2>&1)"
check "tool_name=AgentSomething（前綴誤命中）→ 無輸出" EMPTY \
    "$(run legit AgentSomething 2>&1)"

echo "── 9. content 不是陣列 → 靜默（寧可不注入，也不要把回傳內容弄壞）"
check "content 是字串 → 無輸出" EMPTY "$(run legit Agent '"純字串"' 2>&1)"
check "content 是物件 → 無輸出" EMPTY "$(run legit Agent '{"nested":1}' 2>&1)"
check "content 是 null → 無輸出" EMPTY "$(run legit Agent 'null' 2>&1)"

echo "── 10. CC_HANDOFF_DISABLE=1 → 完全靜默"
check "停用" EMPTY "$(CC_HANDOFF_DISABLE=1 run legit 2>&1)"

echo "── 11. CC_HANDOFF_TRACE"
# trace 是這支 hook 唯一能便宜證實它有在跑的手段；它最大的失敗模式是靜默地
# 永遠不觸發（拿錯 agentId 欄位之類）。寫入要排在所有早退之前。
: > "$TMP/trace.jsonl"
CC_HANDOFF_TRACE="$TMP/trace.jsonl" run aaa >/dev/null 2>&1   # aaa 沒有交接檔＝最早的早退
check "沒注入的路徑也已寫進 trace" "PostToolUse" "$(cat "$TMP/trace.jsonl" 2>/dev/null)"
check "trace 內容是合法 JSON" "aaa" \
    "$(jq -r '.tool_response.agentId // ""' < "$TMP/trace.jsonl" 2>/dev/null)"
# TRACE 指到不可寫路徑不可污染正常路徑
bad=$(CC_HANDOFF_TRACE="$TMP/no-such-dir/t.jsonl" run legit 2>/dev/null)
bad_rc=$?
check "TRACE 不可寫 → 注入仍正常" "context 門檻自動交接" "$(txt "$bad")"
check "TRACE 不可寫 → exit code 仍為 0" "0" "$bad_rc"

echo "── 12. hooks.json 註冊（結構斷言）"
# matchQuery 比對的是 tool_name，而實測派工工具的 tool_name 是 **Agent**
# （不是 Task——`--allowedTools` 才寫 Task）。matcher 寫錯就是靜默失效。
check "PostToolUse 已註冊" "subagent-post.sh" \
    "$(jq -r '.hooks.PostToolUse[0].hooks[0].command // ""' "$PLUGIN_ROOT/hooks/hooks.json")"
check "matcher 必須是 Agent" "Agent" \
    "$(jq -r '.hooks.PostToolUse[0].matcher // ""' "$PLUGIN_ROOT/hooks/hooks.json")"
check "SubagentStop 仍然不得註冊" EMPTY \
    "$(jq -r 'if (.hooks.SubagentStop | type) == "array" then "REGISTERED" else "" end' \
        "$PLUGIN_ROOT/hooks/hooks.json")"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
