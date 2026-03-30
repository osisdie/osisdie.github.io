# IoT 1M Device Architecture — 技術選型規劃

## Context
用戶需要規劃一個支援 1M 現場設備的 IoT 架構，涵蓋：
- Python 後端（評估 free threading）
- 雲端/地端部署
- 即時設備狀態 monitoring（UI 顯示）
- 反向指令下發（UI → Device）
- E2E 通訊協定選型
- Sensor data event-driven 處理 + DB 選型
- Multi-tenancy（device ownership, RBAC, command authorization）
- Device identity & anti-spoofing（合法設備驗證）
- BFF (Backend for Frontend) 層設計

---

## 架構總覽

```
┌─────────────┐
│  1M Devices  │  MQTT v5 over TLS
│  (Sensors)   │
└──────┬──────┘
       │
┌──────▼──────┐
│    EMQX      │  MQTT Broker（3-5 node cluster）
│  (Erlang)    │  100M+ conn 實測、原生 clustering
└──────┬──────┘
       │ MQTT → Kafka bridge
┌──────▼──────┐
│  Redpanda    │  Event Streaming（Kafka API 相容）
│  (3-5 nodes) │  單節點 1M+ msg/sec、低尾延遲
└──────┬──────┘
       │
  ┌────┼────────────────┐
  │    │                 │
  ▼    ▼                 ▼
Benthos  FastStream      ClickHouse
(路由    (Python         (Warm 30-90d
 過濾)   業務邏輯)        分析查詢)
  │        │
  │        ▼
  │    TimescaleDB       S3 + Parquet
  │    (Hot 24-72h)      (Cold 長期歸檔)
  │
  ▼
┌──────────┐     ┌─────────┐     WebSocket     ┌──────────┐
│ FastAPI   │ ──► │  BFF    │ ◄──────────────► │ Dashboard │
│ Backend   │     │ (per UI)│                  │ Web/Mobile│
└──────────┘     └─────────┘                   └──────────┘
```

---

## 1. Python 後端：asyncio + 多進程（不用 free threading）

**結論：Free threading (PEP 703) 尚未 production-ready。**

| | 狀態 |
|---|---|
| Python 3.13t | 實驗性，單線程 5-10% 效能損失 |
| Python 3.14t (2026 Oct) | 仍標記 experimental，目標 <5% overhead |
| 正式 non-experimental | 預計 Python 3.16（~2028） |

**為什麼不適合此場景：**
- 1M 連線是 **I/O-bound**，asyncio event loop 就是為此設計的
- 生態系（SQLAlchemy、paho-mqtt、FastAPI）未經 no-GIL 審計
- C extensions 在無 GIL 下可能有 data race

**推薦架構：**
```
HAProxy / nginx (L4 load balancer)
  ├── Uvicorn worker 1 (asyncio + uvloop, ~50-100K conn)
  ├── Uvicorn worker 2
  ├── ...
  └── Uvicorn worker N (per CPU core)
      └── Redis/NATS for cross-process pub/sub
```

- 用 **uvloop** 替代預設 event loop（2-4x 效能提升）
- CPU-bound 工作（ML inference）用 `ProcessPoolExecutor` 分離
- 重新評估時機：Python 3.16+ 且關鍵依賴都有 `nogil` wheels

---

## 2. 通訊協定：MQTT v5

| 協定 | 雙向 | 功耗 | Overhead | 適用場景 |
|---|---|---|---|---|
| **MQTT v5** ✓ | Yes (pub/sub) | 極低 | 2-byte min header | **IoT 預設選擇** |
| CoAP | 有限 (observe) | 極低 | UDP | NB-IoT 極端受限設備 |
| gRPC | Yes (streaming) | 高 | HTTP/2 + protobuf | 後端 service-to-service |
| AMQP | Yes | 高 | 重 | 企業訊息，不適合設備端 |

**MQTT v5 關鍵功能：**
- Request/Response correlation ID（指令 ack 配對）
- Shared subscriptions（後端 consumer 負載均衡）
- Message expiry（離線指令過期）
- Retained messages（重連後取得最新狀態）
- Last Will and Testament（自動離線偵測）

---

## 3. MQTT Broker：EMQX

| Broker | 1M 連線 | Clustering | 推薦度 |
|---|---|---|---|
| **EMQX** | ✓ (實測 100M+) | 原生 RAFT | ★★★★★ |
| HiveMQ | ✓ | 原生 | ★★★★ (商業) |
| VerneMQ | ✓ | Erlang | ★★★ (社群較小) |
| Mosquitto | ✗ (~100K) | 無 | 僅 dev/edge |

