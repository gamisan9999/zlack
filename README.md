# zlack

A lightweight Slack client for the terminal, built with Zig.

**~6,700 lines of Zig / 5.5MB binary / zero runtime dependencies**

[English](#features) | [日本語](#日本語) | [中文](#中文)

## Features

- Channel browsing with section headers (Channels / DMs)
- Real-time messaging via Socket Mode (WebSocket)
- Thread view and thread replies
- File upload (Ctrl+U)
- Channel search (Ctrl+K)
- @mention with auto-resolve (name to user ID)
- Mention notification (terminal bell + sidebar badge)
- Mouse support (scroll, click, double-click)
- Japanese / Chinese input support (UTF-8 codepoint-aware cursor)
- Keychain token storage (macOS)

## Prerequisites

- macOS (uses Security.framework for Keychain) or Linux (env/prompt auth)
- [devenv](https://devenv.sh/) (provides Zig and SQLite)
- Slack App with Socket Mode enabled

### Required Slack App Scopes (User Token)

| Scope | Purpose |
|-------|---------|
| `channels:read` | Channel list |
| `channels:history` | Message history |
| `channels:write` | Post messages |
| `groups:read` | Private channel list |
| `groups:history` | Private channel history |
| `groups:write` | Post to private channels |
| `im:read` | DM list |
| `im:history` | DM history |
| `im:write` | Send DMs |
| `users:read` | User list (for display names) |
| `chat:write` | Post messages |
| `files:write` | File upload |

### Required Slack App Settings

- **Socket Mode**: Enabled
- **Event Subscriptions**: `message.channels`, `message.groups`, `message.im`
- **App-Level Token**: With `connections:write` scope

## Build

```bash
devenv shell
zig build
```

Binary is output to `zig-out/bin/zlack`.

## Run

### First launch (set tokens)

```bash
# Option 1: Environment variables
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# Option 2: Interactive prompt
./zig-out/bin/zlack
# Enter User Token (xoxp-...): <paste token>
# Enter App Token (xapp-...): <paste token>
```

Tokens are saved to macOS Keychain on first successful auth.

### Subsequent launches

```bash
./zig-out/bin/zlack
```

### Reconfigure tokens

```bash
./zig-out/bin/zlack --reconfigure
```

## Keybindings

### Navigation

| Key | Action |
|-----|--------|
| `Tab` | Cycle focus: Channels -> Messages -> Input |
| `Shift+Tab` | Cycle focus backward |
| `j` / `Down` | Move down in list |
| `k` / `Up` | Move up in list |
| `Ctrl+F` | Page down (10 items) |
| `Ctrl+B` | Page up (10 items) |
| `Enter` | Select channel / Open thread / Send message |

### Commands

| Key | Action |
|-----|--------|
| `Ctrl+K` | Channel search (fuzzy filter) |
| `Ctrl+U` | File upload mode (enter file path) |
| `Ctrl+T` | Toggle thread pane |
| `Escape` | Close thread / Cancel file upload |
| `Ctrl+C` / `Ctrl+Q` | Quit |

### Messaging

| Key | Action |
|-----|--------|
| `Enter` | Send message (or thread reply when in thread mode) |
| `Shift+Enter` | Thread reply + also post to channel |
| `@name` | Auto-resolved to Slack mention on send |

### Mouse

| Action | Effect |
|--------|--------|
| Click sidebar | Select channel + focus input |
| Click message area | Select message + focus messages |
| Click input area | Focus input |
| Double-click message | Open thread |
| Scroll wheel | Scroll sidebar or messages |

## Architecture

```
src/
  main.zig            # Entry point
  app.zig             # Application state + event loop
  slack/
    api.zig           # Slack REST API client
    auth.zig          # Token validation + Keychain storage
    socket.zig        # Socket Mode WebSocket client
    types.zig         # Slack API response types
    pagination.zig    # Cursor-based pagination helper
  tui/
    root.zig          # Root layout (header + sidebar + messages + thread + input)
    sidebar.zig       # Channel list with sections
    messages.zig      # Message display pane
    thread.zig        # Thread display pane
    input.zig         # Text input with UTF-8 support
    modal.zig         # Search/switch modal popup
    mrkdwn.zig        # Slack mrkdwn parser (stub)
  store/
    cache.zig         # In-memory cache (channels, users, messages)
    db.zig            # SQLite database (offline queue)
  platform/
    keychain.zig      # macOS Keychain / Linux stub
```

## Tests

```bash
devenv shell
zig build test --summary all
```

64 tests covering types, auth, cache, UTF-8 handling, and timestamp formatting.

## License

MIT

---

## 日本語

# zlack — ターミナルで動く軽量 Slack クライアント

Zig で構築された TUI ベースの Slack クライアントです。

**約 6,700 行の Zig / 5.5MB バイナリ / ランタイム依存ゼロ**

### 機能一覧

- チャンネル一覧（Channels / DMs セクション表示）
- Socket Mode によるリアルタイムメッセージング（WebSocket）
- スレッド表示・スレッド返信
- ファイルアップロード（Ctrl+U）
- チャンネル検索（Ctrl+K）
- @メンション（ユーザー名を自動で ID に変換）
- メンション通知（ターミナルベル + サイドバーバッジ）
- マウス操作（スクロール、クリック、ダブルクリック）
- 日本語入力対応（UTF-8 コードポイント単位のカーソル移動）
- macOS Keychain によるトークン保存

### 必要なもの

- macOS（Keychain 利用）または Linux（環境変数/プロンプト認証）
- [devenv](https://devenv.sh/)（Zig と SQLite を提供）
- Socket Mode が有効な Slack App

### ビルド

```bash
devenv shell
zig build
```

### 起動

```bash
# 初回: 環境変数でトークンを指定
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# 2回目以降: Keychain から自動読み込み
./zig-out/bin/zlack

# トークン再設定
./zig-out/bin/zlack --reconfigure
```

### キーバインド

| キー | 操作 |
|------|------|
| `Tab` | フォーカス切替（チャンネル → メッセージ → 入力欄） |
| `Shift+Tab` | フォーカス逆順切替 |
| `j` / `↓` | リスト内で下に移動 |
| `k` / `↑` | リスト内で上に移動 |
| `Ctrl+F` / `Ctrl+B` | ページスクロール（10件） |
| `Enter` | チャンネル選択 / スレッド表示 / メッセージ送信 |
| `Shift+Enter` | スレッド返信 + チャンネルにも投稿 |
| `Ctrl+K` | チャンネル検索 |
| `Ctrl+U` | ファイルアップロード |
| `Ctrl+T` | スレッドペイン表示/非表示 |
| `Escape` | スレッド閉じ / アップロードキャンセル |
| `Ctrl+C` / `Ctrl+Q` | 終了 |

### マウス操作

| 操作 | 効果 |
|------|------|
| サイドバークリック | チャンネル選択 + 入力欄にフォーカス |
| メッセージ領域クリック | メッセージ選択 |
| メッセージダブルクリック | スレッド表示 |
| スクロールホイール | サイドバー/メッセージのスクロール |

### テスト

```bash
devenv shell
zig build test --summary all
```

64 テスト（型定義、認証、キャッシュ、UTF-8 処理、タイムスタンプ変換）

---

## 中文

# zlack — 终端轻量级 Slack 客户端

使用 Zig 构建的 TUI Slack 客户端。

**约 6,700 行 Zig 代码 / 5.5MB 二进制文件 / 零运行时依赖**

### 功能

- 频道浏览（Channels / DMs 分区显示）
- 通过 Socket Mode 实时消息传递（WebSocket）
- 线程查看和回复
- 文件上传（Ctrl+U）
- 频道搜索（Ctrl+K）
- @提及（自动将用户名解析为用户 ID）
- 提及通知（终端响铃 + 侧边栏标记）
- 鼠标支持（滚动、点击、双击）
- 中日文输入支持（UTF-8 码点级光标移动）
- macOS Keychain 令牌存储

### 前提条件

- macOS（使用 Keychain）或 Linux（环境变量/提示认证）
- [devenv](https://devenv.sh/)（提供 Zig 和 SQLite）
- 启用了 Socket Mode 的 Slack App

### 构建

```bash
devenv shell
zig build
```

### 运行

```bash
# 首次运行：通过环境变量设置令牌
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# 后续运行：自动从 Keychain 读取
./zig-out/bin/zlack

# 重新配置令牌
./zig-out/bin/zlack --reconfigure
```

### 快捷键

| 按键 | 操作 |
|------|------|
| `Tab` | 切换焦点：频道 → 消息 → 输入框 |
| `Shift+Tab` | 反向切换焦点 |
| `j` / `↓` | 向下移动 |
| `k` / `↑` | 向上移动 |
| `Ctrl+F` / `Ctrl+B` | 翻页滚动（10 项） |
| `Enter` | 选择频道 / 打开线程 / 发送消息 |
| `Shift+Enter` | 线程回复 + 同时发送到频道 |
| `Ctrl+K` | 频道搜索 |
| `Ctrl+U` | 文件上传 |
| `Ctrl+T` | 切换线程面板 |
| `Escape` | 关闭线程 / 取消上传 |
| `Ctrl+C` / `Ctrl+Q` | 退出 |

### 鼠标操作

| 操作 | 效果 |
|------|------|
| 点击侧边栏 | 选择频道 + 焦点移到输入框 |
| 点击消息区域 | 选择消息 |
| 双击消息 | 打开线程 |
| 滚轮 | 滚动侧边栏/消息 |

### 测试

```bash
devenv shell
zig build test --summary all
```

64 个测试，覆盖类型定义、认证、缓存、UTF-8 处理和时间戳格式化。
