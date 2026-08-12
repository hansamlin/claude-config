#!/usr/bin/env bash
# PreToolUse hook：sub agent 的 context 達門檻時，把它從原本的工作上攔下來，
# 要它先寫交接檔、只回報「請重派」，不要把半成品當成果交出去。
#
# 為什麼是 PreToolUse 而不是別的事件：
#   sub agent 沒有「使用者送出訊息」這個事件可攔（它整段生命週期只有一個
#   prompt），Stop 類事件又太晚——那時 context 早就爆了、任務也已經被當成
#   完成回報出去。工具呼叫是 sub agent 迴圈裡唯一每一輪都會經過的關卡。
#
# 為什麼用 permissionDecision:"deny"：
#   deny **不是**唯一的通道——PreToolUse 的 hookSpecificOutput schema 也明列
#   `additionalContext: string().optional()`（binary 反查，Claude Code 2.1.223），
#   消費端獨立處理、與權限決定無關，也就是「不擋、只注入」是做得到的。
#   我們仍然刻意選 deny，理由是**語意強度**：這裡要的是「立刻停止原本的工作」，
#   而不是「在你原本的工作旁邊多給你一段話」。代價是損失一次工具呼叫，可接受。
#   也因為是 deny，指示裡必須明講「原本的工作不用做了」，否則模型會以為只是
#   這一步被擋、換個工具再試一次。
#   日後若想壓低這個代價，`allow` + `additionalContext` 是有 schema 佐證的實驗
#   方向；但**仍然必須保留 `sa-<agent_id>` 記帳**，否則會變成每一次工具呼叫都
#   注入一次。
#
# 什麼情況下寧可完全不攔（見下方 SKIP_TYPES 與 plan mode 兩段早退）：
#   deny 的整套價值建立在「sub agent 收到指示後真的寫得出交接檔」上。寫不出來
#   的時候，攔截等於取消一次工具呼叫、叫它去做一件做不到的事，什麼都沒留下，
#   **比不攔更糟**。已知兩種寫不出來的情況：沒有 Write 工具的 agent_type
#   （Explore / Plan），以及 plan mode（寫檔是白名單制，交接檔不在名單內）。
#
# 為什麼只 deny 一次（見 sa-<agent_id> 狀態檔）：
#   deny 是無差別的，擋掉的是「這次工具呼叫」而不是「某類工具」。持續 deny
#   的話，sub agent 連寫交接檔要用的 Write 都會被擋掉，它會陷入
#   「想寫→被擋→再試→被擋」的死鎖，最後帶著滿的 context 空手而回。
#   所以發過一次指示就記帳，之後一律放行。
#
# 為什麼沒有任何人刪 sa-<agent_id>（2.3.0 起）：
#   2.2.x 有一支 SubagentStop hook 專門在 sub agent 收工時 `rm` 掉這個檔，理由是
#   「agent_id 萬一被重用，不要吃掉新一輪的交接機會」。那條註冊已整條移除，因為
#   它與上面那條「只 deny 一次」的保證**互相衝突**：
#     agent_id 被「重用」最現實的場景是**同一個 sub agent 被續跑**（主 agent 用
#     SendMessage 續接既有 agent，或任何 resume 路徑；binary 的 SubagentStop
#     payload 帶 stop_hook_active 且可以為 true → 續跑後再次觸發是被設計進去的
#     情境）。那時它的 context **還是滿的**，記帳卻已經被刪掉，於是它下一次工具
#     呼叫會**再被 deny 一次**，再被要求寫一次交接檔。
#   這正是 2.2.0 無限迴圈的放大器。真正的「agent_id 碰撞」機率極低（隨機十六進位
#   識別字），殘留檔本身也無害（deny 已經發過，不會死鎖），所以取捨明確：不刪。
#
#   附帶好處：那支 hook 從此沒有任何作用，整條 SubagentStop 註冊可以拿掉——
#   **少一個事件、少一個會吐輸出的風險面**。而「SubagentStop 只要有任何輸出
#   （stdout / stderr / 非零 exit 皆算）就會讓 sub agent 續跑」正是 2.2.0 那場
#   事故的根源，永久移除這個風險面很划算。
#
#   代價：sa-* 的回收從此**完全**依賴 check.sh 的 7 天 find 清掃。那行原本排在
#   三個早退之後（窄到幾乎不跑），已一併移到所有早退之前（同一個 PR）。
#
# 為什麼不叫 sub agent 去跑 handoff skill：
#   那支 skill 寫的是**專案長期記憶**，而且會按任務主題去重、就地更新既有的
#   `type: project` 記憶檔。sub agent 手上的東西是任務內的接力棒（只在這一次
#   派工的上下文有意義），混進專案記憶會汙染主線，最糟的情況是覆蓋掉主 session
#   辛苦寫的專案記憶。所以交接檔獨立放在 STATE_DIR，格式自由、生命週期綁 agent。
#
# 為什麼不做 compact 邊界（isCompactSummary）歸零：
#   sub agent transcript 是否會出現 compact 邊界沒有樣本可驗，而且就算真的出現，
#   最壞情況只是誤觸發一次 deny——deny 對同一個 agent_id 只會發生一次，是
#   自限的。相對地，主 session 那邊誤觸發的代價是「使用者為了繼續工作才
#   compact，卻換來下一則訊息被劫持」，那才值得為它加邏輯。
#
# 為什麼不做 isSidechain 過濾：
#   check.sh 需要那個過濾是因為主 transcript 裡混著 subagent 的小 context。
#   這裡讀的是 sub agent 專屬檔，整個檔每一行都是 isSidechain:true，套用過濾
#   會把全部資料濾光、門檻永遠不觸發且完全靜默。
#
# 為什麼不在這裡順手清 7 天前的狀態檔：
#   check.sh 已經在**每一則**使用者訊息掃過 STATE_DIR 了（2.3.0 起那行排在所有
#   早退之前，不再只跑在「達門檻且未交接過」那條窄路徑上）。這支 hook 是
#   **每一次工具呼叫**都跑（最多 20 個 sub agent 並發），多跑一個 find 就是
#   把成本乘上工具呼叫次數。清掃交給 check.sh。
#
# hooks.json 為什麼給 timeout 5（比 check.sh 的 15 短）：
#   JSON 不能寫註解，理由記在這裡。這支是**每一次工具呼叫**都跑，而且會擋在
#   工具真正執行之前——逾時上限就是每個工具呼叫最壞情況要多等的秒數，乘上
#   最多 20 個並發 sub agent。正常路徑只有 1~2 個 jq，5 秒綽綽有餘。
#
#   ⚠️ 舊註解斷言「hook 逾時＝放行」，那句**沒有一手證據支持**，已撤回。
#   binary 裡唯一談 PreToolUse 逾時的字串是 `The tool call was not executed`，
#   方向可能正好相反（逾時＝連工具都不執行）；但那段程式看起來屬於 SDK/HTTP 型
#   hook 回呼的路徑，`type: "command"` 是否走同一條**未證實**。
#   timeout 5 維持不變：不論答案是哪一邊，把暴露窗口縮短都是對的方向。
#
# 可調環境變數：
#   CC_HANDOFF_SUBAGENT_THRESHOLD  sub agent 的提醒起點（token），預設 300000。
#                                  與主 session 的 CC_HANDOFF_THRESHOLD 分開，
#                                  因為兩者調整的動機不同（主 session 是使用者
#                                  體感，sub agent 是任務切段粒度）。
#   CC_HANDOFF_SUBAGENT_HARD_LIMIT sub agent 的硬上限（token），預設 400000；
#                                  超過才 deny。與主 session 分開的理由同上。
#   CC_HANDOFF_SUBAGENT_NAG_STEP   sub agent 里程碑提醒間距（token），預設 20000；
#                                  設 0 或非數字退回 20000（level 除法的分母）。
#   CC_HANDOFF_SUBAGENT_SKIP_TYPES 完全不 deny 的 agent_type 清單（空白分隔），
#                                  預設 `Explore Plan`。這兩種內建 agent 的工具集
#                                  是「All tools except Agent, Artifact,
#                                  ExitPlanMode, Edit, Write, NotebookEdit」——
#                                  deny 訊息第 1 點要它用 Write 寫交接檔，它根本
#                                  執行不了，結果是白白吃掉一次工具呼叫、什麼都
#                                  沒留下，**比不攔更糟**。
#                                  做成可覆寫而不是寫死在程式裡，是因為這份清單
#                                  必然會腐爛：使用者隨時可以自訂沒有 Write 的
#                                  agent，內建 agent 的工具集也可能改。寫死的話
#                                  唯一的修法是改 plugin；做成環境變數，使用者
#                                  自己就能補上或拿掉。
#                                  ⚠️ 2.5.0 起這條**只守 deny**：stage-2 的里程碑
#                                  提醒不在此限（見下方三階段行為）。
#   CC_HANDOFF_DISABLE             設為 1 完全停用（與 check.sh 共用同一個開關）
#   CC_HANDOFF_STATE_DIR           狀態目錄，預設 ~/.claude/handoff-state
#   CC_HANDOFF_TRACE               設成檔案路徑則附加寫入收到的 payload，除錯用。
#                                  這支 hook 最大的失敗模式是「靜默地永遠不觸發」
#                                  （路徑推導錯、payload 沒有 agent_id 之類），
#                                  trace 是唯一能便宜證實它有在跑的手段。
#
# 三階段行為（2.5.0）：
#   used < THRESHOLD              靜默。
#   THRESHOLD ≤ used < HARD_LIMIT 里程碑提醒：level = (used - THRESHOLD) / NAG_STEP，
#                                 跨 level 才注入 additionalContext（PreToolUse
#                                 schema 沒有 systemMessage，實測明載
#                                 additionalContext），**不 deny**、工具照跑。
#                                 SKIP_TYPES / plan mode **不限制提醒**——它們
#                                 擋的是 deny 的語意「叫它寫交接檔」，提醒只是
#                                 說一句話，Explore / Plan / plan mode 底下也
#                                 收得到。記帳在 sa-nag-<agent_id>，plain `>`
#                                 覆寫（level 單調遞增；並行重複注入是良性雜訊，
#                                 與 sa-<id> 的 noclobber 原子寫入形成對比）。
#   used ≥ HARD_LIMIT             沿用 2.4.0 的機制：deny 一次工具呼叫 + 指示寫
#                                 交接檔 subagent-handoff-<id>.md，sa-<id> 以
#                                 noclobber 記帳保證只 deny 一次。skip / plan
#                                 兩條早退在這裡才生效（只守 deny，不守提醒）。
#
#   sa-nag-* 與 sa-* 一樣沒有任何人會主動刪，回收完全依賴 check.sh 的 7 天
#   find 清掃；reset.sh（PostCompact）刻意不清它們——那是主 session 的壓縮，
#   與 sub agent 的 context 無關。
#
# 為什麼 skip / plan mode 的判定被移到「used < THRESHOLD 早退」之後（2.5.0）：
#   舊版它們排在算用量之前，Explore / Plan / plan mode 底下任何用量都直接
#   退出。stage-2 提醒不需要「寫得出交接檔」這個前提（提醒不叫人寫檔），
#   所以這兩條早退必須退到提醒之後、deny 之前，才能做到「只守 deny」。
#   熱路徑成本：Explore / Plan / plan mode 的 sub agent 在提醒區間內，每次
#   工具呼叫會多付一次掃 transcript 的 jq——這是「skip 只守 deny」的直接代價，
#   實測個位數毫秒，換來的是提醒區間內這些 agent 不再完全沉默。