**部署選項：**

| 選項 | AWS | GCP 對應 | 月費估算 |
|---|---|---|---|
| **EMQX Cloud Dedicated** ✓ | AWS 上部署 | GCP 上部署 | ~$15-30K |
| Self-hosted on K8s | EKS | GKE | ~$5-10K + ops |
| 雲端 Managed IoT | AWS IoT Core | ~~GCP IoT Core~~ (已停, 用 EMQX on GKE) | ~$80-120K |

**資源估算：** 1M idle 連線 ≈ 2-4 GB RAM per node，3-5 node cluster

---

## 4. 即時 Monitor + 反向指令

### 4a. 設備狀態 → Dashboard UI（WebSocket）

```
Device → MQTT topic: telemetry/{device-id}
  → EMQX → Redpanda
    → FastStream consumer → aggregate/filter
      → WebSocket push → Browser Dashboard
```

- 用 **WebSocket**（非 SSE）因為需要雙向（UI 也要發指令）
- 多個 WS server 間用 **Redis Pub/Sub** 或 **NATS** 同步
- Socket.IO 或原生 WS API 皆可

### 4b. Dashboard UI → Device（MQTT 反向指令）

```
Browser Dashboard
  → WebSocket / REST API
    → FastAPI Backend (validate + authorize)
      → MQTT publish: cmd/{device-id}/{action}  (QoS 1)
        → EMQX → Device
          → Device execute → publish: ack/{device-id}/{action}
            → Backend → WebSocket → UI 更新狀態
```

**關鍵設計：**
- Topic 結構：`cmd/{device-id}/{action}` / `ack/{device-id}/{action}`
- **QoS 1**（at-least-once），指令設計為 **idempotent**
- MQTT v5 **Correlation ID** 配對 request/response
- Timeout 10s，無 ack 標記 pending/failed
- 離線設備：Retained message 或 backend 指令佇列，重連後重發
- **ACL 安全**：每個設備只能 subscribe `cmd/{自己的 id}/#`

### 4c. BFF (Backend for Frontend) 層

**為什麼需要 BFF？**

FastAPI Backend 是面向設備與資料的核心服務，不應直接服務前端 UI。不同前端（Web Dashboard、Mobile App、第三方 API）需要不同的資料格式、聚合粒度和認證方式。BFF 層解耦前後端，讓 Backend 專注在設備管理與資料處理。

```
                    ┌─── BFF-Web ───── Web Dashboard (WebSocket + REST)
                    │    (聚合, 分頁, WS 管理)
FastAPI Backend ────┤
  (Device API,      ├─── BFF-Mobile ── Mobile App (REST + Push Notification)
   Telemetry API,   │    (精簡 payload, 離線快取)
   Command API)     │
                    └─── BFF-API ───── 第三方整合 (REST + API Key)
                         (Rate limit, 版本控制, Webhook)
```

**BFF 職責劃分：**

| 層 | 職責 | 不做什麼 |
|---|---|---|
| **FastAPI Backend** | Device CRUD、Telemetry 寫入/查詢、Command 下發、RBAC 驗證、MQTT 互動 | 不處理 UI 特定邏輯（分頁/排序/i18n） |
| **BFF** | UI 專屬聚合、WebSocket 連線管理、Response 格式轉換、Session/Token 管理 | 不直連 DB 或 MQTT |

**BFF 實作建議：**

| 面向 | 選擇 | 說明 |
|---|---|---|
| 語言 | **Python (FastAPI)** 或 **Node.js (Next.js API Routes)** | 依前端團隊技術棧決定 |
| 部署 | 獨立 service（K8s Deployment） | 可獨立擴縮，不影響 Backend |
| 通訊 | BFF → Backend 走 **gRPC** 或 **內部 REST** | gRPC 效能較好，REST 開發較快 |
| 快取 | Redis（device status cache、dashboard 聚合快取） | 減少 Backend 查詢壓力 |
| WebSocket | BFF 管理所有 WS 連線 | Backend 不直接面對瀏覽器 WS |

