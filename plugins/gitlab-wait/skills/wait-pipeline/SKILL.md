---
name: wait-pipeline
description: 追蹤 GitLab pipeline 跑完（追蹤 main pipeline、追蹤 MR pipeline、追蹤指定的 pipeline）：合併後確認 main 的 pipeline 成功，或要等 MR 的 pipeline 跑完、等指定 pipeline 的結果時，在背景執行 wait-pipeline，等到成功或失敗再繼續。使用者說「追蹤 main pipeline」「追蹤 MR pipeline」「追蹤 pipeline」「盯著 pipeline」「等 pipeline 跑完」「main pipeline 好了沒」「確認 main 的 pipeline」「CI 跑完了嗎」時使用。
---

# 等 pipeline 跑完（追蹤 main／MR 的 pipeline）

pipeline 要跑幾分鐘，時間無法預估。**不要自己用 `sleep` 或反覆呼叫 `glab api` 輪詢**（前景 `sleep` 會被擋，反覆查詢浪費 context），也不要把迴圈寫在指令裡（worktree 的 Bash 會拒絕複雜指令）。直接在背景執行腳本，只帶參數。等 MR 本身合併用 `gitlab-wait:wait-mr-merged`。

## 用法

```sh
wait-pipeline <sha|mr|id> <值> [intervalSeconds] [maxSeconds]
```

指令由 plugin 的 `bin/` 加進 `PATH`，直接打指令名，**不要寫死絕對路徑**。若 `command -v wait-pipeline` 找不到（plugin 剛裝、這個 session 的 `PATH` 還是舊的），用 `find ~/.claude/plugins/cache -name wait-pipeline.sh | tail -1` 定位後以 `sh <路徑>` 執行。需要 `glab` 已登入，且在 GitLab 專案目錄（或其 worktree）裡執行。

| 範圍 | 值 | 用在 |
|---|---|---|
| `sha` | 任何 git 能解析的 commit（`88d213f`、`origin/main`、`HEAD`） | **合併後確認 `main`**：帶 `wait-mr-merged` 輸出的 `merge_commit`。解析前先 `git fetch origin`。pipeline 還沒建立時會繼續等，不會誤抓前一個 commit 的結果 |
| `mr` | MR 編號 | 等 MR 最新的 pipeline（合併前想先知道 CI 結果） |
| `id` | pipeline 編號 | 已經知道是哪一條（例如使用者貼了網址） |

- `intervalSeconds`：查詢間隔，預設 20。
- `maxSeconds`：最長等待，預設 540。

用 Bash 工具呼叫時帶 `run_in_background: true` 與 `timeout: 600000`（要比 `maxSeconds` 長，腳本的逾時才會先到）。腳本結束時會通知你，**不要**輪詢輸出檔、不要 `sleep` 等它。找到 pipeline 之後會鎖定它的編號，之後新建的 pipeline 不影響。

## 結束碼與下一步

| 結束碼 | 意思 | 下一步 |
|---|---|---|
| 0 | `success: pipeline=… url=…` | 可以往下做。合併後確認 `main` 時，pipeline 成功才算收尾的第一步完成 |
| 1 | `failed`、`canceled`、`skipped` 或 `manual`（要有人手動觸發 job），輸出狀態與網址 | 回報使用者並附網址，不要當作成功；不要自行重跑 pipeline |
| 2 | 參數錯誤、`sha` 解析不到 commit，或啟動時從 git remote 解析不到 GitLab 專案（會印出 glab 的回應） | 補參數；解析不到 commit 就先 `git fetch origin`；解析不到專案就確認在 repo 裡執行、`glab` 登入與網路正常 |
| 3 | 逾時，輸出 `pipeline=<編號>` 或 `not found` 與目前狀態 | 有編號且是 `running`／`pending` 就再執行一次（可改用 `id <編號>`）；`not found` 持續出現，先確認 commit 對不對、該 ref 有沒有觸發 pipeline，再回報使用者 |

結束碼 0 才代表 pipeline 成功，不要只因為腳本結束就當作成功。
