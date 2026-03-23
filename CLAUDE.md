# 設計と実装の哲学

- すべてのコードは負債。単純・予測可能・副作用分離。
- 境界は跨がない。誇大表現禁止。動くものを出荷。
- YAGNI, KISS, DRY。単純さを常に優先すること。

# 手段

- planモード または superpowersを使う

# README 多言語対応

README を作成・更新する際は、以下の4言語ファイルを**必ず同時に**更新する:

| ファイル | 言語 |
|---------|------|
| `README.md` | English |
| `README.ja.md` | 日本語 |
| `README.zh.md` | 简体中文 |
| `README.pt-BR.md` | Português (BR) |

- 1ファイルだけ更新して他を放置しない
- 各ファイル先頭の言語切替リンクを常に4言語分維持する

# ADR とコミットの双方向トレーサビリティ

## コミットメッセージ

ADR に関連する変更をコミットする際、メッセージに ADR 番号を含める:

```
fix: SQLite 静的リンク [ADR-002]
```

## ADR ファイル

ADR に `## Related Commits` セクションを設け、関連コミット/PR を記録する:

```markdown
## Related Commits
- PR #3: feat: --version/--help + SQLite 静的リンクでポータブルバイナリ
```

これにより `git log --grep="ADR-002"` で関連コミットを検索でき、ADR からも実装を辿れる。

# セキュア実装規約

OWASP Top 10 セキュリティテスト (2026-03-23) で発見されたパターンに基づく。
同じ脆弱性を二度と作り込まないためのルール。

## 外部データのファイル名は basename のみ使用する

Slack API レスポンスなど外部から取得したファイル名には `../` が含まれる可能性がある。
ファイル保存時は **basename のみ** を使い、パストラバーサルを防ぐ。

```zig
// NG: 外部データをそのままパスに結合
const save_path = fmt("{s}/Downloads/{s}", .{ home, file.name });

// OK: basename を抽出して使用
const basename = if (std.mem.lastIndexOfScalar(u8, file.name, '/')) |pos| file.name[pos + 1 ..] else file.name;
const save_path = fmt("{s}/Downloads/{s}", .{ home, basename });
```

## borrowed pointer を保存しない

`std.posix.getenv()` 等の借用ポインタを struct フィールドに保存しない。
必ず `allocator.dupe()` で複製する。

```zig
// NG: borrowed pointer をそのまま保存
self.auth.user_token = std.posix.getenv("TOKEN").?;

// OK: 複製して保存
self.auth.user_token = try allocator.dupe(u8, std.posix.getenv("TOKEN").?);
```

## ログに機密情報を出力しない

以下はログに出力しない:
- トークン（`xoxp-`, `xapp-`, Bearer）
- Slack の一時 URL（`upload_url` 等、一時トークンを含む）
- API レスポンスボディ全文

ログに出力してよいもの:
- HTTP ステータスコード
- API メソッド名
- エラー名（`@errorName(err)`）
- ファイル名（パス部分を除く）

## JSON は文字列結合で構築しない

外部データを含む JSON は `std.fmt.bufPrint` ではなく、JSON シリアライザを使うか、
値をエスケープしてから結合する。

```zig
// NG: 外部値をそのまま文字列結合
const ack = fmt("{{\"envelope_id\":\"{s}\"}}", .{envelope_id});

// OK: エスケープするか、構造体をシリアライズ
```

## parseResponse の戻り値は trackParsed で追跡する

`parseResponse` で返された `Parsed(T)` の arena を `trackParsed` で登録し、
`SlackClient.deinit` で一括解放する。`deinit` し忘れるとメモリリーク。