**Web BFF 具體功能：**
- **Dashboard 聚合查詢**：把多個 Backend API 合成一次回應（device list + 最新 telemetry + alert count）
- **WebSocket 連線管理**：維護 per-user WS 連線，訂閱該 user 有權限的 device 更新
- **Response 裁切**：Web 需要完整欄位，Mobile 只需精簡欄位 → BFF 按 client 裁切
- **Rate limiting (per user)**：Backend 做 per-tenant rate limit，BFF 做 per-user rate limit
- **i18n / 時區轉換**：根據 user locale 轉換日期格式、單位

**部署架構更新：**
```
Browser ──► BFF-Web (FastAPI) ──► FastAPI Backend ──► TimescaleDB
                │                        │
                │ WebSocket              │ gRPC / REST
                │                        │
            Redis (WS pub/sub,       EMQX (MQTT)
             dashboard cache)
```

---

## 5. Event-Driven Data Processing

### 5a. Event Streaming：Redpanda

| | Redpanda | Kafka | NATS JetStream |
|---|---|---|---|
| 吞吐量 | 1M+ msg/sec/node | 1M+ msg/sec/broker | ~500K msg/sec |
| P99 延遲 | 1-5ms | 5-15ms | 2-5ms |
| 運維複雜度 | **低**（single binary） | 高（KRaft 改善中） | 極低 |
| API 相容 | Kafka API | - | 自有 |

選 Redpanda：Kafka 生態 + 更簡單運維 + 更低尾延遲

### 5b. Stream Processing：Benthos + FastStream

| 層 | 工具 | 職責 |
|---|---|---|
| 路由/過濾/格式轉換 | **Benthos** (YAML) | 無需寫 code |
| Python 業務邏輯 | **FastStream** | 異常偵測、閾值告警、聚合 |
| 複雜 CEP (optional) | **Flink** | 跨設備跨時間窗關聯分析 |

FastStream 範例：
```python
@broker.subscriber("sensor-data", group_id="processing")
async def handle_sensor(data: SensorReading):
    if data.temperature > threshold:
        await alert_service.notify(data)
    await tsdb.write(data)
```

90% 的 IoT 場景 Benthos + FastStream 就夠，不需要 Flink。

---

## 6. Database：三層儲存策略

**寫入量估算：** 1M 設備 × 每 10 秒 1 筆 = **100K writes/sec**，~1.7 TB/day raw

| 層 | DB | 保留 | 解析度 | 查詢延遲 | 月成本/TB |
|---|---|---|---|---|---|
| **Hot** | TimescaleDB | 24-72h | 原始 | <10ms | ~$200 (NVMe) |
| **Warm** | ClickHouse | 30-90d | 1min/5min 聚合 | 50-500ms | ~$50 |
| **Cold** | S3 + Parquet | 年 | 時/日聚合 | 秒級 | ~$2-5 |

**為什麼選 TimescaleDB 做 Hot：**
- 完整 PostgreSQL SQL — Python 生態（SQLAlchemy, psycopg）零摩擦
- Continuous aggregates 自動產生 dashboard 用的聚合資料
- 90-95% 壓縮率
- PostGIS 支援（設備地理位置查詢）

**為什麼選 ClickHouse 做 Warm：**
- 95%+ 壓縮率（業界最佳）
- 分析查詢速度最快
- MergeTree + TTL 自動管理生命週期
- 可直接查詢 S3 Parquet（`s3()` table function）

**Cold tier：** TimescaleDB `drop_chunks` + ClickHouse TTL 自動降級，Parquet 歸檔到 S3，用 DuckDB 做 ad-hoc 查詢。

---

## 7. 雲端 vs 地端

> **為什麼以 AWS 為主要參照？** AWS IoT 生態最成熟（IoT Core + Greengrass + SiteWise），市占率最高，文件與社群資源最豐富。但所有選型均為**雲端中立**的開源/第三方服務，可無縫遷移至 GCP 或地端。GCP IoT Core 已於 2023 年停止服務，Google 官方建議改用 EMQX/HiveMQ 等第三方。

