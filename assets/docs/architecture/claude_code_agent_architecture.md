---
layout: page
title: "Agent Architecture Reference"
permalink: /docs/architecture/agent-architecture/
description: "從 1,902 個 TypeScript 檔案中提煉的 Agent 架構參考文件 — 21 個子系統、8 個可複用設計模式"
nav: false
---

# Agent Architecture 摘要

> 原始碼架構參考
> 最後更新：2026-03-31

---

## 目錄

1. [Tool System](#1-tool-system)
2. [Skill System](#2-skill-system)
3. [Agent / Subagent Architecture](#3-agent--subagent-architecture)
4. [Hook System](#4-hook-system)
5. [State Management](#5-state-management)
6. [Context Management](#6-context-management)
7. [Auto Mode / Classifier](#7-auto-mode--classifier)
8. [Plugin System](#8-plugin-system)
9. [Command System](#9-command-system)
10. [Memory System](#10-memory-system)
11. [Scheduler / Cron](#11-scheduler--cron)
12. [Session & History](#12-session--history)
13. [Remote Control & Bridge](#13-remote-control--bridge)
14. [Metrics & Telemetry](#14-metrics--telemetry)
15. [Search & Deferred Tool Loading](#15-search--deferred-tool-loading)
16. [Eval / Classification](#16-eval--classification)
17. [Plan Mode](#17-plan-mode)
18. [Bypass Mode](#18-bypass-mode)
19. [Output Styles](#19-output-styles)
20. [Migration](#20-migration)
21. [Synthesis: 可採用的架構模式](#21-synthesis-可採用的架構模式)

---

## 1. Tool System

> 📁 `Tool.ts`, `tools.ts`, `types/tools.ts`

Tool 是 agent 能力的最小單位。每個 tool 是一個泛型介面 `Tool<Input, Output, Progress>`，透過 Zod schema 做 input 驗證，具備宣告式的安全屬性。

### 1.1 Tool 介面核心屬性

| 屬性 | 用途 |
|---|---|
| `name` / `aliases` | 主要識別名 + 向下相容別名 |
| `inputSchema` | Zod schema，嚴格驗證 input |
| `isConcurrencySafe()` | 是否可平行執行（預設 false — fail-closed） |
| `isReadOnly()` | 是否唯讀（預設 false） |
| `isDestructive()` | 是否具破壞性 |
| `shouldDefer` | 是否延遲載入（透過 ToolSearchTool 發現） |
| `alwaysLoad` | 永不延遲（關鍵 tool 始終可見） |
| `searchHint` | 3-10 字關鍵字供 ToolSearch 匹配 |
| `maxResultSizeChars` | 超過此值的 output 會被持久化到磁碟 |
| `checkPermissions()` | Tool 特定的權限檢查邏輯 |
| `preparePermissionMatcher()` | Hook `if` 條件的模式匹配（如 `"Bash(git *)"`) |

### 1.2 ToolDef Builder Pattern

```
buildTool(def: ToolDef) → BuiltTool
```

`buildTool()` 將 `TOOL_DEFAULTS` 與開發者提供的 `ToolDef` merge。預設值是 fail-closed：`isConcurrencySafe=false`, `isReadOnly=false`, `isDestructive=false`。這確保新 tool 預設受到最嚴格的限制。

### 1.3 Tool 註冊與組裝 Pipeline

```
getAllBaseTools()  →  getTools(permCtx)  →  assembleToolPool()
     ↑                    ↑                      ↑
  所有 base tools      deny rules 過濾       built-in + MCP 合併
  (含 feature gate)   isEnabled() 檢查      按 name 排序 (prompt cache)
```

- **getAllBaseTools()**: Master source — 依 feature flag + `USER_TYPE` 條件載入
- **getTools(permCtx)**: 套用 deny rules，移除被禁用的 tool
- **assembleToolPool()**: 合併 built-in + MCP tools，**按 name 排序**以維持 prompt cache 穩定性
- **getMergedTools()**: 用於 token 計算的 built-in ∪ MCP 集合

### 1.4 Tool 分類

| 類別 | 範例 |
|---|---|
| **Always-available** | Bash, FileRead, FileEdit, FileWrite, WebSearch, Glob, Grep, WebFetch |
| **Deferred** | ToolSearchTool（大型 tool pool 模式） |
| **Feature-gated** | REPLTool (ant-only), SleepTool, CronTools, WebBrowserTool |
| **Execution** | AgentTool, SkillTool |
| **Task Management** | TaskCreate, TaskGet, TaskUpdate, TaskList, TaskStop |
| **Mode Control** | EnterPlanModeTool, ExitPlanModeV2Tool, EnterWorktreeTool |

### 1.5 ToolUseContext — 工具執行上下文

每次 tool 執行時接收的 rich context：

- `options`: commands, tools, debug, model, MCP clients, agentDefinitions
- `abortController`: 取消機制
- `readFileState`: FileStateCache（檔案操作快取）
- `getAppState()` / `setAppState()`: session state 讀寫
- `setAppStateForTasks`: root store 存取（subagent 用）
- `handleElicitation()`: URL elicitation protocol
- `contentReplacementState`: tool result 的 budget 追蹤

### 1.6 Permission Flow（權限流程）

```
validateInput()  →  checkPermissions()  →  PreToolUse hooks  →  UI prompt
     ↑                    ↑                       ↑                 ↑
  語法驗證            權限決策               hook 攔截         互動確認
                  (deny→allow→mode)       (command/prompt/     (僅需要時)
                                          agent/HTTP)
```

- `PermissionRule = { source, behavior('allow'|'deny'|'ask'), ruleValue { toolName, ruleContent } }`
- Deny rules 優先（fail-closed），然後 allow rules，最後 fallback 到 mode 預設值
- Tool 特定的 `preparePermissionMatcher()` 支援模式匹配：`"Bash(git *)"`, `"Write(*.ts)"`

### 1.7 Progress Reporting

```typescript
ToolCallProgress<P>  // P = BashProgress | MCPProgress | SkillToolProgress | ...
```

每種 tool 有自己的 progress 型別，透過 `renderToolUseProgressMessage()` 渲染到 UI。

---

## 2. Skill System

> 📁 `skills/`, `skills/bundledSkills.ts`, `skills/loadSkillsDir.ts`

Skill 是 tool 的 prompt 層包裝 — 將一組 tools + 指導 prompt 組合成可重用的能力單元。Model 透過 SkillTool 呼叫 skill。

### 2.1 BundledSkillDefinition（程式內建）

```typescript
{
  name: string
  description: string
  whenToUse: string          // 描述何時觸發
  argumentHint?: string      // 參數提示
  allowedTools?: string[]    // 可用 tool 子集
  hooks?: HooksSettings      // per-skill hook 設定
  context: 'inline' | 'fork' // inline=展開到主對話; fork=生成 subagent
  files?: EmbeddedFile[]     // 附帶參考檔案（首次使用時解壓到磁碟）
  getPromptForCommand()      // async prompt 生成
}
```

- `registerBundledSkill()` 在啟動時註冊到 bundledSkills 陣列
- `context='fork'` 會產生 subagent，有獨立的 token budget 和 tool 子集

### 2.2 Disk-Based Skills（檔案系統 skill）

掃描目錄：`.claude/skills/`, `~/.claude/skills/`, managed path

**YAML Frontmatter 格式：**
```yaml
---
name: commit-helper
description: Helps create well-structured git commits
whenToUse: When user asks to commit changes
argumentHint: Optional commit message
allowedTools: [Bash, Read, Grep]
effort: medium          # low | medium | high
model: claude-sonnet-4-6  # 覆蓋預設 model
hooks:
  PreToolUse:
    - if: "Bash(git push *)"
      hooks:
        - type: command
          command: validate-push.sh
---
[Skill prompt content here]
```

### 2.3 Skill Discovery & Invocation

```
User/Model → SkillTool → getPromptForCommand(args, context) → ContentBlockParam[]
                                                                    ↓
                                                        inline: 展開到主對話
                                                        fork: 產生 subagent
```

- `getSkillToolCommands()`: 篩選 prompt-type, non-builtin, model-invocable 的 skill
- **Dynamic skill discovery**: 在 file 操作過程中可發現新 skill（paths-based visibility）
- `LoadedFrom` enum: `commands_DEPRECATED | skills | plugin | managed | bundled | mcp`

### 2.4 Skill 來源優先序

```
bundled → plugin → skill directories → MCP → managed
```

Deduplication by name — 先出現的 wins。

→ 參見 [§4 Hook](#4-hook-system)（per-skill hooks）、[§8 Plugin](#8-plugin-system)（plugin-provided skills）

---

## 3. Agent / Subagent Architecture

> 📁 `tools/AgentTool/`, `coordinator/coordinatorMode.ts`

Agent 是自主執行多步驟任務的單位。AgentTool 是 model 產生 subagent 的介面。

### 3.1 AgentTool

```typescript
AgentTool({
  description: string       // 3-5 字任務描述
  subagent_type: string     // 'general-purpose' | 'plan' | 'explore' | 自訂
  prompt: string            // 完整任務描述
  isolation?: 'worktree'    // 可選 git worktree 隔離
  run_in_background?: bool  // 背景執行
  model?: string            // 覆蓋 model
})
```

- Agent definitions 從 `.claude/agents/` 目錄載入，有自己的 frontmatter（tools, model, color, hooks, MCP）
- `agentNameRegistry: Map<string, AgentId>` 用於 `SendMessage` tool 的名稱路由

### 3.2 Coordinator Mode（協調者模式）

Feature-gated: `feature('COORDINATOR_MODE')` + `CLAUDE_CODE_COORDINATOR_MODE` 環境變數

```
┌─────────────────────────────────────────────────────────┐
│                    Coordinator                          │
│  Tools: AgentTool, SendMessage, TaskStop                │
│  角色: 規劃、分派、整合 — 不直接執行 tool               │
└──────────┬──────────┬──────────┬────────────────────────┘
           │          │          │
     ┌─────▼──┐ ┌─────▼──┐ ┌────▼───┐
     │Worker 1│ │Worker 2│ │Worker 3│
     │(Full)  │ │(Simple)│ │(Full)  │
     └────────┘ └────────┘ └────────┘
```

**Worker Tool 存取：**
- Full mode: `ASYNC_AGENT_ALLOWED_TOOLS`（完整 tool 子集）
- Simple mode: `[Bash, FileRead, FileEdit]`
- 加上 MCP tools + Scratchpad directory（如啟用）

**結果回傳機制：**
- Workers 非同步執行，結果以 `<task-notification>` XML 注入 user-role messages
- Coordinator 不直接看到 worker 的 tool call — 只看到最終結果

**工作流程 Phases：**
```
Research → Synthesis → Implementation → Verification
```

Coordinator 的 system prompt 定義四個階段。關鍵原則：**synthesis required** — coordinator 必須理解 research 結果才能指導下一步，不是單純轉發。

### 3.3 Subagent Context

- `createSubagentContext()` 從 parent context clone，帶特定 overrides
- Fork subagents **共用 parent 的 rendered system prompt**（利用 prompt cache）
- `localDenialTracking` 用於 async subagents（其 `setAppState` 是 no-op）
- `contentReplacementState` 管理 tool result 的 budget

→ 參見 [§1 Tool](#1-tool-system)（ToolUseContext）、[§5 State](#5-state-management)（agentNameRegistry）

---

## 4. Hook System

> 📁 `hooks/`, `utils/hooks/`, `schemas/hooks.ts`, `types/hooks.ts`

Hook 是事件驅動的攔截機制，可在 tool 執行前後、session 生命週期等時間點注入自訂邏輯。

### 4.1 Event Types（16 種事件）

| 事件 | 觸發時機 |
|---|---|
| `PreToolUse` | Tool 執行前 |
| `PostToolUse` | Tool 成功執行後 |
| `PostToolUseFailure` | Tool 執行失敗後 |
| `PermissionRequest` | 權限請求時 |
| `PermissionDenied` | 權限被拒時 |
| `SessionStart` | Session 開始 |
| `Setup` | 初始化完成 |
| `UserPromptSubmit` | 使用者提交 prompt |
| `Stop` | Model 停止回應 |
| `FileChanged` | 檔案變更 |
| `WorktreeCreate` | Worktree 建立 |
| `SubagentStart` | Subagent 啟動 |
| `Notification` | 通知觸發 |
| `Elicitation` / `ElicitationResult` | MCP URL 互動 |
| `CwdChanged` | 工作目錄變更 |

### 4.2 Hook Types（5 種類型）

**1. Command Hook（Shell 腳本）**
```json
{
  "type": "command",
  "command": "validate.sh $TOOL_INPUT",
  "shell": "bash",
  "timeout": 30,
  "async": false
}
```
Exit codes: 0=success, 2=blocking error, other=stderr 顯示給使用者

**2. Prompt Hook（LLM side-query）**
```json
{
  "type": "prompt",
  "prompt": "Is this operation safe? $ARGUMENTS",
  "model": "claude-haiku-4-5"
}
```

**3. Agent Hook（產生 agent 驗證）**
```json
{
  "type": "agent",
  "prompt": "Verify this file edit preserves API compatibility"
}
```

**4. HTTP Hook（遠端回呼）**
```json
{
  "type": "http",
  "url": "https://policy.internal/check",
  "headers": { "Authorization": "Bearer $API_TOKEN" },
  "allowedEnvVars": ["API_TOKEN"]
}
```

**5. Callback Hook（JS function，runtime only）**
```typescript
{
  type: 'callback',
  callback: async (input, toolUseID, abort) => HookJSONOutput,
  internal: true  // 排除於 metrics
}
```

### 4.3 HookMatcher（模式匹配）

```json
{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [{ "type": "command", "command": "check-bash.sh" }]
    },
    {
      "if": "Write(*.env)",
      "hooks": [{ "type": "command", "command": "block-env-write.sh" }]
    }
  ]
}
```

- `matcher` / `if`: 匹配 tool name + arguments 的 pattern
- `sortMatchersByPriority()`: 確定執行順序

### 4.4 Hook Sources（7 種來源）

```
userSettings > projectSettings > localSettings > policySettings > pluginHook > sessionHook > builtinHook
```

- Policy settings 可強制 `allowManagedHooksOnly` 限制為 managed hooks
- `getAllHooks(appState)` 聚合所有來源

### 4.5 Hook Response

```typescript
// 同步回應
{ continue?: boolean, suppressOutput?: boolean, decision: 'approve'|'block', reason: string }

// 非同步回應
{ async: true, asyncTimeout?: number }
```

→ 參見 [§2 Skill](#2-skill-system)（per-skill hooks）、[§7 Auto Mode](#7-auto-mode--classifier)（classifier as hook）

---

## 5. State Management

> 📁 `state/store.ts`, `state/AppState.ts`

### 5.1 Store Pattern

```typescript
createStore<T>(initialState: T, onChange?: (prev, next) => void)
→ { getState(), setState(updater), subscribe(listener) }
```

- `Object.is` equality check 防止冗餘更新
- Single-store pattern，非 Redux — 更輕量

### 5.2 AppState 核心結構

```
AppState (DeepImmutable)
├── settings: SettingsJson
├── mainLoopModel: ModelSetting
├── toolPermissionContext: ToolPermissionContext
│   ├── mode: PermissionMode
│   ├── alwaysAllowRules / alwaysDenyRules / alwaysAskRules
│   └── additionalWorkingDirectories
├── tasks: { [taskId]: TaskState }
├── foregroundedTaskId?: string
├── agentNameRegistry: Map<string, AgentId>
├── teamContext?: { teamName, leader, teammates }
├── mcp
│   ├── clients: MCPServerConnection[]
│   ├── tools: Tool[]
│   ├── commands: Command[]
│   └── resources: Record<string, ServerResource[]>
├── plugins
│   ├── enabled / disabled: LoadedPlugin[]
│   └── errors: PluginError[]
├── notifications: { current, queue }
├── speculation: SpeculationState
├── bridge state (replBridge*)
└── plan mode state (pendingPlanVerification)
```

### 5.3 State Change Hooks（onChangeAppState）

| 變更 | 副作用 |
|---|---|
| Permission mode | → 通知 CCR `notifySessionMetadataChanged()` + `notifyPermissionModeChanged()` |
| Model selection | → 自動保存到 settings |
| View expansion | → 持久化 `showExpandedTodos` + `showSpinnerTree` |
| Settings changes | → 清除 auth caches (API key, AWS, GCP) |

→ 參見 [§13 Remote Control](#13-remote-control--bridge)（CCR state sync）

---

## 6. Context Management

> 📁 `context.ts`, `services/compact/`

### 6.1 System & User Context

```
getSystemContext()  — memoized, 包含:
├── git status (branch, main branch, status, recent commits, user name)
│   └── max 2000 chars，超過則 truncation warning
└── cache-breaker injection (ant-only)

getUserContext()  — memoized, 包含:
├── CLAUDE.md files（自動發現 + 過濾）
└── current date
```

- CCR (remote) mode 和 git instructions disabled 時跳過 git status
- `Promise.all()` 平行執行 git 指令

### 6.2 CLAUDE.md 自動發現

- 從 codebase 自動發現 CLAUDE.md files
- 快取在 bootstrap state 中（lazy initialization）
- Filter phase 移除 injected memory files
- Bare mode 跳過自動發現

### 6.3 Context Compaction 三層架構

| 層級 | 檔案 | 觸發條件 |
|---|---|---|
| **Manual compact** | `compact.ts` | 使用者 `/compact` 指令 |
| **Auto compact** | `autoCompact.ts` | Token 超過閾值 = context window - 13K buffer |
| **Micro compact** | `microCompact.ts` | Turn 內即時壓縮 |
| **Session memory** | `sessionMemoryCompact.ts` | Session-level context 整合 |

### 6.4 Token Budget Tracking

```typescript
BudgetTracker = {
  continuationCount: number
  lastDeltaTokens: number
  lastGlobalTurnTokens: number
  startedAt: number
}
```

**Decision logic:**
- 閾值: 90% of budget
- **Diminishing returns**: 3+ continuations + <500 tokens delta → stop
- Warning threshold: 20K buffer
- Log: continuation count + percentage (telemetry)

→ 參見 [§14 Metrics](#14-metrics--telemetry)（token counter telemetry）

---

## 7. Auto Mode / Classifier

> 📁 `utils/permissions/yoloClassifier.ts`, `cli/handlers/autoMode.ts`

Auto mode 是一種 permission mode，使用 AI classifier 自動判斷 tool 操作是否安全。

### 7.1 2-Stage XML Classifier

```
Stage 1: 初步判斷（allow / soft_deny / ask）
     ↓
Stage 2: 精煉（確認或覆蓋 stage 1 決策）
```

- Side-query 到 classifier model，帶入對話 transcript
- 結構化 XML response parsing
- Token usage 和 overhead 追蹤（telemetry）

### 7.2 Classifier Rules（三個區段）

```
allow: [
  "Read any file within the project directory",
  "Run git status, git log, git diff",
  ...
]
soft_deny: [
  "Delete files outside project directory",
  "Run rm -rf commands",
  ...
]
environment: [
  "Working directory: /path/to/project",
  "OS: linux",
  ...
]
```

- `AutoModeRules = { allow: string[], soft_deny: string[], environment: string[] }`
- **使用者自訂 rules 完全取代 defaults**（不是 merge）
- External vs Anthropic-internal 有不同的 permission templates

### 7.3 Bash-Specific Classifier

`bashClassifier.ts` — 專門針對 bash commands 的分類器：
- 獨立的 LLM prompt components
- Shell command 層級的安全判斷
- 結構化 XML response

### 7.4 Denial Tracking

```typescript
DenialTrackingState = { denialCount: number, ... }
```

- Per-conversation denial counter
- 當 denials 累積超過閾值 → **fallback-to-prompting**（從 auto 降級回手動確認）
- `localDenialTracking` 用於 async subagents（其 setAppState 是 no-op）
- `recordDenial()`, `recordSuccess()`: mutable state updates

### 7.5 CLI 管理指令

- `auto-mode defaults` — dump 預設 classifier rules
- `auto-mode config` — 顯示有效設定（user + defaults）
- `auto-mode critique` — 用 side query 批評使用者的 rules

→ 參見 [§1 Tool](#1-tool-system)（permission flow）、[§16 Eval](#16-eval--classification)（classifier as eval）

---

## 8. Plugin System

> 📁 `plugins/builtinPlugins.ts`, `types/plugin.ts`, `services/plugins/`

### 8.1 Plugin 類型

**BuiltinPluginDefinition（內建 plugin）：**
```typescript
{
  name: string, description: string, version: string
  skills: BundledSkillDefinition[]
  hooks: HooksSettings
  mcpServers: Record<string, McpServerConfig>
  isAvailable(): boolean    // 系統能力檢查
  defaultEnabled: boolean   // 使用者偏好 fallback
}
```

**LoadedPlugin（外部 plugin）：**
```typescript
{
  name: string, manifest: PluginManifest
  path: string, source: string, repository: string
  enabled: boolean, isBuiltin: boolean
  skillsPaths: string[]      // 多個 skill 目錄
  commandsPaths: string[]    // 多個 command 目錄
  hooksConfig: HooksSettings
  mcpServers: McpServerConfig[]
}
```

### 8.2 Plugin Component Types（5 種組件）

| 組件 | 說明 |
|---|---|
| `commands` | Slash commands |
| `agents` | Agent definitions |
| `skills` | Prompt-based skills |
| `hooks` | Event hooks |
| `output-styles` | 自訂 output 格式 |

### 8.3 Plugin Error Taxonomy

Discriminated union — 20+ 種錯誤類型：

```
path-not-found | git-auth-failed | git-timeout | network-error
manifest-parse-error | manifest-validation-error
plugin-not-found | marketplace-not-found | marketplace-load-failed
mcp-config-invalid | lsp-config-invalid | hook-load-failed
component-load-failed | mcpb-download-failed | dependency-unsatisfied
```

### 8.4 Plugin Lifecycle

```
Load from marketplace/git → validate manifest → extract components
  → register hooks/skills/commands → enable/disable persistence in settings
```

- `isBuiltinPluginId(pluginId)`: 檢查 `@builtin` suffix
- Dependency resolution 支援（dependency-unsatisfied error）
- `plugins.needsRefresh` flag 觸發 `/reload-plugins` prompt

→ 參見 [§2 Skill](#2-skill-system)（plugin-provided skills）、[§4 Hook](#4-hook-system)（pluginHook source）

---

## 9. Command System

> 📁 `commands.ts`, `types/command.ts`

### 9.1 Command Types

| 類型 | 特性 | 範例 |
|---|---|---|
| **PromptCommand** | model-invocable, 返回 `ContentBlockParam[]` | /commit, /code-review |
| **LocalCommand** | 同步 handler，返回 text/compact/skip | /cost, /session, /model |
| **LocalJSXCommand** | React/Ink UI 渲染 | /help, /config |

### 9.2 Command 共通屬性

- `name`, `description`, `aliases`
- `availability`: `'claude-ai' | 'console'`（auth 要求）
- `isEnabled()`: feature flag / platform 檢查
- `isHidden`: 從 typeahead 排除
- `loadedFrom`: `'bundled' | 'skills' | 'plugin' | 'managed' | 'mcp'`
- `whenToUse`: 詳細的使用情境（給 model 看）
- `disableModelInvocation`: 禁止 model 存取
- `isSensitive`: 從 history 遮蔽 args

### 9.3 Discovery Pipeline

```
COMMANDS() (memoized ~80+ built-in)
  + bundled skills + builtin plugin skills
  + skill directory + workflows + plugin commands
  → loadAllCommands(cwd) → dedup by name (first wins)
  → getCommands(cwd) → availability + isEnabled filter
```

### 9.4 Remote / Bridge 安全篩選

- `REMOTE_SAFE_COMMANDS`: 在 remote mode 安全的 local TUI commands
- `BRIDGE_SAFE_COMMANDS`: 透過 bridge 安全的 commands（compact, clear, cost 等）

---

## 10. Memory System

> 📁 `memdir/`

### 10.1 Memory Types

| 類型 | 範圍 | 用途 |
|---|---|---|
| `user` | always private | 使用者角色、偏好、背景 |
| `feedback` | default private | 使用者對工作方式的指導 |
| `project` | bias toward team | 進行中的工作、目標、事件 |
| `reference` | usually team | 外部系統指標 |

### 10.2 檔案結構

```
memory/
├── MEMORY.md              ← index (max 200 lines, 25KB)
├── user_role.md           ← 個別 memory，含 frontmatter
├── feedback_testing.md
├── project_auth_rewrite.md
└── team/                  ← Team memory (TEAMMEM feature)
    └── ...
```

**Memory 檔案 frontmatter：**
```yaml
---
name: user role
description: data scientist focused on logging
type: user
---
[memory content]
```

### 10.3 Memory Recall

```
scanMemoryFiles()  →  findRelevantMemories()  →  inject to context
   (parallel reads,      (Sonnet selector,        (up to 5 files)
    max 200 files,        JSON output,
    newest first)         already-surfaced filter)
```

- Side-query 到 Sonnet model 選擇最相關的 memories
- 已浮出的 memories 不會重複選取
- Fire-and-forget telemetry: `logMemoryRecallShape()`

### 10.4 Metrics

- `tengu_memdir_loaded`: file count, subdir count, byte count, truncation flags
- `tengu_memdir_disabled`: env var vs setting flags
- `tengu_team_memdir_disabled`: team cohort tracking

---

## 11. Scheduler / Cron

> 📁 `utils/cronScheduler.ts`, `utils/cronTasks.ts`, `utils/cron.ts`

### 11.1 架構

- **持久化**: `.claude/scheduled_tasks.json`
- **In-memory**: session cron tasks（`CronCreate` with `durable: false`）
- **CronScheduler interface**: `start()`, `stop()`, `getNextFireTime()`
- Callbacks: `onFire(prompt)`, `onFireTask(task)`, `onMissed(tasks[])`

### 11.2 特性

| 特性 | 說明 |
|---|---|
| **One-shot vs Recurring** | 單次 vs 重複執行 |
| **Permanent tasks** | 不會 age out |
| **Task aging** | auto-delete after `maxAgeMs` |
| **Missed detection** | 啟動時檢測遺漏的任務 |
| **Jitter** | GrowthBook-tuned stagger 避免 fleet stampede |
| **Lock file** | Per-process lock 防止重複執行 |
| **Killswitch** | `isKilled()` per-task filter |

---

## 12. Session & History

> 📁 `history.ts`, `cost-tracker.ts`

### 12.1 History 持久化

- **Global history**: `~/.claude/history.jsonl`（append-only, line-delimited）
- **LogEntry**: `{ display, pastedContents, timestamp, project, sessionId }`
- **Paste handling**: inline ≤ 1024 chars, 大型 → hash + async disk write
- **Async flushing**: pending buffer + lock-based write, retry with backoff (max 5, 500ms)
- Session-scoped filter: 當前 session 的 entries 優先顯示（up-arrow）

### 12.2 Cost Persistence

```typescript
saveCurrentSessionCosts() → project config
restoreCostStateForSession() ← session ID match required
```

儲存：totalCostUSD, totalAPIDuration, totalToolDuration, lines changed, model usage map, FPS metrics

---

## 13. Remote Control & Bridge

> 📁 `remote/`, `bridge/`, `server/`

### 13.1 三種遠端連線架構

| 架構 | 協議 | 用途 |
|---|---|---|
| **RemoteSessionManager** | WebSocket → CCR | Cloud Codespace Runtime 雙向通訊 |
| **DirectConnectSessionManager** | WebSocket + NDJSON | 直接 agent-to-server 通訊 |
| **Bridge** (replBridge) | HTTP REST polling/streaming | CLI ↔ 行動裝置/web 橋接 |

### 13.2 Bridge 元件

| 元件 | 職責 |
|---|---|
| `replBridge.ts` | Session 管理, message polling, FlushGate |
| `bridgeApi.ts` | REST client（session creation, delivery, polling） |
| `bridgeMessaging.ts` | Message normalization, title extraction |
| `replBridgeTransport.ts` | V1 (HTTP polling) + V2 (streaming) transport |

### 13.3 Permission Bridge

- 遠端的 permission requests → 本地 permission system
- 支援 deny (with message) 和 allow (with updatedInput) responses
- `can_use_tool` subtype 處理

### 13.4 Security

- `workSecret.ts`: 解碼 work secrets 取得 session info
- `trustedDevice.ts`: trusted device token 管理
- JWT-based auth (`jwtUtils.ts`)

---

## 14. Metrics & Telemetry

> 📁 `cost-tracker.ts`, `services/analytics/`, `bootstrap/state.ts`

### 14.1 Cost Tracking

| Metric | 說明 |
|---|---|
| `totalCostUSD` | 累計 API 費用 |
| `totalAPIDuration` | 網路 + 處理時間 |
| `totalAPIDurationWithoutRetries` | 純 API 延遲 |
| `totalToolDuration` | Tool 執行時間 |
| `totalLinesAdded` / `Removed` | Diff 統計 |
| `totalWebSearchRequests` | WebSearch tool 呼叫次數 |
| `modelUsage` | per-model: input/output tokens, cache read/write |

### 14.2 OpenTelemetry Integration

```typescript
getCostCounter()   // OTel counter for USD cost
getTokenCounter()  // OTel counter for token usage
```

- Delayed init（在 trust dialog 後初始化）
- Meter, tracer, logger providers 在 bootstrap state
- 支援 OTLP exporter for first-party events

### 14.3 Analytics Pipeline

```
logEvent(name, metadata)  →  analytics queue  →  sinks
                                                  ├── Datadog
                                                  └── 1P Event Logger (OTLP)
```

- Events logged before sink attached → queue → drain on attach (queueMicrotask)
- **PII handling**: marker types for verified non-sensitive vs PII-tagged metadata
  - 型別名稱包含警示: `AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS`

### 14.4 Feature Flags (GrowthBook)

- Feature flag evaluation with caching
- `checkStatsigFeatureGate_CACHED_MAY_BE_STALE()`: 快取版，可能 stale
- Live mid-session tuning（如 jitter config）

### 14.5 Key Telemetry Events

| Event | 追蹤內容 |
|---|---|
| `git_status_started/completed` | duration_ms, status_length, truncation |
| `system_context_completed` | Prompt building duration |
| `user_context_completed` | CLAUDE.md processing metrics |
| `tengu_memdir_loaded` | Memory dir scan results |
| `tengu_memdir_disabled` | Disabled reasons |
| `tengu_team_memdir_disabled` | Team memory cohort |
| `tengu_coordinator_mode_switched` | Mode mismatch handling |
| `tengu_skill_tool_invocation` | Skill discovery telemetry |

### 14.6 FPS Metrics

- `averageFps`, `low1PctFps` — UI 渲染效能
- 儲存於 session costs 中，ant-only

### 14.7 Profiling

- `headlessProfilerCheckpoint()`: 標記 query 執行中的 timing points
- Profiler-guided optimization for long-running operations

---

## 15. Search & Deferred Tool Loading

> 📁 `tools/` (GlobTool, GrepTool, ToolSearchTool)

### 15.1 Deferred Loading 機制

當 tool pool 很大時（超過閾值），部分 tool 延遲載入：

```
Tool 屬性:
├── shouldDefer: true   → 不在初始 prompt 中，透過 ToolSearch 發現
├── alwaysLoad: true    → 永遠載入（如 Bash, Read, Edit）
└── searchHint: "..."   → 3-10 字關鍵字供 keyword matching
```

- `isToolSearchEnabledOptimistic()`: 檢查 tool count 是否超過閾值
- `ToolSearchTool`: model 可呼叫，以 keyword 搜尋 deferred tools，返回完整 schema

### 15.2 搜尋 Tools

- **GlobTool**: 檔案 pattern matching（`**/*.ts`）
- **GrepTool**: 內容搜尋（基於 ripgrep）
- **ToolSearchTool**: Tool 定義搜尋（deferred tool discovery）

---

## 16. Eval / Classification

> 無獨立 eval 框架 — classification 內嵌於 permission flow

### 16.1 Inline Classification

Claude Code 沒有獨立的 eval 系統。Evaluation 以兩種形式存在：

1. **Permission Classifier**（yoloClassifier）— 作為 auto mode 的 tool 安全評估
   - 2-stage pipeline 本質上是 LLM-as-judge
   - Token usage tracking = eval overhead metrics
2. **Bash Classifier**（bashClassifier）— command 層級的安全分類
3. **Prompt/Agent Hooks** — 可作為 LLM-as-judge eval points
   - Prompt hook: 用小 model 評估操作安全性
   - Agent hook: 產生 agent 做更深入的驗證

### 16.2 對 Agent-Swarm 的啟示

若需要獨立 eval，可參考：
- Classifier 的 2-stage pipeline 架構
- Hook system 作為 eval injection points
- 現有 `multi_domain_resource_plan.md` 中的 Eval Workers 設計

→ 參見 [§7 Auto Mode](#7-auto-mode--classifier)、[§4 Hook](#4-hook-system)

---

## 17. Plan Mode

> Permission mode `'plan'`

- 限制為 **read-only tools**（不能寫入、執行破壞性操作）
- `EnterPlanModeTool` / `ExitPlanModeV2Tool` 切換模式
- `prePlanMode` 儲存在 `ToolPermissionContext` 中，退出時恢復
- `VerifyPlanExecutionTool`（可選，env-gated）：驗證計畫是否正確執行
- `pendingPlanVerification` state: 追蹤 plan verification 進度

---

## 18. Bypass Mode

> Permission modes: `'bypassPermissions'`, `'acceptEdits'`, `'dontAsk'`

| Mode | 行為 |
|---|---|
| `bypassPermissions` | 跳過所有權限檢查（安全風險高） |
| `acceptEdits` | 自動接受檔案編輯，其他仍需確認 |
| `dontAsk` | 永不詢問權限（自動 deny 或 allow based on rules） |

- `isBypassPermissionsModeAvailable` flag 在 `ToolPermissionContext` 中
- 可被 remote settings 禁用：`isBypassPermissionsModeDisabled`
- `shouldAvoidPermissionPrompts`: 用於 background agents（自動 deny）

---

## 19. Output Styles

> 📁 `outputStyles/loadOutputStylesDir.ts`

- `.md` 檔案從 `output-styles/` 目錄載入（project + user + plugin）
- **Frontmatter**: `name`, `description`, `keep-coding-instructions`, `force-for-plugin`
- Filename → style name mapping
- Memoized caching with explicit cache-clear functions
- 用途：自訂 system prompt templates，實現公司特定的 output 格式

---

## 20. Migration

> 📁 `migrations/`

啟動時執行的同步 migration functions：

| 類型 | 範例 |
|---|---|
| **Model migrations** | fennec→opus, opus→opus1m, sonnet1m→sonnet45, sonnet45→sonnet46 |
| **Settings migrations** | autoUpdates→settings, bypassPermissions→settings, enableAllProjectMcpServers→settings |
| **Mode migrations** | replBridgeEnabled→remoteControlAtStartup |
| **Reset migrations** | autoModeOptIn reset, proToOpusDefault reset |

Pattern：
1. 檢查條件（subscription tier, auth provider）
2. 讀取 current settings
3. 套用 migration
4. Log analytics event
5. 可選：儲存 timestamp 供使用者通知

---

## 21. Synthesis: 可採用的架構模式

以下是從 Claude Code 架構中提煉出、對 agent-swarm 最有參考價值的設計模式：

### Pattern 1: Tool Registration Pipeline

```
定義 (ToolDef) → 建構 (buildTool) → 過濾 (deny rules) → 組裝 (assembleToolPool)
```

**啟示**: Tool 的註冊不是一步完成，而是 pipeline — 每一步都可以插入邏輯（feature gate, permission filter, MCP merge）。我們的 agent-swarm 可採用類似 pipeline 來管理 tool 可見性。

### Pattern 2: Immutable State Store + Change Hooks

```
createStore(initialState, onChange) → 訂閱 side effects
```

**啟示**: 單一 immutable store 搭配 change hooks，既保證 state 一致性又允許 reactive side effects。比 event bus 更可預測。

### Pattern 3: Side-Query Pattern

```
Memory Recall:   主對話 → side-query to Sonnet → 選擇 relevant memories
Classification:  主對話 → side-query to classifier → 安全判斷
```

**啟示**: 用較小 model 做 side-query 是成本效率的做法。可用於 eval、routing、memory retrieval。

### Pattern 4: Coordinator / Worker + XML Result Delivery

```
Coordinator (規劃) → Workers (async 執行) → <task-notification> XML → Coordinator (整合)
```

**啟示**: Workers 非同步執行，結果注入 conversation — 不需要 shared state。Coordinator 專注於規劃和整合，不直接用 tools。

### Pattern 5: Permission Rule System with Source Tracking

```
PermissionRule = { source, behavior, ruleValue }
Sources: user > project > local > policy > plugin > session > builtin
```

**啟示**: 每條規則記錄來源，支援優先序和 audit trail。Policy settings 可覆蓋使用者設定。

### Pattern 6: Hook Event System for Extensibility

```
16 event types × 5 hook types × 7 sources = 高度可組合的擴展點
```

**啟示**: Hook 系統是 Claude Code 最核心的擴展機制。從 shell script 到 HTTP callback 到 LLM-as-judge，同一個 event 可以有多種處理方式。

### Pattern 7: Deferred Loading for Large Tool Pools

```
shouldDefer=true → 不載入到 prompt → ToolSearch keyword matching → 按需載入
```

**啟示**: 當 tool 數量大時，不需要把所有 tool 定義放到 system prompt — 用 search hint 做 lazy discovery 可節省大量 tokens。

### Pattern 8: Context Compaction 三層策略

```
microCompact (turn 內) → autoCompact (token 閾值) → manual compact (使用者觸發)
```

**啟示**: 長對話需要多層 context 壓縮策略，每層有不同的觸發條件和壓縮程度。Diminishing returns detection (3+ continuations + <500 delta) 是實用的停止條件。
