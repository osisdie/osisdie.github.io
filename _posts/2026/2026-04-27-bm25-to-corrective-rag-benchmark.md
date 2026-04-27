---
layout: post
title: "從 BM25 到 Corrective RAG：一篇 Text + Table benchmark 的精讀筆記"
date: 2026-04-27 10:00:00 +0800
description: "arXiv:2604.01733 在 T²-RAGBench 23,088 筆財務 QA 上 benchmark 九種檢索策略。本文精讀重點：為什麼 Hybrid + Rerank R@5=0.816 領先 Hybrid RRF 0.695、為什麼 BM25 在金融文件上贏過 dense embedding、以及 CRAG 為何意外輸給單純 hybrid fusion。"
tags: rag retrieval bm25 corrective-rag reranking evaluation paper-review ai
featured: true
og_image: /assets/img/blog/2026/bm25-to-corrective-rag-benchmark/bm25-to-corrective-rag-benchmark-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/bm25-to-corrective-rag-benchmark/bm25-to-corrective-rag-benchmark-architecture.png" class="img-fluid rounded z-depth-1" alt="From BM25 to Corrective RAG — Recall@5 staircase across nine retrieval strategies on T²-RAGBench" caption="One Staircase, Five Categories — 三張 takeaway 卡片配上 Recall@5 的實際數字長條" %}

> **Abstract** — Akarsu, Karaman & Mierbach (arXiv:2604.01733, 2026.04) benchmark nine RAG retrieval strategies on T²-RAGBench, a 23,088-query financial QA corpus over 7,318 text-and-table documents. The headline result is a clean staircase: **Hybrid + Cohere Rerank reaches Recall@5 = 0.816 and MRR@3 = 0.605**, beating unranked Hybrid RRF by +12.1pp and +17.2pp respectively. Three findings deserve special attention. First, **BM25 outperforms `text-embedding-3-large` on every metric except Recall@20**, challenging the assumption that semantic search universally dominates lexical matching on domain-specific text. Second, **CRAG underperforms simple Hybrid RRF** (R@5 = 0.658 vs 0.695) — adaptive query rewriting cannot substitute for the complementary signal of sparse + dense fusion. Third, **HyDE is counterproductive** for precise numerical queries — the LLM-generated hypothetical document drags the embedding away from the true context. The paper closes with a five-step decision framework for production RAG systems, grounded in cost-accuracy trade-offs rather than abstract architecture.

承接上一篇 RAG Pipeline 的實作，今天換個方向 —— 純粹讀一篇剛上 arXiv 的 benchmark，看作者在一個比 FAQ 更難的 text + table 設定下，把九種主流檢索策略放在同一張對照表裡之後，會浮出哪些反直覺的結論。

---

## 1. 為什麼要讀這篇

在生產的 RAG 系統裡，`Recall@5 = 0.6` 跟 `Recall@5 = 0.8` 之間的差距，幾乎決定了下游 LLM 是回答得出來、還是只能去問人。但要把「換哪一種 retriever」這件事說清楚，需要在**同一個資料集、同一個評估腳本**底下做橫向比較 —— 而開源社群這方面的 systematic benchmark 其實少得驚人。

這篇 paper 的價值在三個點：

1. **資料集是 text + table 混合的 financial QA**，不是 FAQ 也不是 wiki 搜尋。文件平均 920 tokens，每篇都帶 markdown 表格。「2019 年的淨利」這類問題的答案常常**藏在某一格 cell 裡**，光靠 paraphrase 抓不到。
2. **比較範圍涵蓋從 BM25 到 CRAG 的九種策略**，分屬 single-method、query expansion、index augmentation、adaptive、fusion 五大類。對於想升級 retriever stack 的工程師，這是一張現成的決策圖。
3. **重要發現很多反直覺**。例如 dense embedding 不是萬靈丹、CRAG 在強的 baseline 上反而退步、HyDE 對精確數值問題有副作用。這些是教科書不會直接寫、但部署後才會痛的事。

---

## 2. 評測設計

### 2.1 資料集：T²-RAGBench

論文整合三個既有 financial QA dataset 成 **T²-RAGBench**：

| 子集 | 來源 | Pairs | 重點挑戰 |
| --- | --- | --- | --- |
| **FinQA** | EMNLP 2021 | 8,281 | 數值推理 |
| **ConvFinQA** | EMNLP 2022 | 3,458 | 多輪對話 |
| **TAT-DQA** | ACL 2021 | 11,349 | 表格 + 文字混排 |

合計 **23,088 questions / 7,318 documents**，每篇 document 平均約 920 tokens，內容是 SEC filings 與 annual reports，含 markdown-formatted 表格。