| 服務層 | 雲端 (AWS) | 雲端 (GCP 對應) | 地端 |
|---|---|---|---|
| MQTT Broker | EMQX Cloud on AWS | EMQX Cloud on GCP | EMQX on K8s |
| Managed IoT | AWS IoT Core | ~~GCP IoT Core~~ (停) → EMQX on GKE | EMQX on K8s |
| K8s | EKS | GKE | K3s / Rancher |
| Streaming | Redpanda Cloud (AWS) / MSK | Redpanda Cloud (GCP) / Confluent | Redpanda on K8s |
| Hot DB | Timescale Cloud (AWS) | Timescale Cloud (GCP) | TimescaleDB on VM |
| Warm DB | ClickHouse Cloud (AWS) | ClickHouse Cloud (GCP) | ClickHouse on K8s |
| Cold Storage | S3 | GCS (Google Cloud Storage) | MinIO |
| Object 查詢 | Athena (S3 Parquet) | BigQuery (GCS Parquet) | DuckDB |
| Pub/Sub 跨服務 | SNS/SQS | Cloud Pub/Sub | NATS / Redis |
| Load Balancer | ALB/NLB | Cloud Load Balancing | HAProxy / nginx |
| 監控 | CloudWatch | Cloud Monitoring | Grafana + Prometheus |
| Secrets | Secrets Manager | Secret Manager | HashiCorp Vault |
| 估算月費 | ~$30-50K | ~$30-50K (類似) | ~$10-20K + ops 人力 |

**建議路徑：** 雲端 managed 起步（AWS 或 GCP 皆可）→ 驗證架構 → 有 K8s 團隊後逐步 self-host 降成本

**GCP 特別注意：**
- GCP IoT Core 已停止，需自建 MQTT broker（EMQX on GKE 是 Google 推薦替代）
- GKE Autopilot 比 EKS 更容易上手（auto node provisioning）
- BigQuery 對大量 IoT 分析查詢有價格優勢（on-demand pricing per TB scanned）

---

## 技術選型總表（含 AWS/GCP 對照）

| 層 | 選擇 | AWS 服務 | GCP 對應 | 理由 |
|---|---|---|---|---|
| 設備協定 | **MQTT v5** | — | — | 低功耗、雙向、QoS |
| MQTT Broker | **EMQX** | EMQX Cloud (AWS) | EMQX Cloud (GCP) | 1M+ 實測、開源 |
| K8s | — | EKS | GKE (Autopilot) | GKE 上手更快 |
| Event Streaming | **Redpanda** | Redpanda Cloud / MSK | Redpanda Cloud | Kafka 相容 + 簡單運維 |
| Stream Processing | **Benthos + FastStream** | — | — | YAML 路由 + Python |
| Python Backend | **FastAPI + asyncio** | EC2 / ECS / Fargate | Cloud Run / GCE | I/O-bound 最佳解 |
| UI 即時推送 | **WebSocket** | ALB WebSocket | Cloud LB | 雙向、成熟 |
| Hot DB | **TimescaleDB** | Timescale Cloud (AWS) | Timescale Cloud (GCP) | Full Postgres SQL |
| Warm DB | **ClickHouse** | ClickHouse Cloud (AWS) | ClickHouse Cloud (GCP) | 最佳壓縮 |
| Cold Storage | **S3 + Parquet** | S3 | GCS | $2/TB |
| Cold 查詢 | **DuckDB / Athena** | Athena | BigQuery | BigQuery 按 scan 計價較划算 |
| Device Auth | **mTLS (X.509)** | ACM PCA (私有 CA) | Certificate Authority Service | 硬體 key 防偽 |
| Secrets | — | Secrets Manager | Secret Manager | 存 bot token, DB creds |
| 監控 | **Grafana** | CloudWatch + Grafana | Cloud Monitoring + Grafana | 統一 dashboard |
| Tenant Isolation | **RLS + Topic ACL** | — | — | 低成本邏輯隔離 |

---

## 8. Device Identity & Anti-Spoofing

### 8a. 認證方式比較

| 方式 | 安全性 | 設備需求 | 1M 規模管理 | 適用 |
|---|---|---|---|---|
| **mTLS (X.509)** ✓ | 最高 | ESP32+ (TLS capable) | CA chain，broker 不存 per-device credential | **預設選擇** |
| PSK (Pre-shared Key) | 中 | MCU 級 (<256KB RAM) | 需存 1M key，rotation 痛苦 | 受限設備/gateway 後方 |
| JWT Token | 高 | 中 | Stateless 驗證，需 refresh | OAuth2 生態整合 |

**推薦：mTLS 為主 + JWT 用於管理 API。** PSK 僅限 legacy/極端受限設備。

### 8b. 為什麼 Device ID 不能單獨信任？

MAC address 可偽造、serial number 可猜測。**Device ID 必須搭配密碼學憑證：**

