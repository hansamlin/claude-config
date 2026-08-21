---
name: context-usage
description: |
  查詢「當前 session 的 context 已經用掉多少 token、佔 context window 的百分之幾」。
  模型看不到自己的 statusline，也無法直接內省 context 用量——一律跑本 skill 的腳本取得。
  當使用者問「現在用了多少 context」、「context 還剩多少」、「上下文用了多少」、「快滿了嗎」、
  「要不要先 compact／handoff」、「還能塞多少」、「context 使用率」、「幾 % 了」時使用。
  Also triggers for: "how much context", "context left", "context usage", "token usage",
  "context window", "am I running out of context", "should I compact".
  ⛔ 不要拿 system prompt 裡的 `<total_tokens>` 回答——那是剩餘 token 預算，不是 context 用量。
---

# Context 用量查詢

## 怎麼用

```bash
context-usage
```

Claude Code 會把 plugin 的 `bin/` 加進 `PATH`，所以裝好之後直接打指令名即可，**不要寫死絕對路徑**
（plugin 實際位置含版號，會隨更新改變）。

`--json` 給機器讀；`--selftest` 驗證路徑推導規則沒隨 Claude Code 版本漂掉。

若 `command -v context-usage` 找不到（plugin 剛裝好、這個 session 的 `PATH` 還是舊的；
或是這份 skill 被手動放進 `~/.claude/skills/` 而非以 plugin 安裝），用這行定位：

```bash
find ~/.claude/plugins/cache ~/.claude/skills -name context-usage.sh 2>/dev/null | tail -1
```

（用 `find` 不用 glob：`ls ~/.claude/plugins/cache/*/…` 在 zsh 下沒配到就直接
`no matches found` 整行失敗，`2>/dev/null` 也擋不住。）

若是前者（plugin 已裝但指令名還沒生效），開新 session 就會有。

### 輸出怎麼讀

想要的樣子：

```
Context: 139,896 / 1,000,000 tokens (14.0%)  ·  剩餘 860,104
來源: statusline 快取（7 秒前）· Opus 5 (1M context)
```

看到這樣代表**只裝了一半**（statusline 那步沒做，見下面步驟 2）：

```
Context: 128,431 tokens（window 大小未知，算不出百分比）
來源: transcript usage ⚠️ 落後一輪，且不含本輪新增
```

---

## 安裝（兩步都要做）

### 步驟 1 — 裝 plugin

```
/plugin marketplace add hansamlin/claude-config
/plugin install context-usage@sam-tools
```

**只做步驟 1 的話永遠算不出百分比。** 原因：context window 大小**只**出現在 Claude Code 餵給
statusline hook 的 payload 裡——transcript JSONL 沒記，`~/.claude/usage-status.json` 是別的
session 留下的殘骸不可信，CLI 也沒有子指令吐它。沒有分母就沒有百分比，這是硬限制。

（同一件事在 `context-handoff` 的 `check.sh` 檔頭也有記載：hook 的 stdin payload 不含任何
context/token 欄位，只有 statusline 拿得到 `.context_window`。）

### 步驟 2 — 讓 statusline 落檔

**本 repo 的使用者**：跑 `./install.sh` 即可，`statusline.sh` 已內含這段。

**其他人**：先確認 `~/.claude/settings.json` 有設 `statusLine`（沒設就沒有 hook 會被呼叫），
然後在自己的 `statusline.sh` **讀完 stdin 之後**（即 `input=$(cat)` 那行下面）貼上：

```bash
# --- context-usage skill cache ---
{
    # `:` 後面容許空白 —— payload 是否 pretty-print 不保證，兩種都要吃
    _cu_n() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"; }
    _cu_sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _cu_mdl=$(printf '%s' "$input" | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*{[^}]*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _cu_ti=$(_cu_n total_input_tokens); _cu_to=$(_cu_n total_output_tokens)
    _cu_ws=$(_cu_n context_window_size)
    if [ -n "$_cu_sid" ] && [ -n "$_cu_ws" ]; then
        mkdir -p "$HOME/.claude/context-usage"
        printf '{"session_id":"%s","model":{"display_name":"%s"},"context_window":{"total_input_tokens":%s,"total_output_tokens":%s,"context_window_size":%s}}\n' \
            "$_cu_sid" "$_cu_mdl" "${_cu_ti:-0}" "${_cu_to:-0}" "$_cu_ws" \
            > "$HOME/.claude/context-usage/${_cu_sid}.json" 2>/dev/null
    fi
} 2>/dev/null || true
# ---------------------------------
```

