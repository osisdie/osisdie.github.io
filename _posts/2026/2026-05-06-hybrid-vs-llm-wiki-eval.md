---
layout: post
title: "Hybrid RAG vs LLM-Wiki：把 Karpathy 的概念拉去做 13 題 A/B 評測"
date: 2026-05-06 18:00:00 +0800
description: "Karpathy 在 2026 年初提出的 LLM Wiki — 讓 LLM 把 raw sources 預先合成成可累積的 markdown 知識庫 — 是個吸引人的概念。把它跟 Hybrid RAG (BM25 + dense + RRF) 在同一個 60 篇知識庫、13 題 A/B 上對照後，硬數字是 accuracy 13/13 vs 12/13、tokens ×9.3、p50 latency ×2.5、LLM calls 2 vs 4。Wiki 的 single failure 不是輸幾個百分點，是跨 tenant 資料污染：把另一個 tenant 的 policy 高 confidence 答給使用者。這篇講三個 failure mode，並提醒在全面採用 LLM-Wiki 之前，先把現有 Hybrid 該有的 reranker / contextual retrieval / tenant filter 補齊。"
tags: rag llm evaluation knowledge-base performance ai
featured: false
og_image: /assets/img/blog/2026/hybrid-vs-llm-wiki-eval/hybrid-vs-llm-wiki-eval-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/hybrid-vs-llm-wiki-eval/hybrid-vs-llm-wiki-eval-architecture.png" class="img-fluid rounded z-depth-1" alt="Hybrid RAG vs LLM-Wiki — head-to-head A/B comparison + three Wiki failure modes" caption="Hybrid RAG 與 LLM-Wiki 在同一知識庫上的 13 題 A/B 對照，與 Wiki 在跨 tenant 污染、語系污染、paraphrase 過簡上的三個 failure mode" %}

