#!/usr/bin/env bash
# gitlab-wait 自動 retry 的黑箱測試（依規格，不依賴實作內容）。
#
# 全程在 mktemp 目錄裡跑：用假的 glab（放在 PATH 最前面）依 fixture 回應 API，
# 不會呼叫真的 glab，也不會連任何網路。假 glab 會把每次呼叫記到 log
# （`GET <path>` / `POST <path>`），供斷言使用。直接執行即可：
#   bash plugins/gitlab-wait/scripts/gitlab-wait.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIPE="$HERE/wait-pipeline.sh"
MRW="$HERE/wait-mr-merged.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"

# --- 假 glab ---------------------------------------------------------------
# 規則：
#   - 找出以 projects/ 開頭的參數當 path；有 -X POST 或 --method POST 即為 POST。
#   - pipeline 狀態：每次 GET pipeline 消耗 pipeline.seq 的一行（最後一行沿用）。
#   - MR 狀態：每次 GET MR 消耗 mr.seq 的一行（最後一行沿用）。
#   - failed／include_retried 的 job 清單與 trace 依 fixture 檔回應；
#     job 清單的版本依目前的 retry 次數（retries 檔）挑 failed-R<n>／all-R<n>。
#   - retry 會把 retries 加 1，新 job id = 舊 id + 1000。
#   - 未知的 path 或錯誤 hostname：記錄後以非 0 結束，讓測試抓得到非預期呼叫。
cat > "$BIN/glab" <<'STUB'
#!/bin/sh
F="$GLW_FIX"
LOG="$GLW_LOG"
host=""
path=""
method=GET
prev=""
for a in "$@"; do
  [ "$prev" = "--hostname" ] && host="$a"
  case "$a" in projects/*) path="$a" ;; esac
  prev="$a"
done
case " $* " in
  *" -X POST "* | *" --method POST "*) method=POST ;;
esac
echo "$method $path" >> "$LOG"
if [ "$host" != "gitlab.example.com" ]; then
  echo "BAD-HOST $host" >> "$LOG"
  echo "stub: unexpected hostname '$host'" >&2
  exit 1
fi

# 取 sequence 的第一行；只剩最後一行時不再消耗
next_line() {
  line=$(head -n 1 "$1")
  n=$(wc -l < "$1" | tr -d ' ')
  if [ "$n" -gt 1 ]; then
    tail -n +2 "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  fi
  printf '%s\n' "$line"
}

# 依目前的 retry 次數取 fixture：$F/<prefix><R>，缺的話往前找
pick() {
  i=$(cat "$F/retries" 2>/dev/null || echo 0)
  while [ "$i" -gt 0 ] && [ ! -f "$F/$1$i" ]; do i=$((i - 1)); done
  cat "$F/$1$i"
}

case "$method $path" in
  "GET projects/:fullpath")
    cat "$F/project" ;;
  "GET projects/42/pipelines/"*"/jobs"*"include_retried"*)
    pick all-R ;;
  "GET projects/42/pipelines/"*"/jobs"*)
    pick failed-R ;;
  "GET projects/42/jobs/"*"/trace")
    jid=$(printf '%s' "$path" | sed -E 's#.*/jobs/([0-9]+)/trace$#\1#')
    if [ -f "$F/trace-$jid" ]; then
      cat "$F/trace-$jid"
    else
      echo "MISSING-TRACE $jid" >> "$LOG"
      exit 1
    fi ;;
  "POST projects/42/jobs/"*"/retry")
    jid=$(printf '%s' "$path" | sed -E 's#.*/jobs/([0-9]+)/retry$#\1#')
    r=$(cat "$F/retries" 2>/dev/null || echo 0)
    echo $((r + 1)) > "$F/retries"
    name=$(grep -h -o "\"id\":$jid,\"name\":\"[^\"]*\"" "$F"/all-R* 2>/dev/null | head -n 1 | sed 's/.*"name":"//; s/"$//')
    printf '{"id":%s,"name":"%s","status":"pending"}\n' "$((jid + 1000))" "$name" ;;
  "GET projects/42/pipelines/"*)
    pid=${path##*/}
    if [ -f "$F/pipeline.seq" ]; then st=$(next_line "$F/pipeline.seq"); else st=running; fi
    printf '{"id":%s,"status":"%s","web_url":"https://gitlab.example.com/grp/proj/-/pipelines/%s"}\n' "$pid" "$st" "$pid" ;;
  "GET projects/42/merge_requests/"*)
    next_line "$F/mr.seq" ;;
  *)
    echo "UNKNOWN $method $path" >> "$LOG"
    echo "stub: unexpected $method $path" >&2
    exit 1 ;;
