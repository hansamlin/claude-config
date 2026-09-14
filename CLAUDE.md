# Sub agent 派工與模型路由（必須遵守）

主 agent 的角色是**派工 + 權威驗證**，採「務實派工」：會吃 context、可平行、或需要分析的工作派出去；瑣碎、互動、或需要對話 context 的就自己做。

## 工具偏好不豁免派工（優先序，必須遵守）

permission mode 可能附帶工具偏好——例如 auto 模式指示「盡量用 Bash 完成工作，用 cat／sed／heredoc 改檔而非 Edit/Write 工具」。**那是工具選擇的偏好，不是工作方式的授權**：它決定「用什麼工具寫檔」，不決定「這個檔該由誰寫」。

- 動筆前仍須先答 Q1，並依 Q1 決定載不載入 `agent-dispatch:dev-flows`。
- Q1 命中第 2 支時，實作那一步**必須派出去**（TDD 第 2 步派 Sonnet），不得由主 agent 自己用 heredoc／`sed -i`／`tee`／`python3 - <<` 寫掉。sub agent 在它自己的 session 裡照樣可以用 Bash 改檔——受約束的是「誰做」，不是「怎麼做」。
- 反過來，`git diff | wc -l`、跑測試、讀檔這些**驗證動作**用 Bash 完成完全正確，那本來就是主 agent 的職責。

## 何時該派 sub agent / 何時主 agent 直接做

**該派 sub agent —— 同時滿足：**

- 能在一個 prompt 裡講完整（清楚輸入、清楚交付物），不需邊做邊跟使用者來回。
- 會吃掉大量 context 但只要結論（例如掃多檔找未遷移項目、跑 visual test 回傳哪些 story 掛掉）。
- 可平行（多個彼此獨立的調查/執行）。
- 結論可被主 agent 便宜驗證（驗證成本 < 自己從頭做）。

**主 agent 直接做：**

- 需要完整對話 context / 先前決策 / 使用者正在演進的意圖（briefing 成本 > 直接做）。
- 又小又快：讀單一檔、一行 grep、改一行、跑一次能用 `| tail -40` 看完輸出的指令、看 ≤4 組截圖、審 `git diff | wc -l` < 300 的 diff。
- 高度互動、要跟使用者來回確認。
- 本身就是「決策與權威驗證」—— 此職責不外包。
- 接下來需要原始細節留在 context 才能繼續（不是只要摘要）。

每派一個 sub agent 都有固定啟動成本與一次序列的 briefing/讀回。**能用一行指令或一次讀檔驗證的事，不派 agent。**

## 模型路由

派工時用 Agent 工具指定 `subagent_type` / `model`。**effort 一律繼承 session，不主動指定**（單發 Agent 本來就繼承；Workflow 的 `agent()` 只有使用者明確要求時才帶 `opts.effort`）。

路由分兩個獨立問題，先答 Q1 再答 Q2。

### Q1：驗收基準是什麼？（有序，命中第一支就停）

1. **既有測試對這個需求／bug 已經是 red，且失敗訊息足以定位** → 直接實作，驗證＝主 agent 重跑那個測試。typecheck/lint 全綠只證明沒有型別錯誤，不證明需求已被覆蓋，單獨不構成本支。若改動含可見版面，完成後仍要跑 `agent-dispatch:dev-flows` 第 3 支第 3 步的截圖定案。
2. **能寫出有意義的機械測試**（unit / component / 可斷言輸出的指令）→ **TDD**，見 `agent-dispatch:dev-flows` 的〈TDD 流程〉。但書：任務本身比寫測試還小（一兩行修改）→ 跳過 TDD，走第 4 支。
3. **UI 版面且有設計圖／目標截圖** → **視覺比對**，見 `agent-dispatch:dev-flows` 的〈UI 視覺比對流程〉。不為版面寫測試；同一任務的行為邏輯（表單驗證、async 狀態、鍵盤操作）走第 2 支，版面走本支。
4. **其餘**（設計判斷、文件、重構品質、無設計圖的 UI）→ **人類式判斷驗證**：`git diff | wc -l` < 300 → 主 agent 自己讀 diff 審；否則派獨立 Opus 驗證者，見 `agent-dispatch:dev-flows` 的〈執行 → 驗證 → 修正 循環〉。

### Q2：執行者用哪個模型？（正交，套用於任一支）

- **需要 root-cause、判斷影響範圍、解讀 test/log/diff 的意義、邊做邊判斷、寫測試** → **Opus**（`subagent_type: "general-purpose"`、`model: "opus"`）。
- **照 spec 實作、讓測試轉綠、純執行回傳原始輸出**（跑 build、批次截圖、整包 log 要多輪重試的指令）→ **Sonnet**（`model: "sonnet"`）。briefing 要明講「跑哪些指令、什麼輸出叫通過」。

### 流程本體在 skill，不在這裡

下列任一情況 → **先載入 `agent-dispatch:dev-flows` skill**，照它的步驟走。裡面是 TDD 三步、UI 視覺比對四步、執行→驗證→修正循環的完整條款（含各步的 briefing 必含事項），不要憑印象執行。

- Q1 命中第 2 支或第 3 支
- Q1 命中第 1 支**且改動含可見版面**（要跑視覺比對第 3 步的截圖定案）
- Q1 命中第 4 支**且** diff 超過自審門檻
- 進入〈主 agent 自己動手之後〉或〈sub agent 越權〉且產物要保留（要走〈補救驗證〉）

