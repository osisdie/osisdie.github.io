---
layout: post
title: "DGX Spark + Ray Serve + vLLM：拿 6.7× TTFT、4.2× decode 的 tuning playbook"
date: 2026-05-10 18:00:00 +0800
description: "兩台 NVIDIA DGX Spark (GB10) 撐 30+ agent 串流，Ray Serve LLM 強制一機一模型反而促成簡潔架構；Tier-1 engine_kwargs 拿 6.7× TTFT、2.76× throughput @ c=16，Tier-2 dense→MoE 拿 4.2× decode speedup。"
tags: llm inference vllm ray-serve gpu performance ai infrastructure
featured: false
og_image: /assets/img/blog/2026/dgx-spark-ray-serve-tuning/dgx-spark-ray-serve-tuning-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/dgx-spark-ray-serve-tuning/dgx-spark-ray-serve-tuning-architecture.png" class="img-fluid rounded z-depth-1" alt="Ray Serve + vLLM on 2× DGX Spark — 2 head-to-head GB10 nodes with three tuning-lever chips (Tier-1, Tier-2, Gotcha)" caption="Ray Serve + vLLM 在 2× DGX Spark 上的部署形狀，與三層 tuning lever。" %}

> **本文用語**：把 LLM serving 的調整分兩層 ——
>
> - **Tier-1 = config-only 調整**：只動 vLLM 的 `engine_kwargs`（prefix cache、KV dtype、batch 上限等），**不換 model、不動架構、quality 風險近 0**
> - **Tier-2 = model identity 改動**：換 model（dense → MoE）或量化權重（FP16 → FP8），**需要重跑下游 eval 確認 quality 沒退**
>
> 順序很重要：**Tier-1 先做完，再考慮 Tier-2**。Tier-2 量出來的數字會被「Tier-1 沒做的部分」污染。

> **TL;DR**：在兩台 **NVIDIA DGX Spark（GB10 Grace Blackwell, 128 GB unified memory）**上跑 **Ray Serve LLM + vLLM + LiteLLM + nginx**。Ray Serve LLM 內部硬寫 `num_gpus=1.0`、無視 actor option，強制「一機一模型」；這個約束在 < 5 節點規模反而促成最簡潔的部署。**Tier-1**（純 `engine_kwargs`）拿 **6.7× TTFT cached / 2.76× throughput @ c=16**；**Tier-2**（dense → MoE 換模型）拿 **4.2× decode（277 → 66 ms/token）**。

前兩篇談 RAG（[Hybrid vs LLM-Wiki 13 題 A/B](/blog/2026/hybrid-vs-llm-wiki-eval/) 與 [一次 LLM call 做兩件事](/blog/2026/multi-task-intent-llm/)），這篇換到下游：**承接 agent 流量的 LLM serving 怎麼讓兩台機台撐 30+ 並行 agent 串流**。重點不在「換更貴的硬體」，而是把現有硬體的 utilization 推到合理上限。

---

## 1. 整體架構

| 層 | 元件 | 職責 |
| --- | --- | --- |
| Edge | nginx | TLS 終結、vhost routing |
| Gateway | LiteLLM | model registry、tenant routing、OpenAI-shape adapter |
| Serving | Ray Serve LLM `:8000` | replica 管理、OpenAI-compatible endpoint |
| Engine | vLLM | KV cache、batching、speculative decoding |
| Hardware | 2× DGX Spark (GB10) | 1 顆 GB10 / 128 GB unified LPDDR5X / NVLink-C2C 物理橋接 |

**網段切兩條**：

- **10 GbE**：控制 / ingress 流量（給使用者、應用後端走）
- **RoCE 192.168.200.x/24**：後端 LLM 流量（避開 corp network 競爭）

**模型權重**：HuggingFace cache **bind-mount 到 host**——容器重啟不重抓，第一次 download 也避開了容器內 ~473 KB/s 的 throttle。

**模型選擇**：用 `SPARK_MODEL=...` env var 切，**同一份 docker-compose.yml 部多 node**，每個 node 跑不同 model。

> **為什麼是 Docker Compose 而不是 Kubernetes？**——當 cluster < 5 nodes、model 數 ≤ node 數、ops 團隊規模小時，Compose 的 declarative coverage 已經夠了。K8s 的 ROI 要等到滾動更新、autoscaling、跨 zone failover 變剛需才划算。

---

## 2. 為什麼是「一機一模型」（其實是 Ray Serve LLM 強制的）

最不直覺的設計選擇來自一個 framework gotcha：

> **發現**：`LLMConfig.deployment_config.ray_actor_options.num_gpus=0.5` 看起來是要 fractional GPU，但 Ray Serve LLM 內部的 vLLM engine wrapper 在啟動 actor 時還是 claim 整顆 GPU。Ray docs 沒寫，要看 `vllm_serve` source 才知道。

也就是說：**就算你把 actor option 設成小於 1，實際上仍然是一顆 GPU 一個 model**。

這個約束有兩面：

**強迫面**：

