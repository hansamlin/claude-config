#!/bin/bash
# Read JSON input from stdin
input=$(cat)

# --- context-usage skill cache -------------------------------------------
# 把 Claude Code 餵進來的第一手 context_window 數字落地，讓 `context-usage`
# skill 的腳本讀得到（模型看不到 statusline 的輸出）。
# 刻意只用 sed，不用 jq —— 這樣分享給沒裝 jq 的人也能直接貼。
# 純加寫，失敗不影響下方顯示。
{
    # `:` 後面容許空白 —— payload 是否 pretty-print 不保證，兩種都要吃
    _cu_n() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"; }
    _cu_sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _cu_mdl=$(printf '%s' "$input" | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*{[^}]*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _cu_ti=$(_cu_n total_input_tokens); _cu_to=$(_cu_n total_output_tokens)
    _cu_ws=$(_cu_n context_window_size)
    if [ -n "$_cu_sid" ] && [ -n "$_cu_ws" ]; then
        mkdir -p "$HOME/.claude/context-usage"
        printf '{"session_id":"%s","model":{"display_name":"%s"},"context_window":{"total_input_tokens":%s,"total_output_tokens":%s,"context_window_size":%s}}\n' \
            "$_cu_sid" "$_cu_mdl" "${_cu_ti:-0}" "${_cu_to:-0}" "$_cu_ws" \
            > "$HOME/.claude/context-usage/${_cu_sid}.json" 2>/dev/null
    fi
} 2>/dev/null || true
# -------------------------------------------------------------------------

# Extract values using jq
MODEL=$(echo "$input" | jq -r '.model.display_name')
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] && MODEL_SEG="[${SESSION_ID:0:8}] | [$MODEL]" || MODEL_SEG="[$MODEL]"

# Get git branch if in a git repo
GIT_BRANCH=""
if git -c core.worktrees= rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    if [ -n "$BRANCH" ]; then
        GIT_BRANCH="$BRANCH"
    else
        # Detached HEAD state
        GIT_BRANCH=$(git rev-parse --short HEAD 2>/dev/null)
    fi
fi

# Get current directory
CURRENT_PATH=$(pwd)

# Detect worktree
GIT_WORKTREE=$(echo "$input" | jq -r '.workspace.git_worktree // empty')

# Build first line: path (+ [Worktree] if in worktree)
if [ -n "$GIT_WORKTREE" ]; then
    FIRST_LINE="$CURRENT_PATH [Worktree]"
else
    FIRST_LINE="$CURRENT_PATH"
fi

# Context usage: used/total (pct%) used, placed right after the model
CTX_USED=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)')
CTX_TOTAL=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
if [ -n "$CTX_TOTAL" ] && [ "$CTX_TOTAL" -gt 0 ]; then
    # Format a token count into a human-readable k/m string
    fmt_tokens() {
        awk -v n="$1" 'BEGIN {
            if (n >= 1000000) printf "%gm", n / 1000000;
            else if (n >= 1000) printf "%.0fk", n / 1000;
            else printf "%d", n;
        }'
    }
    USED_STR=$(fmt_tokens "$CTX_USED")
    TOTAL_STR=$(fmt_tokens "$CTX_TOTAL")
    CTX_PCT=$(awk -v u="$CTX_USED" -v t="$CTX_TOTAL" 'BEGIN { printf "%.1f", u / t * 100 }')
    CONTEXT_SEG=" | ${USED_STR}/${TOTAL_STR} (${CTX_PCT}%) used"
else
    CONTEXT_SEG=""
fi

# Build third line: model + 5-hour rate limit as bar + reset time
FIVE_HOUR_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$FIVE_HOUR_PCT" ]; then
    # Calculate filled blocks (0-10), rounding to nearest integer
    FILLED=$(printf "%.0f" "$(echo "$FIVE_HOUR_PCT / 10" | bc -l)")
    # Clamp to 0-10
    [ "$FILLED" -lt 0 ] && FILLED=0
    [ "$FILLED" -gt 10 ] && FILLED=10
    EMPTY=$((10 - FILLED))

    # Choose color based on percentage
    PCT_INT=$(printf "%.0f" "$FIVE_HOUR_PCT")
    if [ "$PCT_INT" -ge 90 ]; then
        BAR_COLOR=$'\e[38;2;210;70;30m'
    elif [ "$PCT_INT" -ge 80 ]; then
        BAR_COLOR=$'\e[38;2;220;144;0m'
    else
        BAR_COLOR=$'\e[38;2;34;168;89m'
    fi
    DIM_COLOR=$'\e[38;2;80;80;80m'
    RESET=$'\e[0m'

    # Build filled and empty bar strings
    FILLED_STR=""
    i=0
    while [ "$i" -lt "$FILLED" ]; do
        FILLED_STR="${FILLED_STR}█"
        i=$((i + 1))
    done
    EMPTY_STR=""
    i=0
    while [ "$i" -lt "$EMPTY" ]; do
        EMPTY_STR="${EMPTY_STR}░"
        i=$((i + 1))
    done

    # Calculate reset time
    RESET_STR=""
    RESETS_AT=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    if [ -n "$RESETS_AT" ]; then
        NOW=$(date +%s)
        DIFF=$(( RESETS_AT - NOW ))
        if [ "$DIFF" -gt 0 ]; then
            HOURS=$(( DIFF / 3600 ))
            MINS=$(( (DIFF % 3600) / 60 ))
            if [ "$HOURS" -gt 0 ]; then
                RESET_STR=" | Resets in ${HOURS} hr ${MINS} min"
            else
                RESET_STR=" | Resets in ${MINS} min"
            fi
        fi
    fi

    THIRD_LINE="${MODEL_SEG}${CONTEXT_SEG} | 5h: ${BAR_COLOR}${FILLED_STR}${DIM_COLOR}${EMPTY_STR}${RESET} ${BAR_COLOR}${PCT_INT}%${RESET}${RESET_STR}"
else
    THIRD_LINE="${MODEL_SEG}${CONTEXT_SEG}"
fi

# Output: line 1 (path), line 2 (branch if any), line 3 (model + rate limit)
printf "%s\n" "$FIRST_LINE"
[ -n "$GIT_BRANCH" ] && printf "↳ (%s)\n" "$GIT_BRANCH"
printf "%s" "$THIRD_LINE"
