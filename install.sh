#!/usr/bin/env bash
# 把這個 repo 的內容套用到 ~/.claude。
#
# 設計成可重複執行（冪等）：settings.json 是「深度合併」而非覆蓋，
# 只寫入本 repo 真正提供的那幾個 key，目標機器上其他設定原封不動。
#
# 用法：
#   ./install.sh              套用
#   ./install.sh --dry-run    只顯示會做什麼，不動任何檔案
#
# 環境變數：
#   CLAUDE_DIR   目標目錄，預設 ~/.claude
#
# 註：底下一律用 if 而非 `[ x ] && cmd`——後者在 set -e 下條件不成立時
# 會讓整個腳本以非 0 結束。

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

log()  { printf '  %s\n' "$*"; }
step() { printf '\n▸ %s\n' "$*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then log "(dry-run) $*"; else "$@"; fi; }

if ! command -v jq >/dev/null 2>&1; then
    echo "需要 jq，請先安裝：brew install jq" >&2
    exit 1
fi

printf '安裝來源：%s\n目標目錄：%s\n' "$REPO" "$CLAUDE_DIR"
if [ "$DRY_RUN" = 1 ]; then
    printf '（dry-run，不會寫入任何檔案）\n'
fi

step "建立目錄"
run mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/local-plugins"

step "複製檔案"
for f in CLAUDE.md statusline.sh; do
    if [ -f "$CLAUDE_DIR/$f" ] && ! cmp -s "$REPO/$f" "$CLAUDE_DIR/$f"; then
        log "備份既有 $f → $f.bak"
        run cp "$CLAUDE_DIR/$f" "$CLAUDE_DIR/$f.bak"
    fi
    log "$f"
    run cp "$REPO/$f" "$CLAUDE_DIR/$f"
done

# 用 /. 複製目錄「內容」，既有檔案（例如 vendor/node_modules）保留不刪
log "hooks/"
run cp -R "$REPO/hooks/." "$CLAUDE_DIR/hooks/"
log "local-plugins/"
run cp -R "$REPO/local-plugins/." "$CLAUDE_DIR/local-plugins/"

if [ "$DRY_RUN" = 0 ]; then
    chmod +x "$CLAUDE_DIR/hooks/context-handoff-check.sh" \
             "$CLAUDE_DIR/hooks/context-handoff-reset.sh" \
             "$CLAUDE_DIR/hooks/context-handoff-check.test.sh" \
             "$CLAUDE_DIR/statusline.sh"
fi

step "修正 tsgo-lsp 的絕對路徑"
# plugin.json 的 lspServers.command 必須是絕對路徑，不吃 ~ 或環境變數，
# 所以 repo 裡存的是 __CLAUDE_DIR__ 佔位符，安裝時填成目標機器的實際路徑。
PLUGIN_JSON="$CLAUDE_DIR/local-plugins/plugins/tsgo-lsp/.claude-plugin/plugin.json"
TSC_PATH="$CLAUDE_DIR/local-plugins/plugins/tsgo-lsp/vendor/node_modules/.bin/tsc"
log "command → $TSC_PATH"
if [ "$DRY_RUN" = 0 ]; then
    tmp=$(mktemp)
    jq --arg cmd "$TSC_PATH" '.lspServers.typescript.command = $cmd' "$PLUGIN_JSON" > "$tmp"
    mv "$tmp" "$PLUGIN_JSON"
fi

step "合併 settings.json"
SETTINGS="$CLAUDE_DIR/settings.json"
FRAGMENT=$(sed "s|__CLAUDE_DIR__|$CLAUDE_DIR|g" "$REPO/settings.fragment.json")

if [ -f "$SETTINGS" ]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        echo "既有 settings.json 不是合法 JSON，中止以免破壞它" >&2
        exit 1
    fi
    # jq 的 * 對 object 是遞迴合併、對陣列是右側取代——正是要的行為：
    # 目標機器其他設定保留，重複執行也不會讓 hooks 陣列愈疊愈長。
    merged=$(printf '%s' "$FRAGMENT" | jq -s '.[0] * .[1]' "$SETTINGS" -)
    if [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$SETTINGS")" ]; then
        log "已是最新，無需變更"
    else
        log "備份 settings.json → settings.json.bak"
        run cp "$SETTINGS" "$SETTINGS.bak"
        log "寫入合併結果（只動本 repo 提供的 key）"
        if [ "$DRY_RUN" = 0 ]; then
            printf '%s\n' "$merged" | jq . > "$SETTINGS"
        fi
    fi
else
    log "目標無 settings.json，直接以 fragment 建立"
    if [ "$DRY_RUN" = 0 ]; then
        printf '%s\n' "$FRAGMENT" | jq . > "$SETTINGS"
    fi
fi

step "完成"
cat <<EOF
  還原 tsgo LSP 的 TypeScript（首次安裝或版本變更後需要）：
    (cd "$CLAUDE_DIR/local-plugins/plugins/tsgo-lsp/vendor" && npm ci)

  驗證：
    bash "$CLAUDE_DIR/hooks/context-handoff-check.test.sh"
    在 Claude Code 裡執行 /hooks 確認 Stop 與 PostCompact 有出現
EOF