值得注意：原始 dataset 是 oracle-context 設定（題目本來就附了正確 doc），不能直接拿來 evaluate retrieval。論文用 Llama 3.3-70B 把每題重寫成 **context-independent** —— 加上 company name、sector、reporting year，使同一題在任何 doc 集合都有唯一正解。重寫後的 inter-annotator agreement 是 Cohen's κ = 0.58，比原 7.3% context-independent 顯著拉高到 83.9%。

### 2.2 九種策略，五個類別

主結果見 Table I。下表把九種方法按類別整理（數字為 T²-RAGBench 全集 Recall@5）：

| 類別 | 方法 | 代表模型 / 工具 | R@5 |
| --- | --- | --- | --- |
| **Single-method** | BM25 (sparse) | Okapi · `rank_bm25` · k₁=1.2, b=0.75 | 0.644 |
| | Dense | OpenAI `text-embedding-3-large` (3,072 dim) · FAISS IndexFlatIP | 0.587 |
| **Query expansion** | HyDE | GPT-4.1-mini 生成假 doc → embed | 0.544 |
| | Multi-Query + RRF | GPT-4.1-mini 生成 3 個改寫 → 各自 dense → RRF 合併 | 0.640 |
| **Index augmentation** | Contextual Dense | GPT-4.1-mini 為每 chunk 生 doc-level summary 再 embed | 0.615 |
| | Contextual Hybrid | Contextual Dense + BM25 + RRF | 0.717 |
| **Adaptive** | CRAG | top-5 → GPT-4.1-mini 三分類 grader → 必要時 rewrite + retry | 0.658 |
| **Fusion** | Hybrid RRF | BM25 + Dense via RRF (k=60) | 0.695 |
| | **Hybrid + Cohere Rerank** | Hybrid RRF top-50 → Cohere Rerank v4.0 Pro | **0.816** |

指標除了 Recall@k（k ∈ {1,3,5,10,20}），還報 MRR@k、nDCG@k、MAP；end-to-end 用 Number Match (NM) 容差 ε=10⁻². Statistical testing 用 paired bootstrap B=10,000、Bonferroni 校正、p<0.001。

> **讀表小提醒** — Multi-Query 在 R@5 看起來只比 BM25 低 0.4pp，但在 MRR@3 上差距更明顯（0.397 vs 0.411）。論文偏好 Recall@5 作為主軸是合理的：下游 LLM 會看 top-K，但其中前 1-3 名的位置很關鍵。

---

## 3. 主結果：為什麼 Hybrid + Rerank > Ctx Hybrid > Hybrid RRF

這節是全文的核心。把三個「都被叫 hybrid」的方法擺在一起比，差距並不直觀；論文用同一份資料、同一份程式給出明確 ordering：

| 排名 | 策略 | R@5 | MRR@3 | 與下一名差距 |
| --- | --- | --- | --- | --- |
| 1 | **Hybrid + Cohere Rerank** | **0.816** | **0.605** | +9.9pp R@5 |
| 2 | Contextual Hybrid | 0.717 | 0.454 | +2.2pp R@5 |
| 3 | Hybrid RRF (vanilla) | 0.695 | 0.433 | — |

論文用「+17.2pp MRR@3 / +12.1pp Recall@5」作為 reranker 的 headline 收益（與 unranked hybrid 比較）。看似只是兩階段加一層的事，但**為什麼這條 ordering 是這個方向**比數字本身更值得搞清楚：

### 3.1 RRF 的資訊損失

Reciprocal Rank Fusion 的公式：

$$
\mathrm{RRF}(d) = \sum_i \frac{1}{k + r_i(d)}
$$

`r_i(d)` 是 doc `d` 在第 i 個 retriever 的 rank、`k=60` 是 smoothing。表面上「結合 BM25 與 dense」很美，實際上**這個融合只看 rank ordinal、把 score magnitude 全棄掉了**。

舉例：對某個 query，BM25 給文件 A `score=0.95`、文件 B `score=0.40`；dense 給 A `score=0.40`、B `score=0.91`。在「BM25 與 dense 互相 disagree」這種正是裁判最關鍵的場景下，RRF 看到的只是「兩邊都 rank=1 vs rank=2」，**真正能告訴系統「BM25 對 A 強烈確信」的 score margin 完全消失**。

這也呼應論文 ablation 裡的另一個發現：用 Convex Combination (`α·BM25 + (1-α)·dense`，α=0.5) 取代 RRF，R@5 從 0.695 升到 0.726。這 +3.1pp 完全來自「保留分數 magnitude」這件事。RRF 並非沒缺點，只是它 unsupervised 又 robust，作為 default 仍然合理。

