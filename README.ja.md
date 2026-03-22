# zlack

ターミナルで動く軽量 Slack クライアント。Zig で構築。

**約 6,700 行の Zig / 5.5MB バイナリ / ランタイム依存ゼロ**

[English](README.md) | 日本語 | [简体中文](README.zh.md)

## 機能

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

## 必要なもの

- macOS（Keychain 利用）または Linux（環境変数/プロンプト認証）
- [devenv](https://devenv.sh/)（Zig と SQLite を提供）
- Socket Mode が有効な Slack App

### Slack App に必要な権限（User Token Scopes）

| スコープ | 用途 |
|---------|------|
| `channels:read` | チャンネル一覧 |
| `channels:history` | メッセージ履歴 |
| `channels:write` | メッセージ投稿 |
| `groups:read` | プライベートチャンネル一覧 |
| `groups:history` | プライベートチャンネル履歴 |
| `groups:write` | プライベートチャンネルへの投稿 |
| `im:read` | DM 一覧 |
| `im:history` | DM 履歴 |
| `im:write` | DM 送信 |
| `users:read` | ユーザー一覧（表示名取得） |
| `chat:write` | メッセージ投稿 |
| `files:write` | ファイルアップロード |

### Slack App の設定

- **Socket Mode**: 有効化
- **Event Subscriptions**: `message.channels`, `message.groups`, `message.im`
- **App-Level Token**: `connections:write` スコープ付き

## ビルド

```bash
git clone https://github.com/gamisan9999/zlack.git
cd zlack
devenv shell
zig build
```

バイナリは `zig-out/bin/zlack` に出力されます。

### Git hooks の設定（コントリビューター向け）

```bash
git config core.hooksPath .githooks
```

## 起動

### 初回起動（トークン設定）

```bash
# 方法1: 環境変数
ZLACK_USER_TOKEN=xoxp-... ZLACK_APP_TOKEN=xapp-... ./zig-out/bin/zlack

# 方法2: 対話プロンプト
./zig-out/bin/zlack
# Enter User Token (xoxp-...): <トークンを貼り付け>
# Enter App Token (xapp-...): <トークンを貼り付け>
```

初回認証成功時に macOS Keychain にトークンが保存されます。

### 2回目以降

```bash
./zig-out/bin/zlack
```

### トークン再設定

```bash
./zig-out/bin/zlack --reconfigure
```

## キーバインド

### ナビゲーション

| キー | 操作 |
|------|------|
| `Tab` | フォーカス切替（チャンネル → メッセージ → 入力欄） |
| `Shift+Tab` | フォーカス逆順切替 |
| `j` / `↓` | リスト内で下に移動 |
| `k` / `↑` | リスト内で上に移動 |
| `Ctrl+F` | ページダウン（10件） |
| `Ctrl+B` | ページアップ（10件） |
| `Enter` | チャンネル選択 / スレッド表示 / メッセージ送信 |

### コマンド

| キー | 操作 |
|------|------|
| `Ctrl+K` | チャンネル検索 |
| `Ctrl+U` | ファイルアップロード |
| `Ctrl+T` | スレッドペイン表示/非表示 |
| `Escape` | スレッド閉じ / アップロードキャンセル |
| `Ctrl+C` / `Ctrl+Q` | 終了 |

### メッセージング

| キー | 操作 |
|------|------|
| `Enter` | メッセージ送信（スレッドモード時はスレッド返信） |
| `Shift+Enter` | スレッド返信 + チャンネルにも投稿 |
| `@名前` | 送信時に自動で Slack メンションに変換 |

### マウス操作

| 操作 | 効果 |
|------|------|
| サイドバークリック | チャンネル選択 + 入力欄にフォーカス |
| メッセージ領域クリック | メッセージ選択 |
| メッセージダブルクリック | スレッド表示 |
| スクロールホイール | サイドバー/メッセージのスクロール |

## テスト

```bash
devenv shell
zig build test --summary all
```

64 テスト（型定義、認証、キャッシュ、UTF-8 処理、タイムスタンプ変換）

## ライセンス

MIT
