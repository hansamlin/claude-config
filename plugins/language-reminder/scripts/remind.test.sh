#!/usr/bin/env bash
# remind.sh 與 language-reminder plugin 註冊的驗證。
#
# 背景：長時間連續工具呼叫時，回覆會漂成英文（英文系統提醒貼近最新 context，
# 而 language 指示只在遙遠的 system prompt）。本 plugin 用 PostToolUse hook
# 在每次工具呼叫後經 hookSpecificOutput.additionalContext 注入一句繁中提醒。
#
# 直接執行即可（不依賴 cwd）：
#   bash plugins/language-reminder/scripts/remind.test.sh
#
# 涵蓋：
#   1  一般 PostToolUse payload → 合法 JSON、hookEventName、additionalContext 含繁中提醒
#   2  空 stdin → 同上
#   3  帶 agent_id 的 sub agent payload → 同上
#   （1–3 皆檢查 exit 0、stderr 為空，且 transcript_path 不存在也不受影響）
#   4  hooks/hooks.json 註冊形狀
#   5  .claude-plugin/plugin.json
#   6  marketplace.json 登錄
#   7  settings.fragment.json 啟用
#   8  install.sh 驗證清單列入本測試
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/remind.sh"
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
REPO=$(cd "$PLUGIN_ROOT/../.." && pwd)
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKETPLACE="$REPO/.claude-plugin/marketplace.json"
FRAGMENT="$REPO/settings.fragment.json"
INSTALL="$REPO/install.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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
check_eq() { # check_eq <label> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "  ✅ $1"; pass=$((pass+1));
    else echo "  ❌ $1 — 預期 '$2'，實得 '$3'"; fail=$((fail+1)); fi
}

# run_case <label> <stdin-file>：跑 hook 並斷言輸出形狀
run_case() {
    local label="$1" input="$2" rc
    : > "$TMP/out"; : > "$TMP/err"
    bash "$HOOK" < "$input" > "$TMP/out" 2> "$TMP/err"
    rc=$?
    check_eq "[$label] exit 0" "0" "$rc"
    check "[$label] stderr 為空" EMPTY "$(cat "$TMP/err")"
    check_eq "[$label] stdout 是合法 JSON 物件" "object" \
        "$(jq -r 'type' < "$TMP/out" 2>/dev/null)"
    check_eq "[$label] hookEventName 為 PostToolUse" "PostToolUse" \
        "$(jq -r '.hookSpecificOutput.hookEventName // ""' < "$TMP/out" 2>/dev/null)"
    check_eq "[$label] additionalContext 為非空字串" "true" \
        "$(jq -r '(.hookSpecificOutput.additionalContext | type) == "string"
                  and (.hookSpecificOutput.additionalContext | length) > 0' \
            < "$TMP/out" 2>/dev/null)"
    check "[$label] additionalContext 含繁中指示" "繁體中文（台灣用語）" \
        "$(jq -r '.hookSpecificOutput.additionalContext // ""' < "$TMP/out" 2>/dev/null)"
}

echo "── 1. 一般 PostToolUse payload（transcript_path 不存在）"
printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{},"tool_response":{},"session_id":"x","transcript_path":"/nonexistent"}' \
    > "$TMP/main.json"
run_case "一般" "$TMP/main.json"

echo "── 2. 空 stdin"
: > "$TMP/empty.json"
run_case "空 stdin" "$TMP/empty.json"

echo "── 3. sub agent payload（帶 agent_id）"
printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/x"},"tool_response":{},"session_id":"x","transcript_path":"/nonexistent/sub.jsonl","agent_id":"agent-123","agent_type":"general-purpose"}' \
    > "$TMP/sub.json"
run_case "sub agent" "$TMP/sub.json"

echo "── 4. hooks/hooks.json 註冊形狀"
check_eq "hooks.json 存在且為合法 JSON" "object" "$(jq -r 'type' "$HOOKS_JSON" 2>/dev/null)"
check_eq "PostToolUse 恰有一個 entry" "1" \
    "$(jq -r '.hooks.PostToolUse | if type == "array" then length else "NOT_ARRAY" end' "$HOOKS_JSON" 2>/dev/null)"
check_eq "PostToolUse 無 matcher（或 \"*\"／空字串）" "ok" \
    "$(jq -r '.hooks.PostToolUse[0] | if (has("matcher") | not) or .matcher == "*" or .matcher == "" then "ok" else "matcher=\(.matcher)" end' "$HOOKS_JSON" 2>/dev/null)"
check_eq "hooks[0].type 為 command" "command" \
    "$(jq -r '.hooks.PostToolUse[0].hooks[0].type // ""' "$HOOKS_JSON" 2>/dev/null)"
cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command // ""' "$HOOKS_JSON" 2>/dev/null)
check "command 含 \${CLAUDE_PLUGIN_ROOT}" '${CLAUDE_PLUGIN_ROOT}' "$cmd"
check "command 含 scripts/remind.sh" "scripts/remind.sh" "$cmd"
check_eq "不得註冊 SubagentStop" "absent" \
    "$(jq -r 'if (.hooks | has("SubagentStop")) then "REGISTERED" else "absent" end' "$HOOKS_JSON" 2>/dev/null)"
check_eq "不得註冊 Stop" "absent" \
    "$(jq -r 'if (.hooks | has("Stop")) then "REGISTERED" else "absent" end' "$HOOKS_JSON" 2>/dev/null)"

echo "── 5. .claude-plugin/plugin.json"
check_eq "name 為 language-reminder" "language-reminder" \
    "$(jq -r '.name // ""' "$PLUGIN_JSON" 2>/dev/null)"
check_eq "有非空 version" "true" \
    "$(jq -r '(.version | type) == "string" and (.version | length) > 0' "$PLUGIN_JSON" 2>/dev/null)"

echo "── 6. marketplace.json 登錄"
check_eq "plugins 含 language-reminder 且 source 正確" "./plugins/language-reminder" \
    "$(jq -r '[.plugins[] | select(.name == "language-reminder") | .source] | first // ""' "$MARKETPLACE" 2>/dev/null)"

echo "── 7. settings.fragment.json 啟用"
check_eq "enabledPlugins[language-reminder@sam-tools] == true" "true" \
    "$(jq -r '.enabledPlugins["language-reminder@sam-tools"] == true' "$FRAGMENT" 2>/dev/null)"

echo "── 8. install.sh 驗證清單"
check "install.sh 列出本測試" "plugins/language-reminder/scripts/remind.test.sh" \
    "$(grep -F 'bash "$REPO/plugins/language-reminder/scripts/remind.test.sh"' "$INSTALL" 2>/dev/null)"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
