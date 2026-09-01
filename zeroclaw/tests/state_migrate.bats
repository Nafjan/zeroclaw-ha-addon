#!/usr/bin/env bats

setup() {
    TEST_ROOT="$(mktemp -d)"
    DATA_DIR="$TEST_ROOT/data"
    mkdir -p "$DATA_DIR/workspace/sessions-1"
    printf 'brain\n' > "$DATA_DIR/brain.db"
    printf 'config\n' > "$DATA_DIR/config.toml"
    printf 'session\n' > "$DATA_DIR/workspace/sessions-1/state.db"
    printf '3.1.3.3\n' > "$DATA_DIR/.state-version"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

@test "legacy semver state migrates to schema 1 and is checksummed" {
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"old_schema=0 new_schema=1 legacy=3.1.3.3"* ]]
    [ "$(cat "$DATA_DIR/.state-schema")" = 1 ]
    [ ! -e "$DATA_DIR/.state-version" ]
    [ "$(cat "$DATA_DIR/brain.db")" = brain ]
    [ "$(cat "$DATA_DIR/workspace/sessions-1/state.db")" = session ]

    backup_dir="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'legacy-3.1.3.3-to-schema-1-*' -print -quit)"
    [ -n "$backup_dir" ]
    [ "$(cat "$backup_dir/brain.db")" = brain ]
    [ "$(cat "$backup_dir/workspace/sessions-1/state.db")" = session ]
    [ "$(cat "$backup_dir/.state-version")" = 3.1.3.3 ]
    grep -F 'old_schema=0' "$backup_dir/manifest" >/dev/null
    grep -F 'legacy_marker_source=.state-version' "$backup_dir/manifest" >/dev/null
    grep -F './brain.db' "$backup_dir/checksums" >/dev/null
    grep -F './.state-version' "$backup_dir/checksums" >/dev/null
}

@test "same schema is a silent no-op" {
    printf '1\n' > "$DATA_DIR/.state-schema"
    rm -f "$DATA_DIR/.state-version"
    before="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DATA_DIR/.state-schema")" = 1 ]
    after="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    [ "$before" = "$after" ]
}

@test "workspace legacy marker is migrated and retained in the snapshot" {
    rm -f "$DATA_DIR/.state-version"
    printf '3.1.4.0-canary.12\n' > "$DATA_DIR/workspace/.last_version"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -eq 0 ]
    [ "$(cat "$DATA_DIR/.state-schema")" = 1 ]
    [ ! -e "$DATA_DIR/workspace/.last_version" ]
    backup_dir="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'legacy-3.1.4.0-canary.12-to-schema-1-*' -print -quit)"
    [ -n "$backup_dir" ]
    [ "$(cat "$backup_dir/workspace/.last_version")" = 3.1.4.0-canary.12 ]
    grep -F 'legacy_marker_source=workspace/.last_version' "$backup_dir/manifest" >/dev/null
}

@test "missing legacy markers migrate from schema 0 without inventing a version" {
    rm -f "$DATA_DIR/.state-version"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"old_schema=0 new_schema=1 legacy=none"* ]]
    [ "$(cat "$DATA_DIR/.state-schema")" = 1 ]
    backup_dir="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'schema-0-to-schema-1-*' -print -quit)"
    [ -n "$backup_dir" ]
    grep -F 'old_version=fresh' "$backup_dir/manifest" >/dev/null
    [ ! -e "$backup_dir/.state-version" ]
}

@test "conflicting legacy markers fail closed before creating a schema" {
    printf '3.1.3.4\n' > "$DATA_DIR/workspace/.last_version"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"legacy version markers disagree"* ]]
    [ ! -e "$DATA_DIR/.state-schema" ]
    [ ! -e "$DATA_DIR/migrations" ]
}

@test "malformed legacy marker fails closed without changing state" {
    printf 'not-a-version\n' > "$DATA_DIR/.state-version"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"legacy .state-version marker is malformed"* ]]
    [ ! -e "$DATA_DIR/.state-schema" ]
    [ "$(cat "$DATA_DIR/.state-version")" = not-a-version ]
    [ ! -e "$DATA_DIR/migrations" ]
}

@test "malformed schema marker fails closed" {
    printf 'schema-one\n' > "$DATA_DIR/.state-schema"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"state schema must be an integer"* ]]
    [ "$(cat "$DATA_DIR/.state-schema")" = schema-one ]
    [ ! -e "$DATA_DIR/migrations" ]
}

@test "schema downgrade is refused without changing the marker" {
    printf '2\n' > "$DATA_DIR/.state-schema"

    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to migrate state schema backwards"* ]]
    [ "$(cat "$DATA_DIR/.state-schema")" = 2 ]
    [ ! -e "$DATA_DIR/migrations" ]
}

@test "pre-commit failure removes the incomplete snapshot and leaves legacy state" {
    run env STATE_MIGRATE_TEST_FAIL_BEFORE_COMMIT=true \
        "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"test failure injected before schema commit"* ]]
    [ ! -e "$DATA_DIR/.state-schema" ]
    [ "$(cat "$DATA_DIR/.state-version")" = 3.1.3.3 ]
    [ -d "$DATA_DIR/migrations" ]
    [ -z "$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -print -quit)" ]
}