- **MQTT Client ID 格式**：`{tenant_short}:{device_type}:{serial}`（如 `acme:thermo:SN-001`）
- **X.509 Certificate CN** 必須匹配 MQTT Client ID → mTLS 自動綁定身份
- **DB 內部 PK**：UUID v4（provisioning 時產生）

### 8c. 硬體安全要求

| 技術 | 功能 | 設備等級 | 單價 |
|---|---|---|---|
| **ATECC608B** | ECC key storage + ECDSA | MCU (ESP32, Arduino) | $0.5-1 |
| **TPM 2.0** | Key gen + attestation | Linux gateway/industrial | $1-5 |
| **ARM TrustZone** | CPU secure partition | Cortex-M33+ | Free (SoC 內建) |

**建議：新設備設計必須含 ATECC608B 或同等級硬體。** 沒有硬體 key storage，任何軟體憑證都可被 clone。

### 8d. 大規模 Provisioning 流程

```
PKI 架構：
Root CA (離線, air-gapped HSM)
  ├── Intermediate CA - 工廠 (factory provisioning)
  ├── Intermediate CA - Field (JIT provisioning)
  └── Intermediate CA - Per-Tenant (可選, 強隔離)
```

| 方式 | 流程 | 安全 | 適用 |
|---|---|---|---|
| **Factory Provisioning** | 工廠產線產生 key pair → CSR → CA 簽發 → cert 寫入 | 最高 | 高價值設備 |
| **JIT Provisioning** | 設備帶 bootstrap cert → 首次連線時 broker 自動建立記錄 | 高 | 一般 fleet |
| **Claim-based** | 同型號共用 claim cert → 首次連線換發 unique cert | 中 | 無 secure element 的 fallback |

### 8e. EMQX 認證設定

```
認證鏈（依序嘗試）：
1. mTLS → 從 client cert CN 取得 device identity
2. JWT  → 驗證 RS256 簽名 + claims（iss, exp）
3. HTTP → 呼叫外部 auth service（PSK/legacy 設備）

Listener 設定：
- listeners.ssl.default.verify = verify_peer
- listeners.ssl.default.fail_if_no_peer_cert = true
- peer_cert_as_clientid = cn  ← 關鍵：TLS identity 綁定 MQTT identity
```

ACL 則由外部 HTTP service 處理 → 該 service 查詢 device 的 tenant 歸屬，決定 topic 權限。

---

## 9. Multi-Tenancy 架構

### 9a. Broker 隔離策略

| 模式 | 隔離等級 | 成本 | 適用 |
|---|---|---|---|
| **共享 EMQX + Topic ACL** | 邏輯 | 最低 | 95% 租戶 |
| **Broker-per-tenant** (K8s ns) | 進程 | 高 | 法規要求（醫療/金融） |
| **混合** ✓ | 視租戶 tier | 中 | **推薦** |

### 9b. MQTT Topic 命名空間設計

```
{tenant_id}/d/{device_id}/telemetry          # 遙測上報
{tenant_id}/d/{device_id}/status             # 狀態（online/battery/fw）
{tenant_id}/d/{device_id}/event              # 事件告警
{tenant_id}/d/{device_id}/cmd/request        # 指令下發
{tenant_id}/d/{device_id}/cmd/response       # 指令回應
{tenant_id}/d/{device_id}/config/desired     # 期望組態（cloud twin）
{tenant_id}/d/{device_id}/config/reported    # 實際組態
{tenant_id}/g/{group_id}/cmd/request         # 群組指令廣播
```

**關鍵規則：**
- Tenant ID 永遠是第一層 → ACL 可統一前綴比對
- 設備**禁止** wildcard subscribe（防止 `{tenant}/#` 看到全部 tenant 流量）
- 每個設備 ACL：只能 publish/subscribe 自己的 topic

### 9c. Device Ownership Model

```sql
-- 核心資料表
tenants (id, short_code, name, tier)      -- tier: standard | enterprise
devices (id, tenant_id, client_id, device_type, cert_thumbprint, status)
device_transfers (id, device_id, from_tenant, to_tenant, reason, transferred_by, ts)
```

**設備轉移流程（tenant A → tenant B）：**
1. 驗證權限 + 目標 tenant 存在
2. 撤銷當前 cert（CRL/OCSP）→ 強制斷線
3. 更新 DB ownership + 寫入 audit log
4. 重新 provisioning：簽發新 cert（含新 tenant info）
5. 設備重連 → 新 topic namespace
6. 歷史資料留在原 tenant（資料歸屬不轉移）

### 9d. RBAC 權限模型