- 30B-class dense model FP16 weight ≈ 60 GB
- KV cache + activation 留 30–50 GB（看 `max_model_len` 與 batch size）
- 兩個 30B 同 node ≈ 114 GB / 121 GB 可用 → **沒留 KV cache room**
- 即使 Ray Serve LLM 開放真正的 fractional GPU，這個 memory math 也撐不起兩個 30B model 共存

**好處面**：

- **Predictable per-model latency**——沒有跨 model 的 GPU 排隊
- **Cost attribution 直接**——某 model 的成本 = 所在 node 的成本
- **Failure isolation**——一個 model OOM 不影響另一個
- **Ops 簡單**——不需要 scheduler、不需要 priority class、不需要 gang scheduling

當需要 4 個 model 時，加 2 台 node 而不是把它們塞同一台。**規模小的時候，這是優點不是缺點**。

---

## 3. 優點：這個架構效率高在哪

1. **Always-on, zero cold-start**——agent loop 來流量馬上吃，不會被 model 載入的 60–120 s 卡住
2. **Bind-mounted weight cache**——容器升級不重抓 model（GB 級下載一次省一輩子）
3. **Per-model env-var selection**——`SPARK_MODEL=...` 同一份 docker-compose.yml 部多 node
4. **RoCE 後端網段**——LLM 流量不擠 corp 網段，p95 抖動明顯收斂
5. **LiteLLM 中間層**——model registry 與 OpenAI-shape adapter 集中管，新增 model 不動 nginx 與應用層
6. **Tier-1 engine_kwargs 是 composable**——每個參數獨立貢獻，可以一條一條開、量、確認沒 regression

---

## 4. 缺點：這個架構效率低在哪

1. **沒 autoscaling**——半夜流量低也吃滿電；單機台等於最低成本下限
2. **Memory-bandwidth bound**——GB10 unified memory 拉不動 30B FP16 dense（~3–6 t/s decode 不靠 batching 救不回來）
3. **30B 級 model 不能擠同 node**——想跑 4 個 model 就要 4 個 node
4. **Docker Compose 沒滾動更新**——replace container 期間有 ~5–15 s 下線（healthcheck 切換）
5. **NVLink-C2C 沒被拿來用**——256 GB 合併 memory pool 理論存在，但跨 node tensor parallelism 走 RoCE 的 inter-token 通訊延遲蓋過收益

第 5 點值得多說一句：**NVLink-C2C 的物理頻寬高，但 vLLM 的 tensor parallelism 對「inter-token 通訊延遲」極度敏感**——只要每個 token 都要跨 node 同步一次，總成本就會被那個 round-trip 主導。30B-class 在單顆 GB10 已經跑得起來，跨節點切只會變慢不會變快。

---

## 5. Tier-1：純 config 調 engine_kwargs，6.7× TTFT / 2.76× throughput

純 `engine_kwargs` 改動，不換 model、不換 hardware、不改架構。每條都是 vLLM 已經實作的 flag。

```python
TIER1_ENGINE_KWARGS = dict(
    enable_prefix_caching=True,        # agent system prompt 重複命中 cache
    kv_cache_dtype="fp8",              # 2x batch capacity
    enable_chunked_prefill=True,       # p95 latency under concurrent load
    max_num_seqs=64,                   # 30+ concurrent agent streams
    max_num_batched_tokens=8192,
    speculative_config={
        "method": "ngram",
        "num_speculative_tokens": 5,
    },
)
```

每個 lever 各自的貢獻與適用場景：

| Lever | 個別貢獻 | 為什麼有效 |
| --- | --- | --- |
| `enable_prefix_caching=True` | TTFT 30–70% ↓ | agent loop 的 system prompt 永遠重，命中 cache 後 prefill 直接跳過 |
| `kv_cache_dtype="fp8"` | 36 → 104 t/s @ c=16（2.87×） | KV cache 半精度，batch capacity 翻倍 |
| `enable_chunked_prefill=True` | p95 latency 抑制 | 並行下 prefill 不卡 decode 的 forward pass |
| `max_num_seqs=64` | 撐 30+ agent 並行 | 上限拉高才能讓 batching 發揮 |
| ngram speculative (n=5) | repeated-token 加速 | structured output / tool call 重複 token 多 |

**Routing 一併處理**：LiteLLM 從 `shuffle` 換 `least-busy`——不花成本但拉平 p95。

**疊加結果**（c=16 production-shape workload）：

- Cached-prompt **TTFT：6.7×**
- Aggregate **throughput：2.76×**
- Short-prompt regression：**0**

最後一條最關鍵：**Tier-1 是無痛升級**。短 prompt、單 user、cold cache 等場景沒有任何 regression，所以可以放心整批開。

> **警告（vLLM 0.19）**：啟用 ngram speculation 時 async scheduling 會被 disable。Agent workload 影響不大（agent loop 本來就 sync wait response），但 streaming-heavy use case 要實測。

---

## 6. Tier-2：換 model identity，4.2× decode

Tier-1 跑完還要更快，**兩條路擇一**：

### Option A：FP8 weight quantization（llmcompressor）