### 3.2 Contextual Hybrid 補回的是 chunk 上下文，不是 query–doc 互動

Contextual Retrieval（Anthropic 2024 提出）在 indexing 時，請 LLM 為每個 chunk 寫一段 doc-level summary（公司名、會計期間、關鍵指標），prepend 到 chunk 後面再進 embedding。

它修補的是 chunking 帶來的「chunk 在脫離原 doc 之後失去語意」這個老問題。在 paper 裡，**Contextual Dense 比純 Dense 高 +2.8pp R@5；Contextual Hybrid 比 Hybrid RRF 高 +2.2pp R@5**。這個增幅是 indexing-time 一次性成本（每 doc 一次 summary 呼叫，沒有 per-query overhead），所以 cost-effective。

但要注意：這個改良只發生在「**embedding 階段**」—— query 與 chunk 仍然各自獨立 embed，比對只有 `cos(query_emb, chunk_emb)` 一次性。Query 與 doc 的細粒度互動沒被加入。

### 3.3 Cross-encoder rerank：stage 2 的 attention

Cohere Rerank v4.0 Pro 是 cross-encoder：把 `(query, doc)` 拼成單一序列、進 transformer，attention 在 query token 與 doc token 之間自由互動，輸出 query-aware 的 pointwise score。

代價是 **不能 ANN 搜尋**（每筆 query × candidate 都要跑一次 transformer），所以只能放 stage 2、對 top-50 重評。論文 ablation 顯示：

| 候選數 → Top-N | R@5 | 解讀 |
| --- | --- | --- |
| 20 → 10 | 0.458 | 候選太少，gold doc 常常根本不在 pool |
| 50 → 5 | 0.816 | 主結果 |
| 50 → 10 | 0.826 | 取多 5 名、邊際小升 |
| 50 → 20 | ~0.870 | 進入 marginal gain 區 |
| 100 → 10 | 0.888 | 候選翻倍，再升 +6pp |

**重點**：若 stage-1 召回不夠好，再強的 reranker 也救不回來；50 candidates 是這個 benchmark 的實務 sweet spot。

> **Production 提醒** — 論文寫得很清楚：在 300K tokens / min 的 Cohere endpoint 限速下，跑完整 23K query 約一小時。對 production 來說，per-query 加 200-300 ms 重排延遲、換 +12.1pp Recall@5，是少數真的「值得多花的 latency」。

---

## 4. 表格資料的特殊 finding

T²-RAGBench 的核心挑戰是 **table structure mismatch**。論文 §IV-D 對 100 筆 hybrid RRF 失敗 case 做 error analysis：

| 失敗類別 | 占比 |
| --- | --- |
| **Table structure mismatch** | **73%** |
| Numerical reasoning | 20% |
| Vocabulary mismatch | 5% |
| Ambiguous query | 1% |
| Long document | 1% |

七成以上的失敗是「答案藏在表格 cell、但 embedding 沒辦法把 cell 拆解成連續文字」。具體例子：query 問「What was net income in 2019?」，文件用 markdown table 形式呈現財報，"net income" 跟 "2019" 出現在**不同 cell**，標準 embedding 把整段 markdown 當一團處理就抓不到對應關係。

per-subset 結果（Table II，全用 hybrid 方法）：

| 子集 | R@5 | 性質 |
| --- | --- | --- |
| ConvFinQA | 0.754 | 最簡單 — 多輪對話帶 context |
| FinQA | 0.737 | 中等 — 數值推理 |
| **TAT-DQA** | **0.647** | **最難 — 表格密度最高** |

在 TAT-DQA 上，hybrid fusion 比 BM25 多 +8.1pp R@5 —— 是 hybrid 在三個子集裡 **最大** 的相對改進。這說明「混合 lexical + semantic 的價值在 table-heavy 文件上特別明顯」。換個角度看：dense alone 在 TAT-DQA 表現最差（0.549），BM25 反而 hold 住部分數字 exact match，**fusion 之所以有效，是因為兩條路徑的 failure mode 不重疊**。

> **延伸思考** — Text-only embedding 對 tabular 的 degradation，本質上跟 OCR 後純文字流失 schema 同類。下次設計 ingestion pipeline 看到 markdown 表格，要警覺「embedding 看到的 vs 你以為它看到的」之間有顯著落差。

---

## 5. CRAG 的 self-correction loop 解析

CRAG（Yan et al. 2024, arXiv:2401.15884）的設計直覺：retrieval 不一定每次都對，那就讓系統**自己判斷對錯**，不行再 retry。論文用三個元件實作：

