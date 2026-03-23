# 003: Socket Mode envelope_id ACK と ping/pong 対応

- **Status:** Accepted
- **Date:** 2026-03-23

## Context

Slack Socket Mode は WebSocket でリアルタイムイベントを受信する。
zlack は `websocket.zig` ライブラリの `client.read()` を使って低レベルにメッセージを読んでいた。

2つの問題が発見された:

1. **envelope_id ACK 未送信:** Slack は `envelope_id` 付きイベントに対して3秒以内の ACK を要求する。ACK がないとメッセージを再送し、最終的に切断する。
2. **ping/pong 未対応:** `client.read()` は ping フレームを自動処理しない（`readLoop()` は自動処理するが、我々は `read()` を使用）。Slack サーバーの ping に応答しないと切断される。

短時間のテストでは顕在化しないが、長時間運用では確実に切断が発生する。

## Decision

### envelope_id ACK

`handleMessage` でメッセージをパースした直後、`envelope_id` フィールドが存在すれば `{"envelope_id": "..."}` を WebSocket で送り返す。イベント処理より先に ACK を送信する。

### ping/pong

`readLoopThread` で `msg.type == .ping` を検出し、`client.writePong()` で応答する。`readLoop()` への切り替えも検討したが、現在のイベントキュー方式と互換性がないため `read()` + 手動 pong を採用。

## Consequences

- **Positive:** 長時間接続が安定する。メッセージの再送・ロストが防止される。
- **Positive:** Slack Socket Mode の仕様に準拠。
- **Negative:** `writeText` が read ループスレッドから呼ばれるため、送信と受信が同じスレッドで発生。websocket.zig がスレッドセーフかは要確認（現状問題なし）。

## References

- https://api.slack.com/apis/socket-mode#acknowledge
- Issue #10
