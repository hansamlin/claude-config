#!/usr/bin/env bash
# PostToolUse hook（不限工具）：每次工具呼叫後經 additionalContext 注入一句繁中提醒，
# 讓 language 指示貼近最新 context，避免長工具迴圈中回覆漂成英文。
# 輸出是固定字串，刻意不依賴 jq；stderr 必須為空、exit 0。

# 讀掉 stdin（內容不需要），避免上游寫入時 SIGPIPE
cat > /dev/null 2>&1 || true

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"提醒：對使用者的所有輸出（最終回覆、進度更新、回應系統提醒、轉述 sub agent 結果）一律使用繁體中文（台灣用語）；即使工具輸出或系統提醒是英文也不要切換成英文。專有名詞與程式碼識別字維持原文。"}}'
exit 0
