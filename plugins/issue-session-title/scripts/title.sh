#!/usr/bin/env bash
# UserPromptSubmit hook：session 還沒有名稱時，若 prompt 提到 issue 編號，
# 把 session 名稱設成 issue-<編號>（等同 /rename issue-<編號>，terminal tab 標題會跟著變）。
# 已經有名稱（之前自動命名過，或手動 /rename 過）就不動。
# 認得：「issue 98」「issue #98」「issues/98」（GitLab 網址）。
input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
# /rename 與 hook 設的名稱都會在 transcript 留下 custom-title 紀錄
if [ -n "$transcript" ] && [ -f "$transcript" ] && grep -q '"type":"custom-title"' "$transcript" 2>/dev/null; then
    exit 0
fi
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)
num=$(printf '%s' "$prompt" | grep -oiE 'issues?[[:space:]]*(#|/)?[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$')
[ -z "$num" ] && exit 0
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"issue-%s"}}\n' "$num"
