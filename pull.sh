#!/usr/bin/env bash
# 反向同步：把 ~/.claude 的改動抓回這個 repo，之後再 git diff / commit。
#
# 範圍限於「plugin 管不到、又容易在本機被改掉」的三樣：
#   CLAUDE.md、statusline.sh、settings.json 的個人設定
#
# plugin 內容（hook script、handoff skill、tsgo 設定）不在此列——那些請直接在
# repo 裡改，再用 /plugin marketplace update 讓 Claude Code 取得。~/.claude/plugins
# 底下是 Claude Code 的快取，改那裡會被下次更新蓋掉。
#
# 用法：
#   ./pull.sh              抓回來
#   ./pull.sh --dry-run    只列出有差異的項目
#   sh pull.sh             也可以——本檔刻意維持 POSIX sh 相容
#
# 環境變數：
#   CLAUDE_DIR   來源目錄，預設 ~/.claude
#
# 註：不要引入 bashism（process substitution `< <(cmd)`、`[[ ]]`、陣列、
#     `<<<`、`${BASH_SOURCE[0]}`、無條件的 `set -o pipefail`）。有人打
#     `sh pull.sh` 時 bash 是逐段剖析執行，錯誤會等到前面幾步都跑完才炸，
#     留下做到一半的狀態。check.test.sh 第 14 節會擋。

set -eu
# pipefail 不是 POSIX，dash 沒有；有才開，沒有就算了。
if (set -o pipefail) 2>/dev/null; then
    set -o pipefail
fi

REPO=$(cd "$(dirname "$0")" && pwd)
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

# 一律用 if 而非 `[ x ] && cmd`——後者在 set -e 下條件不成立時會讓腳本提前結束
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "需要 jq，請先安裝：brew install jq" >&2
    exit 1
fi

printf '來源：%s\n目標：%s\n\n' "$CLAUDE_DIR" "$REPO"

changed=0

copy() { # copy <相對路徑>
    # 分行宣告：`local a=$1 b=$a` 在 set -u 下會因 a 尚未綁定而中止
    local rel="$1"
    local src="$CLAUDE_DIR/$rel"
    local dst="$REPO/$rel"
    if [ ! -f "$src" ]; then
        printf '  ⚠ 來源不存在，略過：%s\n' "$rel"
        return
    fi
    if cmp -s "$src" "$dst" 2>/dev/null; then
        return
    fi
    printf '  ~ %s\n' "$rel"
    changed=$((changed + 1))
    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    fi
}

copy CLAUDE.md
copy statusline.sh

# settings.json → settings.fragment.json
# 去掉純本機 UI 狀態、hooks（由 context-handoff plugin 提供），以及 autoMode
# （auto mode 的信任邊界描述的是「這台機器接得到什麼」——公司的 GitLab 主機、
# 內網服務、機敏檔案位置，家裡的機器本來就連不到，同步過去只會是錯的），
# 再把本機路徑換回佔位符，這樣 repo 裡不會有個人路徑。
#
# enabledPlugins 與 extraKnownMarketplaces 落檔前一律排成升冪：Claude Code 每次
# 啟用／停用 plugin 都會自行重排這兩個 object 的 key，順序沒有語意（讀設定不看
# 順序），但每次 pull 回來都會在 git diff 上炸出一整片假異動，把真正的設定變更
# 埋掉。固定順序後，diff 只會剩下真的加減了什麼。
SETTINGS="$CLAUDE_DIR/settings.json"
FRAGMENT="$REPO/settings.fragment.json"
if [ -f "$SETTINGS" ]; then
    # has($k) 的防護不能省：`.[$k] |= f` 對不存在的 key 會憑空補一個 null 進去。
    new=$(jq 'del(.feedbackSurveyState) | del(.hooks) | del(.autoMode)
              | reduce ["enabledPlugins", "extraKnownMarketplaces"][] as $k
                  (.; if has($k)
                      then .[$k] |= (to_entries | sort_by(.key) | from_entries)
                      else . end)' "$SETTINGS" \
          | sed "s|$CLAUDE_DIR|__CLAUDE_DIR__|g")
    if [ "$(printf '%s' "$new" | jq -S .)" != "$(jq -S . "$FRAGMENT" 2>/dev/null || echo null)" ]; then
        printf '  ~ %s\n' "settings.fragment.json"
        changed=$((changed + 1))
        if [ "$DRY_RUN" = 0 ]; then
            printf '%s\n' "$new" | jq . > "$FRAGMENT"
        fi
    fi
fi

echo
if [ "$changed" -eq 0 ]; then
    echo "沒有差異，repo 已是最新。"
elif [ "$DRY_RUN" = 1 ]; then
    printf '%d 項有差異。（dry-run，未寫入）\n' "$changed"
else
    printf '%d 項有差異，已抓回，用 git diff 檢視後再 commit。\n' "$changed"
fi
