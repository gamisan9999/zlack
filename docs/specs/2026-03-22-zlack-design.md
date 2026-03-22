# zlack: Slack TUI Client in Zig

## Overview

Neovim 内 Slack プラグイン (neo-slack.nvim) や weechat (wee-slack) の UI/UX 不満を解消するため、Zig でフルスクラッチの Slack TUI クライアントを構築する。

### Goals

- Slack デスクトップアプリの代替となるフル機能 TUI クライアント
- モダンな TUI 操作感（タブ切り替え、マウス対応、ポップアップ）
- シングルバイナリ、依存最小
- 複数ワークスペース対応（MVP では切り替え。同時接続は Phase 4）
- 将来的にベクトル検索（スクショ分析）に拡張可能

### Non-Goals (MVP)

- メッセージ検索（Phase 3）
- リアクション追加/削除（Phase 2）
- ファイルアップロード（Phase 3）
- ベクトル検索（Phase 4）
- DM 表示/送信（Phase 2。サイドバーにはプレースホルダーのみ表示）
- 複数ワークスペース同時接続（Phase 4。MVP は1ワークスペースずつ切り替え）

## Architecture

モノリシック Zig。外部依存は Zig パッケージと C ライブラリの静的リンクのみ。

```
zlack (single binary, ~3-5MB with ReleaseSafe)
│
├── src/
│   ├── main.zig           — エントリポイント、引数パース
│   ├── app.zig            — アプリケーション状態管理、スレッド間メッセージキュー
│   │
│   ├── slack/
│   │   ├── api.zig        — REST API クライアント (std.http.Client)
│   │   ├── socket.zig     — Socket Mode WebSocket (websocket.zig)
│   │   ├── types.zig      — Slack API の型定義 (Channel, Message, User, etc.)
│   │   ├── auth.zig       — トークン管理 (User Token + App-Level Token)
│   │   └── pagination.zig — カーソルベースページネーション汎用処理
│   │
│   ├── tui/
│   │   ├── root.zig       — libvaxis ベースの UI ルート (※ app.zig との名前衝突回避)
│   │   ├── sidebar.zig    — チャンネル一覧 (左ペイン)
│   │   ├── messages.zig   — メッセージ表示 (メインペイン)
│   │   ├── thread.zig     — スレッド表示 (右ペイン、トグル)
│   │   ├── input.zig      — メッセージ入力バー
│   │   ├── modal.zig      — ポップアップ (ワークスペース切替、検索等)
│   │   └── mrkdwn.zig     — Slack mrkdwn パーサ (メンション解決、書式変換)
│   │
│   ├── store/
│   │   ├── cache.zig      — メッセージ・チャンネルのインメモリキャッシュ (スレッドセーフ)
│   │   └── db.zig         — SQLite 永続化 (オフライン閲覧、将来のベクトル検索用)
│   │
│   └── platform/
│       └── keychain.zig   — macOS Keychain (Security.framework @cImport)
│
├── build.zig              — ビルド定義
├── build.zig.zon          — 依存宣言
└── README.md
```

### External Dependencies

| パッケージ | 用途 | リンク方式 |
|-----------|------|-----------|
| karlseguin/websocket.zig | WebSocket クライアント (TLS 1.3 対応) | Zig パッケージ |
| rockorager/libvaxis | TUI フレームワーク | Zig パッケージ |
| SQLite | メッセージキャッシュ・永続化 | C 静的リンク |
| sqlite-vec | ベクトル検索 (Phase 4) | C 拡張 |
| macOS Security.framework | Keychain アクセス | 動的リンク |

### Standard Library Usage

- `std.http.Client` — REST API 呼び出し
- `std.json` — JSON パース/シリアライズ
- `std.crypto` — HMAC 等（必要に応じて）
- `std.Thread` — バックグラウンドスレッド

## Concurrency Model

メインスレッド + バックグラウンドスレッドのマルチスレッド構成。Zig 0.15.x は安定した async/await を持たないため、明示的なスレッド + メッセージキューを採用する。

```
┌─────────────────┐    Event Queue    ┌──────────────────┐
│  Main Thread     │◄────────────────│  Socket Thread    │
│  (TUI rendering  │    (thread-safe  │  (websocket.zig   │
│   + event loop)  │     ring buffer) │   readLoop)       │
│                  │                  │                   │
│  libvaxis render │                  │  WebSocket recv   │
│  user input      │                  │  → parse event    │
│  REST API calls  │                  │  → enqueue        │
└─────────────────┘                  └──────────────────┘
```

### Thread Responsibilities

