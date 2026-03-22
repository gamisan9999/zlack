# zlack MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zig で Slack TUI クライアントの MVP（認証、チャンネル一覧、メッセージ閲覧/送信、スレッド閲覧/返信）を構築する

**Architecture:** モノリシック Zig バイナリ。Main Thread (TUI + REST) + Socket Thread (WebSocket) のマルチスレッド構成。libvaxis で TUI、websocket.zig で Socket Mode、SQLite でキャッシュ

**Tech Stack:** Zig 0.15.x, libvaxis, websocket.zig, SQLite (C static link), macOS Security.framework

**Spec:** `docs/specs/2026-03-22-zlack-design.md`

---

## File Structure

```
zlack/
├── devenv.nix                  — 開発環境 (Zig, SQLite)
├── devenv.yaml                 — devenv 設定
├── .gitignore
├── build.zig                   — ビルド定義
├── build.zig.zon               — 依存宣言 (websocket.zig, libvaxis)
├── src/
│   ├── main.zig                — エントリポイント、引数パース
│   ├── app.zig                 — アプリ状態管理、イベントループ、スレッド間キュー
│   ├── slack/
│   │   ├── api.zig             — REST API クライアント
│   │   ├── socket.zig          — Socket Mode WebSocket
│   │   ├── types.zig           — Slack API 型定義
│   │   ├── auth.zig            — トークン管理
│   │   └── pagination.zig      — カーソルベースページネーション
│   ├── tui/
│   │   ├── root.zig            — libvaxis UI ルート
│   │   ├── sidebar.zig         — チャンネル一覧
│   │   ├── messages.zig        — メッセージ表示
│   │   ├── thread.zig          — スレッド表示
│   │   ├── input.zig           — メッセージ入力バー
│   │   ├── modal.zig           — ポップアップ
│   │   └── mrkdwn.zig          — Slack mrkdwn パーサ
│   ├── store/
│   │   ├── cache.zig           — インメモリキャッシュ (Mutex 保護)
│   │   └── db.zig              — SQLite 永続化
│   └── platform/
│       └── keychain.zig        — macOS Keychain
└── docs/
    ├── specs/                  — 設計ドキュメント
    └── plans/                  — 実装計画
```

---

### Task 1: プロジェクト初期化 (devenv + Zig scaffold)

**Files:**
- Create: `devenv.nix`
- Create: `devenv.yaml`
- Create: `.gitignore`
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`

- [ ] **Step 1: devenv.nix を作成**

```nix
{ pkgs, ... }:

{
  languages.zig.enable = true;

  packages = with pkgs; [
    sqlite
  ];
}
```

- [ ] **Step 2: devenv.yaml を作成**

```yaml
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
```

- [ ] **Step 3: .gitignore を作成**

```
.devenv/
.devenv.flake.nix
devenv.lock
.direnv/
zig-out/
zig-cache/
.zig-cache/
```

- [ ] **Step 4: devenv shell を起動して Zig が使えることを確認**

Run: `cd ~/Documents/dev/github.com/gamisan9999/zlack && devenv shell -- zig version`
Expected: `0.15.1` (or similar 0.15.x)

- [ ] **Step 5: build.zig.zon を作成（依存宣言）**

```zig
.{
    .name = .{ .value = "zlack" },
    .version = "0.1.0",
    .fingerprint = .auto,
    .minimum_zig_version = "0.15.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
    .dependencies = .{
        .websocket = .{
            .url = "https://github.com/karlseguin/websocket.zig/archive/refs/heads/master.tar.gz",
            .hash = .auto,
        },
        .vaxis = .{
            .url = "https://github.com/rockorager/libvaxis/archive/refs/heads/main.tar.gz",
            .hash = .auto,
        },
    },
}
```

Note: `.hash = .auto` は初回ビルド時にエラーで正しいハッシュを出力するので、それに置き換える。依存は特定コミットに固定すること（`main` ブランチ HEAD は不安定）。初回 `zig build` でハッシュエラーが出たら、表示されたハッシュに置き換える。

- [ ] **Step 6: build.zig を作成（最小構成）**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zlack",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));

    // SQLite (C static link)
    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");

    // macOS Keychain
    exe.linkFramework("Security");

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zlack");
    run_step.dependOn(&run_cmd.step);

    // Test step — モジュールごとに addTest を追加し、全テストを実行する
    const test_step = b.step("test", "Run unit tests");

    const test_modules = [_][]const u8{
        "src/main.zig",
        "src/store/db.zig",
        "src/slack/types.zig",
        "src/slack/pagination.zig",
        "src/slack/api.zig",
        "src/slack/auth.zig",
        "src/slack/socket.zig",
        "src/store/cache.zig",
        "src/tui/mrkdwn.zig",
        "src/platform/keychain.zig",
    };

    for (test_modules) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.linkLibC();
        unit_test.linkSystemLibrary("sqlite3");
        unit_test.linkFramework("Security");
        const run_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_test.step);
    }
}
```

