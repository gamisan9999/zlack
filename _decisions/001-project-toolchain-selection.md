# 001: プロジェクトツールチェーン選定

- **Status:** Accepted
- **Date:** 2026-03-22

## Context

zlack は macOS 向け TUI Slack クライアント。以下の要件がある:
- Slack Socket Mode WebSocket 接続
- TUI (Terminal UI) レンダリング
- ローカルキャッシュ (SQLite)
- macOS Keychain によるトークン管理
- 再現可能な開発環境

## Decision

以下のツールチェーンを採用する:

| カテゴリ | ツール | 理由 |
|---------|--------|------|
| 言語 | Zig 0.15.x | C interop が容易、SQLite/Security.framework とのリンクが自然 |
| TUI | libvaxis (rockorager/libvaxis) | Zig ネイティブ TUI ライブラリ、kitty graphics protocol 対応 |
| WebSocket | websocket.zig (karlseguin/websocket.zig) | Zig ネイティブ WebSocket 実装 |
| DB | SQLite (system library) | 組み込み DB、Nix 経由で提供 |
| 開発環境 | devenv (cachix/devenv) | Nix ベースの再現可能な開発環境 |

## Consequences

- Zig 0.15 は安定版ではないため、API の破壊的変更に追従が必要
- libvaxis / websocket.zig は main ブランチを参照しているため、ハッシュ固定で安定化
- macOS Security.framework のリンクには CommandLineTools SDK のパスを明示する必要がある (Nix 環境の制約)