| 權限 | Super Admin | Tenant Admin | Operator | Viewer |
|---|:---:|:---:|:---:|:---:|
| 管理 tenants | ✓ | | | |
| 註冊/停用設備 | ✓ | ✓ | | |
| 轉移設備 | ✓ | ✓ (自有) | | |
| 查看設備列表 | ✓ | ✓ | ✓ | ✓ |
| 發送**任意**指令 | ✓ | ✓ | | |
| 發送**預核准**指令 | ✓ | ✓ | ✓ | |
| 查看 Dashboard | ✓ | ✓ | ✓ | ✓ |
| 管理用戶/角色 | ✓ | ✓ | | |
| OTA 部署 | ✓ | ✓ | | |
| 查看 Audit Log | ✓ | ✓ | | |

**Permission 命名規則**：`{resource}:{action}:{qualifier}`
- `device:read`, `device:write`, `device:transfer`
- `command:send:any`, `command:send:approved`
- `dashboard:read`, `tenant:manage`, `ota:deploy`

### 9e. Command Authorization — 雙層驗證

```
Layer 1 — 管理 API（User 端）：
  POST /api/v1/devices/{id}/commands
  → 檢查：user 有 role in device's tenant?
  → 檢查：command:send:any 或 (command:send:approved && type in 允許列表)?
  → 檢查：device status = active?
  → 檢查：rate limit 未超?

Layer 2 — Device 端驗證：
  收到 cmd/request：
  {
    "command_id": "uuid",
    "command_type": "reboot",
    "issued_at": "2026-03-30T12:00:00Z",
    "signature": "base64(sign(payload, platform_key))"
  }
  → 驗簽名（防 MQTT message injection）
  → 驗 issued_at 是否 recent（防 replay）
  → 驗 command_type 在 device 支援的指令集內
```

### 9f. DB Tenant 隔離

| 策略 | 隔離 | 複雜度 | 適用 |
|---|---|---|---|
| **Row-Level Security (RLS)** ✓ | 邏輯 | 低 | 預設 |
| Schema-per-tenant | 中 | 高 | 中等需求 |
| DB-per-tenant | 最強 | 最高 | Enterprise tier |

**RLS 實作：**
```sql
-- 每個 API request middleware 設定
SET app.current_tenant_id = '{tenant_uuid}';

-- Policy 自動過濾
CREATE POLICY tenant_isolation ON devices
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

-- Super admin bypass
SET ROLE platform_admin;  -- with BYPASSRLS
```

**TimescaleDB 多租戶分區：**
```sql
SELECT create_hypertable('telemetry', 'time');
SELECT add_dimension('telemetry', 'tenant_id', number_partitions => 16);
-- 查詢自動利用 tenant_id 分區 pruning，不同 tenant 互不干擾
-- 可按 tenant 設定不同 retention policy
```

---

## 技術選型完整總表（含 AWS/GCP 對照）

> 同 Section 7 的總表，此處加上 Device Auth / Multi-tenancy 相關選型。

| 層 | 選擇 | AWS | GCP | 理由 |
|---|---|---|---|---|
| 設備協定 | **MQTT v5** | — | — | 低功耗、雙向、QoS |
| MQTT Broker | **EMQX** | EMQX Cloud (AWS) | EMQX Cloud (GCP) | 1M+、開源 |
| K8s | — | EKS | GKE Autopilot | GKE 更易上手 |
| Event Streaming | **Redpanda** | Redpanda Cloud / MSK | Redpanda Cloud | Kafka 相容 |
| Stream Processing | **Benthos + FastStream** | ECS / Fargate | Cloud Run | YAML + Python |
| Python Backend | **FastAPI + asyncio** | EC2 / Fargate | Cloud Run / GCE | I/O-bound |
| BFF | **FastAPI / Next.js** | ECS / Fargate | Cloud Run | 前後端解耦 |
| UI 推送 | **WebSocket (via BFF)** | ALB | Cloud LB | BFF 管理 WS |
| Hot DB | **TimescaleDB** | Timescale Cloud | Timescale Cloud | Postgres SQL + RLS |
| Warm DB | **ClickHouse** | ClickHouse Cloud | ClickHouse Cloud | 最佳壓縮 |
| Cold Storage | **S3 + Parquet** | S3 | GCS | $2/TB |
| Cold 查詢 | **DuckDB** | Athena | BigQuery | BQ 按 scan 計價 |
| Device Auth | **mTLS (X.509)** | ACM PCA | CA Service | CA chain 防偽 |
| HW Security | **ATECC608B / TPM** | — | — | 硬體 key 防 clone |
| Secrets | — | Secrets Manager | Secret Manager | Creds 管理 |
| 監控 | **Grafana** | CloudWatch | Cloud Monitoring | 統一 dashboard |
| Tenant Isolation | **RLS + Topic ACL** | — | — | 低成本邏輯隔離 |
| RBAC | **4 roles + permission** | Cognito / IAM | Firebase Auth / IAM | 靈活權限 |