**重要**: `zig build test` はモジュールごとに `addTest` を追加する構成。新しいモジュールを追加したら `test_modules` 配列にも追加すること。これにより全モジュールのテストが確実に実行される。

- [ ] **Step 7: src/main.zig を作成（Hello World）**

```zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("zlack v0.1.0\n", .{});
}
```

- [ ] **Step 8: ビルドして実行を確認**

Run: `devenv shell -- zig build run`
Expected: `zlack v0.1.0`

- [ ] **Step 9: テストを実行**

Run: `devenv shell -- zig build test`
Expected: All tests passed (no tests yet, should succeed)

- [ ] **Step 10: Commit**

```bash
git add devenv.nix devenv.yaml .gitignore build.zig build.zig.zon src/main.zig
git commit -m "プロジェクト初期化: devenv + Zig scaffold"
```

---

### Task 2: SQLite 永続化層 (store/db.zig)

**Files:**
- Create: `src/store/db.zig`
- Modify: `src/main.zig` (テスト用 import)

- [ ] **Step 1: db.zig のテストを書く — DB 初期化とテーブル作成**

```zig
// src/store/db.zig
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// ... (実装は Step 3)

test "initDb creates all tables" {
    var db = try Database.initInMemory();
    defer db.deinit();

    // workspaces テーブルが存在することを確認
    const count = try db.queryScalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='workspaces'");
    try std.testing.expectEqual(@as(i64, 1), count);
}

test "insertWorkspace and getWorkspace roundtrip" {
    var db = try Database.initInMemory();
    defer db.deinit();

    try db.insertWorkspace(.{
        .id = "T12345",
        .name = "test-workspace",
        .domain = "test",
        .user_token_keychain_key = "zlack.user.T12345",
        .app_token_keychain_key = "zlack.app.T12345",
    });

    const ws = try db.getWorkspace("T12345");
    try std.testing.expectEqualStrings("test-workspace", ws.?.name);
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `devenv shell -- zig build test`
Expected: FAIL (Database 構造体が未定義)

- [ ] **Step 3: Database 構造体と initInMemory, テーブル作成を実装**

`src/store/db.zig` に以下を実装:
- `Database` 構造体 (sqlite3 ポインタを保持)
- `initInMemory()` — `:memory:` で DB を開く
- `init(path)` — ファイルパスで DB を開く
- `deinit()` — DB を閉じる
- `createTables()` — spec のスキーマ (workspaces, channels, users, messages, outbox) を CREATE TABLE IF NOT EXISTS
- `insertWorkspace()`, `getWorkspace()` — ワークスペース CRUD

- [ ] **Step 4: テストが通ることを確認**

Run: `devenv shell -- zig build test`
Expected: All tests passed

- [ ] **Step 5: channels, users, messages の CRUD テストと実装を追加**

テスト:
- `insertChannel` / `getChannelsByWorkspace` roundtrip
- `insertUser` / `getUserById` roundtrip
- `insertMessage` / `getMessagesByChannel` roundtrip (ts 降順)
- `insertMessage` で同じ `(channel_id, ts)` を INSERT OR REPLACE しても壊れない

- [ ] **Step 6: outbox テストと実装を追加**

テスト:
- `enqueueMessage` で outbox に追加
- `getPendingMessages` で pending のみ取得
- `markAsSending` / `markAsFailed` でステータス更新
- `deleteFromOutbox` で送信済み削除

- [ ] **Step 7: テスト全通過を確認**

Run: `devenv shell -- zig build test`
Expected: All tests passed

- [ ] **Step 8: Commit**

```bash
git add src/store/db.zig
git commit -m "store/db.zig: SQLite 永続化層（全テーブル CRUD + outbox）"
```

---

### Task 3: Slack API 型定義 (slack/types.zig)

**Files:**
- Create: `src/slack/types.zig`

- [ ] **Step 1: 型定義のテストを書く — JSON デシリアライズ**

```zig
test "parse Channel from JSON" {
    const json =
        \\{"id":"C12345","name":"general","is_channel":true,"is_member":true}
    ;
    const channel = try std.json.parseFromSlice(Channel, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer channel.deinit();
    try std.testing.expectEqualStrings("C12345", channel.value.id);
    try std.testing.expectEqualStrings("general", channel.value.name);
}

test "parse Message from JSON" {
    const json =
        \\{"ts":"1679000000.123456","user":"U12345","text":"hello","thread_ts":null}
    ;
    const msg = try std.json.parseFromSlice(Message, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer msg.deinit();
    try std.testing.expectEqualStrings("1679000000.123456", msg.value.ts);
    try std.testing.expectEqualStrings("hello", msg.value.text);
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `devenv shell -- zig build test`
Expected: FAIL

- [ ] **Step 3: 型定義を実装**

`src/slack/types.zig`:
- `Channel` — id, name, is_channel, is_group, is_im, is_mpim, is_member, num_members
- `Message` — ts, user, text, thread_ts, reply_count, reactions (optional)
- `User` — id, name, real_name, display_name, is_bot
- `AuthTestResponse` — ok, user_id, team_id, team, user
- `ConversationsListResponse` — ok, channels, response_metadata (next_cursor)
- `ConversationsHistoryResponse` — ok, messages, has_more, response_metadata
- `ConversationsRepliesResponse` — ok, messages, has_more, response_metadata
- `UsersListResponse` — ok, members, response_metadata
- `AppsConnectionsOpenResponse` — ok, url
- `SlackError` — ok, error (エラーレスポンス)

- [ ] **Step 4: テスト全通過を確認**

Run: `devenv shell -- zig build test`
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git add src/slack/types.zig
git commit -m "slack/types.zig: Slack API 型定義 + JSON デシリアライズテスト"
```

---

### Task 4: ページネーション (slack/pagination.zig)

**Files:**
- Create: `src/slack/pagination.zig`

- [ ] **Step 1: ページネーションのテストを書く**

テスト:
- 空レスポンス (next_cursor == "") → 0件で終了
- 1ページ (next_cursor == "") → 全件返却
- 複数ページ (next_cursor あり → 2回呼び出し) → 全件結合

モック: API 呼び出しをコールバック関数で差し替え可能にする

- [ ] **Step 2: テスト失敗を確認**

- [ ] **Step 3: fetchAllPages を実装**

`ResponseMetadata` の `next_cursor` が空になるまでループ。結果を結合して返す。
コールバック `fn(cursor: ?[]const u8) !Response` を受け取る汎用設計。

- [ ] **Step 4: テスト全通過を確認**

- [ ] **Step 5: Commit**

```bash
git add src/slack/pagination.zig
git commit -m "slack/pagination.zig: カーソルベースページネーション"
```

---

### Task 5: Slack REST API クライアント (slack/api.zig)

**Files:**
- Create: `src/slack/api.zig`

- [ ] **Step 1: api.zig の構造体とインターフェースを定義**

```zig
pub const SlackClient = struct {
    allocator: std.mem.Allocator,
    user_token: []const u8,
    app_token: []const u8,
    http_client: std.http.Client,

    pub fn init(allocator: Allocator, user_token: []const u8, app_token: []const u8) SlackClient
    pub fn deinit(self: *SlackClient) void
    pub fn authTest(self: *SlackClient) !AuthTestResponse
    pub fn conversationsList(self: *SlackClient) ![]Channel  // pagination 内蔵
    pub fn conversationsHistory(self: *SlackClient, channel_id: []const u8, opts: struct { limit: u32 = 100, oldest: ?[]const u8 = null }) ![]Message
    pub fn conversationsReplies(self: *SlackClient, channel_id: []const u8, thread_ts: []const u8) ![]Message
    pub fn conversationsMark(self: *SlackClient, channel_id: []const u8, ts: []const u8) !void
    pub fn chatPostMessage(self: *SlackClient, channel_id: []const u8, text: []const u8, thread_ts: ?[]const u8) !void
    pub fn usersList(self: *SlackClient) ![]User  // pagination 内蔵
    pub fn usersInfo(self: *SlackClient, user_id: []const u8) !User
    pub fn appsConnectionsOpen(self: *SlackClient) ![]const u8  // returns wss:// URL
};
```

- [ ] **Step 2: 内部ヘルパーを実装**

- `apiCall(method, token, params) -> []const u8` — HTTP POST/GET + JSON レスポンス body 返却
- `parseResponse(comptime T, body) -> T` — JSON パース + エラーチェック (ok == false → error)
- Rate limit handling: 429 → Retry-After で sleep してリトライ
- 5xx → 3回リトライ (exponential backoff)
- リトライ判定ロジックは純粋関数 `shouldRetry(status_code, attempt) -> RetryAction` として分離し、ユニットテスト可能にする

- [ ] **Step 3: 各エンドポイントメソッドを実装**

`conversationsList` と `usersList` は `pagination.zig` の `fetchAllPages` を使用。

- [ ] **Step 4: テスト（JSON パース + リトライロジック）**

実際の API 呼び出しはテストしない（E2E で確認）。

テスト:
- JSON レスポンス文字列 → 型変換 → フィールド検証
- `shouldRetry(429, 1)` → `RetryAction{ .wait_ms = <Retry-After value> }`
- `shouldRetry(500, 1)` → `RetryAction{ .wait_ms = 1000 }` (1回目)
- `shouldRetry(500, 4)` → `RetryAction.give_up` (3回超過)
- `shouldRetry(200, 1)` → `RetryAction.success`

- [ ] **Step 5: テスト全通過を確認**

Run: `devenv shell -- zig build test`

- [ ] **Step 6: Commit**

```bash
git add src/slack/api.zig
git commit -m "slack/api.zig: Slack REST API クライアント（全 MVP エンドポイント）"
```

---

### Task 6: macOS Keychain (platform/keychain.zig)

**Files:**
- Create: `src/platform/keychain.zig`

- [ ] **Step 1: Keychain インターフェースを定義**

```zig
pub const Keychain = struct {
    pub fn save(service: []const u8, account: []const u8, password: []const u8) !void
    pub fn load(allocator: Allocator, service: []const u8, account: []const u8) !?[]const u8
    pub fn delete(service: []const u8, account: []const u8) !void
};
```

- [ ] **Step 2: Security.framework の @cImport と実装**

macOS Security.framework の `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete` を使用。
`@cImport(@cInclude("Security/Security.h"))` で C API をインポート。

build.zig に `exe.linkFramework("Security")` を追加。

- [ ] **Step 3: テスト（実機テスト）**

Keychain テストは実機でしか動かないため、テスト用のサービス名 `zlack.test.xxx` を使用し、テスト後に削除する。

テスト:
- save → load で値が一致
- load で存在しないキー → null
- save → delete → load で null

- [ ] **Step 4: テスト全通過を確認**

- [ ] **Step 5: Commit**

```bash
git add src/platform/keychain.zig build.zig
git commit -m "platform/keychain.zig: macOS Keychain 読み書き"
```

---

### Task 7: 認証フロー (slack/auth.zig)

**Files:**
- Create: `src/slack/auth.zig`

- [ ] **Step 1: auth.zig のインターフェースを定義**

```zig
pub const Auth = struct {
    user_token: []const u8,
    app_token: []const u8,
    team_id: []const u8,
    user_id: []const u8,

    /// Keychain からトークンを読み込み、auth.test で検証。
    /// 失敗時は null を返す（呼び出し元が対話入力に誘導）
    pub fn loadFromKeychain(allocator: Allocator) !?Auth

    /// トークンを Keychain に保存
    pub fn saveToKeychain(self: Auth) !void

    /// 対話式でトークン入力を促す (stdin/stdout)
    pub fn promptForTokens(allocator: Allocator) !Auth
};
```

- [ ] **Step 2: 実装 — Keychain 読み込み → auth.test 検証 → 保存**

- `loadFromKeychain`: Keychain から読み込み → `SlackClient.authTest()` で検証 → team_id / user_id を取得
- `saveToKeychain`: `zlack.user.{team_id}` / `zlack.app.{team_id}` で保存
- `promptForTokens`: stdin から xoxp- / xapp- を読み取り、検証して返す

- [ ] **Step 3: テスト — トークンフォーマット検証**

```zig
test "validateToken rejects invalid prefix" {
    try std.testing.expectError(error.InvalidTokenFormat, Auth.validateUserToken("xoxb-invalid"));
    try std.testing.expectError(error.InvalidTokenFormat, Auth.validateAppToken("xoxp-invalid"));
}

test "validateToken accepts valid prefix" {
    try Auth.validateUserToken("xoxp-valid-token");
    try Auth.validateAppToken("xapp-valid-token");
}
```

Note: `auth.test` API 呼び出しの統合テストは Task 18 (E2E) で検証する。

- [ ] **Step 4: テスト全通過を確認**

Run: `devenv shell -- zig build test`

- [ ] **Step 5: Commit**

```bash
git add src/slack/auth.zig
git commit -m "slack/auth.zig: 認証フロー（Keychain + 対話式入力）"
```

---

### Task 8: Socket Mode WebSocket (slack/socket.zig)

**Files:**
- Create: `src/slack/socket.zig`

- [ ] **Step 1: Event 型とイベントキューを定義**

```zig
pub const Event = union(enum) {
    message: types.Message,
    channel_marked: struct { channel_id: []const u8, ts: []const u8 },
    reconnect_requested: void,
    error_event: []const u8,
};

/// スレッドセーフなイベントキュー。
/// capacity: 512。オーバーフロー時は最古のイベントを上書き (ring buffer)。
/// Main Thread が遅延しても Socket Thread がブロックしないことを優先する。
pub const EventQueue = struct {
    const CAPACITY = 512;
    buffer: [CAPACITY]?Event = [_]?Event{null} ** CAPACITY,
    write_idx: usize = 0,
    read_idx: usize = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn push(self: *EventQueue, event: Event) void
    pub fn pop(self: *EventQueue) ?Event
};
```

- [ ] **Step 2: SocketClient を実装**

```zig
pub const SocketClient = struct {
    allocator: Allocator,
    event_queue: *EventQueue,
    ws_client: ?websocket.Client,

    pub fn connect(self: *SocketClient, wss_url: []const u8) !void
    pub fn startReadLoop(self: *SocketClient) !std.Thread
    pub fn disconnect(self: *SocketClient) void

    // websocket.zig の serverMessage コールバック
    pub fn serverMessage(self: *SocketClient, data: []u8) !void
    // → JSON パース → Event に変換 → EventQueue に push
};
```

- [ ] **Step 3: 再接続ロジック**

切断検知 → exponential backoff (1s, 2s, 4s, 8s... max 30s) → `apps.connections.open` で新 URL 取得 → 再接続。
`EventQueue` に `reconnect_requested` を push して UI に通知。

- [ ] **Step 4: テスト（EventQueue のスレッドセーフテスト）**

テスト:
- 単スレッドで push/pop
- 2スレッドから同時 push → pop で全件取得

- [ ] **Step 5: Commit**

```bash
git add src/slack/socket.zig
git commit -m "slack/socket.zig: Socket Mode WebSocket + イベントキュー"
```

---

### Task 9: インメモリキャッシュ (store/cache.zig)

**Files:**
- Create: `src/store/cache.zig`

- [ ] **Step 1: テストを書く**

```zig
test "updateChannels and getChannels roundtrip" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    // channels を追加して取得できることを確認
}

test "addMessage and getMessages returns sorted by ts" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    // 順不同で追加しても ts 昇順で取得できることを確認
}

test "getUserName returns null for unknown user" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), cache.getUserName("U_UNKNOWN"));
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `devenv shell -- zig build test`
Expected: FAIL (Cache 構造体が未定義)