set -uo pipefail

# DISABLE 先判：純環境變數比較，連 stdin 都不用讀
[ "${CC_HANDOFF_DISABLE:-0}" = "1" ] && exit 0

THRESHOLD="${CC_HANDOFF_SUBAGENT_THRESHOLD:-300000}"
HARD_LIMIT="${CC_HANDOFF_SUBAGENT_HARD_LIMIT:-400000}"
NAG_STEP="${CC_HANDOFF_SUBAGENT_NAG_STEP:-20000}"
STATE_DIR="${CC_HANDOFF_STATE_DIR:-$HOME/.claude/handoff-state}"
# 用 `-` 而不是本檔其他變數的 `:-`：這是刻意的差別。`:-` 會把空字串也當成
# 「沒設定」而套用預設值，使用者就沒有任何辦法表達「一個都不要跳過」（只能塞
# 一個不存在的假 type 進去）。這個變數的存在意義就是可覆寫，
# `CC_HANDOFF_SUBAGENT_SKIP_TYPES=` 必須真的代表空清單。
SKIP_TYPES="${CC_HANDOFF_SUBAGENT_SKIP_TYPES-Explore Plan}"

# 數值消毒：非數字一律退回預設值（`:-` 對「設成空字串」不設防）。HARD_LIMIT
# 會拿來做 `[ "$used" -lt "$HARD_LIMIT" ]`，非數字會讓 test 以 stderr 炸掉；
# NAG_STEP 是下面 level 除法的分母，0 直接除零。
case "$THRESHOLD" in '' | *[!0-9]*) THRESHOLD=300000 ;; esac
case "$HARD_LIMIT" in '' | *[!0-9]*) HARD_LIMIT=400000 ;; esac
case "$NAG_STEP" in '' | *[!0-9]*) NAG_STEP=20000 ;; esac
[ "$NAG_STEP" -eq 0 ] && NAG_STEP=20000

