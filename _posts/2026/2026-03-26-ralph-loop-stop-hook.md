---
layout: post
title: "深入解析 Claude Code 的 Ralph Loop Stop Hook"
date: 2026-03-26 10:00:00 +0800
description: 拆解 Ralph Loop Stop Hook 的運作機制 — 讓 AI Agent 自主迭代的關鍵技術
tags: claude-code hooks agent-loop automation bash
featured: true
og_image: /assets/img/blog/2026/ralph-loop/ralph-loop-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/ralph-loop/ralph-loop-overview.png" class="img-fluid rounded z-depth-1" alt="Ralph Loop Stop Hook Architecture" caption="Ralph Loop Stop Hook 運作流程與 State File 結構" %}

> **English Abstract** — The Ralph Loop Stop Hook is a bash-based hook for Claude Code that enables autonomous, iterative AI agent sessions. When Claude finishes a response, the Stop Hook intercepts the session exit, reads the agent's transcript, checks for a completion promise, and — if the task isn't done — re-injects the original prompt to continue the loop. This article dissects the 191-line script: state file architecture (YAML frontmatter + markdown prompt), session isolation to prevent cross-session interference, JSONL transcript parsing, Perl-based `<promise>` tag detection, and atomic state updates. Includes the actual source code with production safety considerations.

Claude Code 的 Hook 機制讓開發者可以在 AI agent 的生命週期中插入自訂邏輯。其中 **Stop Hook** 是最強大的一種 — 它在 Claude 每次完成回應時觸發，可以決定是否**阻止 session 結束並繼續執行**。Ralph Loop 正是利用這個機制，實現了 AI agent 的自主迭代。

---

## 什麼是 Ralph Loop？

Ralph Loop 是一個 **Stop Hook 腳本**，核心功能很簡單：

1. Claude 完成回應 → Stop Hook 觸發
2. 檢查是否有活躍的迴圈（state file 是否存在）
3. 如果任務未完成 → **阻止 session 結束**，重新注入 prompt
4. Claude 讀取自己上一輪的輸出，繼續改進

這創造了一個**自我參照的迭代迴路** — Claude 反覆檢視並改進自己的工作，直到達成完成條件或達到迭代上限。

---

## 運作流程

### 1. Hook 觸發與 State 檢查

Stop Hook 首先讀取 stdin 的 JSON 輸入，然後檢查 state file 是否存在：

```bash
# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Check if ralph-loop is active
RALPH_STATE_FILE=".claude/ralph-loop.local.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  # No active loop - allow exit
  exit 0
fi
```

> **Production Notes** — `exit 0` 代表 hook 正常完成但不阻擋。只有輸出 `{"decision": "block"}` 的 JSON 才能阻止 session 結束。State file 不存在時，hook 是完全透明的。

### 2. YAML Frontmatter 解析

State file 使用 **YAML frontmatter + Markdown body** 的格式，與 Jekyll post 結構一致：

```bash
# Parse markdown frontmatter and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | \
  sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
```

State file 結構如下：

```yaml
---
iteration: 3
max_iterations: 10
completion_promise: "DONE"
session_id: abc123
---
Your prompt text here.
每次迭代都會將這段 prompt 重新注入 Claude。
```

### 3. Session 隔離

State file 是 **project-scoped**（位於 `.claude/` 目錄），但 Stop Hook 會在該 project 下的**所有 Claude Code session 中觸發**。如果另一個 session 開了同一個 project，不應該被這個 loop 阻擋：

```bash
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | \
  sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')

if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0  # Wrong session - don't interfere
fi
```

> **Production Notes** — 沒有 session isolation 的話，在同一個 project 開兩個 terminal 跑 Claude Code，一個 session 的 loop 會阻擋另一個 session 的正常退出。這是實際部署中很容易踩到的坑。

### 4. 迭代上限與數值驗證

在做算術運算前，先驗證欄位是否為合法數字 — 防止 state file 被手動編輯後導致 bash 報錯：

```bash
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "Warning: State file corrupted" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
  rm "$RALPH_STATE_FILE"
  exit 0
fi
```

