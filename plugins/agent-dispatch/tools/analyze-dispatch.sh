#!/bin/bash
# analyze-dispatch.sh <session-uuid> <project-slug>
#
# 從 ~/.claude/projects/<slug>/ 的 transcript 還原「主 agent 有沒有照 CLAUDE.md
# 的 Q1 路由與 agent-dispatch:dev-flows 走」。改完 CLAUDE.md 或 SKILL.md 的條款後，
# 用它跑 n=3 驗證改動是否真的生效——2026-09-01 就是靠它發現 auto 模式的
# 「盡量用 Bash」會吃掉 TDD 第 2 步的派工（0/3），加了優先序聲明後回到 3/3。
#
# ⚠️ 相容性警告：本腳本依賴 transcript .jsonl 的**內部格式**，那是 Claude Code 的
# 實作細節，沒有相容性保證。升級後欄位改名的話它會「安靜地失效」——最糟的情況是
# 回報「沒派工」而你以為是規則壞了。所以每次用之前，先拿一個你確定有派工的
# session 當 sanity check，確認 §3 印得出 sub agent 再信它的判讀。
#
# 已知的坑（都是實測踩出來的，改動時別退化）：
#   - skill 載入要雙路徑偵測：`Skill` tool_use ＋ user 訊息內的 <command-name>
#   - resolvedModel 在 in-process teammate 派工時是空的，必須 fallback 到
#     subagents/*.meta.json，否則「派了工」會被誤判成「沒派工」
#   - Write 建新檔時 structuredPatch 是空陣列，行數要退回數 toolUseResult.content
#   - 抓測試指令要排除 `git ` 開頭，否則 `git add …test.ts` 會誤命中
#   - output style 要讀 attachment.type == "output_style"（Learning 反覆注入、
#     default 完全不產生）；讀 settings 檔會被 --settings 覆寫騙過
#   - auto 模式用 heredoc 改檔，structuredPatch 抓不到 → §5 的 diff 行數會失準
#
# 用法：
#   analyze-dispatch.sh <session-uuid> <project-slug>
#   例：analyze-dispatch.sh 2089c550-08a9-4a8e-9baf-12311798041c -Users-sam-project-tRPC-todos
#   ⚠️ 別用 `ls -t` 挑檔案——同一個專案目錄常有多個 session（背景 session、
#      中途開的空 session），挑錯會誤判。用 tool_call 數最多的那個。
#
# 全部欄位都是實測存在的；沒有就印 none。
set -uo pipefail

UUID="${1:?usage: analyze.sh <session-uuid> <project-slug>}"
SLUG="${2:?usage: analyze.sh <session-uuid> <project-slug>}"
ROOT="$HOME/.claude/projects/$SLUG"
MAIN="$ROOT/$UUID.jsonl"
SUBDIR="$ROOT/$UUID/subagents"

[[ -f "$MAIN" ]] || { echo "no such transcript: $MAIN" >&2; exit 1; }

# 判定測試檔的樣式（可依專案調整）
TESTPAT='\.(test|spec)\.[jt]sx?$|(^|/)(tests?|__tests__)/'

hr() { printf '\n== %s ==\n' "$1"; }

hr "0. 環境（混淆因子）"
# 專案根目錄直接從 transcript 的 cwd 反推，不必額外傳參
PROJ=$(jq -r 'select(.cwd!=null) | .cwd' "$MAIN" 2>/dev/null | head -1)
echo "  cwd: ${PROJ:-none}"

# (3) 從 transcript 反推當時「實際生效」的 output style —— 這是權威來源。
#     實測：Learning style 會持續注入 {"type":"output_style","style":"Learning"} 的 attachment；
#     default style 則完全不產生此 attachment（缺席 == default）。
#     比對 settings 檔更可靠：settings 可被 --settings / --output-style 於啟動時覆寫。
TSTYLE=$(jq -r 'select(.type=="attachment" and .attachment.type=="output_style") | .attachment.style' "$MAIN" 2>/dev/null | sort -u | paste -sd, -)
TN=$(jq -r 'select(.type=="attachment" and .attachment.type=="output_style") | .attachment.style' "$MAIN" 2>/dev/null | wc -l | tr -d ' ')
if [[ -n "$TSTYLE" ]]; then
  echo "  outputStyle (from transcript, AUTHORITATIVE): $TSTYLE   [attachment x$TN]"
else
  echo "  outputStyle (from transcript, AUTHORITATIVE): default   [無 output_style attachment]"
fi

# (1) settings 檔宣告值 —— 僅供對照，可能與實際生效值不符
SSTYLE="none"
if [[ -n "$PROJ" ]]; then
  for f in "$PROJ/.claude/settings.local.json" "$PROJ/.claude/settings.json"; do
    if [[ -f "$f" ]]; then
      v=$(jq -r '.outputStyle // empty' "$f" 2>/dev/null)
      [[ -n "$v" ]] && echo "  outputStyle (declared in $(basename "$f")): $v" && SSTYLE="$v"
    fi
  done