input=$(cat)
[ -n "${CC_HANDOFF_TRACE:-}" ] && printf '%s\n' "$input" >> "$CC_HANDOFF_TRACE"

# 一次 jq 取完所有欄位，不用 check.sh 那種一欄一個 jq 的寫法：
# 那邊一輪對話只跑一次，這邊每一次工具呼叫都跑，行程數要壓到 1。
# 分隔字元用 \001 而不是 tab：tab 屬於 IFS whitespace，read 會把連續的
# tab 併成一個分隔符並吃掉頭尾空欄，空欄位（例如沒有 file_path）就會錯位。
# file_path 過 `strings`：join 遇到非字串元素會整個 jq 失敗，而 tool_input 的
# schema 是各工具自訂的（MCP 工具可能在同名 key 塞物件），不能假設它是字串。
# ⚠️ jq 的陣列順序與 read 的變數清單必須逐一對齊，加欄位時兩邊要一起改。
# permission_mode 也過 `strings`，理由與 file_path 相同：join 遇到非字串
# 元素會讓整個 jq 失敗，六個欄位全空→這個 sub agent 從此不再受監控。
agent_id=""; agent_type=""; transcript=""; tool_name=""; file_path=""; perm_mode=""
IFS=$'\001' read -r agent_id agent_type transcript tool_name file_path perm_mode <<EOF
$(printf '%s' "$input" | jq -r '[.agent_id // "", .agent_type // "",
    .transcript_path // "", .tool_name // "",
    ((.tool_input.file_path | strings) // ""),
    ((.permission_mode | strings) // "")] | join("\u0001")' 2>/dev/null)
EOF

# 主 agent 的工具呼叫沒有 agent_id。這條路徑每一次工具呼叫都會走到，
# 必須零成本，所以判定放在能放的最前面（只落後於解析 payload 本身）。
[ -n "$agent_id" ] || exit 0

# agent_id 會變成檔名、也會被印回給模型看。不是純識別字就當作沒收到——
# 與其冒著把 ../ 拼進路徑的風險，不如放棄這次交接。
case "$agent_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

state="$STATE_DIR/sa-$agent_id"
handoff_file="$STATE_DIR/subagent-handoff-$agent_id.md"

# 已經發過指示 → 一律放行。放在讀 transcript 之前：這個分支是超標之後每一次
# 工具呼叫的必經之路，不該為它付 jq 掃整個 transcript 的錢。
#
# ⚠️ 這一行是**便宜快取，不是權威**。它與下面的寫入合起來是 check-then-act，
# 中間隔著一次掃 transcript 的 jq，不是原子操作。權威是下面那個 noclobber
# 寫入（見該處說明）；這行留著純粹是為了不讓熱路徑付掃 transcript 的錢。
[ -e "$state" ] && exit 0

# deny 當下要寫的就是交接檔本身 → 放行，否則第一步就自相矛盾。
# 只認 Write + 完全相同的路徑字串，不做正規化、不放行 Edit：
# 這個例外在實務上近乎 dead code（第一次 deny 之後狀態檔就存在，什麼都放行了），
# 只有「deny 那一瞬間剛好在寫同一個檔」這種巧合會用到，不值得為它擴大開口。
if [ "$tool_name" = "Write" ] && [ "$file_path" = "$handoff_file" ]; then
    exit 0
fi

[ -n "$transcript" ] || exit 0

# sub agent 有獨立的 transcript：主檔 <dir>/<session_id>.jsonl 去掉副檔名當成
# 目錄，底下是 subagents/agent-<agent_id>.jsonl。
#
# payload 的 transcript_path 在 sub agent 內到底指向主檔還是專屬檔沒有實測過，
# 所以兩種都涵蓋：basename 已經是 agent-<agent_id>.jsonl 就直接用，否則照上面
# 的規則推導。兩個候選都不存在就靜默退出——寧可漏掉，也不要因為猜錯路徑而報錯。
sa=""
if [ "${transcript##*/}" = "agent-$agent_id.jsonl" ]; then
    sa="$transcript"
elif [ -f "${transcript%.jsonl}/subagents/agent-$agent_id.jsonl" ]; then
    sa="${transcript%.jsonl}/subagents/agent-$agent_id.jsonl"
fi
[ -n "$sa" ] && [ -f "$sa" ] || exit 0

# 當下 context 用量 ＝ 最後一筆 assistant 的 usage 總和。
used=$(jq -r '
    if (.type == "assistant" and .message.usage != null) then
        ((.message.usage.input_tokens // 0)
        + (.message.usage.cache_creation_input_tokens // 0)
        + (.message.usage.cache_read_input_tokens // 0)
        + (.message.usage.output_tokens // 0) | tostring)
    else empty end
' "$sa" 2>/dev/null | tail -n 1)

# 空字串也走這條：sub agent 的第一次工具呼叫發生在第一筆 assistant 訊息
# 寫進 transcript 之前，那時沒有 usage 可讀，視為未達門檻。
case "$used" in
    '' | *[!0-9]*) exit 0 ;;
esac

[ "$used" -lt "$THRESHOLD" ] && exit 0

# ── stage-2：里程碑提醒（THRESHOLD ≤ used < HARD_LIMIT）──
#
# 只注入 additionalContext（PreToolUse schema 沒有 systemMessage），**不給
# permissionDecision**：工具照常執行，只是讓 sub agent 知道用量在漲。
# 這裡排在 skip / plan mode 判定**之前**——那兩條擋的是 deny（語意是「叫它
# 寫交接檔」），提醒只是說一句話，Explore / Plan / plan mode 底下也收得到。
#
# level = (used - THRESHOLD) / NAG_STEP，跨 level 才提醒。記帳在 sa-nag-<id>，
# 用 plain `>` 覆寫而不是 noclobber：level 只會單調遞增，noclobber 會在第二次
# 寫入時失敗；並行時多個行程同時注入也只是多一句提醒，是良性雜訊（與下方
# sa-<id> 的原子寫入「必須恰好一次」形成對比）。「檔不存在」當成 -1，讓
# level 0（恰達門檻那次）也能觸發。
if [ "$used" -lt "$HARD_LIMIT" ]; then
    level=$(( (used - THRESHOLD) / NAG_STEP ))
    nag_state="$STATE_DIR/sa-nag-$agent_id"
    prev=$(cat "$nag_state" 2>/dev/null)
    case "$prev" in
        '' | *[!0-9]*) prev=-1 ;;
    esac
    if [ "$prev" -lt "$level" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
        printf '%s' "$level" > "$nag_state" 2>/dev/null
        jq -n --argjson used "$used" --argjson threshold "$THRESHOLD" \
              --argjson hard "$HARD_LIMIT" '
        {
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            additionalContext: (
              "【context 用量提醒】你這個 sub agent 的 context 已用約 \($used) tokens，"
              + "進入提醒區間（\($threshold)～\($hard)）。目前不會阻擋任何工具呼叫，"
              + "但請留意用量——超過硬上限 \($hard) 會被強制要求先寫交接檔。"
            )
          }
        }'
    fi
    exit 0
fi

# ── stage-3（used ≥ HARD_LIMIT）之前：skip / plan mode 只守 deny ──
#
# 沒有 Write 工具的 agent_type 直接不 deny（見檔頭 CC_HANDOFF_SUBAGENT_SKIP_TYPES）：
# 攔了它也寫不出交接檔，只是白白損失一次工具呼叫，比不攔更糟。不 deny、也不寫
# 狀態檔——沒發過指示就沒有「已發過」可記。
#
# 2.5.0 起這整段從「算用量之前」移到這裡：提醒區間內 Explore / Plan / plan mode
# 也要收得到提醒（見上方 stage-2），所以 skip 只能在它之後、deny 之前生效。
# 熱路徑成本見檔頭「為什麼 skip / plan mode 的判定被移到…」。
#
# 比對用 for + set -f 而不是 `case " $SKIP_TYPES " in *" $agent_type "*)`：
# case 的 pattern 位置會讓兩邊的 glob 字元都生效，`Explore*` 或 payload 送個
# `*` 進來都會誤命中。這裡要的是**整個 token 字面相等**（大小寫敏感即可：實測
# agent_type 就是 subagent_type 的字面，`general-purpose` 精確吻合），
# `Explorer` 這種多一個字元的必須不命中。
# set -f 是防 SKIP_TYPES 裡萬一有 glob 字元時被 pathname expansion 展開成檔名。
if [ -n "$agent_type" ]; then
    set -f
    for _skip in $SKIP_TYPES; do
        [ "$agent_type" = "$_skip" ] && exit 0
    done
    set +f
fi

# 同一條早退路徑的第二個理由：plan mode。
# plan mode 底下寫檔不是全面禁止，是**白名單制**（binary 反查，2.1.223；
# 用 `rg -a --fixed-strings -o '<字串>' <CLI binary>` 可自行重跑驗證）。
#   阻擋訊息：Cannot write to <path> while in plan mode
#   白名單原文只有這幾類：
#     Plan files for current session are allowed for writing
#     Workflow script files for current session are allowed for writing
#     Scratchpad files for current session are allowed for writing
#     Job tmp/ subtree for current session ...
# 我們的交接檔寫在 $STATE_DIR（預設 ~/.claude/handoff-state/），**不在任何一條
# 白名單裡** → plan mode 下必定被擋。症狀與上面的 Explore / Plan 完全相同：
# deny 取消了一次工具呼叫，然後叫 sub agent 去寫一個它寫不了的檔，結果什麼都
# 沒留下，比不攔更糟。
#
# 而且這條比 agent_type 那條常見得多：sub agent 繼承主 session 的 permission
# mode，所以只要使用者在 plan mode 下派工，**任何** agent_type 都會中招，
# 包括 general-purpose。
#
# 精確相等，不做 substring：合法值枚舉是
# "default" / "acceptEdits" / "bypassPermissions" / "plan"（另有實測到的 "auto"），
# 只有 "plan" 這一個要跳過。欄位不存在時 perm_mode 是空字串，照常往下走。
[ "$perm_mode" = "plan" ] && exit 0

# 記帳一定要在 deny 之前，而且失敗就整個放棄（fail open）。
# 理由：整套「只 deny 一次」的保證完全建立在這個檔存在上。如果先 deny 才寫、
# 或寫失敗了還照樣 deny，接下來每一次工具呼叫都會重新 deny，連交接檔的 Write
# 都會被擋——正是上面要避免的死鎖。fail open 最多損失一次交接，fail closed
# 會直接吊死一個 sub agent。
#
# 為什麼是 noclobber 而不是直接 `>`（＝為什麼要原子）：
#   PreToolUse hook **確實會並行執行**。這是實測過的，不是推測：
#     實驗：一個 sub agent 在同一則訊息裡發出多個平行 Read，hook 裡寫入帶
#           微秒時間戳的 start/end，中間 sleep 1。
#     結果：三個 hook 行程兩兩重疊（第 2 個在第 1 個 end 之前 start，第 3 個
#           在第 2 個 end 之前 start）→ runtime **不序列化**這批 hook。
#   binary 也解釋了原因（Claude Code 2.1.223）：工具排程器的 `processQueue`
#   對每個 queued 工具呼叫 `executeTool`，而 `executeTool` 只把狀態設成
#   executing、啟動一個**不被 await 的** async IIFE 就返回；`canExecuteTool`
#   在「目前執行中的全是 concurrency-safe」時允許下一個直接開跑。每個工具
#   完整的生命週期（含權限判定與 hook）都在那個 IIFE 裡，所以會重疊。
#   Read/Grep/Glob 這類 readOnly 工具是 concurrency-safe；Bash 不是——這正是
#   為什麼過去所有驗收 trace（全是 Bash 序列）從沒觸發過這條路徑。
#
#   ⚠️ 第二個實驗（hook 只跑 50ms、七個平行 Read）**完全沒有重疊**：工具呼叫
#   的起始間隔是 500~900ms，由模型串流出 tool_use block 的節奏決定，比競態
#   窗口大兩個數量級。所以這是「保證有例外」而不是「機制會壞」，實務上幾乎
#   不會發生。之所以還是修，是因為代價近乎為零：
#
# 為什麼這不算動熱路徑：
#   這行排在**所有**早退之後，一個 sub agent 的一生只會走到這裡一次（之後
#   `[ -e "$state" ]` 那條便宜快取就接手了）。多出來的成本是一個 subshell
#   fork，只發生在 deny 的那一次，不是每次工具呼叫。
#
# 兩種失敗都 fail open：檔案已存在（別人先搶到 → 由它去 deny）與寫不進去
# （權限/磁碟）在這裡是同一個處理，因為兩者都不該讓這個行程再 deny 一次。
# 用 subshell 包住 `set -o noclobber`，避免污染腳本其餘部分的重導向行為。
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
if ! ( set -o noclobber; printf '%s\n' "${agent_type:-unknown}" > "$state" ) 2>/dev/null; then
    exit 0
fi

# 註：續作的 sub agent 是新的 agent_id，若它也超標會寫到另一個
# subagent-handoff-<新 id>.md。接力鏈靠的是每一代 sub agent 各自在最終回覆裡
# 報出自己那份交接檔的路徑。**沒有** SubagentStop 兜底——那條通道已於 2.2.1
# 證實有害（任何輸出都會讓 sub agent 續跑）並於 2.3.0 整條移除，理由見檔頭。
# 舊的交接檔不會被合併或刪除，靠 STATE_DIR 的 7 天清掃收尾。
jq -n --arg f "$handoff_file" --argjson used "$used" --argjson hard_limit "$HARD_LIMIT" '
{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "【context 硬上限自動交接】你這個 sub agent 目前 context 已用約 \($used) tokens，"
      + "達到硬上限 \($hard_limit)。這次工具呼叫已被取消；接下來的工具呼叫不會再被擋，"
      + "你有足夠的額度完成下面的交接。\n\n"
      + "**立刻停止原本的工作**，改做這三件事然後結束回合：\n\n"
      + "1. 用 Write 把交接內容寫進這個絕對路徑：\($f)\n"
      + "   至少要涵蓋：任務目標 / 已完成 / 進行中與下一步 / 關鍵決策與原因 / "
      + "踩過的坑 / 相關檔案與指令。判準是：一個完全沒有這段對話、只讀得到這個檔的"
      + "新 sub agent，能不能正確接續。\n"
      + "2. 不要呼叫 handoff skill。那支寫的是專案長期記憶，你手上的是任務內的"
      + "接力棒，寫進去會汙染甚至覆蓋主線的專案記憶。\n"
      + "3. 結束回合，最終回覆**只**回報這三點：(a) 因 context 達上限已中止、"
      + "任務尚未完成；(b) 交接檔路徑 \($f)；(c) 請主 agent 以**相同**的 "
      + "agent_type 與**相同**的模型等級重新派一個 sub agent，並在 briefing 裡"
      + "要求它先讀該交接檔再續作。\n\n"
      + "**不要**把未完成的工作當成完成品回報，也不要在最終回覆裡塞半成品的結論"
      + "——主 agent 會據此判斷任務是否真的完成。"
    )
  }
}'

exit 0
