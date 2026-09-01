#!/usr/bin/env bash

# Operator-side preflight for the external GitHub branch-protection control.
# The Actions GITHUB_TOKEN cannot request repository Administration permission,
# so the release workflow must not pretend it can verify this API itself.

set -euo pipefail

repository="${1:-${GITHUB_REPOSITORY:-}}"
branch="${2:-master}"

if [[ ! "$repository" =~ ^[^/]+/[^/]+$ ]]; then
    echo "usage: $0 OWNER/REPOSITORY [BRANCH]" >&2
    exit 2
fi
if [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "invalid branch name" >&2
    exit 2
fi
command -v gh >/dev/null 2>&1 || {
    echo "GitHub CLI (gh) is required" >&2
    exit 2
}
command -v jq >/dev/null 2>&1 || {
    echo "jq is required" >&2
    exit 2
}

protection="$(gh api \
    --header 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${repository}/branches/${branch}/protection")" || {
    echo "branch protection could not be read; refusing release preflight" >&2
    exit 1
}

printf '%s' "$protection" | jq -e '
    (.required_status_checks.strict == true) and
    ((["Bats unit tests","Shell parsing and ShellCheck","Build and smoke-test arm64 image"] - (.required_status_checks.contexts // [])) | length == 0) and
    (.enforce_admins.enabled == true) and
    (.required_linear_history.enabled == true) and
    (.allow_force_pushes.enabled == false) and
    (.allow_deletions.enabled == false) and
    (.required_conversation_resolution.enabled == true)
' >/dev/null || {
    echo "branch protection does not satisfy the release precondition" >&2
    exit 1
}

printf 'protected branch verified: %s@%s\n' "$repository" "$branch"
