---
layout: post
title: "一行 /handoff：把 E2E 跑完、截圖、組 HTML、draft email 一路串到 reviewer 信箱"
date: 2026-05-27 18:00:00 +0800
description: "Claude Code skill 怎麼把 E2E 測試、截圖、HTML 報告、Microsoft Graph draft email 五個步驟封裝成一個 slash command；進階版 /walkthrough skill 再加 edge-tts + ffmpeg 直接生出帶字幕的導覽影片。重點不在工具，在「把異質 toolchain 攤平成一個動詞」這個 pattern。"
tags: claude-code skills automation playwright e2e testing devops ai
featured: false
og_image: /assets/img/blog/2026/e2e-test-report-skill-pipeline/e2e-test-report-skill-pipeline-overview.png
toc:
  sidebar: left
---

{% include figure.liquid loading="eager" path="assets/img/blog/2026/e2e-test-report-skill-pipeline/e2e-test-report-skill-pipeline-architecture.png" class="img-fluid rounded z-depth-1" alt="兩個 Claude Code skill 的對照流程圖：/handoff 把 Playwright 跑完、組 HTML、推到 Graph API 變草稿；/walkthrough 用 edge-tts + ffmpeg 把 19 場景燒成帶字幕的 MP4 寄出" caption="兩個 skill、同一個 pattern：把異質 toolchain 攤平成一個動詞。" %}

> **本文用語**：
>
> - **Skill** — Claude Code 的 slash command 機制。一個 `.md` 檔放在 `~/.claude/skills/` 或專案層 `.claude/skills/`，用自然語言 + bash + 偶爾 typescript 描述一條 workflow，輸入 `/<name>` 就跑完整條
> - **handoff 流程** — 「跑測試 → 收 artifact → 整理結果 → 交給 reviewer」這條 dev workflow
>
> **TL;DR**：用 Claude Code 的 skill 系統把 **Playwright → screenshot → HTML 組裝 → Microsoft Graph draft email** 5 個步驟封成一個 `/handoff`；進階版 `/walkthrough` 再加 **edge-tts + ffmpeg subtitle burn-in**，產出有字幕的 zh-TW 導覽 MP4 直接寄出。重點不在工具——用到的全是現成的——重點在 **「把異質 toolchain 攤平成一個動詞」** 這個 pattern：步驟少了一階心智成本，使用頻率就上去；使用頻率上去，那個動詞才有存在意義。

跑完一輪 E2E 測試、把結果寄給隊友 review，是每個小團隊都會做的事。但這件事的步驟以前長這樣：

1. 起 dev server、確認跑起來
2. `npx playwright test`
3. 看 console 結果、記下哪幾隻 fail
4. 開瀏覽器、截幾張 UI 截圖
5. 開 Outlook、寫信、貼截圖、把測試結果整理成表格
6. 寄出（或先存草稿等隊友 review 再發）

每次 25–30 分鐘。多數時間花在 step 4–5：截圖要排版、表格格式要對、附件 `cid:` 要對齊——對不齊 inline image 在 Outlook 不顯示，整封信變紅色 X。

後來把整套流程封裝成一個 Claude Code skill：`/handoff`。一行指令把 step 1–6 全部跑完，結果落在 Outlook 的草稿匣，**人類只負責 review + 按送出**。本文拆這條 pipeline 怎麼接，以及更進階的 `/walkthrough` skill 怎麼用同樣的 pattern 把整個平台導覽錄成有字幕的 MP4。

---

## 1. /handoff skill 做了什麼

`~/.claude/skills/handoff.md` 描述一條 6 階段 pipeline，輸入 `/handoff` 就觸發：

1. **parse arguments** — `/handoff login you@example.com` 解出 spec 檔名 + 收件人。沒給就跑全部 `e2e/*.spec.ts`、寄給 `git config user.email`
2. **pre-flight** — `curl -sf` 探 dev server，跑不起來就警告並停手
3. **run Playwright** — `npx playwright test e2e/$SPEC --reporter=list,json --output=test-reports/playwright/`，把 JSON 餵下游
4. **截圖** — 透過 Playwright MCP 連到瀏覽器、導航到 key pages 截 1440×900 PNG，存到 `.playwright-mcp/`。MCP 不在的話降級用既有截圖
5. **組 HTML body** — 標題、summary table（pass / fail / skipped）、failed test 詳情（含 error message 跟對應截圖）、inline screenshot via `cid:`、環境資訊（branch / commit / Node version）
6. **建 draft** — `POST /me/messages` 到 Microsoft Graph，截圖以 `#microsoft.graph.fileAttachment` + `isInline: true` 內嵌。回傳 `webLink` 印出來給 user

整條 chain 由 Claude 自己跑完，我只看最後一行 `https://outlook.office.com/...`，點進去 review 後手動送出。

```bash
# 三種用法
/handoff                          # 跑全部，寄給 git user.email
/handoff login                    # 只跑 login.spec.ts
/handoff login you@example.com    # 指定 spec + 收件人
```

---

