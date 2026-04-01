---
layout: post
title: "本地 Agent Swarm 框架全解析：從架構比較到簡單實作"
date: 2026-03-31 10:00:00 +0800
description: "比較主流本地 Agent Swarm 框架（CrewAI、AutoGen、LangGraph、smolagents），並用 smolagents 實作一個最小化的雙 Agent 協作範例"
tags: agent-swarm multi-agent orchestration llm automation python
featured: true
og_image: /assets/img/blog/2026/local-agent-swarm/local-agent-swarm-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/local-agent-swarm/local-agent-swarm-overview.png" class="img-fluid rounded z-depth-1" alt="Local Agent Swarm Frameworks Overview" caption="本地 Agent Swarm 框架架構總覽" %}

> **English Abstract** — This post surveys the mainstream local agent swarm frameworks in 2026: CrewAI (role-based crews), AutoGen/AG2 (actor-model conversations), LangGraph (graph-based state machines), and smolagents (code-first minimal agents). We compare their architectures, learning curves, and trade-offs, then implement a minimal 2-agent swarm using Hugging Face's smolagents to demonstrate how lightweight multi-agent orchestration can be.

**Multi-Agent 協作**已經從研究論文走進生產環境。當你的 LLM 應用需要不同角色分工——一個搜資料、一個寫摘要、一個檢查品質——你需要一個 **Agent Swarm** 框架來協調它們。

但框架那麼多，哪個適合你？本文從架構本質出發，幫你做出選擇。

---

## 為什麼要用本地 Agent Swarm？

三個核心理由：

1. **隱私與合規** — 敏感資料不出內網，適合金融、醫療場景
2. **成本控制** — 用本地模型（Ollama、vLLM）取代 API 調用，長期成本降 10 倍以上
3. **延遲可控** — 內網通訊 < 1ms vs API 調用 200-500ms

> **Production Notes** — 即使用本地模型，你仍然可以在開發階段用雲端 API 快速迭代，部署時再切換到本地推理。大部分框架都支援這種混合模式。

---

## 主流框架比較

| 框架 | Stars | 架構模式 | 代表企業 | 下載量/月 | 學習曲線 |
|------|-------|---------|---------|----------|---------|
| **LangGraph** | ~28k | 圖狀態機（Nodes + Edges） | LinkedIn, Uber, Klarna | 38.5M | 中等 |
| **CrewAI** | ~46k | 角色分工（Role + Goal） | Novo Nordisk, Oracle | 5.2M | 簡單 |
| **AutoGen/AG2** | ~57k | Actor 模型 / 對話驅動 | ⚠ 維護模式 | — | 困難 |
| **smolagents** | ~26k | Code-first 極簡 | 早期階段 | — | 簡單 |

> **補充框架** — **MetaGPT**（~64k stars）以 SOP 模擬軟體公司運作，適合程式碼生成場景但不適用通用 Agent 協作。**OpenAI Agents SDK**（取代已封存的 Swarm）由 HP、Intuit、Oracle 等企業採用，但綁定 OpenAI API。

### CrewAI — 最直覺的角色扮演

CrewAI 的核心概念是「團隊」：每個 Agent 有 **角色**、**目標** 和 **背景故事**，被分配到 **任務**，然後組成 **Crew** 執行。

```python
from crewai import Agent, Task, Crew

researcher = Agent(
    role="Research Analyst",
    goal="Find the latest trends in AI agent frameworks",
    backstory="You are a senior tech analyst..."
)

writer = Agent(
    role="Content Writer",
    goal="Write a concise summary from research findings",
    backstory="You are a technical blogger..."
)

research_task = Task(description="Research top 5 agent frameworks", agent=researcher)
write_task = Task(description="Write a summary article", agent=writer)

crew = Crew(agents=[researcher, writer], tasks=[research_task, write_task])
result = crew.kickoff()
```

- **優點**：上手最快，概念清晰，社群活躍（成長最快的框架）
- **缺點**：複雜工作流的控制力有限

### AutoGen — 曾經的明星，現已進入維護模式