### 5. Transcript 解析

Claude Code 的 transcript 是 **JSONL 格式**（每行一個 JSON），每個 content block（text / tool_use / thinking）都是獨立的一行。Hook 需要從中提取最後一段 assistant 文字：

```bash
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

# Extract last 100 assistant lines for performance
LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)

# Parse and get the final text block
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
')
```

> **Production Notes** — `tail -n 100` 是效能考量：長時間 session 的 transcript 可能有數千行，全部用 jq slurp 會很慢。100 行足以涵蓋最近的 assistant 回應。

### 6. Completion Promise 偵測

Ralph Loop 使用 `<promise>` tag 作為完成信號。Claude 在輸出中寫入 `<promise>DONE</promise>` 就代表任務已完成：

```bash
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Extract text from <promise> tags using Perl for multiline support
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | \
    perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' \
    2>/dev/null || echo "")

  # Literal string comparison (not glob pattern matching)
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
    rm "$RALPH_STATE_FILE"
    exit 0
  fi
fi
```

> **Production Notes** — 使用 `=` 而非 `==` 做比較是刻意的：`[[ ]]` 中 `==` 會做 **glob pattern matching**，如果 promise 文字包含 `*` 或 `?` 會導致非預期的匹配。`=` 是 literal string comparison，更安全。

### 7. 迴圈繼續

如果 promise 未達成且迭代未到上限，hook 會：

1. 更新 state file 的 iteration 計數（原子操作）
2. 提取 prompt 文字
3. 輸出 JSON 阻止 session 結束

```bash
NEXT_ITERATION=$((ITERATION + 1))

# Atomic state update: temp file + mv
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Extract prompt (everything after the closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

# Output JSON to block the stop and feed prompt back
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "Ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise>" \
  '{ "decision": "block", "reason": $prompt, "systemMessage": $msg }'
```

> **Production Notes** — `mv` 是 POSIX 保證的**原子操作**（在同一檔案系統上）。直接 `sed -i` 在寫入中途若進程被殺，會留下損壞的 state file。temp file + mv 確保 state file 永遠是完整的。

---

## 實際應用場景

**自動化測試修復迴圈：**

```
/ralph-loop "Run the failing tests. Fix the code. Re-run tests.
Repeat until all pass." --max-iterations 5 --completion-promise "ALL TESTS PASS"
```

**文件品質自審迴圈：**

```
/ralph-loop "Review the PR diff. Check for bugs, security issues,
and style violations. If you find issues, fix them and re-review."
--max-iterations 3 --completion-promise "REVIEW COMPLETE"
```

**漸進式重構：**

```
/ralph-loop "Refactor the auth module. Each iteration, improve one aspect:
naming, error handling, or test coverage."
--max-iterations 4 --completion-promise "REFACTOR DONE"
```

---

## 安全機制總結

| 機制 | 用途 | 實作方式 |
|---|---|---|
| `max_iterations` | 防止無限迴圈 | 達到上限時刪除 state file，exit 0 |
| Session Isolation | 防止跨 session 干擾 | 比對 `session_id` |
| 數值驗證 | 防止 state 損壞導致 crash | regex 驗證 + 清理 |
| Atomic Update | 防止 state file 寫入中途損壞 | temp file + `mv` |
| Promise Literal Match | 防止 glob 字元誤匹配 | `=` 取代 `==` |
| Transcript Cap | 防止長 session 效能問題 | `tail -n 100` |

---

## References

- **Claude Code Hooks** — [Official Documentation](https://docs.anthropic.com/en/docs/claude-code/hooks)
- **Ralph Loop Plugin** — [ralph-wiggum on npm](https://www.npmjs.com/package/ralph-wiggum)
- **Stop Hook Deep Dive** — [Claude Code Stop Hook: Force Task Completion](https://claudefa.st/blog/tools/hooks/stop-hook-task-enforcement)
- **Source Script** — [`ralph-loop_stop-hook.sh`](https://github.com/osisdie/osisdie.github.io/blob/main/docs/claude/hook/ralph-loop_stop-hook.sh)

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