## 2. 為什麼用 draft 而不是直接 send

第一版本來是直接寄出。隔天我手抖把一封寫錯收件人的 fail report 寄出去，趕快寫第二封說「請忽略上一封」。當天就把 skill 改成 **draft only**：

- skill 永遠只 `POST /me/messages`、**從不**呼叫 `/sendMail`
- 草稿停在 Outlook 的 Drafts 資料夾
- 使用者收到 webLink → 點開 → review → 自己按 Send

這是 HITL（human-in-the-loop）的最廉價形式。**一個 API endpoint 的差別，把 automation 從「自己跑」變成「建議方案」**。要 retry 就重跑、產生新草稿，舊的還在 Drafts 沒寄出去，不會有「我剛剛寄錯了快幫我撤回」的問題。

這條規則我後來推廣到其他 skill：**任何會對外送訊息的 automation，預設都先 draft、不直接 send**。Slack、Discord、Notion 同理——能 dry-run 的就 dry-run，能 draft 的就 draft。要直接 send 必須 explicit flag。

---

## 3. Inline 截圖的小坑 — Graph API isInline 必填

要在 Outlook 把 cid 圖顯示成 inline、不被當一般附件，**同時**要滿足三個條件：

```json
{
  "body": {
    "contentType": "HTML",
    "content": "<img src=\"cid:screenshot-01\" />"
  },
  "attachments": [{
    "@odata.type": "#microsoft.graph.fileAttachment",
    "name": "01-dashboard.png",
    "contentType": "image/png",
    "contentBytes": "<base64-encoded>",
    "contentId": "screenshot-01",
    "isInline": true
  }]
}
```

三個對齊點：

- `<img src="cid:<id>">` 的 `<id>` 對到 attachment 的 `contentId`
- `contentId` 必須在所有 inline attachments 之間 **unique**
- `isInline: true` 一定要設——漏了，圖檔還是上得去，但 Outlook 把它當一般附件，HTML 裡的 `<img>` 變紅色 X

第一次接的時候漏了 `isInline`，畫面就是滿滿的紅色 X 但 Graph 沒報錯——API 文件有寫，但 sample 很少；要全部對齊才會 inline。另外多張圖的 `contentId` 一開始我都叫 `screenshot`，結果 Outlook 只顯示第一張、其他變紅 X；改成 `screenshot-01`、`screenshot-02` ... 才正常。

最後注意 **4 MB message size limit**：超過要走 attachment upload session。實務上 screenshot pipeline 我都會壓到 < 800 KB / 張，6 張內就夠用；爆了直接降解析度，沒到要切 upload session 的程度。

---

## 4. 進階版 — /walkthrough skill：直接生帶字幕的導覽影片

`/handoff` 的輸出是 email + 截圖。下一步：**把整個平台導覽錄成有字幕的 MP4 直接寄出**。

`/walkthrough` skill 串的 toolchain 比 `/handoff` 又多兩層：

1. **Playwright headed** 跑 5 幕 19 場景的 walkthrough spec
2. 每個場景開始前用 `page.evaluate()` 注入紅框（`position: fixed`, `z-index: 99999`）highlight 對應 UI 元素，下一場景前自動移除
3. **edge-tts** 預先生成 19 段 zh-TW 旁白（`zh-TW-HsiaoChenNeural` voice）
4. Playwright 開錄影模式，video 起點跟 audio offset tracking 對齊在同一個 `testStartMs`
5. **ffmpeg** 把 WebM → MP4、由 narration timing 生 SRT、字幕 burn-in
6. Nodemailer SMTP 把 MP4 + 報告寄出（≥ 3 場景 pass 才寄）

結果是一個 `platform-walkthrough.mp4`——紅框跟著旁白移動、底下有字幕、整段 3–5 分鐘。比起拍 demo 影片用 OBS 錄一次、剪一次、配音一次的工序，省下半天。

裡頭最容易踩的是 **audio / video 同步**：`testStartMs = videoStartMs` 必須在 TTS 預生成 *之前* 就 anchor 住，不然 TTS 生 19 段花掉的時間會讓 audio offset 漂掉，最後字幕對不到畫面。這條時序的細節下篇另開一篇拆。

---

## 5. Skill 系統的價值 — 把異質 toolchain 攤平成一個動詞

放大鏡頭看，`/handoff` 跟 `/walkthrough` 的共同骨架是：

| 階段 | /handoff | /walkthrough |
| --- | --- | --- |
| 啟動 | parse args + curl 探 server | 同左 |
| 跑東西 | Playwright JSON reporter | Playwright headed + video |
| 收 artifact | PNG screenshots | PNG + MP3 + SRT + MP4 |
| 組輸出 | HTML body + cid attachments | MP4 with burned-in subtitles |
| 通知 | Microsoft Graph draft | Nodemailer SMTP send |

