#!/usr/bin/env bash
# install.sh 的「plugin 沒裝成就不套用 CLAUDE.md」閘門驗證。
#
# 為什麼要有這支：CLAUDE.md 只留 router，流程本體指名 `agent-dispatch:dev-flows`
# 這類 plugin skill。指到不存在的名字不會報錯、只會靜默跳過整段流程——所以
# install.sh 刻意在 plugin 全裝成之前不動 CLAUDE.md。這個保護是「不做某件事」，
# 壞掉時畫面上看不出任何差別（CLAUDE.md 照樣被複製、安裝照樣印成功），只有
# 之後某次流程被靜默跳過才會發現。故必須有測試守著。
#
# 怎麼測：閘門吃的 PLUGIN_FAILED 只在 `CLAUDE_DIR = $HOME/.claude` 且非 dry-run
# 時才會被填。所以整組測試在假的 HOME 底下跑真的 install.sh，並把 `claude` 換成
# PATH 上的 stub 決定哪個 plugin 裝失敗。每個 case 用自己的 HOME，避免
# settings.json / *.bak 互相污染。
#
# ⚠️ 這種測法最大的假綠是「plugin 迴圈其實沒跑」——CLAUDE_DIR 只要跟 $HOME/.claude
# 對不上，install.sh 會整段略過，PLUGIN_FAILED 永遠是空的，所有「失敗分支」的
# 斷言就變成在測成功分支且全部通過。所以每個 case 都另外守三件事：
#   1. 輸出不得出現「CLAUDE_DIR 非預設」
#   2. stub 的呼叫記錄裡要有每一個 plugin 的 install
#   3. 有 plugin 失敗的 case，install.sh 的 exit code 必須是 1
#
# 直接執行即可：
#   bash install.test.sh
# 要對變異過的副本跑（mutation testing）可覆寫 INSTALL_SH——注意 install.sh 用
# `dirname $0` 推導來源目錄，副本旁邊必須同時有 settings.fragment.json /
# statusline.sh / CLAUDE.md：
#   INSTALL_SH=/tmp/mut/install.sh bash install.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_SH="${INSTALL_SH:-$HERE/install.sh}"
SRC_REPO=$(cd "$(dirname "$INSTALL_SH")" && pwd)

if ! command -v jq >/dev/null 2>&1; then
    echo "需要 jq，請先安裝：brew install jq" >&2
    exit 1
fi

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

# 「不該出現的字串」檢查：命中就回傳整段輸出（交給 check ... EMPTY 判定失敗）
lacks() { # lacks <needle> <haystack>
    case "$2" in *"$1"*) printf '%s' "$2" ;; esac
}

# 檔案內容比對：相同回空字串，不同或不存在回差異描述
same_as() { # same_as <file> <expected-file>
    if [ ! -f "$1" ]; then printf '%s 不存在' "$1"; return; fi
    if ! cmp -s "$1" "$2"; then printf '%s 內容不等於 %s' "$1" "$2"; fi
}

PLUGINS=$(jq -r '.enabledPlugins // {} | keys[]' "$SRC_REPO/settings.fragment.json")
FIRST_PLUGIN=$(printf '%s\n' "$PLUGINS" | head -1)
LAST_PLUGIN=$(printf '%s\n' "$PLUGINS" | tail -1)
# 刻意挑「中間的一個」而不是全部失敗：只有全滅才擋的閘門是壞的閘門。
BROKEN_PLUGIN=$(printf '%s\n' "$PLUGINS" | sed -n '3p')
if [ -z "$FIRST_PLUGIN" ] || [ "$FIRST_PLUGIN" = "$LAST_PLUGIN" ] || [ -z "$BROKEN_PLUGIN" ]; then
    echo "settings.fragment.json 的 enabledPlugins 不足 3 個，本測試的前提不成立" >&2
    exit 1
fi
FIRST_MARKET=$(jq -r '.extraKnownMarketplaces // {} | keys[0] // ""' "$SRC_REPO/settings.fragment.json")

# 每個 case 一個乾淨的假 HOME
H=''; CD=''; CALLS=''; OUT=''; RC=0
setup() { # setup <case-tag>
    H="$TMP/$1"
    CD="$H/.claude"
    CALLS="$H/claude-calls.log"
    mkdir -p "$CD" "$H/bin"
    : > "$CALLS"
}