- [ ] **Step 3: Cache 構造体を実装**

```zig
pub const Cache = struct {
    mutex: std.Thread.Mutex,
    channels: std.StringHashMap(types.Channel),
    users: std.StringHashMap(types.User),
    messages: std.StringHashMap(std.ArrayList(types.Message)),  // channel_id -> messages

    pub fn init(allocator: Allocator) Cache
    pub fn deinit(self: *Cache) void
    pub fn updateChannels(self: *Cache, channels: []const types.Channel) void
    pub fn updateUsers(self: *Cache, users: []const types.User) void
    pub fn addMessage(self: *Cache, channel_id: []const u8, msg: types.Message) void
    pub fn getMessages(self: *Cache, channel_id: []const u8) ?[]const types.Message
    pub fn getUserName(self: *Cache, user_id: []const u8) ?[]const u8
};
```

全メソッドは `self.mutex.lock()` / `self.mutex.unlock()` で保護。

- [ ] **Step 2: テスト**

- updateChannels → getChannels roundtrip
- addMessage → getMessages で ts 順ソート
- getUserName で存在しないユーザー → null

- [ ] **Step 3: 実装**

- [ ] **Step 4: テスト全通過を確認**

- [ ] **Step 5: Commit**

```bash
git add src/store/cache.zig
git commit -m "store/cache.zig: スレッドセーフなインメモリキャッシュ"
```