1. **Retrieval Grader** —— top-5 retrieved doc 進 GPT-4.1-mini，每篇被分類成 `RELEVANT` / `AMBIGUOUS` / `IRRELEVANT`
2. **Confidence Decision** —— 若全部都被標 `AMBIGUOUS` 或 `IRRELEVANT`，rewrite query
3. **Re-retrieval** —— 用改寫後 query 再撈一次，最後取兩輪 union 的較佳結果

```python
def crag(query: str) -> List[Doc]:
    docs = hybrid_rrf_search(query, top_k=5)
    grades = [grader(query, d) for d in docs]   # RELEVANT / AMBIGUOUS / IRRELEVANT

    if any(g == "RELEVANT" for g in grades):
        return docs                              # 信心夠，直接用

    new_query = rewriter(query, docs, grades)    # 否則改寫
    docs2 = hybrid_rrf_search(new_query, top_k=5)
    return better_of(docs, docs2)
```

聽起來合理。但 paper 給的數字很尷尬：

| 方法 | R@5 | 與 BM25 (0.644) 差距 |
| --- | --- | --- |
| BM25 (baseline) | 0.644 | — |
| CRAG | 0.658 | +1.4pp |
| Hybrid RRF | 0.695 | +5.1pp |
| Hybrid + Rerank | **0.816** | **+17.2pp** |

**CRAG 比單純 Hybrid RRF 還低 3.7pp**。論文同時揭露：23,088 query 裡有 14,569 筆（**63%**）觸發了 CRAG 的 correction pathway —— 並非 grader 沒在動，而是「**動了、改寫了、retry 了，但救不回複雜的 retrieval 失敗**」。

論文結論很直白：

> CRAG falls short of simple hybrid fusion (0.695), suggesting that **query rewriting alone cannot match the complementary strengths of sparse and dense retrieval**.

這個結果重新校準了 CRAG 的定位：**它的價值取決於 baseline 強度**。在 single-method retriever 上加 CRAG，可以 +1.4pp 救一點；但若你的 baseline 已經是 hybrid fusion，CRAG 的 correction loop 邊際收益反而是負的 —— 因為 query rewriting 沒辦法替你引入新的訊號軸（lexical vs semantic），它只是在同一個訊號軸上重新表述。

> **這給工程師的提醒** —— 看到一個會「self-correct」的元件不要直接信，要看它**到底在 correct 什麼**。CRAG correct 的是 query phrasing；如果你的失敗 mode 是 retrieval channel 缺一條（例如沒 BM25），CRAG 救不了，先補 channel 才對。

---

## 6. 五個給 practitioners 的建議

論文 §V 給出明確 decision framework，以下逐條搭配我的解讀：

### 6.1 從 hybrid retrieval 開始，作為 minimum viable baseline

> Recommend hybrid retrieval (BM25 + dense via RRF) as the minimum viable baseline for any RAG deployment.

最大改進出現在 TAT-DQA（+8.1pp R@5 over BM25）—— 表格密度高的 corpus 收益最大。**我的解讀**：「先 single dense」這個做法的時代正在過去，hybrid 已經是 default 而不是 advanced；連用 BM25 + RRF 的 ops cost 都很低，沒理由不做。

### 6.2 加 cross-encoder reranker，獲得最大單一改進

> Adding Cohere Rerank v4.0 Pro yields +12.1pp R@5 and +17.2pp MRR@3. The clear recommended architecture for production RAG on text-and-table documents.

Cost：~300K tokens/min 的 endpoint 處理整個 23K-query benchmark 約 1 小時。**我的解讀**：reranker 是 RAG 升級路上 ROI 最高的單一動作 —— 比繼續放大 stage-1 model size、比加更多 query rewriting trick 都實在。`bge-reranker-v2-m3` 這類 open-source 替代品也值得評估，預算敏感的話。

### 6.3 在 indexing 時做 contextual retrieval

> Apply contextual retrieval at indexing time for consistent moderate gains at one-time cost.

對 dense +2.8pp、對 hybrid +2.2pp R@5，且**完全是 index-time 成本**。**我的解讀**：這是 cost-asymmetric 的好交易 —— 用一次性 LLM 呼叫換永久的 retrieval quality 提升。實作門檻：要小心 prompt 跑出來的 doc-level summary 不要過長（會稀釋 chunk 本身語意），論文用的是 GPT-4.1-mini @ temperature 0。

### 6.4 對精確數值 / 實體查詢避開 HyDE

