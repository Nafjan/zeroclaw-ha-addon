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

@test "version change snapshots state and preserves the live files" {
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" "$DATA_DIR" "$DATA_DIR/.state-version" "3.1.3.5"
    [ "$status" -eq 0 ]
    [[ "$output" == *"old=3.1.3.3 new=3.1.3.5"* ]]
    [ "$(cat "$DATA_DIR/.state-version")" = "3.1.3.5" ]
    [ "$(cat "$DATA_DIR/brain.db")" = "brain" ]
    [ "$(cat "$DATA_DIR/workspace/sessions-1/state.db")" = "session" ]
    backup_dir=$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [ -n "$backup_dir" ]
    [ "$(cat "$backup_dir/brain.db")" = "brain" ]
    [ "$(cat "$backup_dir/workspace/sessions-1/state.db")" = "session" ]
}

@test "same version is a no-op" {
    before=$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" "$DATA_DIR" "$DATA_DIR/.state-version" "3.1.3.3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    after=$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    [ "$before" = "$after" ]
}
