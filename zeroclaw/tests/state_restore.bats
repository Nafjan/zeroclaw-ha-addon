#!/usr/bin/env bats

setup() {
    TEST_ROOT="$(mktemp -d)"
    DATA_DIR="$TEST_ROOT/data"
    mkdir -p "$DATA_DIR/workspace/sessions-1" \
        "$DATA_DIR/provider" "$DATA_DIR/capability" \
        "$DATA_DIR/approval-receipts/tickets" "$DATA_DIR/audit"
    printf 'old-brain\n' > "$DATA_DIR/brain.db"
    printf 'old-config\n' > "$DATA_DIR/config.toml"
    printf 'old-session\n' > "$DATA_DIR/workspace/sessions-1/state.db"
    printf 'old-options\n' > "$DATA_DIR/options.json"
    printf 'old-provider\n' > "$DATA_DIR/provider/profile"
    printf 'old-capability\n' > "$DATA_DIR/capability/state"
    printf 'old-ticket\n' > "$DATA_DIR/approval-receipts/tickets/ticket-1"
    printf 'old-audit\n' > "$DATA_DIR/audit/2026-09-01.jsonl"
    printf '3.1.3.3\n' > "$DATA_DIR/.state-version"
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -eq 0 ]
    BACKUP_DIR="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d ! -name 'rollback-*' -print -quit)"
}

teardown() {
    if [ "$(id -u)" -eq 0 ]; then
        rm -rf "$TEST_ROOT"
    else
        sudo -n rm -rf "$TEST_ROOT"
    fi
}

restore_state() {
    if [ "$(id -u)" -eq 0 ]; then
        "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$@"
    else
        sudo -n "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$@"
    fi
}

restore_state_with_failure() {
    if [ "$(id -u)" -eq 0 ]; then
        STATE_RESTORE_TEST_FAIL_AFTER_MUTATION=true \
            "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$@"
    else
        sudo -n env STATE_RESTORE_TEST_FAIL_AFTER_MUTATION=true \
            "$BATS_TEST_DIRNAME/../lib/state-restore.sh" "$@"
    fi
}

root_find() {
    if [ "$(id -u)" -eq 0 ]; then
        find "$@"
    else
        sudo -n find "$@"
    fi
}

root_cat() {
    if [ "$(id -u)" -eq 0 ]; then
        cat "$@"
    else
        sudo -n cat "$@"
    fi
}

root_test_size() {
    if [ "$(id -u)" -eq 0 ]; then
        test -s "$1"
    else
        sudo -n test -s "$1"
    fi
}

@test "restore verifies the snapshot and replaces the full persistent inventory" {
    printf 'new-brain\n' > "$DATA_DIR/brain.db"
    printf 'new-config\n' > "$DATA_DIR/config.toml"
    printf 'new-session\n' > "$DATA_DIR/workspace/sessions-1/state.db"
    printf 'new-options\n' > "$DATA_DIR/options.json"
    printf 'new-provider\n' > "$DATA_DIR/provider/profile"
    printf 'new-capability\n' > "$DATA_DIR/capability/state"
    printf 'new-ticket\n' > "$DATA_DIR/approval-receipts/tickets/ticket-1"
    printf 'new-audit\n' > "$DATA_DIR/audit/2026-09-01.jsonl"

    run restore_state \
        "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored_schema=0 restored_version=3.1.3.3"* ]]
    [ "$(cat "$DATA_DIR/brain.db")" = old-brain ]
    [ "$(cat "$DATA_DIR/config.toml")" = old-config ]
    [ "$(cat "$DATA_DIR/workspace/sessions-1/state.db")" = old-session ]
    [ "$(cat "$DATA_DIR/options.json")" = old-options ]
    [ "$(cat "$DATA_DIR/provider/profile")" = old-provider ]
    [ "$(cat "$DATA_DIR/capability/state")" = old-capability ]
    [ ! -e "$DATA_DIR/approval-receipts/tickets/ticket-1" ]
    [ "$(cat "$DATA_DIR/audit/2026-09-01.jsonl")" = new-audit ]
    [ ! -e "$DATA_DIR/.state-schema" ]
    [ "$(cat "$DATA_DIR/.state-version")" = 3.1.3.3 ]
    [ "$(root_cat "$DATA_DIR/capability/telegram-offset")" = -1 ]
    [ "$(root_cat "$DATA_DIR/.approval-restore-epoch")" = 1 ]

    rollback_dir="$(root_find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'rollback-*' -print -quit)"
    [ "$(root_cat "$rollback_dir/brain.db")" = new-brain ]
    [ "$(root_cat "$rollback_dir/options.json")" = new-options ]
    [ "$(root_cat "$rollback_dir/provider/profile")" = new-provider ]
    [ "$(root_cat "$rollback_dir/audit/2026-09-01.jsonl")" = new-audit ]
    [ "$(root_cat "$rollback_dir/.state-schema")" = 1 ]
    [ ! -e "$rollback_dir/.state-version" ]
    run root_test_size "$rollback_dir/manifest"
    [ "$status" -eq 0 ]
    run root_test_size "$rollback_dir/checksums"
    [ "$status" -eq 0 ]
}