刻意**不用 jq**，純加寫，整段包在 `|| true` 裡——失敗也不會影響原本的 statusline 顯示。

驗收：跑 `context-usage`，「來源」那行要顯示 `statusline 快取`。

---

## 依賴

| 路徑 | 需要什麼 | 給得出百分比？ |
|---|---|---|
| statusline 快取（主） | `sh` + `sed` + `awk`，**零外部依賴** | ✅ |
| transcript 回退 | `jq` **或** `python3` | ❌ 沒有分母 |

回退路徑刻意不自己刻 JSON parser：transcript 單行可達數 MB，且 `usage` 內的 `iterations`
陣列有同名欄位，手刻文字比對很容易抓錯。兩個都沒有時腳本會明講「裝 statusline 快取即可完全免依賴」。

⚠️ 跨平台注意：macOS 15+ 內建 `/usr/bin/jq`（`jq-1.7.1-apple`）但 Linux 通常沒有；
`python3` 則反過來（Linux 幾乎必有，macOS 的 `/usr/bin/python3` 是 CLT stub）。
**兩邊都保證存在的只有 `sed`／`awk`** ——所以主路徑只用它們。

⚠️ **實測範圍：macOS 已驗，Linux 未驗。** 腳本雖然只用 POSIX 語法，但這幾處在 GNU coreutils 上
未經測試：`stat -f %m`→`stat -c %Y` 的回退（GNU 的 `-f` 是 `--file-system`，會先報錯再回退）、
`find -mtime`、`ls -t` 的 glob 展開、BSD vs GNU awk 的 `commify`、sed 的 `[[:space:]]`。
在 Linux 上第一次跑先執行 `context-usage --selftest`。

---

## ⛔ 判讀陷阱

**別拿這四個混為一談：**

| 來源 | 實際是什麼 | 能當 context 用量嗎 |
|---|---|---|
| `context-usage` 指令 | context window 已用量 | ✅ 就是要的東西 |
| system prompt 的 `<total_tokens>` | 剩餘 **token 預算**（可達數百萬） | ❌ 跟 context window 無關，**最常被誤用** |
| `/context` 指令 | 分類明細（system prompt／工具／memory／訊息各佔多少） | ✅ 但要使用者手動打，輸出才進 context |
| Workflow 的 `budget.spent()` | 該回合 **output** token 花費 | ❌ 只算 output |

**auto-compact 之後數字會斷崖式下掉 —— 那是正確的，不是讀錯。**

---

## 已知限制

- **落後一輪**（走 transcript 時）：誤差約等於最後一則訊息的大小。快取模式沒這問題。
- **快取過期**：超過 15 分鐘的快取視為上個 session 的殘骸，直接不採信，自動退回 transcript。
  秒數可用 `CC_CONTEXT_USAGE_MAX_AGE` 覆寫（設 0 ＝一律不採信快取；非數字退回 900）。
  這與「7 天以上的快取檔會被 prune 刪掉」是兩條獨立機制。
- **平行 session**：`$CLAUDE_CODE_SESSION_ID` 存在時精準命中。若該變數缺席，改用「cwd slug 目錄下
  最新 mtime 的 `.jsonl`」——同專案同時開多個 session 時**會挑錯**。輸出最後一行的 `Session:`
  會標明走了哪條路徑，數字可疑時先看它。
- **Sub agent**：subagent 內跑本 skill 時 `$CLAUDE_CODE_SESSION_ID` 通常指向母 session，
  拿到的是**母 session 的 context**。（腳本已濾掉 transcript 裡的 `isSidechain` 訊息。）
- 目錄名推導規則是「非 `[A-Za-z0-9-]` 一律換成 `-`」（`sam_lin`→`sam-lin`、`/.claude`→`--claude`、
  `tmp.X`→`tmp-X`）。若 Claude Code 改了規則，`--selftest` 會紅。它的兩條斷言都掛在檔案系統上、
  且**與當下 cwd 無關**：(1) 每個既存 project 目錄名都必須是規則的固定點；(2) 拿一份真 transcript，
  它內部記的 `cwd` 過一次規則必須等於它所在的目錄名（round-trip）。不是拿寫死字串比自己算出來的字串。

## 相關

- context 逼近上限時的下一步是 `/context`（看是誰吃掉的）或 `handoff` skill（存進度再 `/clear`）。
- `context-handoff` plugin 會在用量達門檻時自動提醒／強制交接；本 skill 是**按需查詢**，
  兩者各自獨立讀取用量，互不影響。
