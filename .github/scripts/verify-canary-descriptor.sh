#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 6 ] || {
    echo "Usage: verify-canary-descriptor <descriptor> <image> <canary-tag> <digest> <candidate-commit> <sha256>" >&2
    exit 64
}

DESCRIPTOR="$1"
IMAGE="$2"
CANARY_TAG="$3"
CANDIDATE_DIGEST="$4"
CANDIDATE_COMMIT="$5"
EXPECTED_SHA256="$6"
CANARY_SLUG='zeroclaw_canary'

[ -f "$DESCRIPTOR" ] && [ ! -L "$DESCRIPTOR" ] || {
    echo "canary descriptor is not a regular file" >&2
    exit 1
}
[ -s "$DESCRIPTOR" ] || {
    echo "canary descriptor is empty" >&2
    exit 1
}
printf '%s' "$EXPECTED_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "descriptor SHA256 has an invalid format" >&2
    exit 1
}
printf '%s  %s\n' "$EXPECTED_SHA256" "$DESCRIPTOR" | sha256sum --check --status - || {
    echo "canary descriptor SHA256 mismatch" >&2
    exit 1
}
printf '%s' "$IMAGE" | grep -Eq '^ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+$' || exit 1
printf '%s' "$CANARY_TAG" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-canary\.[0-9]+$' || exit 1
printf '%s' "$CANDIDATE_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' || exit 1
printf '%s' "$CANDIDATE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || exit 1

version="${CANARY_TAG%-canary.*}"
image_ref="${IMAGE}:${CANARY_TAG}@${CANDIDATE_DIGEST}"
grep -F -x "# candidate_commit: ${CANDIDATE_COMMIT}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor candidate commit binding is missing" >&2
    exit 1
}
grep -F -x "# candidate_tag: ${CANARY_TAG}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor canary tag binding is missing" >&2
    exit 1
}
grep -F -x "# candidate_digest: ${CANDIDATE_DIGEST}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor candidate digest binding is missing" >&2
    exit 1
}
test "$(grep -Ec '^image:[[:space:]]+' "$DESCRIPTOR")" -eq 1
grep -F -x "image: \"${image_ref}\"" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor image is not pinned to the exact canary tag and digest" >&2
    exit 1
}
test "$(grep -Ec '^slug:[[:space:]]+' "$DESCRIPTOR")" -eq 1
grep -F -x "slug: ${CANARY_SLUG}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor does not use the isolated canary slug" >&2
    exit 1
}
grep -F -x 'name: ZeroClaw Canary' "$DESCRIPTOR" >/dev/null || {
    echo "descriptor does not identify the canary app" >&2
    exit 1
}
grep -F -x "version: ${version}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor version does not match the canary tag" >&2
    exit 1
}

printf 'canary descriptor verified: %s\n' "$DESCRIPTOR"
