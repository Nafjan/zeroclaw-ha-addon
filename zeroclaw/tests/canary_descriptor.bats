#!/usr/bin/env bats

RENDERER="$BATS_TEST_DIRNAME/../../.github/scripts/render-canary-descriptor.sh"
VERIFIER="$BATS_TEST_DIRNAME/../../.github/scripts/verify-canary-descriptor.sh"
CANONICAL_CONFIG="$BATS_TEST_DIRNAME/../config.yaml"
IMAGE='ghcr.io/nafjan/zeroclaw-ha-addon'
TAG='3.1.4.0-canary.123456789'
DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
COMMIT='035516d0428f175e7e90f8e6715a114184e7cb24'

setup() {
    TMP_DIR="$(mktemp -d)"
    DESCRIPTOR_DIR="$TMP_DIR/descriptor"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "renderer creates a pinned isolated Supervisor descriptor and identity" {
    run bash "$RENDERER" "$CANONICAL_CONFIG" "$IMAGE" "$TAG" "$DIGEST" "$COMMIT" "$DESCRIPTOR_DIR"
    [ "$status" -eq 0 ]
    [ -f "$DESCRIPTOR_DIR/config.yaml" ]
    [ -f "$DESCRIPTOR_DIR/canary-identity.json" ]
    config_sha256="$(sha256sum "$DESCRIPTOR_DIR/config.yaml" | awk '{print $1}')"
    run bash "$VERIFIER" "$DESCRIPTOR_DIR/config.yaml" "$IMAGE" "$TAG" "$DIGEST" "$COMMIT" "$config_sha256"
    [ "$status" -eq 0 ]
    jq -e --arg digest "$DIGEST" --arg commit "$COMMIT" --arg sha "$config_sha256" '
        .schema_version == 1 and
        .descriptor_kind == "homeassistant_local_app" and
        .app_slug == "zeroclaw_canary" and
        .candidate_digest == $digest and
        .candidate_commit == $commit and
        .config_sha256 == $sha and
        .minimum_supervisor_version == "2026.04.0"
    ' "$DESCRIPTOR_DIR/canary-identity.json" >/dev/null
    grep -F "image: \"${IMAGE}:${TAG}@${DIGEST}\"" "$DESCRIPTOR_DIR/config.yaml" >/dev/null
    grep -F 'slug: zeroclaw_canary' "$DESCRIPTOR_DIR/config.yaml" >/dev/null
}

@test "renderer rejects a canary tag from a different app version" {
    run bash "$RENDERER" "$CANONICAL_CONFIG" "$IMAGE" '3.1.3.3-canary.123456789' "$DIGEST" "$COMMIT" "$DESCRIPTOR_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"canary tag version does not match canonical app version"* ]]
    [ ! -e "$DESCRIPTOR_DIR" ]
}

@test "descriptor verifier rejects a changed pinned image" {
    run bash "$RENDERER" "$CANONICAL_CONFIG" "$IMAGE" "$TAG" "$DIGEST" "$COMMIT" "$DESCRIPTOR_DIR"
    [ "$status" -eq 0 ]
    config_sha256="$(sha256sum "$DESCRIPTOR_DIR/config.yaml" | awk '{print $1}')"
    sed -i 's/zeroclaw_canary/zeroclaw_other/' "$DESCRIPTOR_DIR/config.yaml"
    run bash "$VERIFIER" "$DESCRIPTOR_DIR/config.yaml" "$IMAGE" "$TAG" "$DIGEST" "$COMMIT" "$config_sha256"
    [ "$status" -ne 0 ]
    [[ "$output" == *"canary descriptor SHA256 mismatch"* ]]
}
