#!/usr/bin/env bash
# context-usage.sh 的分支驗證，外加 statusline.sh 快取區塊的整合驗證。
#
# 全程在 mktemp 目錄裡跑，用 `HOME` 隔離——腳本的快取目錄與 projects 目錄
# 都是從 $HOME 推導的，所以換掉 HOME 就完全碰不到真實資料。直接執行即可：
#   bash plugins/context-usage/scripts/context-usage.test.sh
#
# 涵蓋的分支：
#   1  快取路徑（零依賴）→ used / total / pct
#   2  compact 與 pretty 兩種 JSON 空白風格都要吃（曾經的真 bug）
#   3  快取過期（>15 分）→ 不採信，退回 transcript
#   4  transcript 回退 → 有數字但**沒有**百分比
#   5  無 jq 也無 python3 → 明確錯誤 + exit 1（不可靜默給錯數字）
#   6  session 定位：env var 命中 / 缺席時走 cwd slug
#   7  --json 輸出形狀
#   8  --selftest 在空 HOME 必須 FAIL（vacuous PASS 回歸）
#   9  --selftest 在 slug 規則被改壞時必須 FAIL（drift 偵測有鑑別力）
#   10 statusline.sh 的快取區塊：兩種空白風格都要寫得出可用的快取
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/context-usage.sh"
STATUSLINE="$HERE/../../../statusline.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() { # check <label> <expected-substring|EMPTY> <actual>
    if [ "$2" = "EMPTY" ]; then
        if [ -z "$3" ]; then echo "  ✅ $1"; pass=$((pass+1));
        else echo "  ❌ $1 — 預期無輸出，實得: $3"; fail=$((fail+1)); fi
    else
        case "$3" in
            *"$2"*) echo "  ✅ $1"; pass=$((pass+1)) ;;
            *) echo "  ❌ $1 — 預期含 '$2'，實得: $3" ; fail=$((fail+1)) ;;
        esac
    fi
}

check_status() { # check_status <label> <expected-exit> <actual-exit>
    if [ "$2" = "$3" ]; then echo "  ✅ $1"; pass=$((pass+1));
    else echo "  ❌ $1 — 預期 exit $2，實得 $3"; fail=$((fail+1)); fi
}

# --- fixtures -------------------------------------------------------------

# 刻意帶底線：slug 規則要把 `_` 轉成 `-`，這是第 9 節 mutation 的鑑別點
FAKE_CWD="/fake/my_proj"
FAKE_SLUG="-fake-my-proj"

# 建一個假的 $HOME，內含一個 project 目錄與一份 transcript
seed_home() { # seed_home <home> <session-id> <usage-total>
    local h="$1" sid="$2" total="$3"
    mkdir -p "$h/.claude/projects/$FAKE_SLUG"
    printf '{"type":"assistant","isSidechain":false,"cwd":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' \
        "$FAKE_CWD" "$total" > "$h/.claude/projects/$FAKE_SLUG/$sid.jsonl"
}

# 寫一份 statusline 快取。$4 = compact|pretty
write_cache() { # write_cache <home> <session-id> <used-in> <style>
    local h="$1" sid="$2" used="$3" style="${4:-compact}"
    mkdir -p "$h/.claude/context-usage"
    if [ "$style" = "pretty" ]; then
        printf '{\n  "session_id": "%s",\n  "model": { "display_name": "Opus 5" },\n  "context_window": {\n    "total_input_tokens": %s,\n    "total_output_tokens": 0,\n    "context_window_size": 1000000\n  }\n}\n' \
            "$sid" "$used" > "$h/.claude/context-usage/$sid.json"
    else
        printf '{"session_id":"%s","model":{"display_name":"Opus 5"},"context_window":{"total_input_tokens":%s,"total_output_tokens":0,"context_window_size":1000000}}\n' \
            "$sid" "$used" > "$h/.claude/context-usage/$sid.json"
    fi
}

# 只含最小工具集的 PATH，用來證明「主路徑零外部依賴」與「無 jq/python3 的行為」
minimal_path() { # minimal_path <dir> [extra-tools...]
    local d="$1"; shift
    mkdir -p "$d"
    local t
    for t in sh sed awk date stat ls head basename dirname find cut tail "$@"; do
        local p; p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}