---

### Task 10: mrkdwn パーサ (tui/mrkdwn.zig)

**Files:**
- Create: `src/tui/mrkdwn.zig`

- [ ] **Step 1: テストを書く**

```zig
test "resolve user mention" {
    const resolver = MrkdwnResolver.init(test_user_lookup);
    const result = try resolver.resolve(allocator, "<@U12345> hello");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("@user_a hello", result);
}

test "resolve channel link" {
    const result = try resolver.resolve(allocator, "<#C12345|general> を見て");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("#general を見て", result);
}

test "plain text unchanged" {
    const result = try resolver.resolve(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}
```

- [ ] **Step 2: テスト失敗を確認**

- [ ] **Step 3: MrkdwnResolver を実装**

MVP では:
- `<@U12345>` → `@display_name` (Cache から引く。見つからなければ `@unknown`)
- `<#C12345|name>` → `#name`
- `<URL>` → URL テキストそのまま
- `*bold*`, `_italic_`, `~strike~` → MVP ではテキストとしてそのまま表示（TUI 属性装飾は Phase 2）
- `&amp;`, `&lt;`, `&gt;` → HTML エンティティデコード

- [ ] **Step 4: テスト全通過を確認**

- [ ] **Step 5: Commit**

```bash
git add src/tui/mrkdwn.zig
git commit -m "tui/mrkdwn.zig: Slack mrkdwn パーサ（メンション解決、基本変換）"
```