> **Abstract** — [Karpathy's LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) proposes letting an LLM pre-synthesize raw sources into a persistent, compounding markdown wiki, then answering queries by navigating that wiki — instead of doing classic RAG (BM25 + dense + RRF) from scratch on every question. The promise: amortize the synthesis cost once, get richer cross-references for free. We took an internal 60-article knowledge base and ran 13 hand-graded questions through both pipelines. The numbers: accuracy 13/13 vs 12/13, tokens ×9.3, p50 latency ×2.5, LLM calls 2 vs 4. The single Wiki miss isn't a percentage-point loss — it's the LLM confidently citing one tenant's policy in answer to another tenant's question, because page synthesis merged tenants when generating. This post breaks down the three failure modes and the routing decision tree.

把概念拉到 production 評測之後，硬數字很乾淨：在這個 13 題子集上，**Hybrid 是 cost-、latency-、accuracy- 三項都贏**；Wiki 的 single failure 不是輸幾個百分點，是用 0.9 confidence 給出錯的答案。

---

## 為什麼比這兩個

[Andrej Karpathy 的 LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) 提案一個誘人的設計：與其每個 query 都去 raw sources 撈 chunk、讓 LLM 從零拼接，不如**讓 LLM 把所有 source 預先 synthesize 成一座 markdown wiki** — 包含 entity 頁、概念頁、index 與 log，跨頁面互引、隨新文件持續更新。Query 時 LLM 讀 `index.md` 找相關頁面，再 drill into 拼答案。Karpathy 的核心 claim 是 wiki 是 **persistent, compounding artifact**：bookkeeping 由 LLM 負擔，知識會隨時間越來越富。

這個概念在文字層級很有說服力，但生產系統會問三個問題：

- **Accuracy 真的會比經典 RAG 高嗎？** 預合成的 wiki 看似帶了「結構紅利」，但 page synthesis 階段的 LLM 也會引入新 error。
- **Token 成本回得來嗎？** Wiki bulk-build 是一次性大開銷；query-time 由於要讀 `index.md` + 選頁 + 讀頁，每次也吃比較多 token。
- **Multi-tenant 怎麼隔離？** 如果一個 bot 服務多個 tenant，page synthesis 階段如果沒做 tenant filter，不同 tenant 的 policy 會被合併進同一頁。

要回答這三個問題，唯一的方式是**跑同一個知識庫的 A/B**。

---

## 兩種 pipeline 的 LLM call 拆解

兩條 pipeline 在 query-time 觸發的 LLM 次數差兩次：

```text
Hybrid:                         LLM-Wiki:
  1. classify_intent              1. classify_intent
  2. persona answer               2. WIKI_INDEX_PICK
  ───                             3. WIKI_ANSWER
  共 2 次                         4. persona answer
                                  ───
                                  共 4 次
```

- **`classify_intent`** — 兩邊共用，small classifier model，~100 ms 級
- **`WIKI_INDEX_PICK`** — Wiki 專屬。讀 `index.md` 全文 + 使用者問題，吐 JSON `{pages: [...], reason: "..."}`，最多挑 4 篇
- **`WIKI_ANSWER`** — Wiki 專屬。讀挑出來的 wiki 正文，產生答案 + citations
- **`persona answer`** — 兩邊共用，把 citations 套進 persona prompt 做最終回覆

Hybrid 的「檢索」靠 BM25 + dense vector，**不走 LLM**；LLM-Wiki 把檢索本身換成兩段 LLM-navigation。所以「Wiki 比 Hybrid 多 2 次 LLM」是設計使然，不是 bug。

---

## 評測設定

- **規模**：60 篇 markdown wiki（一次 bulk-build 花 ~194k tokens；包含 30 篇 entity 頁、9 篇時序頁、6 篇 FAQ、7 篇政策頁、其餘為彙總頁）
- **底層檢索資料**：vector store 1,402 個 points，混合 FAQ / policy / entity 描述 / 時序紀錄
- **測試集**：13 題（從原始 43 題裡抽出單一 tenant 子集），覆蓋四個 FAQ 子分類（A/B/C/D）+ 3 題 paraphrase + 1 題 out-of-scope + 1 題 edge case
- **Persona**：兩邊套用同一份 persona prompt，本表只看事實層 accuracy / recall，不評語氣
- **判讀**：人工逐題判讀（RAGAS judge 模型在這次評測時被 wiki bulk-build 吃掉 quota，4 個指標都 None — 這本身是 wiki 維護成本的一個 hidden cost，後面會展開）

---

## Headline scorecard

| 指標 | Hybrid | LLM-Wiki | Δ |
| --- | ---: | ---: | ---: |
| Accuracy（13 題） | 13/13 (100%) | 12/13 (92.3%) | +1 |
| Has-answer rate | 0.923 | 0.923 | tie |
| Avg confidence | 0.808 | 0.862 | wiki +0.054 |
| Latency p50 | 3.3 s | 8.2 s | **×2.5** |
| Latency p95 | 24.3 s | 27.3 s | +12% |
| Avg tokens / query | 1,407 | 13,055 | **×9.3** |
| LLM calls / query | 2 | 4 | +2 |
| One-shot 維護成本 | 0 | ~194k tokens | bulk-build |
| Winner | **Hybrid** | — | — |

兩個值得停下來看的數字：

1. **Avg confidence 0.808 → 0.862** — Wiki 報告自己更有把握，但 accuracy 反而較低。**Confidence 是模型自評，不是命中率**。Wiki 在唯一的錯題上 confidence 給到 0.9 — 高 confidence 配上錯答案，比低 confidence 配上錯答案危險得多。
2. **Tokens ×9.3** — 不只是「Wiki 多花一點」。query 平均 13k tokens 在較貴的 model 上落差會放大；如果這條 pipeline 走 reasoning model，差距是線性放大的。

---

## 逐分類成績

| Category | n | Hybrid 對 | Wiki 對 | Hybrid avg lat | Wiki avg lat | Hybrid avg tok | Wiki avg tok |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| FAQ-A | 2 | 2/2 | 2/2 (1 noisy) | 8.9 s | 10.7 s | 1,452 | 12,977 |
| FAQ-B | 2 | 2/2 | 2/2 | 26.1 s | 13.1 s | 1,686 | 14,894 |
| FAQ-C | 2 | 2/2 | 2/2 | 3.3 s | 18.2 s | 1,477 | 10,187 |
| FAQ-D | 2 | 2/2 | **1/2** | 4.8 s | 13.8 s | 1,520 | 17,094 |
| Paraphrase | 3 | 3/3 | 3/3 (2 thin) | 3.5 s | 14.2 s | 1,527 | 15,353 |
| Out-of-scope | 1 | 1/1 | 1/1 | 2.3 s | 1.6 s | 0 | 0 |
| Edge | 1 | 1/1 | 1/1 | 3.0 s | 7.5 s | 1,443 | 13,355 |
| **Total** | **13** | **13/13** | **12/13** | 6.4 s | 11.4 s | 1,407 | 13,055 |

幾個觀察：

- **FAQ-D 是 Wiki 的弱點**（1/2）。失敗那題不是「沒查到」，而是 wiki 把另一個 tenant 的 policy 引用進來。下一節展開
- **Out-of-scope** Wiki 反而比 Hybrid 快 700 ms — 因為 `WIKI_INDEX_PICK` 早期就判定無相關頁面、沒進到 `WIKI_ANSWER`。這是 wiki 結構的少數 latency 優勢
- **FAQ-B p95 在 Hybrid** 上跳到 24.3 s — 是 vector store 的 quota outlier，與 mode 無關

---

## Token 經濟學

### Query-time

```text
Hybrid avg:  1,407 tokens × 13 題 =  18,294 tokens
Wiki avg:   13,055 tokens × 13 題 = 169,715 tokens
                          ratio  = ×9.3
```

Wiki 的 prompt 主要花在兩段：

- `INDEX_PICK` — 餵一份完整的 `index.md`（13 篇 page summary），每次 ~2-3k tokens
- `ANSWER` — 把選中的 1-4 篇 wiki 正文塞進 context，每篇 800-2,000 tokens

加總每題穩穩落在 10k-15k 區間。

### Bulk-build 維護成本

一次 bulk-build 全 wiki ~**194k tokens**（prompt + completion，跨 60 篇 page synthesis + 1 篇 index）。攤提：

- **每天 regen 一次** → +194k / day
- **每週一次** → ~28k / day
- **新文件 incremental ingest** → 通常每篇 3-5k tokens（Karpathy 的 idea：一篇 source 觸碰 10-15 個 wiki page）

要把 Wiki 的 query-time 多花 token 賺回來，需要它能在某個 query 類別上 dominate Hybrid。從本次 13 題看：**沒有任何分類** Wiki 的 accuracy 高過 Hybrid。Confidence 高一些不算贏 — confidence 高+答錯比 confidence 低更危險。

---

## 三個 Wiki failure mode

### 1. 跨 tenant 資料污染（cross-tenant contamination）

> **先說 tenant 在這篇是什麼**：在 multi-tenant 場景下，同一個 bot / 系統同時服務多個獨立的知識邊界（例如多個品牌、多個產品線、多個 region、多個客戶帳號），每個 tenant 的政策、價格、條件都不同、**不該互通**。檢索系統的責任之一，是只回傳「本 tenant 的事實」。

題目：「[特定政策] 可以轉讓嗎？」

Wiki 答案：「當然可以」+ 把另一個 tenant 的具體政策配額（X 份、Y 份、Z 份）列出來，confidence 0.9。

實際 GT：「本 tenant 的政策是不可轉讓」。

根因有三層：

1. **Page grouping key 沒帶 `tenant_id`**：bulk-build 時，wiki page 的合併單位是 entity 名稱，不是 tenant + entity。多 tenant 的相同類型政策被合併成同一篇。
2. **`INDEX_PICK` 沒做 tenant 後過濾**：拿到的 page 是混的。
3. **Persona prompt 不規範事實過濾**：persona 只規範口吻，沒寫「請只引用本 tenant 的事實」這條 redline。

修復成本最低的路：把 `tenant_id` 加進 wiki page frontmatter 必填欄位，`INDEX_PICK` / `ANSWER` 兩階段都按 tenant filter。代價是其他 tenant 各自要 bulk-build，wiki 的「跨 tenant 知識整合」初衷會打折。

**這是 wiki 不能升 default 的硬阻塞點**。

### 2. Page synthesis 噪音「焊」進 wiki

題目：「有哪些 [取得] 方式」

Wiki 答案：列出方式，但其中一行夾雜 `الالكتروني the electronic ticket` — 阿拉伯文 + 英文混進中文答案。

這不是 retrieval 失敗。是 **bulk-build 階段** small LLM model 在某次 page synthesis 時引入了多語言污染，污染寫進了 page markdown，後續每個 query 都會原樣抄出來。

特性：

- 噪音「焊」在 wiki 上，每次 query 都重現
- 比 Hybrid 偶發性 hallucination 更難偵測 — 因為是 deterministic
- Confidence 可能很高（因為 wiki 自己沒矛盾）

修：bulk-build 加 lint pass，檢查每篇 markdown 是否包含預期語系外的字元 / 重複條目 / 空 page。Karpathy 的 LLM Wiki ops 流程裡 lint 是 first-class step，但目前實作裡還沒做 nightly lint。

### 3. Paraphrase over-simplification

短 paraphrase 問題（例：「[X] 怎麼做」）上，Wiki 傾向給單句答案，丟掉 Hybrid 會列的限制條件（A、B、C 三個 exception）。

可能根因：

- `WIKI_ANSWER` prompt 模板鼓勵簡潔
- 遇到 paraphrase（GT 也很短）時 mirror GT 的簡潔度
- Hybrid 的 chunk 直接餵進 persona prompt，persona 自然能條列限制

表面上 wiki 沒答錯，但 recall 缺很大。**這是更隱性的失敗** — 不會被 binary accuracy 捕捉到，要看 fact-point recall 才看得到。

修：`WIKI_ANSWER` 加 explicit instruction「列出所有相關限制」；或讓 intent classifier 多 emit 一個 `mode_preference` 欄位，paraphrase intent 直接路由到 hybrid。

---

## 路由建議

| 場景 | 推薦 mode | 理由 |
| --- | --- | --- |
| 短 / 直接 FAQ | Hybrid | 快、便宜、retrieval 已足夠 |
| 需要列出條件的 paraphrase | Hybrid | Wiki 在本次測試常給過簡答案 |
| 多文檔 synthesis（「最近有什麼變動」、「跨頁綜合」） | 理論上 Wiki 強，本次 13 題沒覆蓋 | 需要新增 ground truth 才能驗證 |
| 跨 tenant 比較 | **Hybrid only** | Wiki 目前的 page grouping 會跨 tenant 混 |
| Out-of-scope deflect | 任一（Wiki 略快） | 兩邊都正確拒答 |
| 高 confidence + 事實敏感（政策、限制） | Hybrid + 人工審 | Wiki 有 high-conf-on-wrong 風險 |

**Default 維持 Hybrid**，Wiki 留作 per-request `rag_mode=wiki` 覆寫。下一節給「先在 Hybrid 上試這些」的實際清單。

---

## 全面採用 LLM-Wiki 之前 — 先試試把 Hybrid 調好

在這次測試裡，Hybrid 已經 13/13。如果你正在考慮從 Hybrid 換到 LLM-Wiki，先停一下 — Wiki 想帶來的好處（更好的 cross-reference、知識 compounding），其實有相當程度可以在 Hybrid 上拿到，而且代價低得多。按優先序：

1. **加 Cross-encoder reranker** — Hybrid + Cohere Rerank v4.0 在公開 benchmark 上能把 Recall@5 從 ~0.7 推到 ~0.82，是最 cost-effective 的下一步。前文 [BM25 to Corrective RAG benchmark](/blog/2026/bm25-to-corrective-rag-benchmark/) 有完整數字
2. **Contextual retrieval (Anthropic 2024)** — chunk embedding 時把 doc-level summary prepend 進來，補回 chunk 失去的上下文。「不換 architecture 但補回 wiki 想要的 cross-reference」的最低成本路徑
3. **Intent-aware routing** — 像[前一篇 multi-task intent classifier](/blog/2026/multi-task-intent-llm/) 描述的，把 query intent + temporal + cardinality 一次解析，讓不同 intent 走不同檢索分支或 default window
4. **Metadata filters 切到 tenant 維度** — 多 tenant 系統下，retrieval 階段就該按 tenant filter；不要靠 LLM 在 generation 階段判斷事實邊界
5. **RRF k 參數調校** — 標準預設 k=60；BM25 / dense margin 落差大時，調 k=30-100 區間實測 hit ratio 變化

上面五條跑完還不夠的話，再考慮 LLM-Wiki — 但**至少要先補完三個 wiki failure mode**（順序與本文 §「三個 Wiki failure mode」相同）：

- 跨 tenant 資料污染（page synthesis 沒帶 tenant filter）
- Page synthesis lint pass（偵測非預期語系字元 / 重複條目 / 空 page）
- Paraphrase over-simplification（ANSWER prompt 加 explicit「列出限制條件」instruction）

---

## 結論一句

LLM-Wiki 的概念在 idea 層很漂亮 — 把 bookkeeping 從人類手裡轉給 LLM，知識隨時間 compound — 但 production 評測指出三個未解決的工程問題（multi-tenant、language pollution、paraphrase over-simplification）；在這些修完之前，Hybrid 仍是 default，Wiki 是 opt-in。

---

## References

- [Karpathy — LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) — 概念來源、ingest / query / lint 三個 ops、index.md / log.md 兩個導航檔
- [Vannevar Bush — As We May Think (1945)](https://www.theatlantic.com/magazine/archive/1945/07/as-we-may-think/303881/) — Karpathy 引述的 Memex 原型
- [qmd — local markdown search engine with hybrid BM25 + vector](https://github.com/tobi/qmd) — Karpathy 推薦的 wiki 搜尋工具
- 自家 [LLM 多任務輸出：把 temporal date-range 解析合併進 intent classifier](/blog/2026/multi-task-intent-llm/) — `mode_preference` 欄位的 pattern 同源

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
