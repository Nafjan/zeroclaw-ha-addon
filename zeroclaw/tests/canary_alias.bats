#!/usr/bin/env bats

setup() {
    CLASSIFIER="$BATS_TEST_DIRNAME/../../.github/scripts/classify-canary-tag-missing.sh"
    IMAGE='ghcr.io/nafjan/zeroclaw-ha-addon'
    TARGET_TAG='3.1.4.0-canary.33995501230'
    ERROR_FILE="$BATS_TEST_TMPDIR/target-error"
}

write_error() {
    printf '%s' "$1" > "$ERROR_FILE"
}

@test "canary tag classifier accepts the exact missing-target diagnostics" {
    for suffix in 'not found' 'manifest unknown' 'name unknown' 'no such manifest'; do
        write_error "$(printf 'ERROR: %s:%s: %s\n' "$IMAGE" "$TARGET_TAG" "$suffix")"
        run bash "$CLASSIFIER" "$IMAGE" "$TARGET_TAG" "$ERROR_FILE"
        [ "$status" -eq 0 ]
    done
}

@test "canary tag classifier tolerates CRLF but no extra diagnostics" {
    printf 'ERROR: %s:%s: not found\r\n' "$IMAGE" "$TARGET_TAG" > "$ERROR_FILE"
    run bash "$CLASSIFIER" "$IMAGE" "$TARGET_TAG" "$ERROR_FILE"
    [ "$status" -eq 0 ]

    write_error "$(printf 'ERROR: %s:%s: not found\nwarning: retrying' "$IMAGE" "$TARGET_TAG")"
    run bash "$CLASSIFIER" "$IMAGE" "$TARGET_TAG" "$ERROR_FILE"
    [ "$status" -ne 0 ]
}

@test "canary tag classifier rejects generic, wrong-reference, and non-missing errors" {
    for diagnostic in \
        "not found" \
        "ERROR: ghcr.io/other/image:${TARGET_TAG}: not found" \
        "warning: ERROR: ${IMAGE}:${TARGET_TAG}: not found" \
        "ERROR: ${IMAGE}:${TARGET_TAG}: denied" \
        "$(printf 'ERROR: %s:%s: manifest unknown\nERROR: registry timeout' "$IMAGE" "$TARGET_TAG")" \
        ''; do
        write_error "$diagnostic"
        run bash "$CLASSIFIER" "$IMAGE" "$TARGET_TAG" "$ERROR_FILE"
        [ "$status" -ne 0 ]
    done
}
