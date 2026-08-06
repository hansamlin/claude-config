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

# 刻意**不清** sub agent 的 sa-<agent_id>：PostCompact 講的是主 session 被壓縮，
# 與任何一個 sub agent 的 context 無關。清掉等於重新武裝 deny，對一個 context
# 仍然是滿的 sub agent 再擋一次工具呼叫——它已經交接過了，再擋只是白費一輪。
# sa-* 由 subagent-stop.sh 在該 agent 收工時清掉。真的殘留下來的話，只有
# check.sh 那支 7 天 find 會收——但那個 find 掛在「主 session 已達門檻」的
# 路徑上，主 session 從沒破過 300k 的機器上等於不會跑，殘留會一直累積。
# 殘留本身無害（deny 已經發過，最多是少一次通知），所以不為它另外加清掃。
#
# fired-/armed-/used- 是舊版 Stop hook 的狀態檔，一併清掉殘留
rm -f "$STATE_DIR/nags-$session_id" \
      "$STATE_DIR/fired-$session_id" \
      "$STATE_DIR/armed-$session_id" \
      "$STATE_DIR/used-$session_id" 2>/dev/null

exit 0
