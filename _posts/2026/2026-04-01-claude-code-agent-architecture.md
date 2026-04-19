---
layout: post
title: "Claude Code Agent 架構深度拆解：8 個可複用的 Production 設計模式"
date: 2026-04-01 10:00:00 +0800
description: "從 1,902 個 TypeScript 檔案中提煉出 8 個可直接採用的 Agent 架構模式 — Tool Pipeline、Side-Query、Coordinator/Worker、Hook System、Context Compaction"
tags: claude-code agent-swarm architecture automation llm
featured: true
og_image: /assets/img/blog/2026/claude-code-architecture/claude-code-architecture-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/claude-code-architecture/claude-code-architecture-architecture.png" class="img-fluid rounded z-depth-1" alt="Agent Architecture Patterns Overview" caption="從 Claude Code 原始碼提煉的 8 個可複用架構模式" %}

> **English Abstract** — This post dissects the internal architecture of a production agent system, extracting 8 reusable design patterns from 1,902 TypeScript source files: Tool Registration Pipeline, Side-Query for cost-efficient routing, Coordinator/Worker with XML result injection, Hook Event System (16×5×7 combinatorics), and Context Compaction three-layer strategy. Each pattern includes pseudocode and practical adoption guidance.

[昨天的文章]({% post_url 2026-03-31-local-agent-swarm %})從外部比較了主流 Agent Swarm 框架。今天我們換一個角度：**深入一個 production 級 agent 系統的原始碼**，看它是怎麼設計的。

我們分析了 1,902 個 TypeScript 檔案、21 個子系統，提煉出 **8 個可直接複用的設計模式**。不論你用的是 CrewAI、LangGraph 還是自建框架，這些模式都能直接套用。

---

## 架構總覽：21 個子系統

整個系統可以分為 5 大層次：

| 層次 | 子系統 | 職責 |
|------|--------|------|
| **執行層** | Tool System, Skill System | 工具定義、註冊、執行 |
| **協調層** | Agent/Subagent, Coordinator | 多 Agent 分工與結果整合 |
| **安全層** | Permission, Hook System | 權限控制、事件攔截 |
| **記憶層** | State Store, Memory, Context | 狀態管理、上下文壓縮 |
| **擴展層** | Plugin, Command, Output Style | 模組化擴展機制 |

本文深入 5 個最具採用價值的模式（Pattern 1, 3, 4, 6, 8），簡述其餘 3 個。

---

## Pattern 1: Tool Registration Pipeline

**問題**：工具來自多個來源（內建、Plugin、MCP、使用者自訂），需要統一管理並控制可見性。

解法是一個 **四階段 pipeline**，每一步都可以插入邏輯：

```typescript
// Stage 1: Define — 宣告工具的 schema 和能力
const toolDefs: ToolDef[] = [
  { name: "Bash", schema: bashSchema, isDestructive: true },
  { name: "FileRead", schema: readSchema, isReadOnly: true },
  // ... MCP tools, plugin tools, user tools
];

// Stage 2: Build — 實例化工具，注入 context
const tools = toolDefs.map(def => buildTool(def, context));

// Stage 3: Filter — 根據 deny rules 移除不允許的工具
const filtered = tools.filter(t => !denyRules.matches(t.name));

// Stage 4: Assemble — 排序（按名稱，穩定 prompt cache）並組裝
const pool = assembleToolPool(filtered.sort(byName));
```

**關鍵設計決策**：

- **Fail-closed** — 預設拒絕，必須明確允許才能使用
- **按名稱排序** — 工具順序穩定，最大化 prompt cache hit rate
- **Feature gate 注入** — 在 Build 階段根據 feature flag 決定是否包含工具

> **Production Notes** — 如果你正在建 agent 系統，不要把 tool 註冊寫成一個大的 if-else。用 pipeline 模式讓每個階段獨立可測試。特別是 Filter 階段 — 它讓你不用改程式碼就能關閉特定工具。

---

## Pattern 3: Side-Query Pattern

**問題**：每次決策都用主模型太貴。記憶檢索、權限判斷、路由分派這些「輔助判斷」不需要最強的模型。

解法是 **side-query** — 在主對話旁邊開一個輕量的 LLM 查詢：

