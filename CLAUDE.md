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

