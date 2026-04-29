---
layout: post
title: "LLM 多任務輸出：把 temporal date-range 解析合併進 intent classifier"
date: 2026-04-29 18:00:00 +0800
description: "Regex 寫死處理「最近 / 下次 / 上週」效果不佳，額外開一次 LLM call 又抬高 latency 與 token 成本；正解是把 date-range 解析與 vagueness 標註合併進既有的 intent classifier output schema — 同一次 LLM call 同時產出 intent label 與 date_range，零增量 round-trip。"
tags: rag llm intent-classification prompt-engineering temporal performance ai
featured: false
og_image: /assets/img/blog/2026/multi-task-intent-llm/multi-task-intent-llm-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/multi-task-intent-llm/multi-task-intent-llm-architecture.png" class="img-fluid rounded z-depth-1" alt="Multi-task intent LLM — temporal date-range parsing co-located in intent classifier" caption="一次 LLM call 同時產出 intent label 與 temporal date_range — Schema 是被低估的 cost lever" %}

> **Abstract** — Resolving temporal expressions like "recently", "next time", or "last week" into concrete date ranges is a prerequisite for retrieval. Regex patterns are brittle and don't scale to natural-language variation. Adding a dedicated date-range LLM call doubles latency and token cost. The cleaner path is to extend the existing intent classifier's output schema to also emit `temporal`, `date_range`, `vagueness`, and `interpretation` — the same LLM call now does two jobs at zero round-trip cost. This post walks through the schema, the three-tier vagueness handling, and why output schema extension is a discrete cost win compared to adding a second LLM call.

模糊的 temporal query — 「最近的匯率」、「下次客戶會議幾點」、「上週的 newsletter」 — 是 retrieval 系統最常被低估的盲點。要把它解出來，第三條路通常比直覺中的前兩條都便宜。

---

## 模糊 temporal 為什麼難解

對 RAG / retrieval 系統而言，使用者問句裡的時間維度必須先被解析成具體 `date_range`，才能交給後續的 filter 或 ranker 使用。光從句子的時間表達多樣性就能感受到表面的複雜：

| 類型 | 範例 | 難度 |
| --- | --- | --- |
| 明確絕對 | 「2026-04-30 的活動」 | 容易 |
| 明確相對 | 「明天的 standup」、「下週一的會議」 | 中等 |
| 模糊範圍 | 「最近的匯率」、「前陣子的 newsletter」 | 難 |
| 方向性 vague | 「下次客戶會議」、「接下來幾天」 | 難 |
| Implicit reference | 「上次提到的那個方案」 | 需要 chat history |

如果直接把這些句子交給 retrieval 自己處理，多半會出問題：embedding 對「最近」沒有絕對日期感、BM25 不認識「下次」、metadata filter 沒有 `date_range` 可套。**Query understanding 層必須先把時間維度具現化**，retrieval 才能正確過濾。

---

## 三條岔路

### Approach 1：Regex / 規則寫死

直覺解法是在 query 進入 pipeline 前用 regex 把時間詞抽出來：

```python
TEMPORAL_PATTERNS = {
    r"^明天": lambda d: (d + 1, d + 1),
    r"^下週": lambda d: next_monday_range(d),
    r"^最近": lambda d: (d - 7, d),
    # ...持續追加
}
```

自然語言的變體無窮：「後天」、「再過兩天」、「這週末」、英中夾雜的「next Tuesday」、「by EOD」。每個新表達式都要一條 PR + 測試 + 回歸；半年後 pattern table 會變成沒人敢動的灰色地帶。對 implicit reference（「我們上次提到的那個」）更是直接束手 — regex 沒有 chat history 的視野。

### Approach 2：獨立的 date-range LLM call

第二直覺是丟一個小 LLM 專門做 date-range extraction：

```text
query → [LLM 1: intent classifier]   → intent label
query → [LLM 2: date-range extractor] → {start, end}
```

彈性夠了，但成本翻倍：每個 query 多一次 LLM round-trip（即使是 small model，p50 也要 200–400 ms）；system prompt 與 few-shot 各複製一份；兩個 LLM 的輸出可能互相矛盾（intent 說 `temporal=false`，date LLM 卻給了範圍）；並發資源、timeout、retry policy 兩套要維護。**對 chat-grade latency budget 不划算**。

### Approach 3：合併到既有的 intent classifier 多任務輸出（選的這條）

intent classifier 反正會跑。把 output schema 擴充，讓它在同一次 LLM call 裡同時輸出 intent label 與 temporal 解析：

```text
query → [LLM: intent + temporal + date_range + vagueness] → 一份結構化結果
```

不增 round-trip、不增 latency、token 增量很小（< 50 output tokens）；temporal 與 intent 的判斷在同一份 reasoning 裡，不會互相矛盾；同模式可繼續擴 — entity extraction、persona detection、clarification flag 都能塞進來。代價是 intent classifier 的 prompt 略長、few-shot 要包 temporal 案例 — 但這與「多開一次 LLM call」相比是數量級的省。