---

### Task 11: TUI — サイドバー (tui/sidebar.zig)

**Files:**
- Create: `src/tui/sidebar.zig`

- [ ] **Step 1: Sidebar ウィジェットを実装**

libvaxis のウィジェット API を使用:
- チャンネルリスト描画 (公開 `#` / プライベート `🔒`)
- 未読チャンネルに `*` マーク
- 選択カーソル (ハイライト)
- j/k/↑/↓ で移動、Enter で選択
- `──DMs──` セクション (Phase 2 プレースホルダー)

- [ ] **Step 2: ビルド確認（スモークテスト）**

Run: `devenv shell -- zig build`
Expected: コンパイル成功（TUI ウィジェットは描画テストが困難なため、ビルド成功をゲートとする）

- [ ] **Step 3: Commit**

```bash
git add src/tui/sidebar.zig
git commit -m "tui/sidebar.zig: チャンネル一覧サイドバー"
```

---

### Task 12: TUI — メッセージペイン (tui/messages.zig)

**Files:**
- Create: `src/tui/messages.zig`

- [ ] **Step 1: Messages ウィジェットを実装**

- メッセージリスト描画: `user_name  HH:MM` + テキスト
- mrkdwn.zig でメンション解決してから表示
- スレッド親には `[N replies]` 表示
- j/k/↑/↓/Ctrl+F/Ctrl+B でスクロール
- マウスホイールスクロール

