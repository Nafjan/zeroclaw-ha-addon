#!/usr/bin/env bats

setup() {
    command -v jq >/dev/null 2>&1 || skip "state cleanup tests require jq"
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || skip "state cleanup tests require root or sudo"
        sudo -n true 2>/dev/null || skip "state cleanup tests require passwordless sudo"
    fi
    TEST_ROOT="$(mktemp -d)"
    DATA_DIR="$TEST_ROOT/data"
    mkdir -p "$DATA_DIR/approval-receipts/tickets" \
        "$DATA_DIR/approval-receipts/.claims" \
        "$DATA_DIR/approval-receipts/.locks" \
        "$DATA_DIR/approved" "$DATA_DIR/pending" "$DATA_DIR/capability" \
        "$DATA_DIR/provider" "$DATA_DIR/audit/planner"
    NOW="$(date -u +%s)"
}

run_cleanup() {
    if [ "$(id -u)" -eq 0 ]; then
        run "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh" "$DATA_DIR"
    else
        run sudo "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh" "$DATA_DIR"
    fi
}

teardown() {
    if [ -n "${TEST_ROOT:-}" ]; then
        rm -rf "$TEST_ROOT"
    fi
}

@test "expired sealed tickets and stale claims are removed" {
    printf '{"expires_at":%s}\n' "$((NOW - 1))" \
        > "$DATA_DIR/approval-receipts/tickets/deadbeef.json"
    mkdir "$DATA_DIR/approval-receipts/.claims/deadbeef.claim"
    touch -t 200001010000 "$DATA_DIR/approval-receipts/.claims/deadbeef.claim"
    printf 'receipt\n' > "$DATA_DIR/approval-receipts/deadbeef.sha256"
    printf '{}\n' > "$DATA_DIR/approved/deadbeef.marker"
    printf '{}\n' > "$DATA_DIR/pending/deadbeef.json"

    run_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$DATA_DIR/approval-receipts/tickets/deadbeef.json" ]
    [ ! -e "$DATA_DIR/approval-receipts/.claims/deadbeef.claim" ]
    [ ! -e "$DATA_DIR/approval-receipts/deadbeef.sha256" ]
    [ ! -e "$DATA_DIR/approved/deadbeef.marker" ]
    # Pending drafts are planner-owned. Root cleanup must not delete through
    # that attacker-controlled path; the unprivileged planner cleanup handles
    # its own retention safely.
    [ -f "$DATA_DIR/pending/deadbeef.json" ]
}

@test "unexpired tickets are retained" {
    printf '{"expires_at":%s}\n' "$((NOW + 3600))" \
        > "$DATA_DIR/approval-receipts/tickets/c0ffee12.json"
    printf 'receipt\n' > "$DATA_DIR/approval-receipts/c0ffee12.sha256"
    printf '{}\n' > "$DATA_DIR/approved/c0ffee12.marker"

    run_cleanup
    [ "$status" -eq 0 ]
    [ -f "$DATA_DIR/approval-receipts/tickets/c0ffee12.json" ]
    [ -f "$DATA_DIR/approval-receipts/c0ffee12.sha256" ]
    [ -f "$DATA_DIR/approved/c0ffee12.marker" ]
}

@test "old orphaned approval artifacts and locks are reclaimed" {
    printf 'orphan\n' > "$DATA_DIR/approval-receipts/feedcafe.sha256"
    printf '{}\n' > "$DATA_DIR/approved/feedcafe.marker"
    mkdir "$DATA_DIR/approval-receipts/.claims/badc0de1.claim"
    mkdir "$DATA_DIR/approval-receipts/.locks/approval-badc0de1.lock"
    touch -t 200001010000 \
        "$DATA_DIR/approval-receipts/feedcafe.sha256" \
        "$DATA_DIR/approved/feedcafe.marker" \
        "$DATA_DIR/approval-receipts/.claims/badc0de1.claim" \
        "$DATA_DIR/approval-receipts/.locks/approval-badc0de1.lock"

    run_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$DATA_DIR/approval-receipts/feedcafe.sha256" ]
    [ ! -e "$DATA_DIR/approved/feedcafe.marker" ]
    [ ! -e "$DATA_DIR/approval-receipts/.claims/badc0de1.claim" ]
    [ ! -e "$DATA_DIR/approval-receipts/.locks/approval-badc0de1.lock" ]
}

@test "expired correction receipts are removed" {
    printf '{"text":"stale","created_at":%s,"expires_at":%s}\n' \
        "$((NOW - 600))" "$((NOW - 1))" > "$DATA_DIR/capability/last-outcome.json"

    run_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$DATA_DIR/capability/last-outcome.json" ]
}

@test "dead transient broker locks are reclaimed while live owners are retained" {
    for lock in \
        "$DATA_DIR/capability/.read-quota.lock" \
        "$DATA_DIR/capability/.telegram-approval-rate.lock" \
        "$DATA_DIR/capability/.telegram-approval-admission.lock" \
        "$DATA_DIR/provider/.ledger.lock" \
        "$DATA_DIR/audit/.lock" \
        "$DATA_DIR/audit/planner/.quota.lock"; do
        mkdir "$lock"
        touch -t 200001010000 "$lock"
    done
    mkdir "$DATA_DIR/capability/.quota.lock"
    printf '%s\n' "$$" > "$DATA_DIR/capability/.quota.lock/owner"
    touch -t 200001010000 "$DATA_DIR/capability/.quota.lock"
    mkdir "$DATA_DIR/capability/.quota-live.lock"
    touch -t 200001010000 "$DATA_DIR/capability/.quota-live.lock"

    run_cleanup
    [ "$status" -eq 0 ]
    [ -e "$DATA_DIR/capability/.quota.lock" ]
    [ ! -e "$DATA_DIR/capability/.read-quota.lock" ]
    [ ! -e "$DATA_DIR/capability/.telegram-approval-rate.lock" ]
    [ ! -e "$DATA_DIR/capability/.telegram-approval-admission.lock" ]
    [ ! -e "$DATA_DIR/provider/.ledger.lock" ]
    [ ! -e "$DATA_DIR/audit/.lock" ]
    [ ! -e "$DATA_DIR/audit/planner/.quota.lock" ]
    [ -e "$DATA_DIR/capability/.quota-live.lock" ]
}
