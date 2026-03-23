# セキュリティテストレポート

- **対象**: zlack v0.1.1
- **日付**: 2026-03-23
- **テスト者**: Claude Code
- **基準**: OWASP Top 10 (2021) + OWASP Top 10 for Desktop/CLI Applications

## OWASP Top 10 (2021) vs zlack 対照表

| # | OWASP Category | zlack での該当 | 判定 |
|---|---------------|---------------|------|
| A01 | Broken Access Control | ファイルダウンロードのパストラバーサル | ⚠️要改善 |
| A02 | Cryptographic Failures | TLS は Zig std/Slack API に委任。トークンは Keychain 保存 | ✅安全 |
| A03 | Injection | ACK メッセージの JSON 文字列結合、メンション解決 | ⚠️要改善 |
| A04 | Insecure Design | ファイルアップロードのパス検証不足 | ⚠️要改善 |
| A05 | Security Misconfiguration | デバッグログに Slack upload URL が含まれる | ⚠️要改善 |
| A06 | Vulnerable & Outdated Components | Zig 0.15.0, websocket.zig, vaxis — 最新版使用 | ✅安全 |
| A07 | Identification & Authentication Failures | トークン検証あり、Keychain 保存、env var のライフタイム問題 | ⚠️要改善 |
| A08 | Software & Data Integrity Failures | JSON パース時に `ignore_unknown_fields` で安全 | ✅安全 |
| A09 | Security Logging & Monitoring Failures | ログレベル未分離、PII がログに含まれうる | ⚠️要改善 |
| A10 | Server-Side Request Forgery (SSRF) | Slack API の URL のみ呼び出し。ユーザー入力で URL 構築なし | ✅安全 |

## Blue Team（防御観点）

| 項目 | 結果 | 詳細 |
|------|------|------|
| 入力バリデーション | ⚠️要改善 | ファイルダウンロード名に `../` チェックなし (`app.zig:517`) |
| 認証・認可 | ⚠️要改善 | env var トークンが borrowed pointer で use-after-free リスク (`app.zig:159`) |
| シークレット管理 | ✅安全 | Keychain 保存、ハードコード秘密なし、env var は開発用 |
| 依存脆弱性 | ✅安全 | Zig 0.15.0 + 最新 websocket.zig/vaxis |
| ログ・監査 | ⚠️要改善 | upload URL (一時トークン含む) がログに出力 (`api.zig:362`) |
| エラーハンドリング | ✅安全 | エラー名のみ出力、スタックトレース非公開 |
| URI エンコーディング | ✅安全 | `uriEncodeAppend` で全パラメータをエンコード (`api.zig:585`) |
| JSON パース | ✅安全 | `ignore_unknown_fields` + `ok` フィールド検証 |
| スレッドセーフティ | ✅安全 | Cache に Mutex、EventQueue に Mutex |
| メモリ管理 | ⚠️要改善 | JSON arena リーク修正済み、env var のライフタイム未修正 |

## Red Team（攻撃観点）

| 攻撃シナリオ | 結果 | 詳細 |
|-------------|------|------|
| パストラバーサル (download) | ⚠️要改善 | Slack API の `file.name` に `../../.ssh/authorized_keys` を含められた場合、Downloads 外に書き込み可能 |
| パストラバーサル (upload) | ✅安全 | ユーザー自身がパスを入力するので自己責任。ただし symlink 経由で意図しないファイルを送信する可能性あり |
| JSON インジェクション (ACK) | ⚠️要改善 | `envelope_id` に `"` を含む値が来た場合、ACK JSON が壊れる (`socket.zig:207`) |
| コマンドインジェクション | ✅安全 | シェル呼び出しなし |
| SQL インジェクション | ✅安全 | SQLite は prepared statement 相当 (パラメータバインド) |
| XSS | ✅安全 | TUI 出力のため HTML レンダリングなし |
| メンション濫用 | ✅安全 | `@name` → cache 逆引き → マッチしなければ無視 |
| SSRF | ✅安全 | API URL は `https://slack.com/api/` 固定、ユーザー入力で構築しない |
| DoS (入力) | ✅安全 | 入力バッファは ArrayList (動的)、50MB ファイルサイズ制限あり |
| DoS (イベントキュー) | ⚠️要改善 | 512 エントリのリングバッファ、溢れるとサイレントドロップ |
| 情報漏洩 (ログ) | ⚠️要改善 | upload URL に一時トークンが含まれ、ログファイルに残る |
| Use-after-free | ⚠️要改善 | env var トークンの borrowed pointer (`app.zig:159`) |

## 総合判定

⚠️要改善後リリース

## 改善事項 (優先度順)

### Critical (即時対応)

- [ ] **env var トークンの dupe**: `std.posix.getenv()` の返り値を `allocator.dupe()` で複製 (`app.zig:159`)

### High (次バージョン)

- [ ] **ダウンロードファイル名の sanitize**: `file.name` から `../`, `/`, `\` を除去。basename のみ使用 (`app.zig:517`)
- [ ] **デバッグログから機密情報を除去**: upload URL, API レスポンスボディのログ出力を削除または redact (`api.zig:350-368`)

### Medium

- [ ] **ACK メッセージの JSON 安全な構築**: `std.json` のシリアライザを使用するか、`envelope_id` をエスケープ (`socket.zig:207`)
- [ ] **イベントキューオーバーフローのログ**: ドロップ時に警告をログ出力 (`socket.zig:53-68`)
- [ ] **ログレベル設計**: issue #8 で対応予定。PII を debug レベル以下に限定

### Low

- [ ] **ファイルアップロード時の symlink チェック**: `std.fs.cwd().openFile()` 前に symlink を検出
- [ ] **ダウンロードサイズ上限の明示化**: 現在 10MB 固定バッファ。ストリーミングダウンロードに将来対応

## References

- [OWASP Top Ten 2021](https://owasp.org/www-project-top-ten/)
- [OWASP Top 10 2025 (予定)](https://www.owasptopten.org/)
- [OWASP Mobile Top 10 2024](https://owasp.org/www-project-mobile-top-10/2023-risks/)

Sources:
- [OWASP Top Ten](https://owasp.org/www-project-top-ten/)
- [OWASP Top 10 2025](https://www.owasptopten.org/)
- [OWASP Top 10 Vulnerabilities 2024](https://www.wattlecorp.com/owasp-top-10/)