esac
STUB
chmod +x "$BIN/glab"

# --- 版本庫：origin 指向假的 GitLab ----------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://gitlab.example.com/grp/proj.git

# --- 連線失敗的 trace 行（取自真實案例的結尾） ----------------------------
CONN="fatal: unable to access 'https://gitlab.hq.example.com/grp/ui.git/': Failed to connect to gitlab.hq.example.com port 443 after 129729 ms: Could not connect to server"
GEN="npm ERR! Test failed. See above for more details."

# --- fixture 產生器 --------------------------------------------------------

jobj() { # jobj <id> <name> <status> <allow_failure> <failure_reason>
  printf '{"id":%s,"name":"%s","status":"%s","allow_failure":%s,"failure_reason":"%s","web_url":"https://gitlab.example.com/grp/proj/-/jobs/%s"}' \
    "$1" "$2" "$3" "$4" "$5" "$1"
}

arr() { # arr <obj>... -> 輸出 JSON 陣列
  local out="[" sep="" o
  for o in "$@"; do out="$out$sep$o"; sep=","; done
  printf '%s]\n' "$out"
}

mrj() { # mrj <state> <head_pipeline_status>
  local sha="null"
  [ "$1" = "merged" ] && sha='"0123456789abcdef0123456789abcdef01234567"'
  printf '{"iid":112,"state":"%s","merge_commit_sha":%s,"head_pipeline":{"id":9001,"status":"%s","web_url":"https://gitlab.example.com/grp/proj/-/pipelines/9001"}}' \
    "$1" "$sha" "$2"
}

CASE_N=0
FIX=""
LOG=""
new_case() { # new_case <標題>：每個情境獨立的 fixture 目錄與 log
  CASE_N=$((CASE_N + 1))
  FIX="$TMP/fix$CASE_N"
  mkdir -p "$FIX"
  LOG="$FIX/calls.log"
  : > "$LOG"
  printf '{"id":42,"path_with_namespace":"grp/proj"}\n' > "$FIX/project"
  echo "── $1"
}

seq_set() { # seq_set <檔名> <行>...
  local f="$1"; shift
  printf '%s\n' "$@" > "$FIX/$f"
}

put_failed() { # put_failed <R> <job>...  （failed 清單，R = 目前的 retry 次數）
  local r="$1"; shift
  arr "$@" > "$FIX/failed-R$r"
}

put_all() { # put_all <R> <job>...  （include_retried 清單）
  local r="$1"; shift
  arr "$@" > "$FIX/all-R$r"
}

put_trace() { # put_trace <jid> <行>...
  local jid="$1"; shift
  printf '%s\n' "$@" > "$FIX/trace-$jid"
}

# --- 執行器與斷言 ----------------------------------------------------------

OUT=""
RC=0
run_pipe() { # run_pipe <參數>...  （wait-pipeline；結果放 OUT / RC）
  OUT=$(cd "$REPO" && env PATH="$BIN:$PATH" GLW_FIX="$FIX" GLW_LOG="$LOG" sh "$PIPE" "$@" 2>&1)
  RC=$?
}

run_mr() { # run_mr <參數>...  （wait-mr-merged）
  OUT=$(cd "$REPO" && env PATH="$BIN:$PATH" GLW_FIX="$FIX" GLW_LOG="$LOG" sh "$MRW" "$@" 2>&1)
  RC=$?
}

pass=0
fail=0
ok() { echo "  ✅ $1"; pass=$((pass + 1)); }
ng() { echo "  ❌ $1 — $2"; fail=$((fail + 1)); }