裡面用到的工具一共 **Playwright、Playwright MCP、edge-tts、ffmpeg、Microsoft Graph、Nodemailer、curl、git** 八個。如果不用 skill，跑一輪是 6 個 tab 切換、5 個 README 翻一翻、3 個 `.env` 變數要記得 source。Skill 系統的價值就是把這條 chain 寫一次（自然語言 + bash + 偶爾 typescript），之後輸入動詞就跑完。

這個 pattern 不限於測試。任何「runtime artefacts → human notification」的迴路都可以這樣包：

- `/release-note` — 跑 `git log`、生 changelog、推到 Notion
- `/db-snapshot` — `pg_dump`、上 S3、寄連結
- `/cost-report` — 拉雲端帳單、生表格、寫 Slack 訊息
- `/code-review-prep` — `git diff`、跑 linter、組 review checklist

**動詞越單純，使用頻率越高**。五個步驟封成一個動詞後，我跑 E2E 的頻率變 3–4×，因為 setup cost 趨近 0。

**命名也是這個道理：把 skill 命到 outcome、不要命到 implementation**。`/handoff` 講的是「把 review 結果交出去」這個動作，不是「跑 Playwright + 截圖 + 寄 email」這串實作；`/walkthrough` 講的是「帶人逛一遍平台」這個結果，不是「Playwright headed + TTS + ffmpeg burn-in」。命名綁 implementation 就會綁住認知——讀到 skill 名只想到工具鏈、看不到 outcome；命到 outcome 之後，底層工具未來怎麼換都不影響使用者怎麼思考。

---

## 6. 幾個踩到的坑

- **Token leak 風險** — `set -a && source .env.local && set +a` 把 `OAUTH_TOKEN_ENCRYPTION_KEY` 之類的 secret 全載到 process env，第一版 skill 偶爾會把它 echo 到 console debug 用，差點 leak。改成 **token 永遠只在 tsx script 裡從 `process.env` 拿、從不 echo / print**，skill 描述第一行就寫 "Never output tokens"
- **MCP 不在時的 fallback** — 第一版 hard-require Playwright MCP，沒裝就跑不動。改成「MCP 沒裝就用 `docs/screenshots/` 或 `.playwright-mcp/` 既有圖」——降級而不是中止
- **Graph token 過期** — 寫一個 wrapper function `resolveGraphAccessToken()` 把 refresh 邏輯封起來；skill 本身只 `await accessToken`，refresh 透明
- **CID collision** — 第 3 節提過，每張 inline 圖的 `contentId` 必須 unique
- **Audio / video desync (/walkthrough only)** — 第 4 節提過，`testStartMs` anchor 在 TTS 預生成之前

---

## 7. 還能優化的地方

1. **Streaming 模式** — 現在跑完所有 spec 才組 report；改成每跑完一隻就更新 draft 的 progress section，user 可以開著 draft 看著它長大
2. **Failure-only mode** — 只有 fail 時才 draft（pass-all 直接 Slack 一行 ✅），現在不管結果都建草稿，多餘
3. **Retry-flake detector** — 同一隻 spec 連跑 3 次有 2 次 pass 就標 flaky，draft 裡 highlight
4. **Diff 截圖** — 連 baseline 圖一起截，跟前次 run 做 visual diff，UI regression 自動框出
5. **Skill composition** — 讓 `/walkthrough` 內部呼叫 `/handoff`（walkthrough 跑完順便產 handoff report），現在兩個 skill 各自獨立、artifacts 沒共用
6. **換 HF 上比較擬真的 TTS 模型** — 現在用 `edge-tts` 的 `zh-TW-HsiaoChenNeural` voice，產出乾淨但聽起來明顯機器音。HuggingFace 上的 `coqui/XTTS-v2`、`SparkAudio/Spark-TTS-0.5B`、`fishaudio/fish-speech-1.5` 都支援 zh-TW 且更接近真人，差別是要起 GPU container 跑（edge-tts 是免費 API call）。`/walkthrough` 的 demo 影片用擬真語音更好賣相，trade-off 是 generation 從 ~30 秒拉到 ~3 分鐘

---

## 8. 收尾

`/handoff` 跟 `/walkthrough` 都不是技術突破。用到的工具全是現成的：Playwright、edge-tts、ffmpeg、Graph API、Nodemailer、curl。**價值在「把 toolchain 攤平成一個動詞」**：步驟少了一階心智成本，使用頻率就上去；使用頻率上去，那個動詞才有存在意義。

寫 skill 的成本不高（兩個 skill 各 ~150 行 markdown 描述、加起來不到 500 行 tsx 補完），但每用一次省 25–30 分鐘。寫一次、用一年。

下一篇想拆 `/walkthrough` 裡頭 audio / video 同步的細節——為什麼 `videoStartMs` 一定要 anchor 在 TTS 預生成之前，跟 ffmpeg burn-in 字幕怎麼跟 Playwright video timing 對齊。那條時序圖比想像中複雜。

---

前篇 [DGX Spark + Ray Serve tuning playbook](/blog/2026/dgx-spark-ray-serve-tuning/) 拆下層的 LLM serving。本篇換到更上游的 **dev workflow** 層：跑完測試怎麼把結果交出去。