run() { # run <home> <session-id> [args...]
    local h="$1" sid="$2"; shift 2
    env HOME="$h" CLAUDE_CODE_SESSION_ID="$sid" "$SCRIPT" "$@" 2>&1
}

# ==========================================================================

echo "── 1. 快取路徑：算得出 used / total / pct"
H1="$TMP/h1"; seed_home "$H1" sess-1 111; write_cache "$H1" sess-1 250000
out1=$(run "$H1" sess-1)
check "顯示 used/total" "250,000 / 1,000,000" "$out1"
check "算出百分比" "(25.0%)" "$out1"
check "算出剩餘" "剩餘 750,000" "$out1"
check "來源標為 statusline 快取" "statusline 快取" "$out1"
check "帶出 model 名稱" "Opus 5" "$out1"

echo "── 2. 快取的 JSON 空白風格：compact 與 pretty 都要吃"
# 這是真 bug 的回歸：sed pattern 原本寫死 `":` 沒容許空白，pretty 會整份讀不到。
H2="$TMP/h2"; seed_home "$H2" sess-2 111
write_cache "$H2" sess-2 250000 compact
check "compact 讀得到" "250,000 / 1,000,000" "$(run "$H2" sess-2)"
write_cache "$H2" sess-2 250000 pretty
check "pretty 讀得到" "250,000 / 1,000,000" "$(run "$H2" sess-2)"

echo "── 3. 快取過期 → 不採信，退回 transcript"
# ⚠️ 這裡必須用 CC_CONTEXT_USAGE_MAX_AGE 驅動，不能靠改 mtime：
#    把 mtime 調到很舊會先被主流程的 7 天 prune 刪掉，於是不論過期門檻在不在
#    都會退回 transcript ⇒ 該寫法對「過期分支」恆綠（實測 mutation 證實過）。
H3="$TMP/h3"; seed_home "$H3" sess-3 777
write_cache "$H3" sess-3 250000
check "門檻未過 → 採信快取" "250,000 / 1,000,000" "$(run "$H3" sess-3)"
out3=$(env HOME="$H3" CLAUDE_CODE_SESSION_ID=sess-3 CC_CONTEXT_USAGE_MAX_AGE=0 "$SCRIPT" 2>&1)
check "門檻設 0 → 不採信快取" "window 大小未知" "$out3"
check "改用 transcript 的數字" "777" "$out3"
check "非數字門檻 → 退回預設 900（仍採信新快取）" "250,000 / 1,000,000" \
    "$(env HOME="$H3" CLAUDE_CODE_SESSION_ID=sess-3 CC_CONTEXT_USAGE_MAX_AGE=abc "$SCRIPT" 2>&1)"

echo "── 3b. 七天以上的殘骸會被 prune 掉（與上面的門檻是兩條獨立機制）"
H3b="$TMP/h3b"; seed_home "$H3b" sess-3b 888
write_cache "$H3b" sess-3b 250000
touch -t 202001010000 "$H3b/.claude/context-usage/sess-3b.json"
out3b=$(run "$H3b" sess-3b)
check "殘骸不被採用" "window 大小未知" "$out3b"
check "殘骸檔已被刪除" "EMPTY" "$(ls "$H3b/.claude/context-usage/sess-3b.json" 2>/dev/null)"

echo "── 4. transcript 回退：有數字，但沒有百分比"
H4="$TMP/h4"; seed_home "$H4" sess-4 4242
out4=$(run "$H4" sess-4)
check "算出 transcript 用量" "4,242" "$out4"
check "明說沒有 window 大小" "window 大小未知" "$out4"
check "警示落後一輪" "落後一輪" "$out4"
check "指引去裝 statusline 快取" "步驟 2" "$out4"

echo "── 4b. sidechain（sub agent）訊息不可污染主 session 的數字"
# subagent 的 usage 跟主 session 無關。這裡把一筆超大的 sidechain 訊息附在
# 主線之後——若過濾失效，「最後一筆」就會變成它，數字直接爆掉。
H4b="$TMP/h4b"; seed_home "$H4b" sess-4b 4242
printf '{"type":"assistant","isSidechain":true,"cwd":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":999999,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' \
    "$FAKE_CWD" >> "$H4b/.claude/projects/$FAKE_SLUG/sess-4b.jsonl"