# claude stub：記錄每一次呼叫，並讓指定的 plugin / marketplace 失敗
stub() { # stub <fail-plugin|-> <fail-marketplace|->
    cat > "$H/bin/claude" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$CALLS"
if [ "\$1" = "plugin" ] && [ "\$2" = "install" ]; then
    if [ "\$3" = "$1" ]; then
        echo "error: plugin \$3 not found in marketplace"
        exit 1
    fi
    echo "Installed \$3"
    exit 0
fi
if [ "\$1" = "plugin" ] && [ "\$2" = "marketplace" ]; then
    if [ "\$3" = "update" ] && [ "\$4" = "$2" ]; then
        echo "error: cannot update marketplace \$4"
        exit 1
    fi
    echo "ok \$3 \$4"
    exit 0
fi
if [ "\$1" = "plugin" ] && [ "\$2" = "disable" ]; then
    echo "Disabled \$3"
    exit 0
fi
echo "unexpected: \$*"
exit 0
STUB
    chmod +x "$H/bin/claude"
}

run_install() {
    OUT=$(env HOME="$H" CLAUDE_DIR="$H/.claude" PATH="$H/bin:$PATH" \
              bash "$INSTALL_SH" 2>&1)
    RC=$?
}

# 指定 CLAUDE_DIR 跑（用來測「非預設目錄就整段略過」那條）
run_install_at() { # run_install_at <claude-dir>
    OUT=$(env HOME="$H" CLAUDE_DIR="$1" PATH="$H/bin:$PATH" \
              bash "$INSTALL_SH" 2>&1)
    RC=$?
}

# 每個 case 都跑的非空轉守衛
guards() { # guards <expected-rc>
    check "  [守衛] 沒有走到「CLAUDE_DIR 非預設」的略過分支" EMPTY \
        "$(lacks 'CLAUDE_DIR 非預設' "$OUT")"
    check "  [守衛] plugin 迴圈真的跑了第一個（${FIRST_PLUGIN}）" \
        "plugin install $FIRST_PLUGIN" "$(cat "$CALLS")"
    check "  [守衛] 迴圈沒有中途停掉，最後一個也試了（${LAST_PLUGIN}）" \
        "plugin install $LAST_PLUGIN" "$(cat "$CALLS")"
    check "  [守衛] install.sh exit code = $1" "$1" "$RC"
}

SENTINEL="$TMP/sentinel.md"
printf '# 目標機器上的舊 CLAUDE.md\n這一份必須原封不動。\n' > "$SENTINEL"

echo "── 1. 有 plugin 裝失敗 + 目標本來沒有 CLAUDE.md → 不得建立"
setup c1
stub "$BROKEN_PLUGIN" -
run_install
guards 1
check "輸出說明略過了 CLAUDE.md" "略過 CLAUDE.md" "$OUT"
check "目標沒有被建立出 CLAUDE.md" EMPTY "$(ls "$CD/CLAUDE.md" 2>/dev/null)"
check "也沒有留下 CLAUDE.md.bak" EMPTY "$(ls "$CD/CLAUDE.md.bak" 2>/dev/null)"
# 證明失敗只擋 CLAUDE.md，其餘步驟照做（不是整支腳本提早死掉）
check "statusline.sh 仍照常複製" EMPTY "$(same_as "$CD/statusline.sh" "$SRC_REPO/statusline.sh")"

echo "── 2. 有 plugin 裝失敗 + 目標已有舊 CLAUDE.md → 原封不動"
# 這條是「真閘門」與「照複製、只是多印一行警告」的分水嶺。
setup c2
cp "$SENTINEL" "$CD/CLAUDE.md"
stub "$BROKEN_PLUGIN" -
run_install
guards 1
check "舊 CLAUDE.md 內容原封不動" EMPTY "$(same_as "$CD/CLAUDE.md" "$SENTINEL")"
check "沒有備份（根本沒動它）" EMPTY "$(ls "$CD/CLAUDE.md.bak" 2>/dev/null)"

echo "── 3. plugin 全部成功 + 目標本來沒有 → 照常複製"
setup c3
stub - -
run_install
guards 0
check "沒有印出略過訊息" EMPTY "$(lacks '略過 CLAUDE.md' "$OUT")"
check "CLAUDE.md 內容等於 repo 版本" EMPTY "$(same_as "$CD/CLAUDE.md" "$SRC_REPO/CLAUDE.md")"
check "本來就沒有舊檔，不該產生 .bak" EMPTY "$(ls "$CD/CLAUDE.md.bak" 2>/dev/null)"

