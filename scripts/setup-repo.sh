#!/usr/bin/env bash
# Setup GitHub repository settings for zlack.
# Configures branch protection, merge settings, and repo features.
#
# Usage: ./scripts/setup-repo.sh [OWNER/REPO]
# Default: gamisan9999/zlack

set -euo pipefail

REPO="${1:-gamisan9999/zlack}"
echo "Configuring repository: $REPO"

# --- Repository settings ---
echo "=> Repo settings (squash merge default, delete branch on merge)"
gh api -X PATCH "repos/$REPO" \
  --field allow_squash_merge=true \
  --field allow_merge_commit=true \
  --field allow_rebase_merge=false \
  --field delete_branch_on_merge=true \
  --field squash_merge_commit_title=PR_TITLE \
  --field squash_merge_commit_message=PR_BODY \
  --silent

# --- Branch protection for main ---
echo "=> Branch protection: main"
gh api -X PUT "repos/$REPO/branches/main/protection" \
  --input - --silent <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Format check", "Test (ubuntu-latest)", "Test (macos-latest)"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
EOF

# --- Enable features ---
echo "=> Enable Issues and Discussions"
gh api -X PATCH "repos/$REPO" \
  --field has_issues=true \
  --silent
# Note: has_discussions requires org-level or manual enablement

# --- Labels for PRs ---
echo "=> Creating labels"
for label_spec in \
  "bug:d73a4a:Bug fix" \
  "feature:0075ca:New feature" \
  "docs:0e8a16:Documentation" \
  "ci:e4e669:CI/CD changes" \
  "refactor:7057ff:Code refactoring"; do
  IFS=: read -r name color desc <<< "$label_spec"
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force 2>/dev/null || true
done

echo ""
echo "Done! Repository configured:"
echo "  - Squash merge (default), merge commit allowed, rebase disabled"
echo "  - Delete branch on merge: enabled"
echo "  - main branch protection:"
echo "    - Required status checks: Format check, Test (ubuntu/macos)"
echo "    - Strict status checks (branch must be up-to-date)"
echo "    - Linear history required"
echo "    - Force push and deletion blocked"
echo "    - Admin bypass: allowed (self-merge OK)"
echo "    - PR reviews: 0 required (solo dev / self-merge)"
echo "  - Labels: bug, feature, docs, ci, refactor"