> HyDE consistently underperforms vanilla dense retrieval. Avoid HyDE for domains where factual precision dominates over semantic similarity.

HyDE R@5 = 0.544，比 vanilla dense 0.587 還低 4.3pp。原因是 LLM 生成的 hypothetical document 會**用 plausible 但錯誤的 financial figures 把 query embedding 拉偏**。**我的解讀**：HyDE 設計時的主要 use case 是「query 短、語料長」的搜尋（例如 web search），對精確 factual QA 不只沒幫助、是負收益。同一個 LLM 預算改去做 contextual retrieval（§6.3），ROI 高得多。

### 6.5 在自家資料上 evaluate，不要相信 MTEB / BEIR ranking

> MTEB/BEIR rankings do not predict financial retrieval performance.

這是論文最被低估的一條。`text-embedding-3-large` 在 MTEB 排名很前面，但在這個 benchmark 上仍然輸給 BM25。**我的解讀**：domain-specific corpus 的特徵很容易讓通用 leaderboard 失準。建立一份內部 golden set（哪怕只有 50-100 筆），跑一次 sweep，比看 leaderboard 有意義得多 —— 這比直接 pin 論文的某個策略 ranking 都更接近 production reality。

### 6.6 限制 / 未來方向（論文自己列的）

論文坦白列了五個限制：

1. T²-RAGBench 只覆蓋金融 —— 對 scientific papers / medical records 的 generalizability 未知
2. 答案全是數值 —— 偏向 Number Match 評估，free-form 生成品質沒覆蓋
3. Whole-document retrieval（avg 920 tokens），沒做 chunking ablation
4. 只用單一 embedding model（`text-embedding-3-large`），多 model 比較留給未來
5. API-based model 對 reproducibility 是風險（廠商 silently 升級會影響結果）

未來工作列了 ColBERT late-interaction、RAPTOR tree-based retrieval、chunking strategy ablation、跨非金融 domain 等方向。

---

## 7. 小結

把九種策略放在同一張表上比，最值得記住的不是「Hybrid + Rerank 最高」這件事 —— 那其實意料之中。值得記住的是三組反直覺的數字：

- **0.644 vs 0.587** —— BM25 打贏 `text-embedding-3-large`，在每個 metric 上、除了 R@20 才打平。「semantic > lexical」這個假設，在 domain-specific 文件上不成立
- **0.658 vs 0.695** —— CRAG 輸給單純 Hybrid RRF，63% query 觸發了 correction pathway 也救不回來。query rewriting 沒辦法替代 fusion 帶來的訊號軸互補
- **+12.1pp Recall@5** —— 加一層 cross-encoder reranker 帶來的單點改進，比所有其他方法的累加還大；stage 2 的 query–doc full attention 是 stage 1 任何優化都換不來的東西

這篇 paper 真正貢獻的是一個 **可重跑的程式碼基礎**（[zenodo.19382814](https://doi.org/10.5281/zenodo.19382814)）—— 對於任何要為自己 corpus 做類似 sweep 的團隊，這比 abstract 結論更有用。把它當「現成評估腳手架」而不是「結論套用」，價值就回到讀者自己手上。

---

## References

- **Akarsu, Karaman & Mierbach, 2026** — *From BM25 to Corrective RAG: Benchmarking Retrieval Strategies for Text-and-Table Documents.* [arXiv:2604.01733](https://arxiv.org/abs/2604.01733). EACL 2026 (T²-RAGBench dataset originally from Strich et al., EACL 2026)
- **Yan et al., 2024** — *Corrective Retrieval Augmented Generation.* [arXiv:2401.15884](https://arxiv.org/abs/2401.15884) — 原 CRAG 論文
- **Cormack et al., 2009** — *Reciprocal Rank Fusion outperforms Condorcet and individual rank learning methods.* SIGIR 2009 — RRF 數學定義
- **Anthropic, 2024** — [Introducing Contextual Retrieval](https://www.anthropic.com/news/contextual-retrieval) — Contextual Hybrid 的原始作法
- **Cohere, 2025** — [Rerank 4.0 Pro](https://cohere.com/blog/rerank-4) — 論文使用的 reranker
- **Gao et al., 2023** — *Precise Zero-Shot Dense Retrieval without Relevance Labels.* [arXiv:2212.10496](https://arxiv.org/abs/2212.10496) — HyDE 原 paper
- **Code & data** — [Akarsu, Mierbach & Karaman, 2026](https://doi.org/10.5281/zenodo.19382814) — 評測 pipeline 全套釋出

---

> Source: [osisdie/osisdie.github.io](https://github.com/osisdie/osisdie.github.io) — PRs and Issues welcome!