echo "── 4. plugin 全部成功 + 目標有不同的舊檔 → 先備份再覆蓋"
setup c4
cp "$SENTINEL" "$CD/CLAUDE.md"
stub - -
run_install
guards 0
check "輸出提到備份" "備份既有 CLAUDE.md" "$OUT"
check "CLAUDE.md 換成 repo 版本" EMPTY "$(same_as "$CD/CLAUDE.md" "$SRC_REPO/CLAUDE.md")"
# 比對 .bak 的「內容」而非「存在」：cp 兩邊寫反了也會有檔案
check ".bak 是舊的那一份" EMPTY "$(same_as "$CD/CLAUDE.md.bak" "$SENTINEL")"

echo "── 5. plugin 全部成功 + 目標舊檔內容相同 → 不產生多餘的 .bak"
setup c5
cp "$SRC_REPO/CLAUDE.md" "$CD/CLAUDE.md"
stub - -
run_install
guards 0
check "內容不變" EMPTY "$(same_as "$CD/CLAUDE.md" "$SRC_REPO/CLAUDE.md")"
check "內容相同就不備份" EMPTY "$(ls "$CD/CLAUDE.md.bak" 2>/dev/null)"

echo "── 6. marketplace update 失敗但 plugin 全裝成 → CLAUDE.md 照常套用"
# 閘門綁的是 PLUGIN_FAILED，不是 MARKET_FAILED；寫成後者的話這條會紅。
# （marketplace 失敗仍會讓整支腳本以 1 結束，那是最後的彙總，不是這道閘門。）
setup c6
stub - "$FIRST_MARKET"
run_install
guards 1
check "  [守衛] marketplace update 真的被判失敗" "marketplace  $FIRST_MARKET" "$OUT"
check "沒有印出略過訊息" EMPTY "$(lacks '略過 CLAUDE.md' "$OUT")"
check "CLAUDE.md 仍等於 repo 版本" EMPTY "$(same_as "$CD/CLAUDE.md" "$SRC_REPO/CLAUDE.md")"

# ── 以下：fragment 標為 false 的 plugin「照裝、裝完再關」 ─────────────────
# 背景（實測）：`claude plugin install <p>` 會【無條件】把 settings.json 的
# enabledPlugins[<p>] 寫成 true，即使原本是 false，而且沒有 --disabled 之類的
# 旗標。settings 合併又發生在 install 迴圈之前——所以光把 fragment 寫成 false
# 是沒用的，一定會被後面的 install 蓋回去。唯一可行的做法是「照裝，裝完再對
# value=false 的項目補一次 claude plugin disable」，達成「有落地、可隨時用
# /plugin 打開、但預設 disabled」。
#
# 因此這裡守三件事，缺一不可：
#   1. value=false 的項目確實被 disable（否則它會是啟用狀態）
#   2. value=true 的項目【不得】被 disable（否則會誤關別人）
#   3. disable 必須排在同一個 plugin 的 install 【之後】（排前面等於沒做）
# 另外守「fragment 裡該項就是 false」——那是規格本身，不是實作細節。

DISABLED_SPEC="context-handoff@sam-tools"
# 反面樣本不寫死：從 fragment 取仍為 true 的第一個與最後一個
ENABLED_FIRST=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' \
                "$SRC_REPO/settings.fragment.json" | head -1)
ENABLED_LAST=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' \
               "$SRC_REPO/settings.fragment.json" | tail -1)

frag_value() { # frag_value <plugin>  → true / false / null
    jq -r --arg p "$1" '.enabledPlugins[$p] | tostring' "$SRC_REPO/settings.fragment.json"
}

# 順序檢查：正確回空字串，錯誤回描述（交給 check ... EMPTY 判定）
disable_after_install() { # disable_after_install <plugin> <calls-file>
    i=$(grep -n "^plugin install $1\$" "$2" | head -1 | cut -d: -f1)
    d=$(grep -n "^plugin disable $1\$" "$2" | head -1 | cut -d: -f1)
    if [ -z "$i" ]; then printf '沒有 install %s 的呼叫' "$1"; return; fi
    if [ -z "$d" ]; then printf '沒有 disable %s 的呼叫' "$1"; return; fi
    if [ "$d" -lt "$i" ]; then
        printf 'disable 在第 %s 行、install 在第 %s 行：disable 排在 install 之前會被蓋回 true' "$d" "$i"
    fi
}