out4b=$(run "$H4b" sess-4b)
check "仍取主線那筆" "4,242" "$out4b"
case "$out4b" in
    *999,999*) echo "  ❌ sidechain 污染了數字"; fail=$((fail+1)) ;;
    *) echo "  ✅ sidechain 的 999,999 沒有被算進來"; pass=$((pass+1)) ;;
esac

echo "── 5. 無 jq 也無 python3 → 明確錯誤 + exit 1（不可靜默給錯數字）"
H5="$TMP/h5"; seed_home "$H5" sess-5 4242
BARE=$(minimal_path "$TMP/bin-bare")
out5=$(env -i HOME="$H5" PATH="$BARE" CLAUDE_CODE_SESSION_ID=sess-5 /bin/sh "$SCRIPT" 2>&1)
rc5=$?
check "明講需要 jq 或 python3" "需要 jq 或 python3" "$out5"
check "並指出免依賴的作法" "statusline 快取" "$out5"
check_status "exit 1" 1 "$rc5"
# 同一個極簡 PATH 下，快取路徑必須照樣可用（＝主路徑真的零外部依賴）
write_cache "$H5" sess-5 250000
out5b=$(env -i HOME="$H5" PATH="$BARE" CLAUDE_CODE_SESSION_ID=sess-5 /bin/sh "$SCRIPT" 2>&1)
check "零依賴環境下快取路徑仍可用" "250,000 / 1,000,000" "$out5b"

echo "── 6. session 定位：env var 命中 / 缺席時走 cwd slug"
H6="$TMP/h6"; seed_home "$H6" sess-6 6060
check "env var 命中" "env:CLAUDE_CODE_SESSION_ID" "$(run "$H6" sess-6)"

# 缺 env var 時改用「cwd 過 slug 規則」推目錄。用 $TMP 底下的真實目錄當 cwd
# （名稱刻意帶底線），不去動檔案系統根目錄。
CWD6="$TMP/my_proj"
SLUG6=$(printf '%s' "$CWD6" | sed 's/[^A-Za-z0-9-]/-/g')
mkdir -p "$CWD6"
mkdir -p "$H6/.claude/projects/$SLUG6"
printf '{"type":"assistant","isSidechain":false,"cwd":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":6060,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' \
    "$CWD6" > "$H6/.claude/projects/$SLUG6/sess-6b.jsonl"
# ⚠️ 一定要 `env -u`：真實 session 的 CLAUDE_CODE_SESSION_ID 會從外層洩漏進來，
#    不清掉的話這條測的是「env var 命中」而不是 fallback（假測）。
out6=$(cd "$CWD6" && env -u CLAUDE_CODE_SESSION_ID HOME="$H6" "$SCRIPT" 2>&1)
check "無 env var → 走 cwd slug fallback" "fallback:最新 mtime" "$out6"
check "fallback 推得到正確 session" "sess-6b" "$out6"
check "fallback 讀得到該 session 的用量" "6,060" "$out6"

echo "── 7. --json 輸出形狀"
H7="$TMP/h7"; seed_home "$H7" sess-7 111; write_cache "$H7" sess-7 250000
out7=$(run "$H7" sess-7 --json)
check "source 欄位" '"source":"statusline"' "$out7"
check "used 是數字" '"used":250000' "$out7"
check "total 是數字" '"total":1000000' "$out7"
check "pct 是數字" '"pct":25.0' "$out7"
check "lags_a_turn 為 false" '"lags_a_turn":false' "$out7"
# transcript 模式下 total/pct 必須是 null，不可捏造分母
H7b="$TMP/h7b"; seed_home "$H7b" sess-7b 4242
out7b=$(run "$H7b" sess-7b --json)
check "transcript 模式 total=null" '"total":null' "$out7b"
check "transcript 模式 pct=null" '"pct":null' "$out7b"
check "transcript 模式 lags_a_turn=true" '"lags_a_turn":true' "$out7b"

