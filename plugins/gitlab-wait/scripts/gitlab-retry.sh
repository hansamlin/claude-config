# 共用函式：pipeline failed 時，把「runner 連不到 GitLab」這類暫時性失敗的 job 自動 retry。
# 由 wait-pipeline.sh、wait-mr-merged.sh source；呼叫前要先設好 HOST 與 P（projects/<id>）。
#
# 為什麼讀 trace：runner clone 失敗（Failed to connect to … port 443）的 failure_reason 是
# script_failure，跟一般測試失敗分不開，只能比對 log 結尾。
#
# 計次無狀態：某 job 已 retry 幾次 = pipeline 裡（含已 retry 的）同名 job 數 − 1。
# 腳本逾時後重跑、或有人手動 retry 過，次數都不會被重置或多算。
# 需要 jq；沒有 jq 時不 retry，照舊版行為結束。

GITLAB_RETRY_MAX=2
# 不分大小寫比對 trace 最後 200 行。
GITLAB_RETRY_PATTERN="failed to connect to .* port [0-9]+|could not resolve host|unable to access 'https?://|could not connect to server|connection timed out|connection reset by peer|the requested url returned error: 50[234]"
# 本次執行 retry 過的 job name，一行一個（給 gitlab_retry_summary 用）。
GITLAB_RETRIED=""
# 最近一次判定「不 retry」的原因，一行一個；呼叫端印完狀態行之後再印。
GITLAB_RETRY_NOTES=""

# gitlab_retry_transient <pipelineId>
# 回傳 0：已 retry 至少一個 job（或剛 retry 完、GitLab 還沒更新狀態），呼叫端繼續等。
# 回傳 1：不能 retry（有非暫時性失敗、已滿次數、沒有 jq、API 失敗），呼叫端照原本的失敗處理。
# 只有「所有非 allow_failure 的失敗 job 都是暫時性、且都還沒滿次數」才會 retry：
# 只要有一個真的壞掉，pipeline 怎麼重跑都會失敗，retry 只是浪費 runner。
gitlab_retry_transient() {
  _pid="$1"
  GITLAB_RETRY_NOTES=""
  if ! command -v jq >/dev/null 2>&1; then
    GITLAB_RETRY_NOTES="auto-retry skipped: jq not found"
    return 1
  fi
  # 內層 glab 都接 </dev/null：下面的 while 從 here-doc 讀資料，glab 讀 stdin 會把它吃掉。
  _failed=$(glab api --hostname "$HOST" "$P/pipelines/$_pid/jobs?scope[]=failed&per_page=100" </dev/null 2>/dev/null) || {
    GITLAB_RETRY_NOTES="auto-retry skipped: cannot list failed jobs"
    return 1
  }
  _cands=$(printf '%s' "$_failed" | jq -r '.[] | select(.allow_failure != true) | "\(.id)\t\(.failure_reason // "")\t\(.web_url // "")\t\(.name)"' 2>/dev/null) || {
    GITLAB_RETRY_NOTES="auto-retry skipped: unexpected jobs response"
    return 1
  }
  if [ -z "$_cands" ]; then
    # 剛 retry 完的那一輪，舊 job 已被標成 retried、pipeline 狀態可能還沒從 failed 更新。
    [ -n "$GITLAB_RETRIED" ] && return 0
    GITLAB_RETRY_NOTES="auto-retry skipped: no failed job to retry"
    return 1
  fi
  _all=$(glab api --hostname "$HOST" "$P/pipelines/$_pid/jobs?include_retried=true&per_page=100" </dev/null 2>/dev/null) || {
    GITLAB_RETRY_NOTES="auto-retry skipped: cannot list job history"
    return 1
  }

  _tab=$(printf '\t')
  _todo=""
  _blocked=""
  while IFS="$_tab" read -r _jid _reason _url _name; do
    [ -n "$_jid" ] || continue
    _transient=0
    case "$_reason" in
      runner_system_failure | stuck_or_timeout_failure) _transient=1 ;;
      *)
        if glab api --hostname "$HOST" "$P/jobs/$_jid/trace" </dev/null 2>/dev/null | tail -n 200 | grep -Eiq "$GITLAB_RETRY_PATTERN"; then
          _transient=1
        fi
        ;;
    esac
    if [ "$_transient" = 0 ]; then
      _blocked="$_blocked
not retried (not a connection error): $_name $_url"
      continue
    fi
    _count=$(printf '%s' "$_all" | jq --arg n "$_name" '[.[] | select(.name == $n)] | length' 2>/dev/null)
    case "$_count" in '' | *[!0-9]*) _count=1 ;; esac
    _done=$((_count - 1))
    [ "$_done" -ge 0 ] || _done=0
    if [ "$_done" -ge "$GITLAB_RETRY_MAX" ]; then
      _blocked="$_blocked
not retried (already retried $_done times): $_name $_url"
      continue
    fi
    _todo="$_todo$_jid$_tab$((_done + 1))$_tab$_name
"
  done <<EOF
$_cands
EOF

  if [ -n "$_blocked" ]; then
    GITLAB_RETRY_NOTES=$(printf '%s' "$_blocked" | sed '/^$/d')
    return 1
  fi

  _ok=0
  while IFS="$_tab" read -r _jid _attempt _name; do
    [ -n "$_jid" ] || continue
    if glab api --hostname "$HOST" -X POST "$P/jobs/$_jid/retry" </dev/null >/dev/null 2>&1; then
      echo "retry: job=$_jid name=$_name attempt=$_attempt/$GITLAB_RETRY_MAX"
      GITLAB_RETRIED="$GITLAB_RETRIED$_name
"
      _ok=$((_ok + 1))
    else
      GITLAB_RETRY_NOTES="${GITLAB_RETRY_NOTES:+$GITLAB_RETRY_NOTES
}retry request failed: job=$_jid name=$_name"
    fi
  done <<EOF
$_todo
EOF
  [ "$_ok" -gt 0 ]
}

# 印 GITLAB_RETRY_NOTES 與本次 retry 過的 job（例：retried: build x1, test x2）；都沒有就不印。
gitlab_retry_summary() {
  [ -z "$GITLAB_RETRY_NOTES" ] || printf '%s\n' "$GITLAB_RETRY_NOTES"
  [ -n "$GITLAB_RETRIED" ] || return 0
  _s=$(printf '%s' "$GITLAB_RETRIED" | sed '/^$/d' | sort | uniq -c | awk '{c=$1; $1=""; sub(/^ /,""); printf "%s%s x%s", (NR>1?", ":""), $0, c}')
  echo "retried: $_s"
}
