#!/usr/bin/env bash
# 反向同步：把 ~/.claude 裡的改動抓回這個 repo，之後再 git diff / commit。
#
# 實務上你會直接在 ~/.claude 改 hook（例如請 Claude Code 改），這支負責把那些
# 改動收回版控。與 install.sh 互為反向。
#
# 用法：
#   ./pull.sh              抓回來
#   ./pull.sh --dry-run    只列出有差異的檔案，不寫入
#
# 環境變數：
#   CLAUDE_DIR   來源目錄，預設 ~/.claude

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
# 一律用 if 而非 `[ x ] && cmd`——後者在 set -e 下條件不成立時會讓腳本提前結束
DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

command -v jq >/dev/null 2>&1 || { echo "需要 jq，請先安裝：brew install jq" >&2; exit 1; }

printf '來源：%s\n目標：%s\n\n' "$CLAUDE_DIR" "$REPO"

changed=0
copy() { # copy <相對路徑>
    # 分行宣告：`local a=$1 b=$a` 在 set -u 下會因 a 尚未綁定而中止
    local rel="$1"
    local src="$CLAUDE_DIR/$rel"
    local dst="$REPO/$rel"
    [ -f "$src" ] || { printf '  ⚠ 來源不存在，略過：%s\n' "$rel"; return; }
    if cmp -s "$src" "$dst" 2>/dev/null; then return; fi
    printf '  ~ %s\n' "$rel"
    changed=$((changed + 1))
    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    fi
}

copy CLAUDE.md
copy statusline.sh
copy hooks/context-handoff-check.sh
copy hooks/context-handoff-reset.sh
copy hooks/context-handoff-check.test.sh
copy local-plugins/.claude-plugin/marketplace.json
copy local-plugins/plugins/tsgo-lsp/vendor/package.json
copy local-plugins/plugins/tsgo-lsp/vendor/package-lock.json

# plugin.json 的 command 在本機是絕對路徑，收進 repo 前換回佔位符，
# 免得把個人路徑寫進版控（install.sh 會再依目標機器填回實際路徑）。
PLUGIN_SRC="$CLAUDE_DIR/local-plugins/plugins/tsgo-lsp/.claude-plugin/plugin.json"
PLUGIN_DST="$REPO/local-plugins/plugins/tsgo-lsp/.claude-plugin/plugin.json"
if [ -f "$PLUGIN_SRC" ]; then
    normalized=$(jq --arg dir "$CLAUDE_DIR" \
        '.lspServers.typescript.command |= sub("^" + $dir; "__CLAUDE_DIR__")' "$PLUGIN_SRC")
    if [ "$(printf '%s' "$normalized" | jq -S .)" != "$(jq -S . "$PLUGIN_DST" 2>/dev/null || echo null)" ]; then
        printf '  ~ %s\n' "local-plugins/plugins/tsgo-lsp/.claude-plugin/plugin.json"
        changed=$((changed + 1))
        if [ "$DRY_RUN" = 0 ]; then
            printf '%s\n' "$normalized" | jq . > "$PLUGIN_DST"
        fi
    fi
fi

echo
if [ "$changed" -eq 0 ]; then
    echo "沒有差異，repo 已是最新。"
elif [ "$DRY_RUN" = 1 ]; then
    printf '%d 個檔案有差異。（dry-run，未寫入）\n' "$changed"
else
    printf '%d 個檔案有差異，已抓回，用 git diff 檢視後再 commit。\n' "$changed"
fi

cat <<'EOF'

註：settings.json 不在同步範圍內——它會被 Claude Code 執行期改寫，本 repo 只
以 settings.fragment.json 保存自己提供的那幾個 key。若你在 ~/.claude/settings.json
裡改了 hooks / statusLine / 這個 marketplace 的設定，要手動反映到 fragment。
EOF
