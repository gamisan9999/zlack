# セキュリティテストレポート

- **対象**: zlack v0.1.1
- **日付**: 2026-03-23
- **テスト者**: Claude Code
- **基準**: OWASP Top 10:2021 + OWASP Top 10:2025

---

## OWASP Top 10:2021 → 2025 変更サマリ

| 2021 | 2025 | 変更 |
|------|------|------|
| A01: Broken Access Control | A01: Broken Access Control | 維持 (SSRF を統合) |
| A02: Cryptographic Failures | A04: Cryptographic Failures | 順位変更 |
| A03: Injection | A05: Injection | 順位変更 |
| A04: Insecure Design | A06: Insecure Design | 順位変更 |
| A05: Security Misconfiguration | A02: Security Misconfiguration | 順位上昇 (#5→#2) |
| A06: Vulnerable Components | A03: Software Supply Chain Failures | **拡張・改名** |
| A07: Auth Failures | A07: Authentication Failures | 維持 |
| A08: Data Integrity Failures | A08: Data Integrity Failures | 維持 |
| A09: Logging Failures | A09: Security Logging & Alerting Failures | **Alerting 追加** |
| A10: SSRF | (A01 に統合) | 統合 |
| - | A10: Mishandling of Exceptional Conditions | **新規** |

---

## OWASP Top 10:2025 vs zlack 対照マトリクス

### A01:2025 — Broken Access Control

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| ファイルダウンロードのパストラバーサル | ⚠️要改善 | `file.name` に `../` が含まれる場合 Downloads 外に書き込み可能 (`app.zig:517`) | basename のみ使用 (CLAUDE.md ルール追加済み) |
| SSRF (A01 に統合) | ✅安全 | API URL は `https://slack.com/api/` 固定。ユーザー入力で URL 構築しない | - |
| ファイルアップロードの読み取り範囲 | ✅許容 | ユーザー自身がパスを入力する CLI なので自己責任。symlink チェックは LOW | - |

### A02:2025 — Security Misconfiguration

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| デバッグログに機密 URL 出力 | ⚠️要改善 | upload URL (一時トークン含む) がログファイルに残る (`api.zig:362`) | ログから除去 (CLAUDE.md ルール追加済み) |
| API レスポンスボディのログ出力 | ⚠️要改善 | step1 response 全文がログに出る (`api.zig:350`) | redact or 削除 |
| 不要なデバッグ機能の残存 | ⚠️要改善 | `openThread` のデバッグログが残存 (`app.zig:448`) | issue #8 (ログレベル設計) で対応 |
| HTTP ヘッダーの適切な設定 | ✅安全 | `Accept-Encoding: identity`, Bearer auth, Content-Type 適切 | - |

### A03:2025 — Software Supply Chain Failures (2025 新規)

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| 依存パッケージの信頼性 | ⚠️要確認 | websocket.zig は master ブランチ参照 (タグなし)。vaxis は main ブランチ参照 | ハッシュ固定済み (`build.zig.zon`) だが、タグ付きバージョンへの切替を推奨 |
| 依存パッケージの脆弱性 | ✅安全 | Zig パッケージは既知の脆弱性 DB が未整備。ソースコード監査で代替 | - |
| ビルドパイプラインの完全性 | ✅安全 | GitHub Actions で `mlugg/setup-zig@v2` 使用。minisign 検証あり | - |
| SBOMの有無 | ⚠️未対応 | SBOM (Software Bill of Materials) が生成されていない | 将来: `build.zig.zon` から SBOM 生成ツールを検討 |

### A04:2025 — Cryptographic Failures

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| TLS 通信 | ✅安全 | Zig std の TLS 1.3 実装。Slack API は HTTPS のみ | - |
| トークン保存 | ✅安全 | macOS Keychain (Security.framework)。Linux は stub (null 返却) | - |
| 平文でのトークン送信 | ✅安全 | `Authorization: Bearer` ヘッダー、HTTPS のみ | - |
| 暗号アルゴリズム選択 | ✅安全 | TLS は Zig std / OS に委任。自前の暗号実装なし | - |

### A05:2025 — Injection

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| JSON インジェクション (ACK) | ⚠️要改善 | `envelope_id` を `fmt` で JSON 文字列に結合 (`socket.zig:207`) | JSON シリアライザ使用 (CLAUDE.md ルール追加済み) |
| コマンドインジェクション | ✅安全 | シェル呼び出しなし | - |
| SQL インジェクション | ✅安全 | SQLite はパラメータバインド使用 | - |
| URI パラメータインジェクション | ✅安全 | `uriEncodeAppend` で全パラメータをエンコード (`api.zig:585`) | - |
| メンション解決 | ✅安全 | `@name` → cache 逆引き → マッチしなければ無視 | - |

### A06:2025 — Insecure Design

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| ファイルダウンロードサイズ制限 | ⚠️要改善 | 10MB 固定バッファ。超過時はサイレント失敗 (`api.zig:307`) | エラーメッセージ表示 + ストリーミング対応 |
| ファイルアップロードサイズ制限 | ✅安全 | 50MB 制限、`readToEndAlloc` で強制 | - |
| イベントキュー溢れ | ⚠️要改善 | 512 エントリのリングバッファ、サイレントドロップ (`socket.zig:53`) | ドロップ時にログ出力 |
| 認証フローの設計 | ✅安全 | env → keychain → prompt の3段フォールバック | - |

### A07:2025 — Authentication Failures

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| トークン検証 | ✅安全 | prefix (`xoxp-`, `xapp-`) + 最小長チェック (`auth.zig`) | - |
| env var トークンのライフタイム | ⚠️要改善 | `getenv()` の borrowed pointer を struct に保存 (`app.zig:159`) | `allocator.dupe()` で複製 (CLAUDE.md ルール追加済み) |
| Keychain 保存 | ✅安全 | `zlack.user.default` / `zlack.app.default` で保存・読込 | - |
| `--reconfigure` | ✅安全 | keychain を無視して再入力を促す | - |

### A08:2025 — Data Integrity Failures

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| JSON パースの安全性 | ✅安全 | `ignore_unknown_fields = true`、`ok` フィールド検証 | - |
| API レスポンスの検証 | ✅安全 | `parseResponse` で `ok: false` 時に `SlackApiError` を返す | - |
| WebSocket メッセージの検証 | ✅安全 | 型安全な `getStr()` ヘルパーで文字列抽出 | - |
| キャッシュの整合性 | ✅安全 | Mutex で保護、`clearChannelMessages` で stale データ防止 | - |

### A09:2025 — Security Logging & Alerting Failures

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| ログレベルの分離 | ⚠️要改善 | 全て `stderr.write("[zlack]")` で区別なし | issue #8 (ログレベル設計) |
| ログにPII含む | ⚠️要改善 | ユーザー名、チャンネル名がメッセージテキストとしてログに含まれうる | debug レベルに限定 |
| 認証失敗のログ | ✅安全 | `Auth via env failed:` でエラー名を記録 | - |
| ログファイルの保護 | ⚠️要改善 | `~/.local/share/zlack/zlack.log` のパーミッション未設定 (umask 依存) | `0o600` で作成 |
| アラート機能 | ⚠️未対応 | メンション通知 (ベル) はあるが、セキュリティイベントのアラートなし | 将来: 異常な接続切断パターン検出 |

### A10:2025 — Mishandling of Exceptional Conditions (2025 新規)

| チェック項目 | 判定 | 詳細 | 対策 |
|------------|------|------|------|
| HTTP エラー時の動作 | ✅安全 | `HttpConnectionClosing` → リトライ → 失敗 → エラー返却。fail-open しない | - |
| JSON パースエラー時の動作 | ✅安全 | `catch return error.JsonParseFailed` — fail-closed | - |
| WebSocket 切断時の動作 | ✅安全 | `error.Closed` → `reconnect_requested` イベント → 再接続 | - |
| Keychain エラー時の動作 | ✅安全 | エラー → `null` 返却 → プロンプトにフォールバック。fail-open しない | - |
| ファイル操作エラー | ✅安全 | `catch return error.FileNotFound` / `FileWriteFailed` — fail-closed | - |
| メモリ不足時の動作 | ⚠️要確認 | `catch return` / `catch continue` で処理を継続するが、状態が中途半端になる箇所あり | アトミック操作の検討 |

---

## 総合判定

⚠️要改善後リリース

## 改善マトリクス（優先度順）

| # | OWASP | 対策 | 深刻度 | Status |
|---|-------|------|--------|--------|
| 1 | A07 | env var トークンを `dupe()` で複製 | Critical | CLAUDE.md ルール追加済み、コード未修正 |
| 2 | A01 | ダウンロードファイル名を basename 化 | High | CLAUDE.md ルール追加済み、コード未修正 |
| 3 | A02 | デバッグログから機密 URL 削除 | High | CLAUDE.md ルール追加済み、コード未修正 |
| 4 | A05 | ACK の JSON を安全に構築 | Medium | CLAUDE.md ルール追加済み、コード未修正 |
| 5 | A09 | ログファイルのパーミッション 0o600 | Medium | 未対応 |
| 6 | A06 | イベントキュー溢れをログ出力 | Medium | 未対応 |
| 7 | A03 | 依存をタグ付きバージョンに固定 | Low | build.zig.zon のハッシュで固定済み |
| 8 | A09 | ログレベル設計 | Medium | issue #8 |

## References

- [OWASP Top 10:2025 (公式)](https://owasp.org/Top10/2025/en/)
- [OWASP Top 10:2025 Introduction](https://owasp.org/Top10/2025/0x00_2025-Introduction/)
- [OWASP Top 10 2025: What's Changed (GitLab)](https://about.gitlab.com/blog/2025-owasp-top-10-whats-changed-and-why-it-matters/)
- [OWASP Top 10 2025: Supply Chain (Fastly)](https://www.fastly.com/blog/new-2025-owasp-top-10-list-what-changed-what-you-need-to-know)
- [OWASP Top 10 2025: Developer Guide (Aikido)](https://www.aikido.dev/blog/owasp-top-10-2025-changes-for-developers)