| スレッド | 責務 | ブロッキング対策 |
|---------|------|-----------------|
| **Main** | TUI 描画、ユーザー入力処理、REST API 呼び出し | REST は libvaxis のイベントループ間に実行。重い API 呼び出し（起動時の全チャンネル取得等）は起動フェーズで完了 |
| **Socket** | WebSocket 接続維持、イベント受信 | websocket.zig の `readLoopInNewThread` を使用 |

### Thread-Safe Communication

- Socket Thread → Main Thread: スレッドセーフなリングバッファ（`std.Thread.ResetEvent` で通知）
- `cache.zig` は `std.Thread.Mutex` で保護。読み書きは mutex 経由

## UI Layout

```
┌─────────────────────────────────────────────────────────┐
│ andgate  (workspace switcher: Ctrl+W)           Ctrl+? │
├──────────┬──────────────────────────┬───────────────────┤
│ Channels │ #team-infosys            │ Thread (toggle)   │
│          │                          │                   │
│ * general│ user_a  10:30           │ user_b  10:32    │
│   random │ おはようございます       │ 了解です           │
│ * team-  │                          │                   │
│   infosys│ user_b  10:32           │ user_c  10:45    │
│   sales  │ > おはようございます     │ 対応します         │
│          │ 了解です                  │                   │
│ ──DMs──  │                          │                   │
│  (Ph.2)  │ user_c  10:45           │                   │
│          │ チケット確認お願いします  │                   │
│          │                          │                   │
├──────────┴──────────────────────────┴───────────────────┤
│ > メッセージを入力... (Enter: 送信, Ctrl+T: スレッド)    │
└─────────────────────────────────────────────────────────┘
```

### Layout Components

- **ヘッダー**: ワークスペース名、ヘルプキー表示
- **サイドバー（左）**: チャンネル一覧。未読は `*` 表示。DM セクションは Phase 2（プレースホルダー表示）
- **メッセージペイン（中央）**: 選択チャンネルのメッセージ
- **スレッドペイン（右）**: トグル表示（Ctrl+T で開閉）
- **入力バー（下）**: メッセージ入力。コンテキストに応じてチャンネル/スレッド返信を切替

### Message Rendering (mrkdwn)

Slack メッセージは独自の mrkdwn フォーマットを使用する:

- `<@U12345>` → ユーザー名に解決（users キャッシュから引く）
- `<#C12345|channel-name>` → `#channel-name` に変換
- `*bold*`, `_italic_`, `~strike~`, `` `code` `` → TUI 属性に変換
- `>blockquote` → インデント + 色変更
- MVP ではメンション解決と基本書式のみ。コードブロック等は Phase 2 以降

### Keybindings

| キー | 操作 |
|------|------|
| `j` / `k` / `↑` / `↓` | リスト内移動 |
| `Ctrl+F` / `Ctrl+B` | ページダウン / ページアップ |
| `Tab` / `Shift+Tab` | ペイン間フォーカス移動 |
| `Enter` | チャンネル選択 / メッセージ送信 |
| `Ctrl+T` | スレッドペイン開閉 |
| `r` | 選択メッセージにスレッド返信 |
| `Ctrl+N` | チャンネル検索（ポップアップ） |
| `Ctrl+W` | ワークスペース切替（ポップアップ） |
| `Ctrl+R` | トークン再設定 |
| `q` / `Ctrl+C` | 終了 |
| マウスクリック | ペイン/チャンネル/メッセージ選択 |
| マウススクロール | メッセージスクロール |

## Data Model

### SQLite Schema (MVP)

