# 005: ファイルアップロード/ダウンロード API 設計

- **Status:** Accepted
- **Date:** 2026-03-23

## Context

Slack のファイル操作には複数の API がある:
- **Upload (legacy):** `files.upload` — 1ステップだが deprecated
- **Upload (new):** 3ステップ方式 — `files.getUploadURLExternal` → PUT → `files.completeUploadExternal`
- **Download:** `url_private` フィールドに Bearer 認証で GET

## Decision

### アップロード

新しい3ステップ API を採用:

1. `files.getUploadURLExternal` — presigned URL と file_id を取得
2. 取得した URL に POST でファイルデータを送信
3. `files.completeUploadExternal` — file_id とチャンネル ID で共有を完了

操作キー: `Ctrl+U` → ファイルパス入力 → Enter

### ダウンロード

`conversations.history` のレスポンスに含まれる `files[0].url_private` に、
`Authorization: Bearer {user_token}` ヘッダー付きで GET。
保存先は `~/Downloads/{filename}`。

操作キー: `Ctrl+D`（Messages ペインで選択中のメッセージ）

### データフロー

メッセージの `files` フィールドを `SlackFile` 型でパース → `CachedMessage` に `file_name`, `file_url`, `file_size` を保持 → `MessageEntry.FileInfo` として TUI に渡す → `[Ctrl+D] filename (size)` と黄色で表示。

## Consequences

- **Positive:** 新 API は Slack 推奨。50MB まで対応。
- **Positive:** ダウンロードは追加 scope 不要（`files:read` は history のレスポンスに含まれる）。
- **Negative:** アップロードに `files:write` scope が必要（ユーザーが Slack App で追加する必要がある）。
- **Negative:** 10MB 以上のダウンロードは現在の固定バッファ (10MB) で失敗する。将来的にストリーミングダウンロードが必要。
- **Negative:** 複数ファイル添付のうち最初の1つしか表示・ダウンロードできない。

## References

- https://api.slack.com/messaging/files
- Slack App scope: `files:write` (upload), `files:read` (download URL in history)