fi
[[ "$SSTYLE" == "none" ]] && echo "  outputStyle (declared in settings): none"
# 不一致 = 啟動時被覆寫，或反之；兩者都要提醒
EFF="${TSTYLE:-default}"
if [[ "$SSTYLE" != "none" && "$SSTYLE" != "$EFF" ]]; then
  echo "  ⚠ MISMATCH: settings 宣告 '$SSTYLE' 但實際生效 '$EFF'（啟動時被 --settings/--output-style 覆寫）"
fi
# 非 default 一律標為污染
[[ "$EFF" != "default" ]] && echo "  ⚠ CONTAMINATED: output style '$EFF' 可能與 dev-flows 互斥（如 Learning 會刻意把實作留給人類），此樣本應作廢"

# (2) 專案記憶檔
if [[ -n "$PROJ" ]]; then
  FOUND=""
  for m in CLAUDE.md AGENTS.md GEMINI.md .claude/CLAUDE.md; do
    [[ -f "$PROJ/$m" ]] && FOUND="$FOUND $m"
  done
  echo "  memory files:${FOUND:- none}"
else
  echo "  memory files: none (無法解析 cwd)"
fi

hr "1. skill 載入偵測 (agent-dispatch:dev-flows)"
# 路徑 A：Skill tool_use
A=$(jq -rc 'select(.type=="assistant") | .message.content[]?
      | select(.type=="tool_use" and .name=="Skill") | .input.skill' "$MAIN" 2>/dev/null \
    | grep -x 'agent-dispatch:dev-flows' | head -1)
# 路徑 B：斜線叫用 → user 訊息內的 <command-name>，或 SKILL.md 內文被內嵌
B=$(jq -rc 'select(.type=="user") | (.message.content|tostring)
      | select(test("<command-name>[^<]*dev-flows|skills/dev-flows"))' "$MAIN" 2>/dev/null | head -1)
[[ -n "$A" ]] && echo "path-A (Skill tool_use): $A" || echo "path-A (Skill tool_use): none"
[[ -n "$B" ]] && echo "path-B (slash / inlined SKILL.md): HIT" || echo "path-B (slash / inlined SKILL.md): none"
{ [[ -n "$A" || -n "$B" ]] && echo "LOADED: yes"; } || echo "LOADED: no"

hr "2. 主 agent 自身 tool call 序列"
jq -rc 'select(.type=="assistant") | .message.content[]?
    | select(.type=="tool_use") | [.name, (.input|tostring|.[0:120])] | @tsv' "$MAIN" \
  | nl -ba | sed 's/^/  /' || echo "  none"

hr "3. 派出的 sub agent (subagent_type / 請求端 model / 實際 model / 來源)"
# 以「請求端的 Agent tool_use」為主鍵，用 tool_use_id 對回 toolUseResult 取 agentId/resolvedModel。
# 注意：in-process teammate（taskKind=in_process_teammate）不產生 resolvedModel，
# 必須 fallback 到 subagents/*.meta.json，否則會被誤判成「沒派工」。
jq -sr '
  (map(select(.type=="assistant") | .message.content[]?
     | select(.type=="tool_use" and .name=="Agent")
     | {id:.id, st:(.input.subagent_type//"none"), req:(.input.model//"none"), nm:(.input.name//"none")}
   )) as $reqs
  | (map(select(.toolUseResult|type=="object") | select(.toolUseResult|has("agentId"))
     | {key:(.message.content[0].tool_use_id//"_"),
        value:{aid:.toolUseResult.agentId, rm:(.toolUseResult.resolvedModel//"")}}
   ) | from_entries) as $res
  | $reqs[]
  | . as $r
  | ($res[$r.id] // {aid:"", rm:""}) as $x
  | [$r.st, $r.req, $r.nm, $x.aid, $x.rm] | @tsv
' "$MAIN" 2>/dev/null > /tmp/.aa_req.$$

if [[ -s /tmp/.aa_req.$$ ]]; then
  while IFS=$'\t' read -r st req nm aid rm; do
    eff=""; src=""
    # 1) toolUseResult.resolvedModel（一般 Agent 派工）
    if [[ -n "$rm" ]]; then
      eff="$rm"; src="resolvedModel"
    # 2) agentId → subagents/agent-<id>.meta.json
    elif [[ -n "$aid" && -f "$SUBDIR/agent-$aid.meta.json" ]]; then
      eff=$(jq -r '.model // empty' "$SUBDIR/agent-$aid.meta.json" 2>/dev/null)
      [[ -n "$eff" ]] && src="meta.json(agentId)"
    fi
    # 3) 具名 teammate：用 name 匹配 meta.json 的 .name
    if [[ -z "$eff" && -n "$nm" && "$nm" != "none" && -d "$SUBDIR" ]]; then
      for m in "$SUBDIR"/*.meta.json; do
        [[ -e "$m" ]] || continue
        if [[ "$(jq -r '.name // empty' "$m" 2>/dev/null)" == "$nm" ]]; then
          eff=$(jq -r '.model // empty' "$m" 2>/dev/null)
          [[ -n "$eff" ]] && src="meta.json(name)" && break
        fi
      done
    fi
    printf '  subagent_type=%-16s req_model=%-8s 實際=%-22s 來源=%-18s name=%s\n' \
      "$st" "$req" "${eff:-UNKNOWN}" "${src:-none}" "${nm:-none}"
  done < /tmp/.aa_req.$$
else
  echo "  none  (主 agent 全程未派任何 sub agent)"
fi

# 未被上面配對到的 meta.json（例如巢狀派工、或主 agent 之外生出的 agent）
if [[ -d "$SUBDIR" ]]; then
  extra=""
  for m in "$SUBDIR"/*.meta.json; do
    [[ -e "$m" ]] || continue
    n=$(jq -r '.name // empty' "$m" 2>/dev/null)
    b=$(basename "$m" .meta.json); mid=${b#agent-}
    seen=0
    [[ -n "$n" ]] && cut -f3 /tmp/.aa_req.$$ 2>/dev/null | grep -qx "$n" && seen=1
    [[ -n "$mid" ]] && cut -f4 /tmp/.aa_req.$$ 2>/dev/null | grep -qx "$mid" && seen=1
    if [[ $seen -eq 0 ]]; then
      extra+="$(jq -rc '"    agentType=\(.agentType)  model=\(.model)  name=\(.name//"none")  taskKind=\(.taskKind)"' "$m" 2>/dev/null)"$'\n'
    fi
  done
  [[ -n "${extra// /}" ]] && { echo "  -- 未配對到請求端的 meta.json --"; printf '%s' "$extra"; }
fi
rm -f /tmp/.aa_req.$$

hr "4. 各 sub agent 內部是否 Edit 過測試檔"
if [[ -d "$SUBDIR" ]]; then
  found=0
  for f in "$SUBDIR"/*.jsonl; do
    [[ -e "$f" ]] || continue
    hits=$(jq -rc 'select(.toolUseResult|type=="object")
        | select(.toolUseResult|has("structuredPatch"))
        | .toolUseResult.filePath' "$f" 2>/dev/null | grep -E "$TESTPAT" | sort -u)
    if [[ -n "$hits" ]]; then found=1; echo "  $(basename "$f"):"; echo "$hits" | sed 's/^/    /'; fi
  done
  [[ $found -eq 0 ]] && echo "  none (沒有 sub agent 動過測試檔)"
else
  echo "  none (無 sub agent 子 transcript)"
fi

hr "5. 實作 diff 行數 (structuredPatch 加總，排除測試檔)"
# 主檔 + 所有子檔一起算
FILES=("$MAIN"); [[ -d "$SUBDIR" ]] && for f in "$SUBDIR"/*.jsonl; do [[ -e "$f" ]] && FILES+=("$f"); done
# 注意：Write 建新檔時 structuredPatch 是空陣列，行數只能從 .content 數 → 需 fallback
jq -rc 'select(.toolUseResult|type=="object")
    | select(.toolUseResult|has("structuredPatch"))
    | ([.toolUseResult.structuredPatch[]?.lines[]? | select(startswith("+") or startswith("-"))] | length) as $p
    | [ .toolUseResult.filePath,
        (if $p > 0 then $p
         else ((.toolUseResult.content // "") | split("\n") | length) end)
      ] | @tsv' "${FILES[@]}" 2>/dev/null \
  | awk -F'\t' -v pat="(\\.(test|spec)\\.[jt]sx?$)|(/(tests?|__tests__)/)" '
      { if ($1 ~ pat) t+=$2; else { i+=$2; impl[$1]+=$2 } }
      END {
        if (i=="" && t=="") { print "  none"; exit }
        for (f in impl) printf "  impl %6d  %s\n", impl[f], f
        printf "  ---\n  IMPL_DIFF_LINES=%d   TEST_DIFF_LINES=%d   (自審門檻 300)\n", i+0, t+0
      }'

hr "6. 最後一次 edit 之後，主 agent 有沒有自己跑測試"
# 先找主檔中最後一筆 structuredPatch 的時間戳
LAST_EDIT=$(jq -rc 'select(.toolUseResult|type=="object")
    | select(.toolUseResult|has("structuredPatch")) | .timestamp' "$MAIN" 2>/dev/null | sort | tail -1)
if [[ -z "$LAST_EDIT" ]]; then
  echo "  none (主 agent 沒有任何 edit)"
else
  echo "  last edit at: $LAST_EDIT"
  OUT=$(jq -rc --arg t "$LAST_EDIT" 'select(.type=="assistant") | select(.timestamp > $t)
      | .message.content[]? | select(.type=="tool_use" and .name=="Bash") | .input.command' "$MAIN" 2>/dev/null \
    | grep -Ev '^\s*git ' | grep -Ei '(^|[;&|] *)(cd .*&& *)?(pnpm|npm|yarn|npx|bun|uv|poetry)? *(run )?(test|vitest|jest|pytest|go test|cargo test)' | sed 's/^/    /')
  [[ -n "$OUT" ]] && { echo "  post-edit test commands:"; echo "$OUT"; } || echo "  none (最後一次 edit 之後沒跑過測試指令)"
fi

echo