# 只取 disable 的呼叫對象（斷言用這個當 haystack，失敗訊息才不會噴整份 log）
disable_calls() { # disable_calls <calls-file>
    sed -n 's/^plugin disable //p' "$1" | sort -u
}

nonempty() { # nonempty <text> <說明>  → 空的話回說明（交給 check ... EMPTY）
    if [ -z "$1" ]; then printf '%s' "$2"; fi
}

# 被 disable 的集合是否剛好等於 fragment 裡 value=false 的集合
disable_set_diff() { # disable_set_diff <calls-file>
    expected=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == false) | .key' \
               "$SRC_REPO/settings.fragment.json" | sort)
    actual=$(disable_calls "$1")
    if [ "$expected" != "$actual" ]; then
        printf '預期 disable 集合 [%s]，實得 [%s]' "$(echo $expected)" "$(echo $actual)"
    fi
}

echo "── 7. fragment 裡 value=false 的 plugin → 照裝，裝完再 disable"
setup c7
stub - -
run_install
guards 0
# 非空轉守衛：整段 disable 機制真的有跑（不是「沒人打 disable」讓反面斷言全綠）
check "  [守衛] 確實打出了 plugin disable（不是整段沒跑）" EMPTY \
    "$(nonempty "$(disable_calls "$CALLS")" '完全沒有 plugin disable 的呼叫——反面斷言等於沒測到')"
check "規格：fragment 裡 $DISABLED_SPEC 的值是 false" "false" "$(frag_value "$DISABLED_SPEC")"
check "$DISABLED_SPEC 有被 disable" "$DISABLED_SPEC" "$(disable_calls "$CALLS")"
check "disable 排在它自己的 install 之後" EMPTY "$(disable_after_install "$DISABLED_SPEC" "$CALLS")"
check "value=true 的 $ENABLED_FIRST 沒有被 disable" EMPTY \
    "$(lacks "$ENABLED_FIRST" "$(disable_calls "$CALLS")")"
check "value=true 的 $ENABLED_LAST 沒有被 disable" EMPTY \
    "$(lacks "$ENABLED_LAST" "$(disable_calls "$CALLS")")"
check "disable 的對象剛好是 fragment 裡 value=false 的那些" EMPTY "$(disable_set_diff "$CALLS")"
check "合併後的 settings.json 裡 $DISABLED_SPEC 也是 false" "false" \
    "$(jq -r --arg p "$DISABLED_SPEC" '.enabledPlugins[$p] | tostring' "$CD/settings.json")"

echo "── 8. 同一台機器重跑 install.sh → 冪等，disable 照打"
# 第二次跑時 settings.json 已經是合併後的樣子，但 install 仍會把 enabledPlugins
# 寫回 true，所以 disable 必須每次都補打，不能只在「第一次安裝」時做。
: > "$CALLS"
run_install
guards 0
check "第二次仍然 disable 了 $DISABLED_SPEC" "$DISABLED_SPEC" "$(disable_calls "$CALLS")"
check "第二次的 disable 也排在 install 之後" EMPTY "$(disable_after_install "$DISABLED_SPEC" "$CALLS")"
check "第二次仍然沒有誤關 $ENABLED_FIRST" EMPTY \
    "$(lacks "$ENABLED_FIRST" "$(disable_calls "$CALLS")")"
check "settings.json 已是最新，不會反覆改寫" "已是最新" "$OUT"
echo "── 9. CLAUDE_DIR 非預設 → 連 disable 都不准打（claude plugin 只認真實 ~/.claude）"
# marketplace / install 兩段都因為這個條件整段略過，disable 必須跟它們同進退：
# 寫成 install 迴圈之後「另起一段」而漏掉這個判斷的話，操作者明明把 CLAUDE_DIR
# 指到別處，卻會對真實的 ~/.claude 打 disable。
setup c9
stub - -
run_install_at "$H/elsewhere"
# 本 case 的非空轉守衛方向相反：要證明真的走到了略過分支
check "  [守衛] 真的走到「CLAUDE_DIR 非預設」的略過分支" "CLAUDE_DIR 非預設" "$OUT"
check "  [守衛] install.sh exit code = 0" "0" "$RC"
check "沒有打出任何 plugin install" EMPTY "$(lacks 'plugin install' "$(cat "$CALLS")")"
check "沒有打出任何 plugin disable" EMPTY "$(lacks 'plugin disable' "$(cat "$CALLS")")"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
