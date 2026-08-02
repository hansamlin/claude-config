#!/usr/bin/env bash
# 把這個 repo 的設定套用到 ~/.claude。
#
# 分工：
#   plugin（context-handoff / tsgo-lsp）   由 Claude Code 的 marketplace 管，
#                                          更新走 /plugin update，不經這支腳本
#   CLAUDE.md / statusline.sh / settings   plugin 管不到，由這支腳本套用
#
# settings.json 是「深度合併」而非覆蓋，只寫入本 repo 提供的 key，
# 目標機器上其他設定原封不動；可重複執行。
#
# 用法：
#   ./install.sh              套用
#   ./install.sh --dry-run    只顯示會做什麼
#   sh install.sh             也可以——本檔刻意維持 POSIX sh 相容
#
# 環境變數：
#   CLAUDE_DIR   目標目錄，預設 ~/.claude
#
# 註 1：底下一律用 if 而非 `[ x ] && cmd`——後者在 set -e 下條件不成立時
#       會讓整個腳本以非 0 結束。
# 註 2：不要用 process substitution `while ... done < <(cmd)`、`[[ ]]`、
#       陣列、`${BASH_SOURCE[0]}`。這些是 bashism，`sh install.sh` 會在
#       剖析階段就 syntax error（macOS 的 /bin/sh 是 bash 的 POSIX 模式，
#       該模式停用 process substitution）。要餵迴圈請用 here-doc，見下方。

set -eu
# pipefail 不是 POSIX，dash 沒有；有才開，沒有就算了。
if (set -o pipefail) 2>/dev/null; then
    set -o pipefail
fi

REPO=$(cd "$(dirname "$0")" && pwd)
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

step "複製 plugin 管不到的檔案"
run mkdir -p "$CLAUDE_DIR"
for f in CLAUDE.md statusline.sh; do
    if [ -f "$CLAUDE_DIR/$f" ] && ! cmp -s "$REPO/$f" "$CLAUDE_DIR/$f"; then
        log "備份既有 $f → $f.bak"
        run cp "$CLAUDE_DIR/$f" "$CLAUDE_DIR/$f.bak"
    fi
    log "$f"
    run cp "$REPO/$f" "$CLAUDE_DIR/$f"
done
if [ "$DRY_RUN" = 0 ]; then
    chmod +x "$CLAUDE_DIR/statusline.sh"
fi

step "合併 settings.json"
SETTINGS="$CLAUDE_DIR/settings.json"
FRAGMENT=$(sed "s|__CLAUDE_DIR__|$CLAUDE_DIR|g" "$REPO/settings.fragment.json")

if [ -f "$SETTINGS" ]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        echo "既有 settings.json 不是合法 JSON，中止以免破壞它" >&2
        exit 1
    fi
    # jq 的 * 對 object 是遞迴合併、對陣列是右側取代：目標機器其他設定保留，
    # 本 repo 提供的 key 以 repo 為準，重複執行結果穩定。
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

step "安裝 plugin"
# settings.json 的 enabledPlugins 只是「啟用」旗標，不會讓 plugin 真的落地——
# 沒跑過 install 的話 installed_plugins.json 是空的，hook 完全不會觸發且毫無錯誤訊息。
# 所以這裡逐一安裝 fragment 裡列出的每一個，而不是只裝本 repo 自己的兩個。
# 已安裝的 Claude Code 會自行略過，可重複執行。
if [ "$CLAUDE_DIR" != "$HOME/.claude" ]; then
    log "CLAUDE_DIR 非預設，略過──claude plugin 一律操作真實 ~/.claude，不吃這個變數"
else
    # 先取出清單再用 here-doc 餵迴圈：here-doc 是 POSIX，而且迴圈本體留在
    # 當前 shell（用 `cmd | while` 的話迴圈會跑在 subshell，變數異動會丟失）。
    PLUGINS=$(jq -r '.enabledPlugins // {} | keys[]' "$REPO/settings.fragment.json")
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        log "$p"
        if [ "$DRY_RUN" = 0 ]; then
            claude plugin install "$p" 2>&1 | tail -1 | sed 's/^/    /' || true
        fi
    done <<EOF
$PLUGINS
EOF
fi

step "還原 tsgo-lsp 的 TypeScript"
if [ "$CLAUDE_DIR" != "$HOME/.claude" ]; then
    log "CLAUDE_DIR 非預設，略過（plugin 不在此目錄底下）"
    printf '\n▸ 完成（部分步驟因 CLAUDE_DIR 非預設而略過）\n'
    exit 0
fi
# vendor/node_modules 不進版控（約 30MB 二進位），從 lockfile 還原。
# plugin 實際落地位置由 Claude Code 決定，所以用 find 定位。
# 可能同時存在 marketplaces/ 與 cache/ 兩份，逐一處理而非只取第一個
# 同上用 here-doc；這裡尤其不能用 pipe，否則 found=1 會留在 subshell 裡失效。
# find 對讀不到的子目錄會回非 0，`|| true` 以免 set -e 中止。
VENDORS=$(find "$CLAUDE_DIR/plugins" -type d -path '*tsgo-lsp/vendor' 2>/dev/null || true)
found=0
while IFS= read -r vendor; do
    [ -n "$vendor" ] || continue
    found=1
    if [ -x "$vendor/node_modules/.bin/tsc" ]; then
        log "已安裝，略過：$vendor"
    else
        log "npm ci → $vendor"
        if [ "$DRY_RUN" = 0 ]; then
            (cd "$vendor" && npm ci >/dev/null 2>&1) || log "⚠ npm ci 失敗，請手動在該目錄執行"
        fi
    fi
done <<EOF
$VENDORS
EOF

if [ "$found" = 0 ]; then
    log "找不到已安裝的 tsgo-lsp，plugin 安裝完成後再跑一次這支腳本"
fi

step "完成"
cat <<EOF
  驗證：
    bash "$REPO/plugins/context-handoff/scripts/check.test.sh"
    在 Claude Code 裡執行 /hooks 確認 Stop 與 PostCompact 有出現
    ps aux | grep -- '--lsp'   確認 LSP 跑的是 tsgo

  之後 repo 有更新時，plugin 部分用 /plugin marketplace update 即可，
  只有 CLAUDE.md / statusline.sh / settings 變動才需要再跑這支腳本。
EOF
