#!/bin/sh
# 回報「當前 session 已用掉多少 context」。
#
# 依賴策略（重點：主路徑零依賴，方便分享）
#   主路徑  statusline 快取 → 只用 sed/awk 解析扁平小 JSON ⇒ 零外部依賴
#   回退    transcript JSONL → 需要 jq 或 python3（巢狀 + 單行數 MB，不手刻解析器）
#
# 用法：context-usage.sh [--json] [--selftest]

set -u

CACHE_DIR="$HOME/.claude/context-usage"
PROJECTS_DIR="$HOME/.claude/projects"

# 快取超過這個秒數就視為上個 session 的殘骸，不採信。可用環境變數覆寫，
# 測試靠它直接驅動「過期」分支——不然只能改檔案 mtime，而那會先被下面的
# 7 天 prune 掃掉，測到的其實是 prune 不是這條門檻。
CACHE_MAX_AGE_S="${CC_CONTEXT_USAGE_MAX_AGE:-900}"
case "$CACHE_MAX_AGE_S" in '' | *[!0-9]*) CACHE_MAX_AGE_S=900 ;; esac

AS_JSON=0
DO_SELFTEST=0
for a in "$@"; do
    case "$a" in
        --json) AS_JSON=1 ;;
        --selftest) DO_SELFTEST=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "未知參數: $a" >&2; exit 2 ;;
    esac
done

die() {
    if [ "$AS_JSON" -eq 1 ]; then
        printf '{"error":"%s"}\n' "$1" >&2
    else
        printf '❌ %s\n' "$1" >&2
    fi
    exit 1
}

# --- 小工具 ---------------------------------------------------------------

# 從扁平 JSON 檔抓字串／數字欄位。鍵在快取內唯一，故貪婪 .* 安全。
# `:` 後容許空白 —— 別假設快取一定是 compact 的。
pick_num() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" 2>/dev/null; }
pick_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null; }

commify() { awk -v n="$1" 'BEGIN{
    s=sprintf("%d",n); out=""; len=length(s)
    for(i=1;i<=len;i++){ out=out substr(s,i,1); r=len-i; if(r>0 && r%3==0) out=out"," }
    print out }'; }

# 複製 Claude Code 的 ~/.claude/projects/ 目錄命名規則：
# 非 [A-Za-z0-9-] 一律換成 '-'。實測：sam_lin→sam-lin、/.claude→--claude、tmp.X→tmp-X
project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }

file_age_s() {
    now=$(date +%s)
    mt=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || return 1
    echo $((now - mt))
}

# --- session 定位 ---------------------------------------------------------

SID=""
HOW=""
resolve_session() {
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
        SID="$CLAUDE_CODE_SESSION_ID"
        HOW="env:CLAUDE_CODE_SESSION_ID"
        return 0
    fi
    # ⚠️ 同專案有多個平行 session 時，這條會挑到最近寫入的那個，未必是自己
    proj="$PROJECTS_DIR/$(project_slug "$PWD")"
    [ -d "$proj" ] || die "無法定位 session：找不到 $proj"
    newest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
    [ -n "$newest" ] || die "無法定位 session：$proj 底下沒有 .jsonl"
    SID=$(basename "$newest" .jsonl)
    HOW="fallback:最新 mtime（平行 session 下可能挑錯）"
}

# --- 來源 1：statusline 快取（零依賴）------------------------------------

try_cache() {
    f="$CACHE_DIR/$SID.json"
    [ -f "$f" ] || return 1

    age=$(file_age_s "$f") || return 1
    # 用 -lt 而非 -le：門檻設 0 時必須「一律不採信」。寫成 -le 的話，同一秒內
    # 產生的快取 age=0，`0 -le 0` 成立 ⇒ 仍被採用，該分支變成看時鐘的 flaky。
    [ "$age" -lt "$CACHE_MAX_AGE_S" ] || return 1   # 太舊＝上個 session 的殘骸

    ti=$(pick_num "$f" total_input_tokens)
    to=$(pick_num "$f" total_output_tokens)
    tt=$(pick_num "$f" context_window_size)
    [ -n "$ti" ] && [ -n "$tt" ] && [ "$tt" -gt 0 ] || return 1

    USED=$((ti + ${to:-0}))
    TOTAL="$tt"
    MODEL=$(pick_str "$f" display_name)
    AGE="$age"
    SOURCE=statusline
    return 0
}