check() { # check <標籤> <needle> <haystack>：應含
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) ng "$1" "預期含 '$2'，實得: $3" ;;
  esac
}

check_not() { # check_not <標籤> <needle> <haystack>：不應含
  case "$3" in
    *"$2"*) ng "$1" "不應含 '$2'，實得: $3" ;;
    *) ok "$1" ;;
  esac
}

check_eq() { # check_eq <標籤> <預期> <實得>
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "預期 '$2'，實得 '$3'"; fi
}

post_count() { grep -c '^POST ' "$LOG"; }
post_lines() { grep '^POST ' "$LOG"; }
log_txt() { cat "$LOG"; }

# ==========================================================================

new_case "1. 連線失敗 → retry 一次，之後 success"
seq_set pipeline.seq failed running success
put_failed 0 "$(jobj 101 build failed false script_failure)"
put_all 0 "$(jobj 101 build failed false script_failure)"
put_trace 101 "$CONN"
run_pipe id 9001 1 5
check_eq "exit 0" 0 "$RC"
check "印出 retry 行" "retry: job=101 name=build attempt=1/2" "$OUT"
check "最後 success" "success: pipeline=9001" "$OUT"
check "輸出含 retried:" "retried:" "$OUT"
check_eq "只 POST 一次" 1 "$(post_count)"
check_eq "POST 目標為 job 101" "POST projects/42/jobs/101/retry" "$(post_lines)"

new_case "2. 同名 job 已 retry 2 次（3 筆）又連線失敗 → 不 retry"
seq_set pipeline.seq failed
put_failed 0 "$(jobj 103 build failed false script_failure)"
put_all 0 "$(jobj 101 build failed false script_failure)" \
          "$(jobj 102 build failed false script_failure)" \
          "$(jobj 103 build failed false script_failure)"
put_trace 103 "$CONN"
run_pipe id 9001 1 5
check_eq "exit 1" 1 "$RC"
check "輸出含 failed: pipeline=" "failed: pipeline=9001" "$OUT"
check_not "沒有 retry 行" "retry:" "$OUT"
check_eq "不 POST" 0 "$(post_count)"

new_case "3. 連續失敗：retry 兩次後第三次仍連線失敗 → exit 1，共恰好 2 次 POST"
seq_set pipeline.seq failed running failed running failed
put_failed 0 "$(jobj 101 build failed false script_failure)"
put_all 0 "$(jobj 101 build failed false script_failure)"
put_trace 101 "$CONN"
put_failed 1 "$(jobj 1101 build failed false script_failure)"
put_all 1 "$(jobj 101 build failed false script_failure)" \
          "$(jobj 1101 build failed false script_failure)"
put_trace 1101 "$CONN"
put_failed 2 "$(jobj 2101 build failed false script_failure)"
put_all 2 "$(jobj 101 build failed false script_failure)" \
          "$(jobj 1101 build failed false script_failure)" \
          "$(jobj 2101 build failed false script_failure)"
put_trace 2101 "$CONN"
run_pipe id 9001 1 10
check_eq "exit 1" 1 "$RC"
check "第一次 retry 行" "retry: job=101 name=build attempt=1/2" "$OUT"
check "第二次 retry 行（attempt=2/2）" "retry: job=1101 name=build attempt=2/2" "$OUT"
check "最後 failed" "failed: pipeline=9001" "$OUT"
check_eq "總共恰好 2 次 POST" 2 "$(post_count)"

new_case "4. 一般測試失敗（npm ERR! Test failed）→ 不 retry"
seq_set pipeline.seq failed
put_failed 0 "$(jobj 201 unit failed false script_failure)"
put_all 0 "$(jobj 201 unit failed false script_failure)"
put_trace 201 "$GEN"
run_pipe id 9001 1 5
check_eq "exit 1" 1 "$RC"
check "輸出含 failed: pipeline=" "failed: pipeline=9001" "$OUT"
check_eq "不 POST" 0 "$(post_count)"

