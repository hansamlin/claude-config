---
name: wait-mr-merged
description: 追蹤 GitLab MR 的合併狀態：使用者設了自動合併（pipeline 成功後自動合併），或要等 MR 合併後才能做 worktree 收尾時，在背景執行 wait-mr-merged <iid>，等到合併或關閉再繼續。使用者說「我設定自動合併了」「追蹤 MR」「追蹤合併狀態」「盯著 MR」「等 MR 合併」「MR 合併了沒」「合併了再收尾」「merge when pipeline succeeds」時使用。
---

# 等 MR 合併（追蹤合併狀態）

使用者設了自動合併後，MR 要等 pipeline 跑完才會合併，時間無法預估。**不要自己用 `sleep` 或反覆呼叫 `glab api` 輪詢**（前景 `sleep` 會被擋，反覆查詢浪費 context），也不要把迴圈寫在指令裡（worktree 的 Bash 會拒絕複雜指令）。直接在背景執行腳本，只帶參數。

## 用法

```sh
wait-mr-merged [--no-retry] <iid> [intervalSeconds] [maxSeconds]
```

指令由 plugin 的 `bin/` 加進 `PATH`，直接打指令名，**不要寫死絕對路徑**。若 `command -v wait-mr-merged` 找不到（plugin 剛裝、這個 session 的 `PATH` 還是舊的），用 `find ~/.claude/plugins/cache -name wait-mr-merged.sh | tail -1` 定位後以 `sh <路徑>` 執行。需要 `glab` 已登入，且在 GitLab 專案目錄（或其 worktree）裡執行。

- `iid`：MR 編號（`!112` 就是 `112`）。開 MR 時 API 回傳的 `iid`，或 `glab mr list` 查。
- `intervalSeconds`：查詢間隔，預設 20。
- `maxSeconds`：最長等待，預設 1800。
- `--no-retry`：只能放第一個參數，關閉自動 retry，也不檢查 head pipeline（行為同舊版）。

每輪也會看 MR 的 head pipeline：`failed` 且失敗的 job 都是 runner 連不到 GitLab 這類暫時性錯誤時，自動 retry（同名 job 最多 2 次）並繼續等，判斷規則同 `gitlab-wait:wait-pipeline` 的「自動 retry 暫時性連線失敗」；有真的失敗就以結束碼 4 結束。需要 `jq`，沒有就不看 pipeline。

用 Bash 工具呼叫時帶 `run_in_background: true`（背景執行不受 Bash 的 `timeout` 限制，由腳本自己的 `maxSeconds` 逾時）。腳本結束時會通知你，**不要**輪詢輸出檔、不要 `sleep` 等它。在專案目錄或它的 worktree 裡執行都可以。

## 結束碼與下一步

| 結束碼 | 意思 | 下一步 |
|---|---|---|
| 0 | 已合併，輸出 `merged: iid=… merge_commit=<sha>` | 若專案 AGENTS.md 有「使用者合併後」流程就照做，常見是：確認 `main` 的 pipeline（`gitlab-wait:wait-pipeline` skill，`sha` 帶輸出的 `merge_commit`）、worktree 收尾（先 `git fetch origin` 再 `git merge-base --is-ancestor HEAD origin/main`）、主目錄 `main` 拉最新版 |
| 1 | MR 被關閉但沒合併 | 回報使用者，不收尾、不移除 worktree |
| 2 | 參數錯誤，或啟動時從 git remote 解析不到 GitLab 專案（會印出 glab 的回應） | 補上 `iid`（數字）；解析不到專案就確認在 repo 裡執行、`glab` 登入與網路正常 |
| 3 | 逾時，MR 仍是 `opened` | 不要無限重跑。先查 `glab api "projects/:fullpath/merge_requests/<iid>"` 的 `detailed_merge_status` 與 pipeline 狀態：只是還在跑就再執行一次；pipeline 失敗、有衝突或需要審核就回報使用者 |
| 4 | head pipeline 失敗且不可自動 retry（真的失敗，或 retry 滿 2 次），輸出 `pipeline failed: iid=… pipeline=… url=…`，有 retry 過會多印 `retried:` | 自動合併不會發生：回報使用者並附網址，不收尾、不自行重跑 |

結束碼 0 才代表「已合併」，不要只因為腳本結束就當作已合併。
