# 006: CI パスフィルタによるビルドスキップ

- **Status:** Accepted
- **Date:** 2026-03-23

## Context

ドキュメント（README、ADR、CLAUDE.md）のみの変更で Zig ビルド・テスト・リリースビルドが
毎回実行されていた。GitHub Actions の無料枠を消費し、マージまでの待ち時間も発生していた。

ADR 追加やトレーサビリティルール変更など、ドキュメントタスクの頻度が上がるにつれ無駄が顕著に。

## Decision

`dorny/paths-filter@v3` で変更されたファイルパスを検出し、ソースコードに変更がない場合は
ビルド・テスト・リリースビルドをスキップする。

### トリガー条件

| ジョブ | 実行条件 |
|--------|---------|
| Format check | 常に実行（全 .zig ファイル対象） |
| Detect changes | 常に実行（`src/**`, `build.zig`, `build.zig.zon` を監視） |
| Test | ソースコード変更あり、またはタグ push |
| Release build | テスト成功、またはタグ push |
| Publish Release | タグ push のみ |

### 監視対象パス

```yaml
src:
  - 'src/**'
  - 'build.zig'
  - 'build.zig.zon'
```

## Consequences

- **Positive:** ドキュメント PR で fmt check のみ実行（~10秒）。ビルド（~3分）がスキップされる。
- **Positive:** GitHub Actions 無料枠の節約。
- **Positive:** ドキュメント PR のマージが高速化。
- **Negative:** ブランチ保護の required checks に Test が含まれるため、skipped 時は admin マージが必要。将来的に required checks の条件調整が必要。
- **Negative:** CI ワークフローファイル自体の変更はソース変更と判定されないため、CI の動作確認にはタグ push か手動 rerun が必要。

## Alternatives Considered

- **`paths:` trigger（GitHub native）:** `on.push.paths` でワークフロー全体を制御する方法。ジョブ単位の制御ができない。
- **`paths-ignore:` trigger:** `on.push.paths-ignore: ['**.md', '_decisions/**']` で除外する方法。新しいドキュメントディレクトリが増えるたびにメンテが必要。
- **ワークフロー分離:** `ci.yml`（ソース用）と `docs.yml`（ドキュメント用）を分ける。管理が煩雑になる。

## Related Commits

- PR #16: ci: ドキュメントのみの変更で build/test をスキップ
