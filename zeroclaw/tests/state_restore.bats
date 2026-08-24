#!/usr/bin/env bats

setup() {
    TEST_ROOT="$(mktemp -d)"
    DATA_DIR="$TEST_ROOT/data"
    mkdir -p "$DATA_DIR/workspace/sessions-1"
    printf 'old-brain\n' > "$DATA_DIR/brain.db"
    printf 'old-config\n' > "$DATA_DIR/config.toml"
    printf 'old-session\n' > "$DATA_DIR/workspace/sessions-1/state.db"
    printf '3.1.3.3\n' > "$DATA_DIR/.state-version"
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" "$DATA_DIR" "$DATA_DIR/.state-version" "3.1.3.5"
    [ "$status" -eq 0 ]
    BACKUP_DIR="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d ! -name 'rollback-*' -print -quit)"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

@test "restore verifies the snapshot and preserves the replaced state" {
    printf 'new-brain\n' > "$DATA_DIR/brain.db"
    printf 'new-config\n' > "$DATA_DIR/config.toml"
    printf 'new-session\n' > "$DATA_DIR/workspace/sessions-1/state.db"

    run "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored_version=3.1.3.3"* ]]
    [ "$(cat "$DATA_DIR/brain.db")" = old-brain ]
    [ "$(cat "$DATA_DIR/config.toml")" = old-config ]
    [ "$(cat "$DATA_DIR/workspace/sessions-1/state.db")" = old-session ]
    [ "$(cat "$DATA_DIR/.state-version")" = 3.1.3.3 ]

    rollback_dir="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d -name 'rollback-*' -print -quit)"
    [ "$(cat "$rollback_dir/brain.db")" = new-brain ]
    [ "$(cat "$rollback_dir/config.toml")" = new-config ]
    [ "$(cat "$rollback_dir/workspace/sessions-1/state.db")" = new-session ]
    [ -s "$rollback_dir/manifest" ]
    [ -s "$rollback_dir/checksums" ]
}

@test "restore of a fresh snapshot removes the version marker and remains recoverable" {
    rm -f "$DATA_DIR/.state-version"
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" "$DATA_DIR" "$DATA_DIR/.state-version" "3.1.3.5"
    [ "$status" -eq 0 ]
    fresh_backup="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d -name 'fresh-to-*' -print -quit)"
    printf 'new-brain\n' > "$DATA_DIR/brain.db"
    run "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$DATA_DIR" "$fresh_backup"
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored_version=fresh"* ]]
    [ ! -e "$DATA_DIR/.state-version" ]
    rollback_dir="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d -name 'rollback-*' -print -quit)"
    [ -s "$rollback_dir/manifest" ]
    [ -s "$rollback_dir/checksums" ]
}

@test "a failed restore repairs live state from the durable rollback snapshot" {
    printf 'new-brain\n' > "$DATA_DIR/brain.db"
    printf 'new-config\n' > "$DATA_DIR/config.toml"
    printf 'new-session\n' > "$DATA_DIR/workspace/sessions-1/state.db"

    run env STATE_RESTORE_TEST_FAIL_AFTER_MUTATION=true \
        "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"live state was restored from rollback snapshot"* ]]
    [ "$(cat "$DATA_DIR/brain.db")" = new-brain ]
    [ "$(cat "$DATA_DIR/config.toml")" = new-config ]
    [ "$(cat "$DATA_DIR/workspace/sessions-1/state.db")" = new-session ]
    [ "$(cat "$DATA_DIR/.state-version")" = 3.1.3.5 ]
    rollback_dir="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d -name 'rollback-*' -print -quit)"
    [ -s "$rollback_dir/manifest" ]
    [ -s "$rollback_dir/checksums" ]
}

@test "a tampered snapshot is rejected before live state moves" {
    printf 'tampered\n' > "$BACKUP_DIR/brain.db"
    printf 'current\n' > "$DATA_DIR/brain.db"

    run "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -ne 0 ]
    [ "$(cat "$DATA_DIR/brain.db")" = current ]
    [ -z "$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d -name 'rollback-*' -print -quit)" ]
}
