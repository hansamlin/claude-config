#!/usr/bin/env bash
# title.sh 與 issue-session-title plugin 註冊的驗證（黑箱，只依規格寫）。
#
# 背景：UserPromptSubmit hook。prompt 提到 issue 編號、且 session 還沒有名稱
# （transcript 裡沒有 custom-title 紀錄）時，stdout 輸出 sessionTitle = issue-<編號>。
#
# 直接執行即可（不依賴 cwd）：
#   bash plugins/issue-session-title/scripts/title.test.sh
#
# 涵蓋：
#   1  issue 寫法辨識（issue 98、issue #98、issue#98、issues/98、網址、大小寫）
#   2  多個 issue 取第一個；只有 #98 不算；無 issue 字樣不算
#   3  transcript 含 custom-title → 不輸出；不含 → 輸出；檔案不存在 → 輸出
#   4  stdin 空、非合法 JSON、空 prompt、prompt 含跳脫字元
#   5  hooks/hooks.json 註冊形狀
#   6  .claude-plugin/plugin.json
#   7  marketplace.json 登錄
#   8  settings.fragment.json 啟用
#   9  install.sh 驗證清單列入本測試
# （1–4 皆檢查 exit 0、stderr 為空）
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/title.sh"
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

# hook_run <stdin-file>：跑 hook，結果放進 RC / OUT / ERR
hook_run() {
    : > "$TMP/out"; : > "$TMP/err"
    bash "$HOOK" < "$1" > "$TMP/out" 2> "$TMP/err"
    RC=$?
    OUT=$(cat "$TMP/out")
    ERR=$(cat "$TMP/err")
}

# expect_title <label> <prompt> <transcript_path> <issue-number|EMPTY>
# 組出 UserPromptSubmit payload，跑 hook 並斷言輸出
expect_title() {
    local label="$1" prompt="$2" tp="$3" want="$4" in="$TMP/in.json"
    jq -cn --arg p "$prompt" --arg t "$tp" \
        '{hook_event_name:"UserPromptSubmit", prompt:$p, transcript_path:$t, session_id:"x"}' > "$in"
    hook_run "$in"
    check_eq "[$label] exit 0" "0" "$RC"
    check "[$label] stderr 為空" EMPTY "$ERR"
    if [ "$want" = "EMPTY" ]; then
        check "[$label] 不輸出任何東西" EMPTY "$OUT"
    else
        check_eq "[$label] stdout 恰一行" "1" "$(grep -c '' "$TMP/out")"
        check_eq "[$label] 輸出為 sessionTitle=issue-$want 的合法 JSON" \
            "$(jq -cnS --arg t "issue-$want" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", sessionTitle:$t}}')" \
            "$(jq -cS '.' "$TMP/out" 2>/dev/null)"
    fi
}

# 共用 transcript 夾具
T_NOEXIST="$TMP/does-not-exist.jsonl"
T_EMPTY="$TMP/empty.jsonl"; : > "$T_EMPTY"
T_PLAIN="$TMP/plain.jsonl"
printf '%s\n' \
    '{"type":"user","message":"hi","sessionId":"x"}' \
    '{"type":"assistant","message":"hello","sessionId":"x"}' > "$T_PLAIN"
T_CUSTOM="$TMP/custom.jsonl"
printf '%s\n' \
    '{"type":"user","message":"hi","sessionId":"x"}' \
    '{"type":"custom-title","customTitle":"foo","sessionId":"x"}' \
    '{"type":"assistant","message":"hello","sessionId":"x"}' > "$T_CUSTOM"
T_CUSTOM_LAST="$TMP/custom-last.jsonl"
printf '%s\n' '{"type":"user","message":"hi","sessionId":"x"}' > "$T_CUSTOM_LAST"
printf '%s' '{"type":"custom-title","customTitle":"bar","sessionId":"x"}' >> "$T_CUSTOM_LAST"  # 最後一行、無換行

echo "── 1. issue 寫法辨識"
expect_title "issue 98" "issue 98" "$T_NOEXIST" 98
expect_title "issue #98" "issue #98" "$T_NOEXIST" 98
expect_title "issue#98" "issue#98" "$T_NOEXIST" 98
expect_title "issues/98" "看 issues/98 的內容" "$T_NOEXIST" 98
expect_title "GitLab 網址" "https://gitlab.com/g/p/-/issues/98 幫我看" "$T_NOEXIST" 98
expect_title "Issue 98（大寫首字）" "Issue 98 怎麼處理" "$T_NOEXIST" 98
expect_title "ISSUE 98（全大寫）" "請處理 ISSUE 98" "$T_NOEXIST" 98