echo "── 8. --selftest 在空 HOME 必須 FAIL（vacuous PASS 回歸）"
# 舊版會印 ⏭ 跳過所有檢查然後報 PASS——drift detector 在別人的新機器上報綠
# 是最糟的假綠，故「檢查不成立」一律計為失敗。
H8="$TMP/h8"; mkdir -p "$H8/.claude/projects"
out8=$(env HOME="$H8" "$SCRIPT" --selftest 2>&1)
rc8=$?
check "空 HOME 不可印 PASS" "selftest: FAIL" "$out8"
check_status "空 HOME → exit 1" 1 "$rc8"
check "明說無從檢查" "無從檢查" "$out8"

echo "── 9. --selftest 對 slug 規則的 mutation 必須 FAIL（有鑑別力）"
H9="$TMP/h9"; seed_home "$H9" sess-9 111
out9=$(env HOME="$H9" "$SCRIPT" --selftest 2>&1)
rc9=$?
check "健全的 HOME → PASS" "selftest: PASS" "$out9"
check_status "健全的 HOME → exit 0" 0 "$rc9"
# mutation：讓 slug 規則保留底線（`_` 不再轉成 `-`）
MUT="$TMP/mutated.sh"
sed 's|s/\[\^A-Za-z0-9-\]/-/g|s/[^A-Za-z0-9_-]/-/g|' "$SCRIPT" > "$MUT"
if cmp -s "$SCRIPT" "$MUT"; then
    # sed 沒改到任何東西 ⇒ mutation 沒生效，這條就變成 vacuous，必須報失敗
    echo "  ❌ mutation 未生效（腳本內找不到 slug 規則），本條無鑑別力"
    fail=$((fail+1))
else
    out9b=$(env HOME="$H9" bash "$MUT" --selftest 2>&1)
    rc9b=$?
    check "規則被改壞 → FAIL" "selftest: FAIL" "$out9b"
    check "指出 round-trip 不吻合" "round-trip 不吻合" "$out9b"
    check_status "規則被改壞 → exit 1" 1 "$rc9b"
fi

echo "── 10. statusline.sh 的快取區塊：兩種空白風格都要寫得出可用的快取"
if [ ! -f "$STATUSLINE" ]; then
    echo "  ❌ 找不到 $STATUSLINE，整合未受測"
    fail=$((fail+1))
else
    for style in compact pretty; do
        H10="$TMP/h10-$style"; mkdir -p "$H10"
        if [ "$style" = "compact" ]; then
            payload='{"session_id":"sess-10","transcript_path":"/tmp/x.jsonl","model":{"id":"claude-opus-5[1m]","display_name":"Opus 5 (1M context)"},"workspace":{"current_dir":"/tmp"},"context_window":{"total_input_tokens":92000,"total_output_tokens":3000,"context_window_size":1000000}}'
        else
            payload='{ "session_id": "sess-10", "transcript_path": "/tmp/x.jsonl", "model": { "id": "claude-opus-5[1m]", "display_name": "Opus 5 (1M context)" }, "workspace": { "current_dir": "/tmp" }, "context_window": { "total_input_tokens": 92000, "total_output_tokens": 3000, "context_window_size": 1000000 } }'
        fi
        printf '%s' "$payload" | env HOME="$H10" bash "$STATUSLINE" >/dev/null 2>&1
        cache="$H10/.claude/context-usage/sess-10.json"
        if [ -f "$cache" ]; then
            echo "  ✅ $style payload → 有寫出快取"; pass=$((pass+1))
            seed_home "$H10" sess-10 111
            check "$style payload → 快取可被腳本讀出正確數字" \
                "95,000 / 1,000,000" "$(run "$H10" sess-10)"
        else
            echo "  ❌ $style payload → 沒寫出快取"; fail=$((fail+1))
        fi
    done
    # statusline 原本的顯示不可被這段影響
    out10=$(printf '%s' '{"session_id":"sess-11","model":{"display_name":"Opus 5"},"context_window":{"total_input_tokens":1,"total_output_tokens":1,"context_window_size":200000}}' \
        | env HOME="$TMP/h11" bash "$STATUSLINE" 2>&1)
    check "statusline 仍輸出模型名（原顯示未被破壞）" "Opus 5" "$out10"
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