@test "restore preserves current monotonic quotas, admissions, and audit history" {
    printf '{"hour_window":123,"requests_hour":17}\n' > "$DATA_DIR/capability/quota.json"
    printf '{"schema":1,"records":[{"id":"current-ledger","profile_id":"openrouter","reserved_tokens":1,"reserved_input_tokens":2,"settled_tokens":3,"settled_input_tokens":4,"reserved_cost_micros":5,"settled_cost_micros":5,"state":"settled","hour_window":123,"day_window":1,"month_window":"1970-01","created_at":1,"expires_at":1,"updated_at":2}],"profile_quarantine":[]}\n' \
        > "$DATA_DIR/provider/quota.json"
    mkdir -p "$DATA_DIR/capability/action-admissions" "$DATA_DIR/audit/planner"
    printf '{"ticket":"cafe0001","hour_window":123}\n' \
        > "$DATA_DIR/capability/action-admissions/cafe0001.json"
    printf '{"hour_window":123,"units_hour":9}\n' > "$DATA_DIR/capability/read-quota.json"
    printf '{"schema":1,"window_start":1,"clients":{"42":3}}\n' \
        > "$DATA_DIR/capability/telegram-approval-rate.json"
    printf '{"hour_window":123,"events_hour":4,"bytes_day":5}\n' \
        > "$DATA_DIR/audit/planner/.quota.json"
    printf 'current-audit\n' > "$DATA_DIR/audit/2026-09-02.jsonl"

    run restore_state "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -eq 0 ]
    [ "$(root_cat "$DATA_DIR/capability/quota.json")" = '{"hour_window":123,"requests_hour":17}' ]
    [[ "$(root_cat "$DATA_DIR/provider/quota.json")" == *'current-ledger'* ]]
    [ "$(root_cat "$DATA_DIR/capability/action-admissions/cafe0001.json")" = '{"ticket":"cafe0001","hour_window":123}' ]
    [ "$(root_cat "$DATA_DIR/capability/read-quota.json")" = '{"hour_window":123,"units_hour":9}' ]
    [[ "$(root_cat "$DATA_DIR/capability/telegram-approval-rate.json")" == *'"42":3'* ]]
    [ "$(root_cat "$DATA_DIR/audit/planner/.quota.json")" = '{"hour_window":123,"events_hour":4,"bytes_day":5}' ]
    [ "$(root_cat "$DATA_DIR/audit/2026-09-02.jsonl")" = current-audit ]
    [ "$(root_cat "$DATA_DIR/audit/2026-09-01.jsonl")" = old-audit ]
}

@test "restore of a fresh snapshot removes the schema marker and remains recoverable" {
    rm -f "$DATA_DIR/.state-schema" "$DATA_DIR/.state-version"
    run "$BATS_TEST_DIRNAME/../lib/state-migrate.sh" \
        "$DATA_DIR" "$DATA_DIR/.state-schema" 1
    [ "$status" -eq 0 ]
    fresh_backup="$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'schema-0-to-schema-1-*' -print -quit)"
    [ -n "$fresh_backup" ]
    printf 'new-brain\n' > "$DATA_DIR/brain.db"

    run restore_state \
        "$DATA_DIR" "$fresh_backup"
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored_schema=0 restored_version=fresh"* ]]
    [ "$(cat "$DATA_DIR/brain.db")" = old-brain ]
    [ ! -e "$DATA_DIR/.state-schema" ]
    [ ! -e "$DATA_DIR/.state-version" ]
    rollback_dir="$(root_find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'rollback-*' -print -quit)"
    run root_test_size "$rollback_dir/manifest"
    [ "$status" -eq 0 ]
    run root_test_size "$rollback_dir/checksums"
    [ "$status" -eq 0 ]
}

@test "a failed restore repairs live state from the durable rollback snapshot" {
    printf 'new-brain\n' > "$DATA_DIR/brain.db"
    printf 'new-config\n' > "$DATA_DIR/config.toml"
    printf 'new-session\n' > "$DATA_DIR/workspace/sessions-1/state.db"

    run restore_state_with_failure \
        "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"live state was restored from rollback snapshot"* ]]
    [ "$(cat "$DATA_DIR/brain.db")" = new-brain ]
    [ "$(cat "$DATA_DIR/config.toml")" = new-config ]
    [ "$(cat "$DATA_DIR/workspace/sessions-1/state.db")" = new-session ]
    [ "$(cat "$DATA_DIR/.state-schema")" = 1 ]
    [ ! -e "$DATA_DIR/.state-version" ]
    rollback_dir="$(root_find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'rollback-*' -print -quit)"
    run root_test_size "$rollback_dir/manifest"
    [ "$status" -eq 0 ]
    run root_test_size "$rollback_dir/checksums"
    [ "$status" -eq 0 ]
}

@test "a tampered snapshot is rejected before live state moves" {
    printf 'tampered\n' > "$BACKUP_DIR/brain.db"
    printf 'current\n' > "$DATA_DIR/brain.db"

    run restore_state \
        "$DATA_DIR" "$BACKUP_DIR"
    [ "$status" -ne 0 ]
    [ "$(cat "$DATA_DIR/brain.db")" = current ]
    [ "$(cat "$DATA_DIR/.state-schema")" = 1 ]
    [ -z "$(find "$DATA_DIR/migrations" -mindepth 1 -maxdepth 1 \
        -type d -name 'rollback-*' -print -quit)" ]
}