Microsoft 的 AutoGen 在 v0.4 做了完全重寫，採用 **Actor 模型**。但 **2025 年 10 月起已進入維護模式**，Microsoft 將其與 Semantic Kernel 合併為統一的 Microsoft Agent Framework。原始創作者（Chi Wang、Qingyun Wu）離開 Microsoft，建立了社群驅動的 **AG2** fork。

```python
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.teams import RoundRobinGroupChat

researcher = AssistantAgent("researcher", model_client=model_client)
writer = AssistantAgent("writer", model_client=model_client)

team = RoundRobinGroupChat([researcher, writer], max_turns=3)
result = await team.run(task="Research and summarize AI trends")
```

- **優點**：Actor 模型架構設計優秀，可分散式部署
- **缺點**：已停止新功能開發，v0.2 → v0.4 不相容，社群分裂為 AG2 fork
- **⚠ 注意**：如果你現在才要選框架，不建議新專案採用 AutoGen

### LangGraph — 企業級生產首選

LangGraph 用有向圖來定義 Agent 之間的流轉邏輯。每個節點是一個處理步驟，邊決定下一步走向。它是目前**企業生產環境採用率最高**的多 Agent 框架：

- **LinkedIn** — AI 招募助手，自動化候選人配對
- **Uber** — 服務 5,000 名工程師，節省 21,000+ 開發小時
- **Klarna** — 客服 AI 處理 8,500 萬用戶，回覆時間縮短 80%

```python
from langgraph.graph import StateGraph

graph = StateGraph(AgentState)
graph.add_node("researcher", research_node)
graph.add_node("writer", writer_node)
graph.add_edge("researcher", "writer")

app = graph.compile(checkpointer=MemorySaver())
result = app.invoke({"task": "Research AI trends"})
```

- **優點**：工作流可視化，checkpoint + human-in-the-loop，企業實戰驗證最多
- **缺點**：需要理解圖資料結構，boilerplate 較多

### smolagents — Code-first 極簡主義

Hugging Face 的 smolagents 核心只有 ~1000 行程式碼。Agent 直接寫 Python code 來呼叫工具，不用 JSON schema。

```python
from smolagents import CodeAgent, HfApiModel, DuckDuckGoSearchTool

model = HfApiModel("Qwen/Qwen2.5-Coder-32B-Instruct")
agent = CodeAgent(tools=[DuckDuckGoSearchTool()], model=model)
result = agent.run("What are the top AI agent frameworks in 2026?")
```

- **優點**：最輕量，支援本地 HF 模型，code-first 比 JSON 更靈活
- **缺點**：多 Agent 協作功能較新，生態系較小，尚無知名企業採用案例

> **Production Notes** — 如果你只是需要 **單一 Agent + 工具呼叫**，smolagents 是最佳起點。需要 **多角色協作** 用 CrewAI。需要 **複雜工作流 + checkpoint + 企業級生產** 用 LangGraph。

---

## 簡單實作：smolagents 雙 Agent 協作

選擇 smolagents 是因為它最輕量、不依賴特定 API provider、且支援本地模型。

### 安裝

```bash
pip install smolagents[litellm] duckduckgo-search
```

### 程式碼

```python
"""
minimal_swarm.py - 最小化的雙 Agent 協作範例
Agent A (Manager): 協調任務分配
Agent B (WebSearch): 搜尋網路資訊
"""
from smolagents import CodeAgent, LiteLLMModel, DuckDuckGoSearchTool, tool

@tool
def summarize_text(text: str) -> str:
    """Summarize the given text into 3 bullet points."""
    return f"Summary of: {text[:100]}..."

# 使用 LiteLLM 支援任意 LLM provider
model = LiteLLMModel(model_id="gpt-4o-mini")  # 或 ollama/llama3.2

# Web Search Agent
web_agent = CodeAgent(
    tools=[DuckDuckGoSearchTool()],
    model=model,
    name="web_search_agent",
    description="Searches the web for information on a given topic",
)

# Manager Agent (orchestrates the web agent)
manager = CodeAgent(
    tools=[],
    model=model,
    name="manager",
    managed_agents=[web_agent],
)

# 執行
result = manager.run(
    "Search for the top 3 local AI agent frameworks in 2026, "
    "and give me a brief comparison."
)
print(result)
```

