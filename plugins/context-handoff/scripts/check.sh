#!/usr/bin/env bash
# UserPromptSubmit hook：使用者送出訊息時檢查 context 用量，超過門檻就先交接。
#
# 為什麼掛在 UserPromptSubmit 而不是 Stop：
#   1. 這個事件只在「使用者實際送出訊息」時觸發，本身就證明有人在互動，
#      不必再猜 session 是不是無人值守的背景 job（舊版用 sessionKind=="bg"
#      排除，結果把使用者日常在用的 bg session 全擋掉了，門檻永遠不觸發）。
#   2. 攔截點落在使用者交派新任務的當下，Claude 還沒開始動工就先交接，
#      不會出現「做到一半被打斷」。
#   3. 因此也不需要預測下一輪成長量——直接看當下用量夠不夠門檻即可。
#
# 為什麼要自己算 token：hook 的 stdin payload 不含任何 context/token 欄位
# （只有 statusline 拿得到 .context_window），所以唯一來源是 transcript_path
# 裡最後一筆 assistant 訊息的 message.usage。
#
# 可調環境變數：
#   CC_HANDOFF_THRESHOLD  觸發門檻（token），預設 300000
#   CC_HANDOFF_MAX_NAGS   最多主動要求交接幾次，預設 3
#   CC_HANDOFF_LOOKBACK   往回掃幾筆 transcript 找 handoff 執行記錄，預設 300
#   CC_HANDOFF_DISABLE    設為 1 完全停用
#   CC_HANDOFF_STATE_DIR  狀態目錄，預設 ~/.claude/handoff-state（測試用來隔離）
#   CC_HANDOFF_TRACE      設成檔案路徑則附加寫入收到的 payload，除錯用

set -uo pipefail

THRESHOLD="${CC_HANDOFF_THRESHOLD:-300000}"
MAX_NAGS="${CC_HANDOFF_MAX_NAGS:-3}"
LOOKBACK="${CC_HANDOFF_LOOKBACK:-300}"
STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"

[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"
jq_in() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# sub agent 的 context 與主 session 無關，交接要等主 agent 接手才有意義。
# 真正做到這件事的**不是**下面那行 agent_id guard，而是下方算 used 時的
# `isSidechain != true` 過濾——sub agent 的訊息在主 transcript 裡全都是
# isSidechain:true，濾掉之後剩下的就只有主線用量。那才是第一道也是唯一實際
# 生效的防線（回歸測試見 check.test.sh「── 9. isSidechain 過濾」）。
#
# 下面這行 agent_id guard 是**零成本的防禦性 dead code**，保留無妨但不是防線：
# 實測 + binary 反查（Claude Code 2.1.223）確認 UserPromptSubmit 的 payload
# **永遠**不帶 agent_id——建構 payload 的 `Bm(t)` 沒有傳入 agent context 那個
# 參數，agent_id 恆為 undefined。全部 trace 檔裡 UserPromptSubmit 帶 agent_id
# 的次數是 **0**，而同一批 run 的 PreToolUse / SubagentStop 帶 agent_id 的有
# 上百筆；trace 寫入排在這個 guard 之前，所以那個 0 不是採樣不足。
#
# 官方文件寫的 agent_id「present only when the hook fires inside a subagent
# call」——對 PreToolUse 成立，對 UserPromptSubmit **不成立**。
#
# 只認 agent_id 不認 agent_type 的理由仍然有效：`claude --agent foo` 啟動的
# **主** session 帶的是 agent_type，連它一起擋的話那種 session 會永遠不觸發，
# 正是這個 plugin 原本 bg 排除那個 bug 的翻版。
[ -n "$(jq_in '.agent_id // ""')" ] && exit 0

transcript=$(jq_in '.transcript_path // ""')
session_id=$(jq_in '.session_id // ""')
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ -n "$session_id" ] || exit 0