---

## 10. Data Quality, Rate Limiting & Deduplication

### 10a. Rate Limiting — Global & Per-Device

設備異常（firmware bug、sensor malfunction、infinite loop）可能瞬間灌入大量資料，必須多層防護：

```
Layer 1 — EMQX Broker Rate Limit（第一道防線）
  ├── Per-client publish rate:  max 10 msg/sec（正常 1 msg/10s）
  ├── Per-client bandwidth:     max 50 KB/sec
  ├── Global cluster limit:     max 500K msg/sec
  └── Action on exceed:         throttle（delay）→ 超過 10x 則 disconnect

Layer 2 — Redpanda/Kafka 層
  ├── Topic-level quota:        per-tenant produce rate limit
  └── Consumer lag alert:       lag > 100K → 告警（下游處理不及）

Layer 3 — Application 層（FastStream consumer）
  ├── Per-device sliding window: 丟棄 10 sec 內重複 timestamp 的資料
  ├── Per-tenant aggregate rate: 超過 quota 的 tenant → queue 降級
  └── Circuit breaker:          DB 寫入失敗 → 暫停消費，避免 OOM
```

**EMQX 設定範例：**
```
# emqx.conf
listeners.ssl.default {
  # Per-client rate limit
  messages_rate = "10/s"
  bytes_rate = "50KB/s"
}

# Global overload protection
overload_protection {
  enable = true
  backoff_delay = 1     # ms delay per excess message
  backoff_gc = true
}
```

### 10b. Deduplication

設備重送（QoS 1 at-least-once、網路閃斷後 reconnect）會產生重複資料：

| 層 | 策略 | 實作 |
|---|---|---|
| **MQTT Broker** | MQTT v5 message dedup | Broker 追蹤 packet ID（僅限同一 session） |
| **Streaming** | Redpanda idempotent producer | `enable.idempotence = true`（防 producer retry 重複） |
| **Application** | Content-based dedup | `(device_id, timestamp, metric_hash)` 做 unique key |
| **Database** | Upsert / ON CONFLICT | TimescaleDB: `INSERT ON CONFLICT (device_id, time) DO NOTHING` |

**Content-based dedup 實作（FastStream consumer）：**
```python
# Redis-based sliding window dedup
async def is_duplicate(device_id: str, timestamp: datetime, payload_hash: str) -> bool:
    key = f"dedup:{device_id}:{timestamp.isoformat()}"
    # SET NX with 60s TTL — if already exists, it's a duplicate
    return not await redis.set(key, payload_hash, nx=True, ex=60)
```

### 10c. 異常資料偵測

| 類型 | 偵測方式 | 處理 |
|---|---|---|
| **超頻上報** | Rate > 10x normal → EMQX throttle | Broker 層直接擋 |
| **資料範圍異常** | sensor value 超出 physical range（如溫度 -100°C ~ 200°C） | Consumer 丟棄 + 告警 |
| **時序異常** | Timestamp 與 server time 差距 > 5 min | 記錄但標記 `quality: suspect` |
| **靜默設備** | 超過 3x 正常間隔無上報 | LWT 觸發 → 標記 offline → 告警 |

---

## 11. Edge Resilience & Disaster Recovery

### 11a. Edge 端 Reconnect + Offline Buffering

**Server down 時設備端必須自主處理：**

```
Device Reconnect Strategy:
───────────────────────────
1. 初次斷線 → 立即重連
2. 連續失敗 → Exponential backoff: 1s, 2s, 4s, 8s, ... max 5min
3. 加 jitter（隨機 ±30%）→ 防止 1M 設備同時重連（thundering herd）
4. Backoff 期間 → 資料寫入 local buffer
5. 重連成功 → drain buffer，按時序重送
```

**Offline Buffer 設計：**