- [ ] **Step 2: ビルド確認**

Run: `devenv shell -- zig build`
Expected: コンパイル成功

- [ ] **Step 3: Commit**

```bash
git add src/tui/messages.zig
git commit -m "tui/messages.zig: メッセージ表示ペイン"
```

---

### Task 13: TUI — スレッドペイン (tui/thread.zig)

**Files:**
- Create: `src/tui/thread.zig`

- [ ] **Step 1: Thread ウィジェットを実装**

- messages.zig と同様の描画ロジック（共通部分は抽出可能）
- Ctrl+T でトグル表示
- 親メッセージをヘッダーに表示
- 返信一覧を時系列で表示

- [ ] **Step 2: ビルド確認**

Run: `devenv shell -- zig build`
Expected: コンパイル成功

- [ ] **Step 3: Commit**

```bash
git add src/tui/thread.zig
git commit -m "tui/thread.zig: スレッド表示ペイン"
```

---

### Task 14: TUI — 入力バー (tui/input.zig)

**Files:**
- Create: `src/tui/input.zig`

- [ ] **Step 1: Input ウィジェットを実装**

- テキスト入力 (カーソル移動、バックスペース、日本語入力対応)
- Enter で送信 (コンテキストに応じてチャンネルまたはスレッドへ)
- プレースホルダー: `> メッセージを入力...`
- スレッドモード時: `> スレッドに返信...`