```typescript
// 記憶檢索：用較小模型挑選相關記憶
async function recallMemories(query: string): Promise<Memory[]> {
  const allMemories = await scanMemoryFiles();    // 掃描所有記憶檔
  const selected = await sideQuery({
    model: "fast",                                 // 用便宜的模型
    prompt: `從以下記憶中選出與 "${query}" 相關的（最多 5 個）`,
    context: allMemories.map(m => m.summary),
  });
  return selected;
}

// 權限分類：2 階段 XML classifier
async function classifyPermission(toolCall: ToolCall): Promise<Decision> {
  const stage1 = await sideQuery({
    model: "fast",
    prompt: `判斷此工具呼叫的安全性：${toolCall.name}(${toolCall.args})`,
  });
  if (stage1 === "soft_deny") {
    return await sideQuery({ model: "fast", prompt: "進一步評估..." });
  }
  return stage1;  // "allow" or "ask"
}
```

**實際應用場景**：

| 用途 | 主模型 | Side-Query | 成本比 | 說明 |
|------|--------|-----------|--------|------|
| 記憶檢索 | Opus | Haiku | ~20:1 | 大量記憶快速篩選 |
| 權限判斷 | Opus | Haiku | ~20:1 | 語意判斷不需推理 |
| 路由分派 | Opus | Sonnet | ~5:1 | 中等複雜度路由 |

> **Production Notes** — Side-query 的 prompt 要精心設計 — 它是整個系統最高頻的 LLM 呼叫。建議固定 prompt 格式以最大化 cache hit，並設定 timeout 防止 side-query 拖慢主對話。

---

## Pattern 4: Coordinator / Worker + XML 結果注入

**問題**：複雜任務需要多個 Agent 並行處理，但共享狀態會帶來競爭問題。

解法是 **Coordinator/Worker 模式** — Coordinator 只負責規劃和整合，Workers 非同步執行：

```text
Coordinator (規劃)
    │
    ├── Worker A (Research)    ──async──→ <task-notification> XML
    ├── Worker B (Implement)   ──async──→ <task-notification> XML
    └── Worker C (Test)        ──async──→ <task-notification> XML
    │
    └── Coordinator (整合所有結果)
```

**四個階段**：

1. **Research** — 搜集資訊、理解需求
2. **Synthesis** — 整合發現、制定方案
3. **Implementation** — 並行執行具體工作
4. **Verification** — 驗證結果、品質檢查

**結果注入機制**：Worker 完成後，結果以 XML 格式注入 Coordinator 的對話：

```xml
<task-notification>
  <task-id>worker-a</task-id>
  <status>completed</status>
  <result>Found 3 relevant APIs: ...</result>
</task-notification>
```

**關鍵設計**：

- Coordinator **不直接使用工具** — 只有 AgentTool、SendMessage、TaskStop
- Workers 在 **獨立 context** 中執行 — 不共享 state，避免競爭
- XML 注入是 **append-only** — 不會修改已有的對話歷史

> **Production Notes** — 這個模式的核心是「不共享狀態」。昨天我們比較的 LangGraph 用 graph state 共享，CrewAI 用 sequential task passing。Coordinator/Worker 則完全解耦 — 代價是 Coordinator 需要更強的整合能力。適合高併發、低耦合的場景。

---

## Pattern 6: Hook Event System

**問題**：系統需要可擴展性，但不希望核心程式碼被修改。

解法是一個 **高度可組合的 Hook 系統**：16 種事件 × 5 種 Hook 類型 × 7 個來源。

### 16 種事件

```text
SessionStart, Setup, UserPromptSubmit,
PreToolUse, PostToolUse, PostToolUseFailure,
PermissionRequest, PermissionDenied,
Stop, FileChanged, WorktreeCreate,
SubagentStart, Notification, Elicitation, CwdChanged
```

### 5 種 Hook 類型

| Hook 類型 | 執行方式 | 適用場景 |
|-----------|---------|---------|
| **Command** | Shell script (exit 0=pass, 2=block) | 快速檢查、git hooks |
| **Prompt** | LLM side-query | 語意判斷、品質檢查 |
| **Agent** | 生成 subagent 驗證 | 複雜驗證邏輯 |
| **HTTP** | Remote callback | 外部審核系統 |
| **Callback** | JS function (runtime) | 內部擴展 |

