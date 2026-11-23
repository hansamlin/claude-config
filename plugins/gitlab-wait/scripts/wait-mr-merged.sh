#!/bin/sh
# 輪詢 GitLab MR，直到合併或關閉。使用者設了「pipeline 成功後自動合併」時，
# 在背景用它等合併完成，再做 worktree 收尾。要在專案目錄（或其 worktree）裡執行，
# `glab api` 的 :fullpath 由 git remote 決定。
# 用法：wait-mr-merged [--no-retry] <iid> [intervalSeconds] [maxSeconds]
#   （plugin 的 bin/ 在 PATH 上；直接執行本檔則用 sh wait-mr-merged.sh …）
#   例：wait-mr-merged 112
#       wait-mr-merged 112 15 300
# 預設每 20 秒查一次、最多等 1800 秒。
# 每輪也看 MR 的 head pipeline：failed 且失敗的 job 都是 runner 連不到 GitLab 這類暫時性錯誤時，
# 自動 retry 那些 job（同名 job 最多 2 次）繼續等，規則見 gitlab-retry.sh；--no-retry 關閉（也不看 pipeline）。
# 結束碼：0 已合併（印出 merge commit）；1 已關閉但沒合併；2 參數錯誤；3 逾時（MR 仍是 opened）；
#         4 head pipeline 失敗且不可自動 retry（自動合併不會發生）。
. "$(dirname "$0")/gitlab-retry.sh"
RETRY=1
if [ "$1" = "--no-retry" ]; then
  RETRY=0
  shift
fi
IID="$1"
INTERVAL="${2:-20}"
MAX="${3:-1800}"
for v in "$IID" "$INTERVAL" "$MAX"; do
  case "$v" in
    '' | *[!0-9]*)
      echo "usage: wait-mr-merged [--no-retry] <iid> [intervalSeconds] [maxSeconds]" >&2
      exit 2
      ;;
  esac
done
if [ "$INTERVAL" -lt 1 ]; then
  echo "intervalSeconds must be >= 1" >&2
  exit 2
fi

# host 與專案 id 只在啟動時從 git remote 解析一次，之後 cd /：
# 背景執行期間 worktree 被移除（cwd 消失）時，:fullpath 會展開失敗。
HOST=$(git remote get-url origin 2>/dev/null | sed -E 's#^[a-z+]+://([^@/]*@)?##; s#^[^@]*@##; s#[:/].*##')
resolved=$(glab api --hostname "$HOST" "projects/:fullpath" 2>&1)
PROJECT=$(printf '%s' "$resolved" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
if [ -z "$HOST" ] || [ -z "$PROJECT" ]; then
  echo "cannot resolve GitLab project from git remote (host=${HOST:-none}): run inside the repo, or check glab auth/network" >&2
  printf 'glab response: %.300s\n' "$resolved" >&2
  exit 2
fi
P="projects/$PROJECT"
cd /

elapsed=0
while :; do
  json=$(glab api --hostname "$HOST" "$P/merge_requests/$IID" 2>&1)
  # 取第一個 "state"（MR 自己的；description 與 title 裡的引號都被跳脫，不會誤中）。
  # glab 失敗或回傳不是 JSON 時 state 為空，當作還沒合併繼續等。
  state=$(printf '%s' "$json" | grep -o '"state":"[a-z]*"' | head -1 | cut -d'"' -f4)
  case "$state" in
    merged)
      sha=$(printf '%s' "$json" | grep -o '"merge_commit_sha":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
      echo "merged: iid=$IID merge_commit=${sha:-none}"
      exit 0
      ;;
    closed)
      echo "closed (not merged): iid=$IID"
      exit 1
      ;;
    opened)
      if [ "$RETRY" = 1 ] && command -v jq >/dev/null 2>&1; then
        hp=$(printf '%s' "$json" | jq -r '.head_pipeline // empty | "\(.id) \(.status) \(.web_url // "")"' 2>/dev/null)
        hp_id=${hp%% *}
        hp_rest=${hp#* }
        hp_status=${hp_rest%% *}
        hp_url=${hp_rest#* }
        if [ -n "$hp" ] && [ "$hp_status" = failed ]; then
          if ! gitlab_retry_transient "$hp_id"; then
            echo "pipeline failed: iid=$IID pipeline=$hp_id url=$hp_url"
            gitlab_retry_summary
            exit 4
          fi
        fi
      fi
      ;;
  esac
  if [ "$elapsed" -ge "$MAX" ]; then
    echo "TIMEOUT after ${elapsed}s: iid=$IID state=${state:-unknown}"
    # 狀態取不到時附上 glab 最後的回應，避免只看到 unknown。
    [ -n "$state" ] || printf 'last glab response: %.300s\n' "$json"
    exit 3
  fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done
