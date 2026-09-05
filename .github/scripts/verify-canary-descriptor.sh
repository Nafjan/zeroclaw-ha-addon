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
grep -F -x "# resolved_image: ${image_ref}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor resolved image binding is missing" >&2
    exit 1
}
test "$(grep -Ec '^image:[[:space:]]+' "$DESCRIPTOR")" -eq 1
grep -F -x "image: \"${IMAGE}\"" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor image is not a Supervisor-compatible bare image repository" >&2
    exit 1
}
test "$(grep -Ec '^slug:[[:space:]]+' "$DESCRIPTOR")" -eq 1
grep -F -x "slug: ${CANARY_SLUG}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor does not use the isolated canary slug" >&2
    exit 1
}
top_level_allowlist='^(name|version|slug|description|url|image|arch|init|startup|boot|homeassistant_api|hassio_api|hassio_role|options|schema):'
while IFS= read -r descriptor_line; do
    case "$descriptor_line" in
        ''|'#'*) continue ;;
    esac
    if [[ "$descriptor_line" =~ ^([A-Za-z0-9_-]+): ]]; then
        printf '%s' "${BASH_REMATCH[1]}:" | grep -Eq "$top_level_allowlist" || {
            echo "descriptor contains an unapproved top-level Supervisor field" >&2
            exit 1
        }
    fi
done < "$DESCRIPTOR"
# These manifest capabilities are intentionally absent from this canary. A
# future descriptor must not gain them merely because the canonical config or
# renderer starts copying a new field.
if grep -Eiq '^[[:space:]]*(privileged|host_network|host_pid|host_ipc|devices|map|usb|gpio|uart|audio|video|ports|ports_description|cap_add|cap_drop|security_opt|apparmor|full_access):' "$DESCRIPTOR"; then
    echo "descriptor requests an unapproved privileged or host capability" >&2
    exit 1
fi
grep -F -x 'init: false' "$DESCRIPTOR" >/dev/null || {
    echo "descriptor must disable the init process" >&2
    exit 1
}
grep -F -x 'hassio_role: default' "$DESCRIPTOR" >/dev/null || {
    echo "descriptor must use the default least-privilege Supervisor role" >&2
    exit 1
}
grep -F -x 'name: ZeroClaw Canary' "$DESCRIPTOR" >/dev/null || {
    echo "descriptor does not identify the canary app" >&2
    exit 1
}
grep -F -x "version: ${CANARY_TAG}" "$DESCRIPTOR" >/dev/null || {
    echo "descriptor version does not carry the exact canary tag" >&2
    exit 1
}

printf 'canary descriptor verified: %s\n' "$DESCRIPTOR"
