#!/usr/bin/env bash
# PostCompact hook：compact 之後 context 會塌回去，
# 先前「已強制交接過」的記錄就沒有意義了，清掉讓門檻重新計算。
#
# 只掛 PostCompact 不掛 PreCompact：實測 PreCompact 在「壓縮嘗試前」就觸發，
# 連 /compact 因訊息太少而失敗（Not enough messages to compact）那次也照跑，
# 掛上去會在壓縮根本沒發生時誤清狀態。PostCompact 才代表真的壓縮完成。
set -uo pipefail

STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

session_id=$(cat | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$session_id" ] || exit 0

# armed-/used- 是舊版 Stop hook 的狀態檔，一併清掉殘留
rm -f "$STATE_DIR/fired-$session_id" \
      "$STATE_DIR/armed-$session_id" \
      "$STATE_DIR/used-$session_id" 2>/dev/null

exit 0