# --- 來源 2：transcript 回退（需要 jq 或 python3）-------------------------

find_transcript() {
    # session 換過 worktree 時同 id 可能落在兩個 project 目錄，取最新寫入的
    ls -t "$PROJECTS_DIR"/*/"$SID".jsonl 2>/dev/null | head -1
}

try_transcript() {
    tp=$(find_transcript)
    [ -n "$tp" ] || return 1

    line=""
    if command -v jq >/dev/null 2>&1; then
        line=$(jq -r 'select(.type=="assistant" and (.isSidechain != true) and .message.usage != null)
                      | [ (.message.usage.input_tokens//0)
                        + (.message.usage.cache_creation_input_tokens//0)
                        + (.message.usage.cache_read_input_tokens//0),
                          (.message.model//"?") ] | @tsv' "$tp" 2>/dev/null | tail -1)
    elif command -v python3 >/dev/null 2>&1; then
        line=$(python3 - "$tp" <<'PY' 2>/dev/null
import json,sys
last=None
for l in open(sys.argv[1]):
    # 前置過濾只為省 json.loads；刻意用寬鬆的子字串，不要寫成 '"type":"assistant"'
    # ——那樣一旦 JSON 帶空白（"type": "assistant"）就會整份靜默略過。
    if 'assistant' not in l: continue
    try: d=json.loads(l)
    except Exception: continue
    if d.get("isSidechain"): continue
    u=(d.get("message") or {}).get("usage")
    if u: last=(u.get("input_tokens",0)+u.get("cache_creation_input_tokens",0)
                +u.get("cache_read_input_tokens",0), (d.get("message") or {}).get("model","?"))
if last: print("%d\t%s"%last)
PY
)
    else
        die "transcript 回退需要 jq 或 python3。裝好 statusline 快取即可完全免依賴（見 SKILL.md 步驟 2）"
    fi

    [ -n "$line" ] || return 1
    USED=$(printf '%s' "$line" | cut -f1)
    MODEL=$(printf '%s' "$line" | cut -f2)
    TOTAL=""
    AGE=""
    SOURCE=transcript
    TPATH="$tp"
    return 0
}

# --- selftest -------------------------------------------------------------

selftest() {
    # ⚠️ 斷言掛在檔案系統上，不是拿寫死字串比自己算出來的字串。
    # 關鍵設計：不看 $PWD——改用 transcript 自己記錄的 cwd 反推目錄名，
    # 這樣從任何目錄跑結果都一樣，只有「規則真的漂掉」才會紅。
    failed=0

    # ⛔ 鐵律：「檢查不成立」一律算 FAIL，不可印 ⏭ 然後 PASS。
    #    drift detector 在別人的機器上跳過所有檢查卻報綠 = 最糟的假綠。

    # 1) 弱檢查：每個既存的 project 目錄名都必須是 project_slug 的固定點。
    #    只在規則變「更窄」時會紅；變更寬（例如開始保留 `_`）抓不到——靠第 2 條。
    bad=0; total=0
    for d in "$PROJECTS_DIR"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        total=$((total + 1))
        [ "$(project_slug "$n")" = "$n" ] || { bad=$((bad + 1)); [ "$bad" -le 3 ] && printf '     ✗ %s\n' "$n"; }
    done
    if [ "$total" -eq 0 ]; then
        printf '❌ %s 底下沒有任何 project 目錄——無從檢查（不算通過）\n' "$PROJECTS_DIR"
        failed=$((failed + 1))
    elif [ "$bad" -eq 0 ]; then
        printf '✅ %s 個既存 project 目錄名都是 slug 規則的固定點（弱檢查）\n' "$total"
    else
        printf '❌ %s/%s 個目錄名不符合 slug 規則\n' "$bad" "$total"
        failed=$((failed + 1))
    fi

    # 2) 主檢查（round-trip）：真 transcript 內部記著自己的 cwd，
    #    該 cwd 過一次 slug 必須等於它所在的目錄名。與當下 $PWD 無關。
    tp=""
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && tp=$(ls -t "$PROJECTS_DIR"/*/"$CLAUDE_CODE_SESSION_ID".jsonl 2>/dev/null | head -1)
    [ -n "$tp" ] || tp=$(ls -t "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | head -1)

    if [ -z "$tp" ]; then
        printf '❌ 找不到任何 transcript——round-trip 無從檢查（不算通過）\n'
        failed=$((failed + 1))
    else
        # 只掃前幾十行；用 sed 不用 grep，少一個執行時依賴
        rec_cwd=$(head -50 "$tp" 2>/dev/null | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        parent=$(basename "$(dirname "$tp")")
        if [ -z "$rec_cwd" ]; then
            printf '❌ transcript 前 50 行沒有 cwd 欄位——round-trip 無從檢查（不算通過）\n     → %s\n' "$tp"
            failed=$((failed + 1))
        elif [ "$(project_slug "$rec_cwd")" = "$parent" ]; then
            printf '✅ round-trip：transcript 記的 cwd → 目錄名吻合\n     %s\n     → %s\n' "$rec_cwd" "$parent"
        else
            printf '❌ round-trip 不吻合（slug 規則已漂移）\n     cwd=%s\n     算出=%s\n     實際=%s\n' \
                "$rec_cwd" "$(project_slug "$rec_cwd")" "$parent"
            failed=$((failed + 1))
        fi
    fi

    printf -- '--- 執行時可用性 ---\n'
    for c in sed awk; do
        command -v "$c" >/dev/null 2>&1 \
            && printf '✅ %s（主路徑用得到）\n' "$c" \
            || { printf '❌ %s 缺席\n' "$c"; failed=$((failed + 1)); }
    done
    if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
        printf '✅ jq 或 python3 至少有一個（transcript 回退可用）\n'
    else
        printf '⚠️  無 jq／python3 ⇒ 只剩快取路徑可用\n'
    fi

    [ "$failed" -eq 0 ] && { echo "selftest: PASS"; return 0; }
    echo "selftest: FAIL ($failed)"; return 1
}

# --- main -----------------------------------------------------------------

[ "$DO_SELFTEST" -eq 1 ] && { selftest; exit $?; }

# 順手清掉七天前的快取殘骸
find "$CACHE_DIR" -name '*.json' -mtime +7 -delete 2>/dev/null || true

resolve_session
USED=""; TOTAL=""; MODEL=""; AGE=""; SOURCE=""; TPATH=""
try_cache || try_transcript || die "session $SID 找不到快取也讀不到 transcript"

if [ "$AS_JSON" -eq 1 ]; then
    if [ -n "$TOTAL" ]; then
        pct=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN{printf "%.1f",u/t*100}')
        printf '{"source":"%s","used":%s,"total":%s,"pct":%s,"age_s":%s,"model":"%s","lags_a_turn":false,"session_id":"%s","resolved_by":"%s"}\n' \
            "$SOURCE" "$USED" "$TOTAL" "$pct" "${AGE:-null}" "$MODEL" "$SID" "$HOW"
    else
        printf '{"source":"%s","used":%s,"total":null,"pct":null,"age_s":null,"model":"%s","lags_a_turn":true,"session_id":"%s","resolved_by":"%s","path":"%s"}\n' \
            "$SOURCE" "$USED" "$MODEL" "$SID" "$HOW" "$TPATH"
    fi
    exit 0
fi

if [ -n "$TOTAL" ]; then
    pct=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN{printf "%.1f",u/t*100}')
    printf 'Context: %s / %s tokens (%s%%)  ·  剩餘 %s\n' \
        "$(commify "$USED")" "$(commify "$TOTAL")" "$pct" "$(commify $((TOTAL - USED)))"
    printf '來源: statusline 快取（%s 秒前）· %s\n' "$AGE" "$MODEL"
else
    printf 'Context: %s tokens（window 大小未知，算不出百分比）\n' "$(commify "$USED")"
    printf '來源: transcript usage ⚠️ 落後一輪，且不含本輪新增\n'
    printf '   → 想要百分比：裝 statusline 快取，見 SKILL.md 步驟 2\n'
fi
printf 'Session: %s  (%s)\n' "$SID" "$HOW"