- [ ] **Step 2: ビルド確認**

Run: `devenv shell -- zig build`
Expected: コンパイル成功

- [ ] **Step 3: Commit**

```bash
git add src/tui/input.zig
git commit -m "tui/input.zig: メッセージ入力バー"
```

---

### Task 15: TUI — ルートレイアウト (tui/root.zig)

**Files:**
- Create: `src/tui/root.zig`

- [ ] **Step 1: レイアウト構成を実装**

libvaxis でペインを配置:
- ヘッダー (1行): ワークスペース名 + Ctrl+? ヘルプ
- サイドバー (幅 20文字固定)
- メッセージペイン (flex)
- スレッドペイン (幅 30文字、Ctrl+T でトグル)
- 入力バー (2行)
- Tab/Shift+Tab でフォーカス移動

- [ ] **Step 2: ビルド確認**

Run: `devenv shell -- zig build`
Expected: コンパイル成功

- [ ] **Step 3: Commit**

```bash
git add src/tui/root.zig
git commit -m "tui/root.zig: 3ペインレイアウト + フォーカス管理"
```

---

### Task 16: TUI — モーダル (tui/modal.zig)

**Files:**
- Create: `src/tui/modal.zig`

- [ ] **Step 1: モーダルポップアップを実装**

- ワークスペース切替 (Ctrl+W): リスト表示 → 選択
- チャンネル検索 (Ctrl+N): テキスト入力 → フィルタ → 選択
- 中央に浮遊する矩形、背景を暗くする

- [ ] **Step 2: ビルド確認**

Run: `devenv shell -- zig build`
Expected: コンパイル成功

- [ ] **Step 3: Commit**

```bash
git add src/tui/modal.zig
git commit -m "tui/modal.zig: ワークスペース切替・チャンネル検索モーダル"
```

---

### Task 17: アプリケーション統合 (app.zig + main.zig)

