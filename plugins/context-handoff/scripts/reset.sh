#!/usr/bin/env bash
# PostCompact hook：compact 之後 context 會塌回去，
# 先前「已強制交接過」的記錄就沒有意義了，清掉讓門檻重新計算。
#
# 只掛 PostCompact 不掛 PreCompact：實測 PreCompact 在「壓縮嘗試前」就觸發，
# 連 /compact 因訊息太少而失敗（Not enough messages to compact）那次也照跑，
# 掛上去會在壓縮根本沒發生時誤清狀態。PostCompact 才代表真的壓縮完成。
set -uo pipefail

# 與 check.sh / subagent-check.sh / subagent-stop.sh 共用同一個總開關。
# 2.2.1 之前只有這支漏掉，結果 CC_HANDOFF_DISABLE=1 之下 PostCompact 仍會去刪
# nags-*——「完全停用」卻還在改狀態，是最難察覺的那種不一致。
[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

session_id=$(cat | jq -r '.session_id // ""' 2>/dev/null)
[ -n "$session_id" ] || exit 0

# session_id 會被拼進下面 `rm -f` 的路徑——這是整個 plugin 唯一會刪檔的地方，
# 風險最高，所以白名單在這裡最不可省。字元集與 check.sh / subagent-check.sh
# 一致。不符就靜默 exit 0：不清狀態最多是多催一次，拼錯路徑去 rm 是災難。
case "$session_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# 刻意**不清** sub agent 的 sa-<agent_id> 與 sa-nag-<agent_id>：PostCompact 講的
# 是主 session 被壓縮，與任何一個 sub agent 的 context 無關。清掉 sa-* 等於
# 重新武裝 deny，對一個 context 仍然是滿的 sub agent 再擋一次工具呼叫——它
# 已經交接過了，再擋只是白費一輪；清掉 sa-nag-* 則會對它重新武裝里程碑提醒。
# 兩者都由 check.sh 那支 7 天 find 收（已排在所有早退之前），殘留本身無害
# （deny 已發過、level 已記過，最多是少一次通知），所以不為它們另外加清掃。
#
# nags-* 是 2.4.0 以前的催告計數檔，里程碑機制（nag-level-$session_id）取代後
# 已不會再寫新的，這裡保留 rm 是為了收舊版本留下的殘留。nag-level-* 則與
# nags-* 相同語意——主 session 被壓縮後 context 塌回去，里程碑 level 過期，
# 清掉讓提醒重新計算。fired-/armed-/used- 是更早的 Stop hook 狀態檔，一併清。
rm -f "$STATE_DIR/nags-$session_id" \
      "$STATE_DIR/nag-level-$session_id" \
      "$STATE_DIR/fired-$session_id" \
      "$STATE_DIR/armed-$session_id" \
      "$STATE_DIR/used-$session_id" 2>/dev/null

exit 0