```sql
-- ワークスペース
CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,              -- Slack team_id
    name TEXT NOT NULL,
    domain TEXT NOT NULL,
    user_token_keychain_key TEXT NOT NULL,  -- xoxp- トークンの Keychain サービス名
    app_token_keychain_key TEXT NOT NULL    -- xapp- トークンの Keychain サービス名
);

-- チャンネル
-- conversations.list の types=public_channel,private_channel で取得
-- (im, mpim は Phase 2 で追加)
CREATE TABLE channels (
    id TEXT PRIMARY KEY,              -- Slack channel_id
    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
    name TEXT NOT NULL,
    channel_type TEXT NOT NULL DEFAULT 'public_channel',
        -- 'public_channel' | 'private_channel' | 'im' | 'mpim' (Phase 2)
    is_member BOOLEAN DEFAULT TRUE,
    last_read_ts TEXT,                -- 未読管理用 (Slack float-string: "1679000000.123456")
    updated_at TEXT NOT NULL          -- Slack float-string timestamp
);

-- ユーザー
CREATE TABLE users (
    id TEXT PRIMARY KEY,              -- Slack user_id
    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
    name TEXT NOT NULL,
    display_name TEXT,
    is_bot BOOLEAN DEFAULT FALSE
);

-- メッセージ
-- thread_ts の解釈:
--   NULL → 通常メッセージ（スレッド親でない）
--   thread_ts == ts → スレッド親メッセージ
--   thread_ts != ts → スレッド内返信
-- conversations.replies は親メッセージも含めて返すため、
-- INSERT OR REPLACE で重複を処理する
CREATE TABLE messages (
    ts TEXT NOT NULL,                 -- Slack timestamp (メッセージID, float-string)
    channel_id TEXT NOT NULL REFERENCES channels(id),
    user_id TEXT,
    text TEXT NOT NULL,
    thread_ts TEXT,
    reply_count INTEGER DEFAULT 0,
    PRIMARY KEY (channel_id, ts)
);

-- オフライン送信キュー
CREATE TABLE outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
    channel_id TEXT NOT NULL,
    thread_ts TEXT,                   -- NULL ならチャンネル直送、非NULL ならスレッド返信
    text TEXT NOT NULL,
    created_at TEXT NOT NULL,         -- ISO 8601
    status TEXT NOT NULL DEFAULT 'pending'  -- 'pending' | 'sending' | 'failed'
);

-- Phase 4: ベクトル検索用 (MVP では未使用)
-- CREATE VIRTUAL TABLE message_vectors USING vec0(...);
```

### Cache Strategy

- **起動時**: `conversations.list` でチャンネル一覧を取得（カーソルベースページネーションで全件） → SQLite に保存
- **起動時**: `users.list` でユーザー一覧を取得（ページネーションで全件） → SQLite に保存。未知ユーザーは `users.info` でフォールバック
- **チャンネル選択時**: `conversations.history` でメッセージ取得 → キャッシュ & 表示
- **リアルタイム**: Socket Mode で新着メッセージを受信 → キャッシュに追加 & UI 更新
- **オフライン閲覧**: SQLite に保存済みのメッセージは再取得不要

### Pagination

`conversations.list`, `users.list` 等の Slack API はカーソルベースページネーション（1回最大200件）を使用する。`pagination.zig` で汎用的なカーソルイテレータを実装し、全件取得を保証する。

```
fn fetchAllPages(endpoint, params) -> []Item {
    loop:
        response = api.call(endpoint, params ++ cursor)
        items.append(response.items)
        if response.response_metadata.next_cursor == "" -> break
        cursor = response.response_metadata.next_cursor
}
```

## Slack API

### Authentication

#### Token Types

zlack は **2種類のトークン** を使用する:

| トークン | プレフィックス | 用途 | Keychain サービス名 |
|---------|-------------|------|-------------------|
| User Token | `xoxp-` | REST API (メッセージ送受信、チャンネル操作等) | `zlack.user.{team_id}` |
| App-Level Token | `xapp-` | Socket Mode (`apps.connections.open`) | `zlack.app.{team_id}` |

**User Token** は Slack App の OAuth & Permissions → User Token Scopes で権限を付与する。
**App-Level Token** は Slack App の Basic Information → App-Level Tokens で `connections:write` スコープ付きで生成する。

#### Required OAuth Scopes (User Token)

| スコープ | 用途 |
|---------|------|
| `channels:read` | 公開チャンネル一覧取得 |
| `channels:history` | 公開チャンネルメッセージ取得 |
| `channels:write` | 公開チャンネル既読マーク (`conversations.mark`) |
| `groups:read` | プライベートチャンネル一覧取得 |
| `groups:history` | プライベートチャンネルメッセージ取得 |
| `groups:write` | プライベートチャンネル既読マーク |
| `chat:write` | メッセージ送信 |
| `users:read` | ユーザー情報取得 |

#### Authentication Flow

```
初回起動
  → User Token (xoxp-) の入力を促す
  → App-Level Token (xapp-) の入力を促す
  → auth.test (User Token) で検証 → team_id 取得
  → macOS Keychain に保存:
      service: "zlack.user.{team_id}", account: "user_token"
      service: "zlack.app.{team_id}",  account: "app_token"

次回以降
  → Keychain からトークン読み込み
  → auth.test で有効性チェック
  → 失敗なら再入力を促す

トークン再設定
  → Ctrl+R または --reconfigure フラグで再入力フローを起動
```

### MVP Endpoints

