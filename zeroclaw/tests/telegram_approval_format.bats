#!/usr/bin/env bats

setup() {
    command -v jq >/dev/null 2>&1 || skip "approval-format tests require jq"
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || skip "approval-format tests require root or sudo"
        sudo -n true 2>/dev/null || skip "approval-format tests require passwordless sudo"
    fi
    TEST_ROOT="$(mktemp -d)"
    DATA_DIR="$TEST_ROOT/data"
    mkdir -p "$DATA_DIR/approval-receipts/tickets" \
        "$DATA_DIR/approval-receipts/.claims" \
        "$DATA_DIR/approval-receipts/.locks" \
        "$DATA_DIR/approval-receipts/ticket-nonces" \
        "$DATA_DIR/approved" "$DATA_DIR/pending" "$DATA_DIR/capability" \
        "$DATA_DIR/provider" "$DATA_DIR/audit/planner"
    TICKET="$DATA_DIR/approval-receipts/tickets/deadbeef.json"
    OLD_GENERATION=11111111111111111111111111111111
    NEW_GENERATION=22222222222222222222222222222222
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../lib/telegram-approval-format.sh"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

run_cleanup() {
    if [ "$(id -u)" -eq 0 ]; then
        run "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh" "$DATA_DIR"
    else
        run sudo "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh" "$DATA_DIR"
    fi
}

@test "approval and rejection text include the sealed generation" {
    run approval_request " YES deadbeef $OLD_GENERATION "
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeef $OLD_GENERATION" ]

    run rejection_request "NO deadbeef $OLD_GENERATION"
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeef $OLD_GENERATION" ]

    run approval_request "YES deadbeef"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "expired cleanup and id reuse reject delayed text from the old generation" {
    printf '{"expires_at":0,"approval_generation":"%s"}\n' "$OLD_GENERATION" > "$TICKET"
    run approval_generation_matches "$TICKET" "$OLD_GENERATION"
    [ "$status" -eq 0 ]

    mkdir "$DATA_DIR/approval-receipts/ticket-nonces/deadbeef"
    run_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$TICKET" ]
    [ ! -e "$DATA_DIR/approval-receipts/ticket-nonces/deadbeef" ]

    # The expired ticket and its nonce barrier are gone, so a later broker
    # request may reuse the short id with a new root-sealed code.
    printf '{"expires_at":9999999999,"approval_generation":"%s"}\n' "$NEW_GENERATION" > "$TICKET"

    run approval_generation_matches "$TICKET" "$OLD_GENERATION"
    [ "$status" -ne 0 ]
    run approval_generation_matches "$TICKET" "$NEW_GENERATION"
    [ "$status" -eq 0 ]
}