new_case "5. 兩個失敗 job：一個連線錯誤、一個一般失敗 → 都不 retry"
seq_set pipeline.seq failed
put_failed 0 "$(jobj 301 build failed false script_failure)" \
             "$(jobj 302 unit failed false script_failure)"
put_all 0 "$(jobj 301 build failed false script_failure)" \
          "$(jobj 302 unit failed false script_failure)"
put_trace 301 "$CONN"
put_trace 302 "$GEN"
run_pipe id 9001 1 5
check_eq "exit 1" 1 "$RC"
check_not "沒有 retry 行" "retry:" "$OUT"
check_eq "不 POST" 0 "$(post_count)"

new_case "6. allow_failure:true 的一般失敗不阻擋另一個連線失敗 job 的 retry"
seq_set pipeline.seq failed running success
put_failed 0 "$(jobj 401 lint failed true script_failure)" \
             "$(jobj 402 build failed false script_failure)"
put_all 0 "$(jobj 401 lint failed true script_failure)" \
          "$(jobj 402 build failed false script_failure)"
put_trace 401 "$GEN"
put_trace 402 "$CONN"
run_pipe id 9001 1 5
check_eq "exit 0" 0 "$RC"
check "retry job 402" "retry: job=402 name=build attempt=1/2" "$OUT"
check_eq "只 POST job 402" "POST projects/42/jobs/402/retry" "$(post_lines)"
check_eq "POST 次數 1" 1 "$(post_count)"

new_case "7. failure_reason=runner_system_failure（trace 無特徵）→ retry"
seq_set pipeline.seq failed running success
put_failed 0 "$(jobj 501 build failed false runner_system_failure)"
put_all 0 "$(jobj 501 build failed false runner_system_failure)"
put_trace 501 "Running with gitlab-runner 17.0.0" \
              "ERROR: Job failed (system failure): container create failed"
run_pipe id 9001 1 5
check_eq "exit 0" 0 "$RC"
check "retry job 501" "retry: job=501 name=build attempt=1/2" "$OUT"
check_eq "POST 次數 1" 1 "$(post_count)"

new_case "8. --no-retry：failed 直接 exit 1，log 不含 jobs／trace／retry"
seq_set pipeline.seq failed
put_failed 0 "$(jobj 601 build failed false script_failure)"
put_all 0 "$(jobj 601 build failed false script_failure)"
put_trace 601 "$CONN"
run_pipe --no-retry id 9001 1 5
check_eq "exit 1" 1 "$RC"
check "輸出含 failed: pipeline=" "failed: pipeline=9001" "$OUT"
check_not "未呼叫 jobs" "/jobs" "$(log_txt)"
check_not "未呼叫 trace" "/trace" "$(log_txt)"
check_not "未呼叫 retry" "retry" "$(log_txt)"
check_eq "POST 次數 0" 0 "$(post_count)"

new_case "9. canceled → exit 1，不 retry"
seq_set pipeline.seq canceled
put_failed 0 "$(jobj 701 build failed false script_failure)"
put_all 0 "$(jobj 701 build failed false script_failure)"
put_trace 701 "$CONN"
run_pipe id 9001 1 5
check_eq "exit 1" 1 "$RC"
check "輸出含 canceled: pipeline=" "canceled: pipeline=9001" "$OUT"
check_eq "不 POST" 0 "$(post_count)"

new_case "10. wait-mr-merged：head_pipeline 連線失敗 → retry，之後 merged → exit 0"
seq_set mr.seq "$(mrj opened failed)" "$(mrj opened running)" "$(mrj merged success)"
put_failed 0 "$(jobj 801 build failed false script_failure)"
put_all 0 "$(jobj 801 build failed false script_failure)"
put_trace 801 "$CONN"
run_mr 112 1 10
check_eq "exit 0" 0 "$RC"
check "retry 行" "retry: job=801 name=build attempt=1/2" "$OUT"
check "輸出含 merged: iid=112" "merged: iid=112" "$OUT"
check_eq "POST 次數 1" 1 "$(post_count)"