| エンドポイント | 用途 | トークン | メソッド | ページネーション |
|---|---|---|---|---|
| `auth.test` | トークン検証 | User | POST | - |
| `conversations.list` | チャンネル一覧 | User | GET | cursor |
| `conversations.history` | メッセージ取得 | User | GET | cursor |
| `conversations.replies` | スレッド取得 | User | GET | cursor |
| `conversations.mark` | 既読マーク | User | POST | - |
| `chat.postMessage` | メッセージ送信 | User | POST | - |
| `users.list` | ユーザー一覧 | User | GET | cursor |
| `users.info` | ユーザー詳細 | User | GET | - |
| `apps.connections.open` | Socket Mode URL | **App-Level** | POST | - |

### Socket Mode (Real-time)

```
apps.connections.open (App-Level Token) → wss:// URL 取得
  → websocket.zig で接続 (Socket Thread)
  → イベント受信ループ:
      message: メッセージ受信 → Event Queue に enqueue
      reaction_added/removed: (Phase 2)
      channel_marked: 未読状態更新
  → Main Thread が Event Queue から dequeue → キャッシュ更新 → UI 再描画
  → 切断時: 自動再接続 (exponential backoff)
```

### Rate Limiting

| API | Tier | 制限 | 対策 |
|-----|------|------|------|
| `chat.postMessage` | Tier 3 | ~50 req/min | 入力バーに送信クールダウン表示。連打時はキューイング |
| `conversations.history` | Tier 3 | ~50 req/min | チャンネル切替時のみ呼び出し。キャッシュヒットで回避 |
| `conversations.list` | Tier 2 | ~20 req/min | 起動時のみ。ページネーション間隔を調整 |
| REST 全般 (429) | - | Retry-After | ヘッダーに従って待機後リトライ |
| REST 全般 (5xx) | - | - | 3回まで exponential backoff でリトライ |

## Error Handling

### Network Failures

```
WebSocket 切断
  → 即座に UI ヘッダーに「再接続中...」表示
  → Exponential backoff で再接続 (1s, 2s, 4s, 8s... 最大 30s)
  → 再接続成功 → 切断中のメッセージを conversations.history で補完

REST API エラー
  → 429 (Rate Limit): Retry-After ヘッダーに従って待機
  → 5xx: 3回までリトライ (exponential backoff)
  → 401 (Token Invalid): トークン再入力を促す (Ctrl+R と同じフロー)
```

### Offline Mode

- SQLite キャッシュから既読メッセージを表示
- 入力バーに「オフライン — 送信は接続回復後」と表示
- 送信メッセージは `outbox` テーブルに永続化（アプリ終了しても失われない）
- 再接続時に `outbox` から `pending` を順次送信。失敗は `failed` に更新し UI に通知
- `outbox` の最大キュー深度: 100件（超過時は古いものを破棄して警告）

## Build & Distribution

### Dependencies (build.zig.zon)

```
dependencies:
  - karlseguin/websocket.zig  (WebSocket + TLS)
  - rockorager/libvaxis         (TUI)
  - sqlite (C, static link)
  - sqlite-vec (C extension, Phase 4)
```

### Build Output

- **シングルバイナリ**: `zlack` (~3-5MB, `ReleaseSafe` ビルド)
- **ターゲット**: macOS aarch64 (Apple Silicon)。将来的に Linux 対応可
- **動的リンク**: macOS Security.framework のみ（Keychain 用）

## Phased Release Plan

| Phase | Scope | Dependencies |
|-------|-------|-------------|
| **Phase 1 (MVP)** | 認証 (2トークン)、チャンネル一覧 (public/private)、メッセージ閲覧/送信、スレッド閲覧/返信、mrkdwn 基本レンダリング | websocket.zig, libvaxis, SQLite |
| **Phase 2** | リアクション追加/削除、DM (im/mpim)、未読管理、メンション通知、コードブロック表示 | Phase 1 |
| **Phase 3** | ファイルアップロード、メッセージ検索、チャンネル検索 | Phase 2 |
| **Phase 4** | ベクトル検索（スクショ分析）、複数ワークスペース同時接続 | sqlite-vec, Claude API |

## Testing Strategy

### Unit Tests

- `slack/api.zig` — REST レスポンスの JSON パース
- `slack/types.zig` — 型変換、バリデーション
- `slack/pagination.zig` — ページネーション処理（空結果、1ページ、複数ページ）
- `tui/mrkdwn.zig` — mrkdwn パース（メンション解決、書式変換）
- `store/db.zig` — SQLite CRUD 操作、outbox キュー処理
- `platform/keychain.zig` — Keychain 読み書き

### Integration Tests

- WebSocket 接続 → メッセージ受信 → キャッシュ更新のフロー
- REST API モック → UI 状態更新の検証
- オフライン → outbox → 再接続 → 送信のフロー

### Manual Testing

- 実際の Slack ワークスペースに接続しての E2E 確認
