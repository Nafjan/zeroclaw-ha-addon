#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 6 ] || {
    echo "Usage: render-canary-descriptor <canonical-config> <image> <canary-tag> <digest> <candidate-commit> <output-dir>" >&2
    exit 64
}

CANONICAL_CONFIG="$1"
IMAGE="$2"
CANARY_TAG="$3"
CANDIDATE_DIGEST="$4"
CANDIDATE_COMMIT="$5"
OUTPUT_DIR="$6"
CANARY_SLUG='zeroclaw_canary'
MIN_SUPERVISOR_VERSION='2026.04.0'

[ -f "$CANONICAL_CONFIG" ] && [ ! -L "$CANONICAL_CONFIG" ] || {
    echo "canonical app config is not a regular file" >&2
    exit 1
}
printf '%s' "$IMAGE" | grep -Eq '^ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+$' || {
    echo "image must be a bare lowercase GHCR repository" >&2
    exit 1
}
printf '%s' "$CANDIDATE_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' || {
    echo "candidate digest has an invalid format" >&2
    exit 1
}
printf '%s' "$CANDIDATE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "candidate commit has an invalid format" >&2
    exit 1
}
printf '%s' "$CANARY_TAG" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-canary\.[0-9]+$' || {
    echo "canary tag has an invalid format" >&2
    exit 1
}
printf '%s' "$CANARY_SLUG" | grep -Eq '^[a-z][a-z0-9_]{0,30}$' || {
    echo "canary slug has an invalid format" >&2
    exit 1
}

config_version="$(awk '$1 == "version:" { value=$2; count++ } END { if (count != 1) exit 1; print value }' "$CANONICAL_CONFIG")"
config_slug="$(awk '$1 == "slug:" { value=$2; count++ } END { if (count != 1) exit 1; print value }' "$CANONICAL_CONFIG")"
config_image="$(awk '$1 == "image:" { value=$2; count++ } END { if (count != 1) exit 1; print value }' "$CANONICAL_CONFIG")"
printf '%s' "$config_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "canonical app version is not a bare four-part version" >&2
    exit 1
}
test "$config_image" = "$IMAGE" || {
    echo "descriptor image does not match canonical app image" >&2
    exit 1
}
test "$config_slug" != "$CANARY_SLUG" || {
    echo "canonical app slug collides with the canary slug" >&2
    exit 1
}
version_regex="${config_version//./\\.}"
printf '%s' "$CANARY_TAG" | grep -Eq "^${version_regex}-canary\\.[0-9]+$" || {
    echo "canary tag version does not match canonical app version" >&2
    exit 1
}
[ ! -e "$OUTPUT_DIR" ] || {
    echo "refusing to overwrite an existing descriptor directory" >&2
    exit 1
}
mkdir -p "$OUTPUT_DIR"

image_ref="${IMAGE}:${CANARY_TAG}@${CANDIDATE_DIGEST}"
config_tmp="$OUTPUT_DIR/config.yaml.tmp.$$"
{
    printf '# ZeroClaw canary side-load descriptor; use only for the matching immutable digest.\n'
    printf '# candidate_commit: %s\n' "$CANDIDATE_COMMIT"
    printf '# candidate_tag: %s\n' "$CANARY_TAG"
    printf '# candidate_digest: %s\n' "$CANDIDATE_DIGEST"
    awk -v canary_slug="$CANARY_SLUG" -v canary_image="$image_ref" '
        BEGIN { name_count=0; slug_count=0; image_count=0 }
        $1 == "name:" {
            name_count++
            print "name: ZeroClaw Canary"
            next
        }
        $1 == "slug:" {
            slug_count++
            print "slug: " canary_slug
            next
        }
        $1 == "image:" {
            image_count++
            print "image: \"" canary_image "\""
            next
        }
        { print }
        END {
            if (name_count != 1 || slug_count != 1 || image_count != 1) exit 1
        }
    ' "$CANONICAL_CONFIG"
} > "$config_tmp"
chmod 0644 "$config_tmp"
mv -f "$config_tmp" "$OUTPUT_DIR/config.yaml"

config_sha256="$(sha256sum "$OUTPUT_DIR/config.yaml" | awk '{print $1}')"
identity_tmp="$OUTPUT_DIR/canary-identity.json.tmp.$$"
jq -n \
    --arg image "$image_ref" \
    --arg version "$config_version" \
    --arg slug "$CANARY_SLUG" \
    --arg tag "$CANARY_TAG" \
    --arg digest "$CANDIDATE_DIGEST" \
    --arg commit "$CANDIDATE_COMMIT" \
    --arg config_sha256 "$config_sha256" \
    --arg minimum_supervisor_version "$MIN_SUPERVISOR_VERSION" \
    '{
      schema_version: 1,
      descriptor_kind: "homeassistant_local_app",
      config_filename: "config.yaml",
      app_name: "ZeroClaw Canary",
      app_slug: $slug,
      version: $version,
      image: $image,
      candidate_tag: $tag,
      candidate_digest: $digest,
      candidate_commit: $commit,
      config_sha256: $config_sha256,
      minimum_supervisor_version: $minimum_supervisor_version
    }' > "$identity_tmp"
chmod 0644 "$identity_tmp"
mv -f "$identity_tmp" "$OUTPUT_DIR/canary-identity.json"

printf 'descriptor_dir=%s\nconfig_sha256=%s\nimage_ref=%s\napp_slug=%s\nminimum_supervisor_version=%s\n' \
    "$OUTPUT_DIR" "$config_sha256" "$image_ref" "$CANARY_SLUG" "$MIN_SUPERVISOR_VERSION"