new_case "11. wait-mr-merged：head_pipeline 一般失敗 → exit 4，不 retry"
seq_set mr.seq "$(mrj opened failed)"
put_failed 0 "$(jobj 901 unit failed false script_failure)"
put_all 0 "$(jobj 901 unit failed false script_failure)"
put_trace 901 "$GEN"
run_mr 112 1 5
check_eq "exit 4" 4 "$RC"
check "輸出含 pipeline failed:" "pipeline failed:" "$OUT"
check_eq "不 POST" 0 "$(post_count)"

new_case "12. wait-mr-merged --no-retry：不呼叫 jobs／retry，MR 仍 opened → 逾時 exit 3"
seq_set mr.seq "$(mrj opened failed)"
put_failed 0 "$(jobj 1001 build failed false script_failure)"
put_all 0 "$(jobj 1001 build failed false script_failure)"
put_trace 1001 "$CONN"
run_mr --no-retry 112 1 3
check_eq "exit 3" 3 "$RC"
check "輸出含 TIMEOUT" "TIMEOUT" "$OUT"
check_not "未呼叫 jobs" "/jobs" "$(log_txt)"
check_not "未呼叫 retry" "retry" "$(log_txt)"
check_eq "POST 次數 0" 0 "$(post_count)"

new_case "13. 參數錯誤 → exit 2"
run_pipe --no-retry
check_eq "wait-pipeline：--no-retry 後缺參數 → exit 2" 2 "$RC"
run_pipe id
check_eq "wait-pipeline：缺 value → exit 2" 2 "$RC"
run_pipe id 9001 abc
check_eq "wait-pipeline：interval 非數字 → exit 2" 2 "$RC"
run_mr
check_eq "wait-mr-merged：缺 iid → exit 2" 2 "$RC"
run_mr abc
check_eq "wait-mr-merged：iid 非數字 → exit 2" 2 "$RC"
run_mr --no-retry
check_eq "wait-mr-merged：--no-retry 後缺 iid → exit 2" 2 "$RC"

new_case "15. trace 的連線錯誤不在最後 200 行 → 不 retry"
seq_set pipeline.seq failed
put_failed 0 "$(jobj 1101 build failed false script_failure)"
put_all 0 "$(jobj 1101 build failed false script_failure)"
{
  echo "$CONN"
  i=0
  while [ "$i" -lt 205 ]; do echo "noise line $i"; i=$((i + 1)); done
} > "$FIX/trace-1101"
run_pipe id 9001 1 5
check_eq "exit 1" 1 "$RC"
check_eq "不 POST" 0 "$(post_count)"

new_case "16. 比對不分大小寫（全大寫的連線錯誤）→ retry"
seq_set pipeline.seq failed running success
put_failed 0 "$(jobj 1201 build failed false script_failure)"
put_all 0 "$(jobj 1201 build failed false script_failure)"
put_trace 1201 "FATAL: UNABLE TO ACCESS 'HTTPS://GITLAB.HQ.EXAMPLE.COM/GRP/UI.GIT/'" \
               "COULD NOT CONNECT TO SERVER"
run_pipe id 9001 1 5
check_eq "exit 0" 0 "$RC"
check "retry job 1201" "retry: job=1201 name=build attempt=1/2" "$OUT"
check_eq "POST 次數 1" 1 "$(post_count)"

new_case "17. 找不到 jq → 不 retry，exit 1"
seq_set pipeline.seq failed
put_failed 0 "$(jobj 1301 build failed false script_failure)"
put_all 0 "$(jobj 1301 build failed false script_failure)"
put_trace 1301 "$CONN"
NOJQ="$TMP/bin-nojq"
mkdir -p "$NOJQ"
for t in git sed grep cut head tail wc tr cat mv sleep printf awk dirname; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$NOJQ/$t"
done
ln -sf "$BIN/glab" "$NOJQ/glab"
OUT=$(cd "$REPO" && env PATH="$NOJQ" GLW_FIX="$FIX" GLW_LOG="$LOG" /bin/sh "$PIPE" id 9001 1 5 2>&1)
RC=$?
check_eq "exit 1" 1 "$RC"
check "輸出含 failed: pipeline=" "failed: pipeline=9001" "$OUT"
check_eq "不 POST" 0 "$(post_count)"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
