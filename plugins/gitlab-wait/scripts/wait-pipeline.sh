#!/bin/sh
# 輪詢 GitLab pipeline，直到跑完。合併後要確認 main 的 pipeline 成功、或要等 MR 的 pipeline 跑完時，
# 在背景用它等。要在專案目錄（或其 worktree）裡執行，`glab api` 的 :fullpath 由 git remote 決定。
# 用法：wait-pipeline <sha|mr|id> <值> [intervalSeconds] [maxSeconds]
#   （plugin 的 bin/ 在 PATH 上；直接執行本檔則用 sh wait-pipeline.sh …）
#   sha <rev>：該 commit 的 pipeline。rev 是 git 解析得到的 commit（origin/main、HEAD、短 sha 都行），
#              解析前要先 git fetch。pipeline 還沒建立時會繼續等，不會誤抓前一個 commit 的結果。
#   mr <iid>：該 MR 最新的 pipeline。
#   id <pipelineId>：指定的 pipeline。
#   例：wait-pipeline sha 88d213f
#       wait-pipeline mr 114 15 300
#       wait-pipeline id 49862
# 預設每 20 秒查一次、最多等 540 秒。找到 pipeline 之後就鎖定它的編號，之後新建的 pipeline 不影響。
# 結束碼：0 success；1 failed／canceled／skipped／manual（輸出狀態與網址）；2 參數錯誤；3 逾時。
SCOPE="$1"
VALUE="$2"
INTERVAL="${3:-20}"
MAX="${4:-540}"
usage() {
  echo "usage: wait-pipeline <sha|mr|id> <value> [intervalSeconds] [maxSeconds]" >&2
  exit 2
}
case "$SCOPE" in
  sha | mr | id) ;;
  *) usage ;;
esac
[ -n "$VALUE" ] || usage
for v in "$INTERVAL" "$MAX"; do
  case "$v" in
    '' | *[!0-9]*) usage ;;
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

PID=""
case "$SCOPE" in
  sha)
    FULL=$(git rev-parse --verify "$VALUE^{commit}" 2>/dev/null) || {
      echo "cannot resolve commit: $VALUE (git fetch first?)" >&2
      exit 2
    }
    LIST="$P/pipelines?sha=$FULL&per_page=1"
    ;;
  mr)
    case "$VALUE" in
      *[!0-9]*) usage ;;
    esac
    LIST="$P/merge_requests/$VALUE/pipelines?per_page=1"
    ;;
  id)
    case "$VALUE" in
      *[!0-9]*) usage ;;
    esac
    PID="$VALUE"
    ;;
esac
cd /

elapsed=0
out=""
while :; do
  # 列表由新到舊，第一個 "id" 是最新的 pipeline；找不到（還沒建立、glab 失敗）就下一輪再找。
  if [ -z "$PID" ]; then
    out=$(glab api --hostname "$HOST" "$LIST" 2>&1)
    PID=$(printf '%s' "$out" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  fi
  status=""
  url=""
  if [ -n "$PID" ]; then
    json=$(glab api --hostname "$HOST" "$P/pipelines/$PID" 2>&1)
    out="$json"
    # 單一 pipeline 物件裡，第一個 "status"、"web_url" 都是 pipeline 自己的（後面的是巢狀的 user 等）。
    status=$(printf '%s' "$json" | grep -o '"status":"[a-z_]*"' | head -1 | cut -d'"' -f4)
    url=$(printf '%s' "$json" | grep -o '"web_url":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi
  case "$status" in
    success)
      echo "success: pipeline=$PID url=$url"
      exit 0
      ;;
    failed | canceled | skipped | manual)
      echo "$status: pipeline=$PID url=$url"
      exit 1
      ;;
  esac
  if [ "$elapsed" -ge "$MAX" ]; then
    echo "TIMEOUT after ${elapsed}s: pipeline=${PID:-not found} status=${status:-unknown}"
    # 狀態取不到時附上 glab 最後的回應，避免只看到 unknown。
    [ -n "$status" ] || printf 'last glab response: %.300s\n' "$out"
    exit 3
  fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done