把 dense FP16 權重壓成 FP8 → memory 半 → 可以拉更大 batch。

- **風險**：quality regression（要重跑下游 eval）
- **適用**：原 model 已經在 production 驗證過、不想動 model identity 的場景

### Option B：Dense → MoE 換模型（本架構走這條）

把 **Gemma-4-31B dense** 換成 **Qwen-3-30B-A3B**——A3B 表示「activated params per token ≈ 3B」，**總參數 ~30B 但每 token 只活化 ~3B**。Memory footprint 接近，但 decode 的 FLOPs 大幅降低。

實測（同樣的 GB10、同樣的 c=16 workload）：

| 指標 | Gemma-4-31B (dense) | Qwen-3-30B-A3B (MoE) | Δ |
| --- | --- | --- | --- |
| Decode latency | 277 ms/token | 66 ms/token | **× 4.2** |
| Throughput @ production load | 1.0× | 3.0× | **× 3** |
| 256-token 端到端 | 70 s | 17 s | **× 4.1** |

**Tool-calling 副紅利**：Qwen-3 直接 emit OpenAI-compatible structured `tool_calls`；Gemma-4 emit 文字 marker 要自己寫 parser proxy。**換 MoE 順便簡化 application layer**——這條增益不在性能 metric 裡，但 ops 成本下降明顯。

> **重要順序**：Tier-2 不應該越過 Tier-1 先做——Tier-2 量出來的數字會被「Tier-1 沒做的部分」污染。先把 prefix cache、FP8 KV、chunked prefill 開好，再去評估換 model 的真實增益。

---

## 7. 還有哪些調整空間

讀者 actionable 的 7 條，依風險排序：

1. **Prefix cache hit rate observability**——加 metric export 看 agent loop 的真實 hit rate（猜測 > 60% 但沒量過，量了才知道 prefix cache 投資回報）
2. **HF download pipeline 自動化**——host bind-mount 解了 throttle，但 first-time download 還是要手動 `huggingface-cli download`，可以 script 化
3. **Speculative w/ draft model**（不只 ngram）——用 1B 級 draft model 預測，比 ngram 命中率高，但要多載一個 model
4. **Disaggregated prefill / decode**（vLLM 實驗中）——prefill node 跟 decode node 拆開，prefill 重 batch、decode 重 latency
5. **Ray Serve LLM 升級**——等上游釋出真正的 fractional GPU 支援，可以考慮 7B–13B 級 model 同 node 共享
6. **K8s + KubeRay**——規模上到 4+ node 後，Compose 的 ops 成本會超過 K8s 的學習曲線
7. **Cross-node tensor parallelism**——70B+ model 才有意義；目前 30B 級用 NVLink-C2C 反而吃虧

前三條是「現有架構就能做」；中間兩條要等上游；最後兩條是規模超過某個門檻才划算。

---

## 8. 結論：一個 GB10-class 的通用 playbook

- **Tier-1 一定先做**：config-only、不動 model 與架構、quality 風險近 0，可以一條一條開、量、確認沒 regression
- **Tier-2 是「架構選擇」題**：quantize 留原 model 可控（quality 風險自己擔）；MoE 直接拿 4× 但 quality 與 tool-calling shape 要重新 evaluate
- **Ray Serve LLM 的 `num_gpus=1.0` 強制 1-model-per-node**：這個 gotcha 把架構簡化成可預測的形狀，**規模小時這是優點**
- **不上 K8s 的時機**：< 5 node、model 數量 ≤ node 數量、ops 團隊規模小

如果你正在用任何 GB10 / B200-class 的單卡高記憶體 GPU 跑 open-weight LLM，這個 Tier-1 → Tier-2 progression 應該都適用。**先把 `engine_kwargs` 的低風險增益拿好，再決定要不要動 model identity**。

---

## 參考資料

- [vLLM Automatic Prefix Caching](https://docs.vllm.ai/en/latest/automatic_prefix_caching/apc.html)
- [vLLM FP8 KV Cache](https://docs.vllm.ai/en/latest/quantization/fp8_e5m2_kvcache.html)
- [vLLM Chunked Prefill](https://docs.vllm.ai/en/latest/usage/performance.html)
- [vLLM Speculative Decoding](https://docs.vllm.ai/en/latest/usage/spec_decode.html)
- [Ray Serve LLM Deployment](https://docs.ray.io/en/latest/serve/llm/serving-llms.html)
- [LiteLLM Router](https://docs.litellm.ai/docs/routing)
- [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)
- [Qwen-3 Models on HuggingFace](https://huggingface.co/Qwen)
- [llmcompressor (FP8 weight quantization)](https://github.com/vllm-project/llm-compressor)

延伸閱讀：

- 前篇 [Hybrid RAG vs LLM-Wiki：13 題 A/B 評測](/blog/2026/hybrid-vs-llm-wiki-eval/)——RAG retrieval 比較
- 兩篇前 [一次 LLM call 做兩件事——Multi-task intent classifier](/blog/2026/multi-task-intent-llm/)——agent 串流的「intent 解析」上游