### 執行結果

```text
$ python minimal_swarm.py

╭─ Manager Agent ──────────────────────────────────────╮
│ I'll delegate the web search to my web_search_agent. │
╰──────────────────────────────────────────────────────╯
╭─ web_search_agent ───────────────────────────────────╮
│ Searching: "top local AI agent frameworks 2026"      │
│ Found 5 results...                                   │
╰──────────────────────────────────────────────────────╯
╭─ Manager Agent ──────────────────────────────────────╮
│ Based on web_search_agent's findings:                │
│                                                      │
│ 1. LangGraph (~28k stars) - Enterprise production    │
│ 2. CrewAI (~46k stars) - Role-based, easiest setup   │
│ 3. smolagents (~26k stars) - Code-first, minimal     │
│                                                      │
│ For quick prototyping: CrewAI or smolagents           │
│ For production at scale: LangGraph                   │
╰──────────────────────────────────────────────────────╯
```

> 以上為簡化的示意輸出，實際執行結果會因模型和搜尋結果而異。

> **Production Notes** — `LiteLLMModel` 讓你用同一份程式碼切換任意 LLM：`gpt-4o-mini`（雲端）、`ollama/llama3.2`（本地）、或 `anthropic/...`（其他 provider）。部署時只改 `model_id` 即可。

---

## 框架選型決策樹

```text
你的需求是什麼？
│
├── 只需要單一 Agent + 工具 → smolagents
│
├── 需要多角色協作
│   ├── 簡單的順序/並行執行 → CrewAI
│   └── 複雜的條件分支/迴圈 → LangGraph
│
└── 企業級生產部署 → LangGraph（已被 LinkedIn, Uber, Klarna 驗證）
```

---

## 總結

| 如果你是... | 推薦 | 理由 |
|------------|------|------|
| 剛接觸 Agent 的開發者 | **smolagents** | 最少 boilerplate，10 行就能跑 |
| 需要快速建立 Agent 團隊 | **CrewAI** | 角色概念直覺，社群資源豐富 |
| 建構複雜工作流 | **LangGraph** | 圖模型 + checkpoint + human-in-the-loop |
| 企業級生產部署 | **LangGraph** | LinkedIn, Uber, Klarna 驗證，38.5M 月下載 |

> **⚠ AutoGen 已不建議新專案採用** — 自 2025 年 10 月起進入維護模式，Microsoft 已將其合併至 Microsoft Agent Framework。

Agent Swarm 的未來趨勢是 **更輕量的核心 + 更強的互操作性**。smolagents 的 ~1000 行核心證明了一個好的 Agent 框架不需要很複雜。市場正在向 **圖式工作流**（LangGraph 領先）收斂，CrewAI 也在積極整合 LangChain 生態。

---

## 相關連結

- **CrewAI** — [github.com/crewAIInc/crewAI](https://github.com/crewAIInc/crewAI)
- **AutoGen** — [github.com/microsoft/autogen](https://github.com/microsoft/autogen)
- **AG2 (AutoGen fork)** — [github.com/ag2ai/ag2](https://github.com/ag2ai/ag2)
- **LangGraph** — [github.com/langchain-ai/langgraph](https://github.com/langchain-ai/langgraph)
- **smolagents** — [github.com/huggingface/smolagents](https://github.com/huggingface/smolagents)
- **OpenAI Agents SDK** — [github.com/openai/openai-agents-python](https://github.com/openai/openai-agents-python)
- **MetaGPT** — [github.com/FoundationAgents/MetaGPT](https://github.com/FoundationAgents/MetaGPT)
- **企業採用數據** — [Is LangGraph Used In Production?](https://blog.langchain.com/is-langgraph-used-in-production/)
- **AutoGen 維護模式** — [Microsoft retires AutoGen](https://venturebeat.com/ai/microsoft-retires-autogen-and-debuts-agent-framework-to-unify-and-govern)

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