| 方案 | 容量 | 持久性 | 適用設備 |
|---|---|---|---|
| **Ring buffer in RAM** | 1K-10K messages | 斷電即失 | MCU 級（ESP32） |
| **SQLite on flash** | 100K+ messages | 持久 | Linux gateway |
| **MQTT v5 Session Expiry** | Broker 端保留 | Broker 存活時有效 | 所有設備 |

**MQTT v5 Session Expiry 機制：**
```
Device CONNECT:
  Clean Start = false
  Session Expiry Interval = 3600  (1 hour)

→ Broker 保留 device 的 subscription + pending QoS 1/2 messages
→ Device 重連後自動收到累積的 cmd/request 指令
→ 超過 1 hour 未重連 → session 過期，pending messages 丟棄
```

**未成功送出的訊息重送策略：**
```
Device Publish with QoS 1:
  1. 發送 PUBLISH → 等待 PUBACK
  2. 未收到 PUBACK（timeout 5s）→ 標記為 pending
  3. Reconnect 後 → 重送所有 pending messages（by packet ID）
  4. MQTT spec 保證：QoS 1 = at-least-once delivery

For critical data（如 alert events）:
  - 使用 QoS 2（exactly-once）→ 四步握手，較慢但不重複
  - 或 QoS 1 + application-level dedup（見 10b）
```

### 11b. Server-Side Disaster Recovery

| 組件 | HA 策略 | RPO | RTO |
|---|---|---|---|
| **EMQX** | 3-5 node cluster, RAFT consensus | 0（同步複製） | <30s（自動 failover） |
| **Redpanda** | 3 node, replication factor 3 | 0 | <10s |
| **TimescaleDB** | Patroni + streaming replication | ~0（async）或 0（sync） | <30s |
| **ClickHouse** | ReplicatedMergeTree + ZooKeeper/ClickHouse Keeper | ~0 | <60s |
| **FastAPI Backend** | K8s Deployment, min 3 replicas | — | <5s（pod restart） |

**Thundering Herd 防護（Broker 恢復後）：**
```
場景：Broker 掛了 5 分鐘 → 恢復 → 1M 設備同時重連

防護：
1. EMQX Overload Protection → 自動 backoff 新連線
2. Device-side jitter → 重連時間分散在 0-5min 窗口
3. Connection rate limit → EMQX: max_conn_rate = "10000/s"
4. 預估：1M 設備 / 10K/s = 100s 內全部重連完成
```

### 11c. Multi-Region / Geo-DR

| 層級 | 方案 | AWS | GCP |
|---|---|---|---|
| MQTT | EMQX cluster linking（跨 region bridge） | 跨 AZ 部署 | 跨 Zone 部署 |
| Streaming | Redpanda geo-replication / MirrorMaker2 | 跨 Region S3 replication | 跨 Region GCS replication |
| DB | TimescaleDB read replicas in 2nd region | RDS Multi-AZ + cross-region replica | Cloud SQL cross-region |
| Cold | — | S3 Cross-Region Replication | GCS Dual/Multi-Region |
| DNS | — | Route 53 health check failover | Cloud DNS routing policy |

**Active-Passive 架構（起步推薦）：**
- Primary region 處理所有流量
- Secondary region 有 DB replica + Redpanda mirror
- DNS failover（Route 53 / Cloud DNS）→ RPO ~minutes, RTO ~5-10min
- 進階可做 Active-Active（EMQX cluster linking + CRDT），但複雜度高

---

## 不在此規劃範圍但需後續考慮
- OTA firmware update pipeline
- Edge computing / gateway aggregation（減少雲端流量，edge 預處理）

---

## 執行計畫（本次 BFF 新增）

### 修改檔案
1. **`_posts/2026/2026-03-30-iot-1m-device-architecture.md`** — blog post
   - 「即時 Monitor + 反向指令」section 新增 BFF subsection
   - 更新架構 mermaid diagram（加入 BFF 層）
   - 技術選型總表加 BFF 列
   - 極簡版 mermaid 也需更新（即使極簡版也有 BFF 概念）

2. **`assets/img/blog/2026/iot-architecture/iot-architecture-overview.svg`** — hero image
   - FastAPI box 拆分為 Backend + BFF
   - 或在 FastAPI 與 Dashboard 之間加入 BFF 層

3. **`assets/img/blog/2026/iot-architecture/iot-architecture-overview.png`** — 重新生成

4. **`assets/img/blog/2026/iot-architecture/iot-architecture-plan-raw.md`** — 同步更新
