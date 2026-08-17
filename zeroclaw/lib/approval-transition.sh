#!/bin/sh
# Transactional, actor-bound approval state transition.
# The Telegram adapter is the only caller allowed to approve/reject a ticket.
set -eu

ACTION="${1:-}"
SHORT="${2:-}"
ACTOR="${3:-}"
CHAT="${4:-}"
MARKER="/data/approved/${SHORT}.marker"
LOCK="${ZEROCLAW_APPROVAL_LOCK_DIR:-/data/approval-receipts/.locks}/approval-${SHORT}.lock"
RECEIPT="/data/approval-receipts/${SHORT}.sha256"
CLAIMS_DIR="${ZEROCLAW_APPROVAL_CLAIM_DIR:-/data/approval-receipts/.claims}"
CLAIM="${CLAIMS_DIR}/${SHORT}.claim"
TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"
TICKET="${TICKET_DIR}/${SHORT}.json"

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

case "$ACTION" in
    approve|reject|claim|complete)
        [ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || fail "approval transition is internal-only"
        ;;
    verify|verify_claim)
        [ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || fail "approval verification is internal-only"
        ;;
    *)
        fail "usage: approve|reject|verify|verify_claim <ticket> [actor] [chat]"
        ;;
esac

printf '%s' "$SHORT" | grep -Eq '^[a-f0-9]{8}$' || fail "invalid ticket id"

verify_marker() {
    [ -f "$MARKER" ] || fail "ticket ${SHORT} is not approved"
    [ -f "$TICKET" ] || fail "ticket ${SHORT} is missing"
    jq -e --arg id "$SHORT" --arg actor "$(jq -r '.approval.actor_user_id // empty' "$TICKET")" \
        --arg chat "$(jq -r '.approval.chat_id // empty' "$TICKET")" \
        '.ticket == $id and .actor_user_id == $actor and .chat_id == $chat and (.approved_at | type == "number")' \
        "$MARKER" >/dev/null 2>&1 || fail "ticket ${SHORT} approval marker is invalid"
    verify_receipt
    EXP=$(jq -r '.expires_at // 0' "$TICKET")
    NOW=$(date -u +%s)
    [ "$NOW" -le "$EXP" ] || fail "ticket ${SHORT} expired"
}

verify_receipt() {
    [ -f "$RECEIPT" ] || fail "ticket ${SHORT} was not sealed by the Telegram broker"
    expected_digest=$(cat "$RECEIPT")
    actual_digest=$(sha256sum "$TICKET" | cut -d' ' -f1)
    [ -n "$expected_digest" ] && [ "$actual_digest" = "$expected_digest" ] || fail "ticket ${SHORT} changed after notification"
}

if [ "$ACTION" = "verify" ]; then
    verify_marker
    [ ! -e "$CLAIM" ] || fail "ticket ${SHORT} is already claimed for application"
    echo "APPROVED ${SHORT}"
    exit 0
fi

if [ "$ACTION" = "verify_claim" ]; then
    verify_marker
    [ -d "$CLAIM" ] || fail "ticket ${SHORT} is not claimed for application"
    echo "CLAIMED_APPROVED ${SHORT}"
    exit 0
fi

acquire_lock() {
    LOCK_ATTEMPTS=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
        [ "$LOCK_ATTEMPTS" -lt 100 ] || fail "ticket ${SHORT} is already being transitioned"
        sleep 0.1
    done
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

if [ "$ACTION" = "claim" ]; then
    [ -f "$TICKET" ] || fail "ticket ${SHORT} is missing or expired"
    acquire_lock
    verify_receipt
    [ -f "$MARKER" ] || fail "ticket ${SHORT} is not approved"
    [ ! -e "$CLAIM" ] || fail "ticket ${SHORT} is already claimed"
    EXP=$(jq -r '.expires_at // 0' "$TICKET")
    NOW=$(date -u +%s)
    [ "$NOW" -le "$EXP" ] || fail "ticket ${SHORT} expired"
    mkdir -p "$CLAIMS_DIR"
    mkdir "$CLAIM" 2>/dev/null || fail "ticket ${SHORT} is already claimed"
    echo "CLAIMED ${SHORT}"
    exit 0
fi

if [ "$ACTION" = "complete" ]; then
    acquire_lock
    [ -d "$CLAIM" ] || fail "ticket ${SHORT} is not claimed"
    rm -f "$MARKER" "$TICKET" "$RECEIPT"
    rmdir "$CLAIM" || fail "ticket ${SHORT} claim could not be cleared"
    echo "COMPLETED ${SHORT}"
    exit 0
fi

[ -f "$TICKET" ] || fail "ticket ${SHORT} is missing or expired"
acquire_lock
verify_receipt

EXP=$(jq -r '.expires_at // 0' "$TICKET")
NOW=$(date -u +%s)
[ "$NOW" -le "$EXP" ] || fail "ticket ${SHORT} expired"
EXPECTED_ACTOR=$(jq -r '.approval.actor_user_id // empty' "$TICKET")
EXPECTED_CHAT=$(jq -r '.approval.chat_id // empty' "$TICKET")
[ -n "$EXPECTED_ACTOR" ] && [ "$ACTOR" = "$EXPECTED_ACTOR" ] || fail "actor is not authorized for ticket ${SHORT}"
[ -n "$EXPECTED_CHAT" ] && [ "$CHAT" = "$EXPECTED_CHAT" ] || fail "chat is not authorized for ticket ${SHORT}"
[ ! -e "$CLAIM" ] || fail "ticket ${SHORT} is being applied"
[ ! -e "$MARKER" ] || fail "ticket ${SHORT} was already approved"

case "$ACTION" in
    approve)
        mkdir -p /data/approved
        TMP=$(mktemp "/data/approved/.${SHORT}.XXXXXX")
        jq -nc --arg ticket "$SHORT" --arg actor_user_id "$ACTOR" --arg chat_id "$CHAT" \
            --argjson approved_at "$NOW" \
            '{ticket:$ticket,actor_user_id:$actor_user_id,chat_id:$chat_id,approved_at:$approved_at}' > "$TMP"
        chmod 0640 "$TMP"
        mv "$TMP" "$MARKER"
        echo "APPROVED ${SHORT}"
        ;;
    reject)
        rm -f "$TICKET" "$MARKER" "$RECEIPT"
        echo "REJECTED ${SHORT}"
        ;;
esac