echo "── 2. 多個 issue、只有 #、無 issue 字樣"
expect_title "多個 issue 取第一個" "issue 12 跟 issue 34 一起做" "$T_NOEXIST" 12
expect_title "網址與 issue 字樣混用，取文字中最先出現者" \
    "https://gitlab.com/g/p/-/issues/9 和 issue 3" "$T_NOEXIST" 9
expect_title "只出現 #98 不算" "看一下 #98 這個" "$T_NOEXIST" EMPTY
expect_title "無 issue 字樣的一般 prompt" "幫我寫一個排序函式" "$T_NOEXIST" EMPTY
expect_title "有 issue 字樣但沒有編號" "this issue is broken" "$T_NOEXIST" EMPTY

echo "── 3. transcript 的 custom-title 判斷"
expect_title "transcript 含 custom-title → 不輸出" "issue 98" "$T_CUSTOM" EMPTY
expect_title "custom-title 為最後一行（無結尾換行）→ 不輸出" "issue 98" "$T_CUSTOM_LAST" EMPTY
expect_title "transcript 存在但無 custom-title → 輸出" "issue 98" "$T_PLAIN" 98
expect_title "transcript 存在但為空檔 → 輸出" "issue 98" "$T_EMPTY" 98
expect_title "transcript 不存在 → 輸出" "issue 98" "$T_NOEXIST" 98

echo "── 4. stdin 邊界"
: > "$TMP/empty-stdin.json"
hook_run "$TMP/empty-stdin.json"
check_eq "[空 stdin] exit 0" "0" "$RC"
check "[空 stdin] stderr 為空" EMPTY "$ERR"
check "[空 stdin] 不輸出任何東西" EMPTY "$OUT"

printf '%s' 'not json {{{' > "$TMP/bad-json.json"
hook_run "$TMP/bad-json.json"
check_eq "[非法 JSON] exit 0" "0" "$RC"
check "[非法 JSON] stderr 為空" EMPTY "$ERR"
check "[非法 JSON] 不輸出任何東西" EMPTY "$OUT"

expect_title "空 prompt" "" "$T_NOEXIST" EMPTY
expect_title "prompt 含換行與引號" $'第一行\n說 "issue 55" 好嗎' "$T_NOEXIST" 55

echo "── 5. hooks/hooks.json 註冊形狀"
check_eq "hooks.json 為合法 JSON 物件" "object" "$(jq -r 'type' "$HOOKS_JSON" 2>/dev/null)"
check_eq "只註冊 UserPromptSubmit" "UserPromptSubmit" \
    "$(jq -r '.hooks | keys | join(",")' "$HOOKS_JSON" 2>/dev/null)"
check_eq "UserPromptSubmit 恰有一個 entry" "1" \
    "$(jq -r '.hooks.UserPromptSubmit | if type == "array" then length else "NOT_ARRAY" end' "$HOOKS_JSON" 2>/dev/null)"
check_eq "entry 無 matcher（或 \"*\"／空字串）" "ok" \
    "$(jq -r '.hooks.UserPromptSubmit[0] | if (has("matcher") | not) or .matcher == "*" or .matcher == "" then "ok" else "matcher=\(.matcher)" end' "$HOOKS_JSON" 2>/dev/null)"
check_eq "hooks[0].type 為 command" "command" \
    "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].type // ""' "$HOOKS_JSON" 2>/dev/null)"
cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // ""' "$HOOKS_JSON" 2>/dev/null)
check "command 含 \${CLAUDE_PLUGIN_ROOT}" '${CLAUDE_PLUGIN_ROOT}' "$cmd"
check "command 含 scripts/title.sh" "scripts/title.sh" "$cmd"

echo "── 6. .claude-plugin/plugin.json"
check_eq "name 為 issue-session-title" "issue-session-title" \
    "$(jq -r '.name // ""' "$PLUGIN_JSON" 2>/dev/null)"
check_eq "有非空 version" "true" \
    "$(jq -r '(.version | type) == "string" and (.version | length) > 0' "$PLUGIN_JSON" 2>/dev/null)"

echo "── 7. marketplace.json 登錄"
check_eq "plugins 含 issue-session-title 且 source 正確" "./plugins/issue-session-title" \
    "$(jq -r '[.plugins[] | select(.name == "issue-session-title") | .source] | first // ""' "$MARKETPLACE" 2>/dev/null)"

echo "── 8. settings.fragment.json 啟用"
check_eq "enabledPlugins[issue-session-title@sam-tools] == true" "true" \
    "$(jq -r '.enabledPlugins["issue-session-title@sam-tools"] == true' "$FRAGMENT" 2>/dev/null)"

echo "── 9. install.sh 驗證清單"
check "install.sh 列出本測試" "plugins/issue-session-title/scripts/title.test.sh" \
    "$(grep -F 'bash "$REPO/plugins/issue-session-title/scripts/title.test.sh"' "$INSTALL" 2>/dev/null)"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