# session_id 會被拼進 `nags-$session_id` 路徑並寫檔，而 reset.sh 拿同一個值去
# `rm -f`。實際上它一律是 UUID（只含 [0-9a-f-]），但「實際上長這樣」不是防禦。
# 白名單刻意與 agent_id 那條同一套字元集：一致的風格比逐處收得更緊更好維護，
# 也不會誤殺日後可能出現的其他 id 形態。不符就靜默 exit 0——寧可少一次催告，
# 也不要把 ../ 拼進會被寫入、會被刪除的路徑。
case "$session_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# 目前 context 大小＝最後一筆「非 sidechain」assistant 訊息的 usage 總和。
#
# isSidechain 過濾是必要的：一旦跑過 subagent，最後一筆會是 subagent 的小
# context，門檻就永遠不會到。
#
# compact 邊界（頂層 isCompactSummary == true）之後要歸零重算，否則會誤觸發：
# 這個 hook 在使用者送出訊息的當下跑，那時 transcript 裡還沒有任何 compact
# 之後的 assistant 訊息——append-only 的結構決定了使用者的 prompt 一定排在
# compact 後第一筆 assistant 之前——直接取最後一筆會讀到 compact **前**的
# 舊數字。使用者為了繼續工作才去 compact，卻換來下一則訊息被劫持去做一次
# 多餘的交接。邊界之後還沒有 usage 就視為未達門檻，靜默放行。
# （舊版 Stop hook 天然免疫：它在整輪結束後才跑，那時新數字已經寫進去了。）
used=$(jq -r '
    if (.isCompactSummary == true and (.isSidechain != true)) then
        "R"
    elif (.type == "assistant" and (.isSidechain != true) and .message.usage != null) then
        ((.message.usage.input_tokens // 0)
        + (.message.usage.cache_creation_input_tokens // 0)
        + (.message.usage.cache_read_input_tokens // 0)
        + (.message.usage.output_tokens // 0) | tostring)
    else empty end
' "$transcript" 2>/dev/null | awk '/^R$/ { v = ""; next } { v = $0 } END { print v }')

case "$used" in
    '' | *[!0-9]*) exit 0 ;;
esac

[ "$used" -lt "$THRESHOLD" ] && exit 0

# 這則 prompt 本身是不是 handoff 呼叫？
#
# 欄位名：實測 2026-08-06（Claude Code 2.1.223）攔到的 UserPromptSubmit payload
# 帶的是 `prompt`。官方文件所載的 `prompt_text` 與本測試舊版 run() 用的
# `user_message` 都不符實際（後者讓那條測試一直是 vacuous）。故以 `prompt`
# 為主，其餘兩個保留為防禦性 fallback，日後欄位改名時還有一層緩衝。
#（jq 的 // 只在 null/false 時往下掉，「存在但空字串」的 .prompt 會蓋掉後面
#  的 fallback；既然 .prompt 已是實測確認的欄位，這個順序正是我們要的。）
prompt_text=$(jq_in '(.prompt // .prompt_text // .user_message // "")
                     | gsub("^\\s+|\\s+$"; "")')

# 比對規則（依實測的使用者輸入形態調校）：
#
#  1. 斜線形式 `/handoff`、`/context-handoff:handoff`——**出現在訊息任何位置**
#     都算。實測使用者的 shell history，句尾附加才是最常見的用法
#     （「MR 都合併了，更新記憶然後 /handoff」「已合併 /handoff」），只認
#     行首開頭會漏掉一大半，等於這個機制做了等於沒做。
#     後綴需為字串結尾或非文字字元，`/handoffxyz` 不算。
#     **前綴刻意不設限**：中文語境常寫成「然後/handoff」「，/handoff」，前面
#     直接接的是中文字或全形標點，用 ASCII 空白／詞邊界去卡會在 UTF-8 locale
#     下行為不定，反而漏認。
#
#  2. 純文字形式 `handoff`、`交接`——只認整則 trim 後**完全相等**，不做部分
#     比對。這是最關鍵的收斂：一旦放寬成 substring，「以後不要再自動 handoff
#     了」「hook 會在超過 300k 時觸發 handoff skill」這種在「談論」handoff 的
#     句子全會命中，門檻機制就被使用者的一句閒聊整個關掉。
#
# 不需要處理 slash command 的「展開／包裝」形式：已於 2026-08-06（Claude Code
# 2.1.223）實測確認，行首 slash command 送進 hook 時 `.prompt` 就是原字面
# `/handoff`，沒有 <command-name> 之類的包裝。少一個分支就少一處會腐爛的猜測。
#
# 已知會誤命中但刻意不處理：「/handoff skill 有被收入進去嗎」這種用斜線形式在
# 發問的句子。誤命中的代價只是少一次自動催告、使用者仍看得到用量提醒；漏命中
# 的代價是使用者主動交接卻還被叫去交接。取捨明確偏向不增加複雜度。
HANDOFF_SLASH_RE='/(handoff|context-handoff:handoff)([^A-Za-z0-9_-]|$)'

# 實測發現：UserPromptSubmit **不等於「真人送出訊息」**。背景任務跑完的通知也
# 走同一條路進來，prompt 長這樣：
#   <task-notification>\n<task-id>…</task-id>…<status>completed</status>…</task-notification>
# 這類系統注入的訊息不是使用者在交派工作，不可當成 handoff 呼叫，更不可被
# decision:"block" erase 掉——那會讓主 agent 永遠收不到自己派出去的背景工作結果。
# 用「trim 後以尖角標籤開頭」一併涵蓋 <task-notification> / <system-reminder>
# 這類注入；真人打字幾乎不會以 <foo> 起頭。
SYSTEM_INJECTED_RE='^<[A-Za-z][A-Za-z0-9_-]*>'
is_system_injected_prompt() { [[ "$1" =~ $SYSTEM_INJECTED_RE ]]; }

is_handoff_prompt() {
    local p="$1"
    is_system_injected_prompt "$p" && return 1
    [[ "$p" =~ $HANDOFF_SLASH_RE ]] && return 0
    case "$p" in
        handoff | 交接) return 0 ;;
    esac
    return 1
}

# 位置至關重要：必須排在下面「已交接過就 block」那個分支**之前**。
# 那個分支會硬性阻斷所有 prompt，若本判定排在它後面，使用者交接完又多做了
# 幾件事、想再交接一次時就會被永久鎖死——這裡等於是那道封鎖的逃生口。
#
# 命中時只給 systemMessage：不注入 additionalContext（叫一則已經是 /handoff
# 的 prompt「先別做使用者要求的工作、去呼叫 handoff skill」毫無意義，語意還
# 重複）、不給 decision（skill 要有 turn 才跑得起來）、也不寫 nag 檔（那是
# 給「使用者沒主動交接」用的催告配額，使用者自己交接不該扣額度）。
if is_handoff_prompt "$prompt_text"; then
    jq -n --argjson used "$used" --argjson threshold "$THRESHOLD" '
    { systemMessage: ("⚠️ 已收到你的 handoff 請求。context 目前約 \($used) tokens"
                      + "（門檻 \($threshold)）；交接完成後請開新 session 接續。") }'
    exit 0
fi

# handoff 到底跑了沒，以 transcript 為準而不是「我催過了」為準。
# additionalContext 只是注入指示，沒有任何機制保證 Claude 一定照做；
# 催一次就記帳收手的話，模型忽略一次就等於這個 session 再也不會交接。
# 只看尾端一段：compact 之後 context 會塌回去，先前那次 handoff 早就過期，
# 掃全檔會讓舊記錄永遠壓住後續的觸發。
if [ "$(tail -n "$LOOKBACK" "$transcript" 2>/dev/null | jq -r '
    if (.isCompactSummary == true and (.isSidechain != true)) then
        "R"
    elif (.type == "assistant" and (.isSidechain != true)) then
        (.message.content[]?
         | select(.type == "tool_use" and .name == "Skill")
         | .input.skill // "")
    else empty end
' 2>/dev/null | awk '/^R$/ { done = 0; next } /handoff/ { done = 1 } END { print done + 0 }')" = "1" ]; then
    # 這裡用 decision:"block" 是對的，和下面「達門檻、尚未交接」那個分支的
    # 理由正好相反：那邊還需要一個 turn 讓 Claude 去跑 handoff skill，block
    # 掉就永遠交接不成；這邊 skill 已經跑完了，再給 turn 只會讓使用者交接後
    # 又順手多做幾件事，context 繼續長。block 會 erase 這則 prompt 並把
    # reason 顯示給使用者，Claude 不會有 turn，才是真正的中斷。
    #
    # 例外：系統注入的通知（背景任務完成通知等，見上方 is_system_injected_prompt）
    # 不可 block——那會讓主 agent 收不到自己派出去的背景工作結果。只提醒不中斷。
    if is_system_injected_prompt "$prompt_text"; then
        jq -n --argjson used "$used" '
        { systemMessage: "⚠️ 已交接過，context 目前約 \($used) tokens，建議盡快開新 session。" }'
    else
        jq -n --argjson used "$used" '
        { decision: "block",
          reason: "⚠️ 已交接過，context 目前約 \($used) tokens，建議盡快開新 session。本次請求未執行。",
          systemMessage: "⚠️ 已交接過，context 目前約 \($used) tokens，建議盡快開新 session。" }'
    fi
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
nags="$STATE_DIR/nags-$session_id"

# 順手清掉 7 天前的殘留狀態檔
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

count=$(cat "$nags" 2>/dev/null)
case "$count" in
    '' | *[!0-9]*) count=0 ;;
esac

# 催過上限次數還是沒交接，就當使用者是刻意要繼續用，只留不打斷的提醒。
if [ "$count" -ge "$MAX_NAGS" ]; then
    jq -n --argjson used "$used" '
    { systemMessage: "⚠️ context 已達交接門檻（目前約 \($used) tokens），建議盡快開新 session。" }'
    exit 0
fi

printf '%s' "$((count + 1))" > "$nags" 2>/dev/null

# 用 additionalContext 而非 decision:"block"：block 會讓這次 prompt 直接作廢，
# Claude 沒有 turn 可以執行 handoff skill，就只剩一句提醒而沒有真的交接。
# additionalContext 把指示連同使用者的訊息一起送進去，Claude 照常有 turn，
# 才能實際呼叫 skill 把進度寫進記憶。
jq -n --argjson used "$used" --argjson threshold "$THRESHOLD" '
{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: (
      "【context 門檻自動交接】本 session 已用約 \($used) tokens，達到設定門檻 \($threshold)。\n"
      + "**先不要執行使用者這則訊息要求的工作。**請依序做完這三件事，然後結束回合：\n"
      + "1. 用 Skill 工具呼叫 handoff skill（可用技能清單裡是 `handoff` 或 "
      + "`context-handoff:handoff`，兩者同一支），把目前進度與關鍵決策寫進專案記憶。\n"
      + "2. 使用者這則訊息的內容本身也要寫進交接記錄，當作下一個 session 的第一件待辦。\n"
      + "3. 用一段話告訴使用者：context 已達門檻、進度已寫入記憶、請開新 session 接續。"
    )
  },
  systemMessage: "⚠️ context 已達門檻 \($threshold)（目前約 \($used) tokens），本次請求已改為先執行 handoff，請開新 session 接續。"
}'

exit 0