**Files:**
- Create: `src/app.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: app.zig — アプリケーション状態管理**

```zig
pub const App = struct {
    allocator: Allocator,
    auth: Auth,
    slack_client: SlackClient,
    socket_client: SocketClient,
    cache: Cache,
    db: Database,
    tui: TuiRoot,
    event_queue: EventQueue,
    current_channel: ?[]const u8,

    pub fn init(allocator: Allocator) !App
    pub fn deinit(self: *App) void
    pub fn run(self: *App) !void  // メインイベントループ
};
```

- [ ] **Step 2: メインイベントループを実装**

```
run():
  1. auth.loadFromKeychain() or auth.promptForTokens()
  2. slack_client.init(user_token, app_token)
  3. libvaxis を初期化し、ローディング画面を表示
     ("zlack を起動中... チャンネル一覧を取得しています")
     ※ Ctrl+C でクリーンに終了できるよう、signal handler を設定
  4. conversations.list → cache + db に保存 (ローディング表示更新)
  5. users.list → cache + db に保存 (ローディング表示更新)
  6. apps.connections.open → socket_client.connect()
  7. socket_client.startReadLoop() (Socket Thread 起動)
  8. ローディング画面をメイン UI に切り替え
  9. loop:
     a. libvaxis のイベント poll (キー入力、マウス、リサイズ)
     b. event_queue.pop() で Socket イベントを処理
        - reconnect_requested の場合: outbox の pending を flush 送信
     c. ユーザーアクションに応じて REST API 呼び出し
     d. TUI 再描画
```

**重要**: ステップ 3 で libvaxis を先に初期化してローディング画面を表示してから、ブロッキング API 呼び出し (4, 5) を実行する。API 呼び出し中にエラーが発生した場合は、libvaxis を正しく deinit してターミナルを復元してからエラーメッセージを表示する。

- [ ] **Step 3: main.zig を更新**

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}
```

引数パース: `--reconfigure` フラグ対応。

```zig
const args = try std.process.argsAlloc(allocator);
defer std.process.argsFree(allocator, args);

const reconfigure = for (args[1..]) |arg| {
    if (std.mem.eql(u8, arg, "--reconfigure")) break true;
} else false;

if (reconfigure) {
    // 既存トークンを無視して対話式入力を強制
    const auth = try Auth.promptForTokens(allocator);
    try auth.saveToKeychain();
}
```

- [ ] **Step 4: ビルドして起動を確認**

Run: `devenv shell -- zig build run`
Expected: トークン入力プロンプトが表示される（初回起動）

- [ ] **Step 5: Commit**

```bash
git add src/app.zig src/main.zig
git commit -m "app.zig + main.zig: アプリケーション統合・メインイベントループ"
```

---

### Task 18: E2E 手動テスト

- [ ] **Step 1: Slack App を作成し、トークンを取得**

1. https://api.slack.com/apps でアプリ作成
2. OAuth & Permissions → User Token Scopes に必要なスコープを追加
3. App-Level Tokens で `connections:write` スコープ付きトークンを生成
4. Socket Mode を有効化

- [ ] **Step 2: zlack を起動してトークンを入力**

Run: `devenv shell -- zig build run`
- User Token (xoxp-) を入力
- App-Level Token (xapp-) を入力
- チャンネル一覧が表示されることを確認

- [ ] **Step 3: 基本操作を確認**

- [ ] チャンネル選択 → メッセージ表示
- [ ] メッセージ送信 → Slack に反映
- [ ] スレッド表示 (Ctrl+T)
- [ ] スレッド返信 → Slack に反映
- [ ] リアルタイム受信 (別端末から送信 → zlack に表示)
- [ ] Ctrl+N でチャンネル検索
- [ ] q で終了

- [ ] **Step 4: Commit (README 追加)**

```bash
git add README.md
git commit -m "README.md: セットアップ手順・使い方"
```

---

### Task 19: 最終整備

- [ ] **Step 1: `zig build test` で全テスト通過を確認**

- [ ] **Step 2: `zig build -Doptimize=ReleaseSafe` でリリースビルド確認**

- [ ] **Step 3: バイナリサイズを確認**

Run: `ls -lh zig-out/bin/zlack`
Expected: ~3-5MB

- [ ] **Step 4: Commit & push**

```bash
git push origin main
```