### HookMatcher 模式匹配

```text
"Bash"              → 攔截所有 Bash 呼叫
"Bash(git *)"       → 只攔截 git 相關指令
"Write(*.env)"      → 攔截寫入 .env 檔案
"Edit(**/*.ts)"     → 攔截編輯 TypeScript 檔案
```

**來源優先序**（高 → 低）：

```text
userSettings > projectSettings > localSettings > policySettings > pluginHook > sessionHook > builtinHook
```

> **Production Notes** — Hook 系統是投資報酬率最高的架構元件。一個 `PreToolUse` command hook 可以實現：程式碼審查（lint before write）、安全檢查（block dangerous commands）、日誌記錄（audit trail）。建議從 command hook 開始，需要語意判斷時再升級到 prompt hook。

---

## Pattern 8: Context Compaction 三層策略

**問題**：長對話耗盡 context window，但簡單截斷會丟失關鍵資訊。

解法是 **三層漸進式壓縮**：

```text
Layer 1: Micro Compact（turn 內壓縮）
  → 觸發：單次回應過長
  → 壓縮：移除冗餘 tool output，保留摘要

Layer 2: Auto Compact（token 閾值觸發）
  → 觸發：total tokens > context_window - 13,000
  → 壓縮：用 LLM 摘要歷史對話，保留近期 turns

Layer 3: Manual Compact（使用者觸發）
  → 觸發：/compact 指令
  → 壓縮：最激進 — 只保留核心 context
```

**停止條件（Diminishing Returns Detection）**：

```typescript
// 連續壓縮 3+ 次，且每次只省 < 500 tokens → 停止
if (continuations >= 3 && tokenDelta < 500) {
  return "compaction_exhausted";
}
```

> **Production Notes** — 這就是我們[上一篇]({% post_url 2026-03-31-local-agent-swarm %})討論 task planner 的原因 — 壓縮會丟失 in-progress 的 task 狀態。解法是把 task 持久化到檔案系統（`.claude/tasks/`），讓它不受 context 壓縮影響。

---

## 其他值得關注的模式

### Pattern 2: Immutable State Store + Change Hooks

單一 immutable store 搭配 reactive change hooks。用 `Object.is` 判斷是否真正變更，避免多餘的 side effect。比 event bus 更可預測 — 每個 state change 都有明確的因果鏈。

### Pattern 5: Permission Rule System

每條權限規則記錄 **來源**（user/project/policy/plugin/builtin），支援優先序和 audit trail。Policy settings 可以覆蓋使用者設定，實現企業級管控。

### Pattern 7: Deferred Loading

當工具數量超過 prompt 容量時，不把所有定義放進 system prompt。標記 `shouldDefer=true` 的工具只在被搜尋時才載入 — 用 `searchHint` 關鍵字做 lazy discovery，節省大量 tokens。

---

## 給 Agent 系統開發者的建議

**優先採用順序**（從投資報酬率排列）：

1. **Hook System** — 最小侵入性，立即獲得可擴展性
2. **Tool Pipeline** — 統一管理工具來源，避免 if-else 地獄
3. **Context Compaction** — 長對話必備，越早做越好
4. **Side-Query** — 成本最佳化的關鍵，production 必須有
5. **Coordinator/Worker** — 需要並行處理時再引入

**最小可行 Agent 架構**：

```text
Tool Pipeline + Hook System + State Store = 可生產的 Agent
加上 Side-Query + Compaction = 可規模化的 Agent
加上 Coordinator/Worker = 可並行的 Agent Swarm
```

---

## 相關連結

- **昨日文章** — [本地 Agent Swarm 框架全解析]({% post_url 2026-03-31-local-agent-swarm %})
- **Agent Architecture Reference** — [本文分析的架構文件來源](/docs/architecture/agent-architecture/)
- **Claude Code** — [Anthropic 官方 Agent Coding Tool](https://docs.anthropic.com/en/docs/claude-code)
- **LangGraph** — [github.com/langchain-ai/langgraph](https://github.com/langchain-ai/langgraph) — 企業級圖工作流引擎
- **CrewAI** — [github.com/crewAIInc/crewAI](https://github.com/crewAIInc/crewAI) — 角色分工框架

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
