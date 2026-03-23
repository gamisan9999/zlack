# Architecture Decision Records

## ADR テンプレート

新しい ADR を作成する際は、以下のテンプレートを使用する。
ファイル名: `NNN-kebab-case-title.md`（NNN は既存の最大番号 + 1）

```markdown
# NNN: タイトル

- **Status:** Proposed | Accepted | Deprecated | Superseded by [ADR-XXX]
- **Date:** YYYY-MM-DD

## Context

この決定が必要になった背景・状況・制約を記述する。
技術的な問題だけでなく、ビジネス上の制約や時間的な制約も含める。

## Considered Alternatives

検討した選択肢とその評価。「なぜやらなかったか」を残すことで、
同じ議論の繰り返しを防ぐ。

### Alternative A: (名前)

- 概要: ...
- 利点: ...
- 不採用理由: ...

### Alternative B: (名前)

- 概要: ...
- 利点: ...
- 不採用理由: ...

## Decision

採用した決定とその理由。

## Consequences

この決定によって生じる影響（ポジティブ・ネガティブ両方）。

- Good: ...
- Bad: ...
- Neutral: ...

## Related Commits

関連するコミットや PR をここに記録する。

- PR #N: コミットメッセージ
```

## 運用ルール

- `git log --grep="ADR-NNN"` で関連コミットを検索できるよう、コミットメッセージに `[ADR-NNN]` を含める
- ADR のステータスが変わったら Status と Date を更新する
- Superseded の場合は後継 ADR 番号を明記する