---

## Schema 設計：intent classifier 的多任務輸出

擴充前 schema 只有 intent label：

```json
{"intent": "category_A"}
```

擴充後同一次 LLM call 吐出：

```json
{
  "intent": "category_B",
  "temporal": true,
  "date_range": {"start": "2026-04-22", "end": "2026-04-29"},
  "vagueness": "fuzzy",
  "interpretation": "把『最近』解讀為過去 7 天",
  "requires_context": false
}
```

幾個設計要點：

1. **System prompt 注入今天的日期** — 確保「明天」、「上週」 都能解析成絕對日期，否則 LLM 會猜（或拒答）
2. **`temporal: bool` 是 short-circuit 開關** — 非時間性 query 全 false，下游直接略過後續欄位處理
3. **`vagueness` 分三檔**：
   - `"exact"` — 明確日期或範圍（「2026-04-30」、「明天」）
   - `"fuzzy"` — 有界但範圍由 LLM 推（「最近」 → 7 天；「上個月」 → 30 天）
   - `"vague"` — 無明確邊界（「以前」、「之後」），需要 fallback 或 clarification
4. **`interpretation` 是自然語言字串** — LLM 把它對模糊 temporal 的解讀寫出來；UI 可以直接拿去顯示（「我把『最近』理解為過去 7 天，需要調整嗎？」）
5. **`requires_context: bool` 處理 implicit reference** — 「那個」、「那次」 這類需要對話脈絡才能消歧的句子；下游切到 chat-history-aware retrieval

落地建議：用 OpenAI / Anthropic 的 structured output（JSON mode 或 function calling）強制 LLM 回 valid JSON，parser 不必自己處理空白或格式異常。

---

## 三檔 vagueness 的下游策略

光有 schema 還不夠，downstream 要對應不同行為：

| `vagueness` | retrieval 行為 | UI 行為 |
| --- | --- | --- |
| `exact` | 直接套 `date_range` | 不需提示 |
| `fuzzy` | 套 LLM 給的 range | 顯示 `interpretation`，提供「調整範圍」按鈕 |
| `vague` | 套 default window（如 30 天）並降權 temporal filter | 顯示「已用最近 30 天範圍」並請使用者確認 |

對 `requires_context: true` 的 case：

- 不直接 retrieve；先把 chat history 的最近 N 句拼進 follow-up prompt，再丟回 intent classifier 重跑一次
- 第二次仍然 `requires_context` 就改顯示 disambiguation prompt（「您指的是 X 還是 Y？」）

關鍵：**模糊性是 first-class signal，不要把它藏在 retrieval 內部猜**。Schema 把它顯式 emit 給整個 pipeline，UI、retrieval、後續 ranker 都能各自對齊決策。

---

## 為什麼這算「零成本」設計

成本對比：

| 指標 | Approach 2 dedicated | Approach 3 co-located | Δ |
| --- | --- | --- | --- |
| LLM calls / query | 2 | 1 | -50% |
| 中位 latency 增量 | +200–400 ms | +0 ms | 顯著下降 |
| Token 成本 | 2× system prompt + 2× few-shot | 1× + 一些 schema overhead | ~50% 省 |
| 並發資源 | 2 套 connection pool / timeout | 1 套 | -1 dependency |
| Source of truth | 2 places | 1 place | 矛盾消除 |

關鍵 insight：**LLM 多任務輸出 = 用 prompt schema 換 LLM call**。

- 多 emit 幾個 output field：成本連續、極小，幾乎是 noise
- 新增一次 LLM call：成本離散、跳升一個量級（latency + 並發 + 錯誤處理三條同時抬高）

把「擴 schema」與「多開一次 call」放同一張橫軸上看，是兩個 cost regime。**這個對立是 LLM cost engineering 最常被忽略的決策節點**。

---

## Practitioner takeaways

1. **不要為每個小抽取任務多開一次 LLM call** — 先試試合併到既有的 intent / parse / classify call
2. **Output schema 是被低估的 cost lever** — 多 emit 幾個 field 幾乎免費；多開一次 call 是離散跳升
3. **Vagueness 要分三檔（exact / fuzzy / vague）+ 一個 `requires_context` flag**，比 boolean 更實用
4. **模糊性要顯式 emit 給 downstream**（含 UI），別讓 retrieval 自己猜 default window
5. **Multi-task LLM 是常用招** — 同樣套路可用於 entity extraction、persona detection、clarification needed、safety classification 等多個子任務

---

## References

- [OpenAI structured outputs](https://platform.openai.com/docs/guides/structured-outputs) — 用 JSON schema 強制輸出格式
- [Anthropic tool use](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview) — function calling 風格的 structured output
- 自家 [RAG Pipeline Eval-Driven Tuning]({% post_url 2026-04-22-rag-eval-driven-tuning %}) — intent / temporal 計算的位置與觀察訊號

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
