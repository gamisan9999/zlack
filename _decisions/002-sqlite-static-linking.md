# 002: SQLite 静的リンクによるポータブルバイナリ

- **Status:** Accepted
- **Date:** 2026-03-23

## Context

ローカル開発環境 (Nix/devenv) でビルドしたバイナリが、他の macOS マシンで動作しなかった。
`otool -L` で確認すると `/nix/store/.../libsqlite3.dylib` に動的リンクしており、
Nix がインストールされていない環境ではライブラリが見つからずクラッシュする。

CI (GitHub Actions) の Linux ビルドでも `libsqlite3-dev` のインストールが必要だった。

## Decision

`build.zig` の `linkSystemLibrary("sqlite3")` を `linkSystemLibrary2("sqlite3", .{ .preferred_link_mode = .static })` に変更し、SQLite を静的リンクする。

## Consequences

- **Positive:** バイナリコピーだけでどの macOS でも動作する。CI でも apt install 後に静的リンク可能。
- **Positive:** 動的依存は macOS 標準ライブラリ (Security, CoreFoundation, libSystem) のみ。
- **Negative:** バイナリサイズが若干増加（SQLite 分 ~1MB）。
- **Negative:** SQLite のセキュリティパッチ適用にはリビルドが必要（OS のライブラリ更新では対応されない）。

## Alternatives Considered

- **SQLite amalgamation をソースとしてバンドル:** 確実だが build.zig の変更が大きい。`preferred_link_mode = .static` で十分だった。
- **Nix flake でビルド環境を固定:** CI でも Nix を使う方法。ghostty 等の大規模プロジェクトが採用。zlack の規模では過剰。
