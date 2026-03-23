# 004: HTTP stale connection リトライ戦略

- **Status:** Accepted
- **Date:** 2026-03-23

## Context

Zig の `std.http.Client` はコネクションプールを内部で保持する。
Slack API を長時間使用すると、サーバー側がアイドル接続を切断し、
クライアントが stale connection を再利用して `HttpConnectionClosing` や `WriteFailed` が発生する。

初回の対処（リトライのみ）では不十分だった。同じ壊れたコネクションプールを再利用するため、
リトライしても同じエラーが繰り返された。

## Decision

`apiCall` の fetch エラーハンドリングで、`HttpConnectionClosing` または `WriteFailed` の場合:

1. `http_client.deinit()` でコネクションプールを破棄
2. `http_client = std.http.Client{ .allocator = self.allocator }` で再初期化
3. 最大3回までリトライ

## Consequences

- **Positive:** stale connection による全 API 呼び出し失敗を自動回復。
- **Positive:** ユーザーに見えるエラー（No messages 等）が解消。
- **Negative:** deinit/init のコストがリトライごとに発生（TLS ハンドシェイクのやり直し）。許容範囲。
- **Negative:** リトライ中は UI がブロックされる。将来的に非同期化が必要。

## Alternatives Considered

- **リトライのみ（deinit なし）:** コネクションプールが壊れたままで無効。実際に失敗した。
- **リクエストごとに新しい http_client:** 毎回 TLS ハンドシェイクが発生し遅い。コネクションプールの恩恵がなくなる。
- **keep-alive 無効化:** `Connection: close` ヘッダーで毎回新しい接続。パフォーマンスとのトレードオフ。

## Related Commits
- PR #5: fix: HTTP stale connection でリトライ
- PR #6: fix: stale connection リトライ時に HTTP client リセット