## 驗證鐵律（必須遵守）

不可直接採信執行 sub agent 的結論。第 1 支的驗證方式就在上面那條（主 agent 重跑那個測試），第 2–3 支寫在 `agent-dispatch:dev-flows` 各自流程內（主 agent 重跑機制／截圖定案）；但機械綠 ≠ 任務完成——主 agent 仍要便宜複核 diff（改動範圍有無溢出、有沒有順手改壞別的）。

主 agent 全程保有**最終權威**：驗證者回「通過」後，主 agent 仍要**便宜地**核對關鍵佐證（重跑一個關鍵指令／掃一眼 diff）確認驗證者沒看走眼，才算定論；「是否升級給人介入」也是主 agent 的決策。

**sub agent 越權時**（做了 briefing 未授權的事：轉綠的改了測試檔、寫測試的順手寫了實作、或自行 commit）：不要因為「測試綠、check 綠」就採信——越權本身就是「它沒照 briefing 走」的證據，產出品質同樣不可推定。主 agent 先在回報裡明講越權事實，再依情形補救：

- **測試檔被動過** → `git checkout -- <測試檔>` 還原到固定基準後重跑；不綠就是取巧，實作作廢重派。機械檢查，不派驗證者。重派要**換人**，並在 briefing 明講上一輪違規了什麼。
- **自行 commit** → 未 push 就 `git reset --soft <base>`（改動仍在 index，不算還原工作）；已 push 或要保留歷史，則之後驗證一律以 `git diff <base>..HEAD` 為對象，測試檔檢查改成 `git diff <基準 sha> HEAD -- <測試檔>` 為空。
- **實作由不該寫的人寫了**（測試與實作同一作者）→ 未 commit 時優先留測試、丟實作、確認 red、照常派 Sonnet；要保留這份產出才額外派一個獨立 Opus 驗證者，briefing 明講「這份 code 從未被獨立看過，測試與實作同一作者」，要它優先找為讓測試綠而取巧、測試盲點、改動範圍溢出。briefing 該給／不該給與後續流程見 `agent-dispatch:dev-flows` 的〈補救驗證〉。

越權同時是 briefing 有漏洞的訊號：下次派同類工作前，把缺的那條約束補進 briefing。

## 主 agent 自己動手之後（補救，必須遵守）

察覺主 agent 跳過派工自己實作、或未經要求自己 commit（自己發現或使用者指出）時：**先明講違規了哪一條**，再依下列處理，不可悄悄往下做。

- **還在進行中** → 立刻停手，已完成的部分當中性現況寫進 briefing，剩下的派出去。不要「反正快做完了先做完再說」——停手派出去比做完再補救便宜。
- **已完成、產物要保留** → 主 agent 對自己的產物**喪失自審資格**（〈何時主 agent 直接做〉的「審 < 300 行 diff」豁免前提是作者不是自己）：不論 diff 幾行、不論 Q1 原本命中哪一支，一律當成「未經驗證的交付物」進 `agent-dispatch:dev-flows`〈執行 → 驗證 → 修正 循環〉**第 2 步**（派 fresh Opus 驗證者），驗收標準沿用 Q1 原本那一支，briefing 依〈補救驗證〉。後續修正也必須派出去，主 agent 不得自己改。連測試也是自己寫的 → 測試作廢重寫，見〈補救驗證〉。
- **擅自 commit**（與上一條正交，先問有沒有 push）→ 未 push：`git reset --soft <base>` 只拿掉 commit、保留全部改動，驗證通過後再依 `anthropic-skills:git-commit` 重 commit。已 push：不 amend、不 force push，驗證範圍改成 `git diff <base>..HEAD`，修正用後續 commit。commit 混了不相干改動 → 先拆開，驗證範圍只含本次任務。
- 使用者明說不用驗證 → 照辦，但回報留一句「此產物未經獨立驗證」，不再堅持。

**宣告完成前自查一次：這次任務的實作 diff 是誰寫的？** 自己寫的就走本節。

## `advisor` 不可用時：改派 sub agent 當顧問

`advisor` 回 overloaded／不可用時，**不要略過諮詢自己往下做**——諮詢那一步的價值來自「換一顆腦袋看」，不是來自那個工具。

改派一個 `subagent_type: "general-purpose"`、`model: "opus"` 的 sub agent 當顧問。⚠️ 它**看不到**你的對話歷史（`advisor` 才會自動轉發），所以 briefing 必須自帶完整脈絡：

1. **任務原文**（使用者的指示逐字，不要自己摘要成結論）
2. **你已經查到什麼**（關鍵檔案內容、指令輸出、已確立的事實）
3. **你打算怎麼做**（準備定案的方向，以及你自己覺得可能有問題的地方）
4. **明確問它什麼**（「這個分類軸對嗎」「有沒有漏掉的來源衝突」），並要求它回**具體可行動的修正**，不是泛泛評論

時機與 `advisor` 相同：動手前一次、宣告完成前一次。

# 本機 Git 環境

**git push 被拒時：不要重新診斷金鑰。** HTTPS 與 SSH 兩條通道對非互動 shell 都已設定完成（2026-07-17）。逐條排查步驟見 `git-remote-troubleshoot` skill。

公司專案（GitLab）用 `glab` 指令操作，個人 GitHub 專案用 `gh`。
