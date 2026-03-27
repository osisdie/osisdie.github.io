---
layout: post
title: "Claude Code Channel Plugin 開發實戰：Telegram Inline Buttons 與 Symlink 架構"
date: 2026-03-27 10:00:00 +0800
description: 從 Telegram inline buttons 到 plugin cache 覆蓋問題，記錄一天內嘗試 5 種方案最終用 symlink 解決的完整過程
tags: claude-code telegram plugin mcp automation
featured: true
toc:
  sidebar: left
---

## 前言

[claude-code-channels](https://github.com/osisdie/claude-code-channels) 是一個讓 Claude Code 透過 Telegram、Discord、Slack、LINE、WhatsApp 等通訊平台互動的開源專案。每個 channel 都是一個 MCP server，以 Bun subprocess 的形式運行，透過 stdio transport 與 Claude Code session 溝通。

今天的目標看似簡單：讓 Telegram 的 `reply` tool 支援 **inline keyboard buttons**。實作按鈕本身不難，但在過程中踩到了 Claude Code plugin cache 的覆蓋機制，最終花了更多時間在架構問題上。這篇文章記錄完整過程。

---

## Telegram Inline Buttons 實作

### 需求

當 Claude 需要用戶回應一組固定選項時（Yes/No、Approve/Reject、1~5 數字），讓用戶直接按按鈕比打字更直覺。官方 Telegram plugin 的 `reply` tool 只支援純文字，沒有按鈕參數。

### 方案設計

在 `reply` tool 加一個 optional `buttons` 參數，二維字串陣列，每個內層陣列代表一排按鈕：

```typescript
// Claude 可以發送任意按鈕組合
reply({ chat_id, text: "確認部署?", buttons: [["Yes", "No"]] })
reply({ chat_id, text: "選擇方案:", buttons: [["方案A", "方案B"], ["取消"]] })
```

### 關鍵技術決策

**使用 raw Telegram API format，而非 grammy 的 InlineKeyboard class。**

一開始用 grammy 的 `InlineKeyboard` 建構按鈕，搭配 spread operator 傳入 `sendMessage` options：

```typescript
// 這個寫法看起來正確，但按鈕不會出現在 Telegram
const kb = new InlineKeyboard().text('Yes', 'btn:Yes').text('No', 'btn:No')
await bot.api.sendMessage(chat_id, text, {
  ...otherOpts,
  ...(kb ? { reply_markup: kb } : {}),
})
```

MCP tool call 回傳 `sent (id: XX)` — 沒有錯誤，但 Telegram 就是不顯示按鈕。用 curl 直接呼叫 Telegram Bot API 測試，按鈕正常出現。問題出在 grammy class 跟 spread operator 的序列化。

改用 raw format 後立即解決：

```typescript
const replyMarkup = {
  inline_keyboard: buttons.map(row =>
    row.map(label => ({
      text: String(label),
      callback_data: `btn:${String(label).slice(0, 59)}`, // 64 bytes 上限
    }))
  ),
}
```

**按鈕按壓的回調處理：**

用戶按下按鈕後，Telegram 送出 `callback_query`。我們攔截 `btn:` prefix 的 callback，將按鈕 label 作為一般的 inbound channel message 轉回 Claude，meta 帶 `button: "true"` 標記：

```typescript
bot.on('callback_query:data', async ctx => {
  if (data.startsWith('btn:')) {
    // 1. 回應 Telegram（消除 loading 動畫）
    await ctx.answerCallbackQuery({ text: label })
    // 2. 更新訊息顯示選了什麼（防止重複點擊）
    await ctx.editMessageText(`${msg.text}\n\n→ ${label}`)
    // 3. 轉發給 Claude Code session
    mcp.notification({
      method: 'notifications/claude/channel',
      params: { content: label, meta: { chat_id, button: 'true' } },
    })
  }
})
```

最後在 MCP server 的 `instructions` 加上一句引導：

> Prefer buttons over asking the user to type whenever the response is a small fixed set of choices.

這樣 Claude 在猜數字、確認操作等場景會主動使用 buttons，不需用戶提醒。

---

## Plugin Cache 覆蓋問題

### 發現問題

按鈕功能寫好了，直接改 `~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/server.ts`，重啟 Claude Code，按鈕不出現。加了 diagnostic watermark 到回傳值：

```text
sent (id: 54)          ← 沒有 [local-v1] watermark
```

**確認：Claude Code 在 `--channels plugin:telegram@claude-plugins-official` 啟動時，會 re-extract 官方 plugin 到 cache，覆蓋所有修改。**

### 嘗試過的 5 種方案

| # | 方案 | 結果 |
|---|------|------|
| 1 | **Pre-sync cp** — `start.sh` 在 `exec claude` 前 cp local → cache | Claude re-extracts 覆蓋 |
| 2 | **Background watcher** — 背景 process 偵測覆蓋後立即替換 | Race condition — bun 可能先載入 |
| 3 | **`--plugin-dir`** — 用 local plugin 目錄 | 不支援 channel plugins (SessionStart hook error) |
| 4 | **`--mcp-config`** — 自定 MCP server config | 沒有 channel notification capability |
| 5 | **Symlink** — cache 目錄 symlink → local fork | Claude 看到目錄存在就跳過 extraction |

### Bun Transpile Cache 的額外坑

即使成功把修改放進 cache，重啟後仍可能跑舊 code。原因是 **bun 會 cache transpiled TypeScript**，即使 `server.ts` 檔案改了，bun 仍可能使用舊的 cached bytecode。需要 `rm -rf /tmp/bun-*` 清除。

這個問題已開 upstream issue：[anthropics/claude-plugins-official#1057](https://github.com/anthropics/claude-plugins-official/issues/1057)

---

## Symlink 架構

最終採用的方案：將官方 plugin fork 到 `external_plugins/` 做版控，用 symlink 讓 Claude Code 載入我們的 fork。

### 工作原理

```text
~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/
    ↓ symlink (start.sh 自動建立)
<project>/external_plugins/telegram-channel/
    ├── .claude-plugin/plugin.json
    ├── .mcp.json
    ├── server.ts          ← 我們的 fork（版控裡的 source of truth）
    ├── skills/
    ├── node_modules/      ← gitignore
    └── bun.lock
```

### start.sh 啟動流程

```bash
# 1. 解析 plugin cache 路徑
cache_base="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"

# 2. 每個版本目錄 symlink → local fork
for ver_dir in "$cache_base"/*/; do
  ln -sfn "$local_abs" "$target"
done

# 3. 自動安裝 node_modules（如果缺少）
bun install --cwd "$local_abs" --no-summary

# 4. 啟動 Claude Code
exec claude "${CHANNEL_ARGS[@]}"
```

### Contributor 體驗

```bash
git pull                    # 取得最新 plugin code
./start.sh telegram         # 自動 symlink + 安裝依賴 + 啟動
```

不需要手動管理 cache。所有 plugin 修改都在 `external_plugins/` 裡做版控。

---

## STATE_DIR 修復

官方 plugin 的 skills（`/telegram:access`、`/telegram:configure`）裡所有路徑都 hardcode 為 `~/.claude/channels/telegram/`。當 `start.sh` export `TELEGRAM_STATE_DIR` 到 project-level 路徑時，server.ts 正確使用了環境變數，但 skills 仍讀寫 global 路徑，導致 pairing 失敗。

Fork 後修復：skills 改用 `$STATE` shorthand，由 `$TELEGRAM_STATE_DIR` 解析，fallback 到 global：

```markdown
**Path resolution**: Use `$TELEGRAM_STATE_DIR` if set, otherwise fall back to
`~/.claude/channels/telegram`. All paths below use `$STATE` as shorthand.
```

同樣的修復也套用到 Discord plugin 和 `ACCESS.md` 文件。

---

## Verify Scripts

新增兩個健康檢查腳本：

**`verify_telegram.sh`** — 8 項檢查：

1. Bot token 存在 & 格式驗證
2. Bot identity（Telegram `getMe` API）
3. Webhook 狀態（確認是 long-polling 模式）
4. Access 設定（`access.json` 配對狀態）
5. 通信測試（發送 DM 給已配對用戶）
6. Plugin process 是否運行
7. 檔案權限（`.env` / `access.json` 應為 600）

**`verify_discord.sh`** — 同樣 8 項，額外包含 Gateway connectivity 和 Guild membership 檢查。

兩個腳本都支援三層 STATE_DIR 解析：env override → project-based → global fallback，global 時會顯示提醒。

---

## 總結

### Takeaways

1. **Plugin 開發最大障礙**：Claude Code 的 `--channels` 只接受官方 plugin identifier，啟動時會 re-extract 覆蓋 cache。目前沒有官方的 local plugin 載入方式。

2. **Symlink 是最可靠的 workaround**：比 pre-sync、background watcher、`--plugin-dir`、`--mcp-config` 都穩定。

3. **Bun transpile cache 是隱性坑**：改了 TypeScript 原始碼，bun 可能仍跑舊版本。清 `/tmp/bun-*` 或設定 `BUN_DISABLE_CACHE=1` 可解。

4. **建議官方改進**：
   - `--channels` 支援 local path（類似 `--plugin-dir`）
   - Plugin 啟動時加 `--no-cache` 避免 transpile cache 問題

### 相關連結

- [claude-code-channels](https://github.com/osisdie/claude-code-channels) — 本專案
- [anthropics/claude-plugins-official#1057](https://github.com/anthropics/claude-plugins-official/issues/1057) — Bun cache issue
- [PR: feat/telegram-buttons-local-plugins](https://github.com/osisdie/claude-code-channels/tree/feat/telegram-buttons-local-plugins) — 本次完整改動
