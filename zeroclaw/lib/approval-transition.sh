#!/bin/sh
# Transactional, actor-bound approval state transition.
# The Telegram adapter is the only caller allowed to approve/reject a ticket.
set -eu

ACTION="${1:-}"
SHORT="${2:-}"
ACTOR="${3:-}"
CHAT="${4:-}"
GENERATION="${5:-}"
MESSAGE_ID="${6:-}"
MARKER="/data/approved/${SHORT}.marker"
LOCK="${ZEROCLAW_APPROVAL_LOCK_DIR:-/data/approval-receipts/.locks}/approval-${SHORT}.lock"
RECEIPT="/data/approval-receipts/${SHORT}.sha256"
CLAIMS_DIR="${ZEROCLAW_APPROVAL_CLAIM_DIR:-/data/approval-receipts/.claims}"
CLAIM="${CLAIMS_DIR}/${SHORT}.claim"
TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"
TICKET="${TICKET_DIR}/${SHORT}.json"
TICKET_NONCE_DIR="${ZEROCLAW_APPROVAL_TICKET_NONCE_DIR:-/data/approval-receipts/ticket-nonces}"
RESTORE_EPOCH_FILE="${ZEROCLAW_RESTORE_EPOCH_FILE:-/data/.approval-restore-epoch}"
AUDIT_DIR="${ZEROCLAW_AUDIT_DIR:-/data/audit}"
ACTION_ADMISSION_DIR="${ZEROCLAW_ACTION_ADMISSION_DIR:-/data/capability/action-admissions}"
ACTION_QUOTA_LOCK="${ZEROCLAW_ACTION_QUOTA_LOCK:-/data/capability/.quota.lock}"
ACTION_QUOTA_FILE="${ZEROCLAW_ACTION_QUOTA_FILE:-/data/capability/quota.json}"
ACTION_LIMIT="${CAPABILITY_MAX_ACTIONS_PER_HOUR:-200}"
approval_lock_held=0
quota_lock_held=0
admission_tmp=""

cleanup() {
    rm -f "$admission_tmp"
    if [ "$quota_lock_held" -eq 1 ]; then
        rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
    fi
    if [ "$approval_lock_held" -eq 1 ]; then
        rm -f -- "$LOCK/owner" 2>/dev/null || true
        rmdir "$LOCK" 2>/dev/null || true
    fi
}
trap cleanup EXIT

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

case "$ACTION" in
    approve|reject|claim|claim_admit|complete)
        [ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || fail "approval transition is internal-only"
        ;;
    verify|verify_claim)
        [ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || fail "approval verification is internal-only"
        ;;
    *)
        fail "usage: approve|reject|verify|verify_claim <ticket> [actor] [chat] [generation] [message_id]"
        ;;
esac

printf '%s' "$SHORT" | grep -Eq '^[a-f0-9]{8}$' || fail "invalid ticket id"

ensure_ticket_nonce() {
    [ -d "$TICKET_NONCE_DIR" ] && [ ! -L "$TICKET_NONCE_DIR" ] || fail "ticket nonce history is unavailable"
    nonce_path="${TICKET_NONCE_DIR}/${SHORT}"
    if [ -e "$nonce_path" ] || [ -L "$nonce_path" ]; then
        [ -d "$nonce_path" ] && [ ! -L "$nonce_path" ] || fail "ticket nonce record is unsafe"
        chmod 0700 "$nonce_path" || fail "ticket nonce record is unsafe"
        return 0
    fi
    if mkdir "$nonce_path" 2>/dev/null; then
        chmod 0700 "$nonce_path" || fail "ticket nonce could not be secured"
        return 0
    fi
    # Another concurrent transition may have created the directory after the
    # existence check. Treat that valid, non-symlink directory as the same
    # reservation; any other mkdir failure remains fail-closed.
    [ -d "$nonce_path" ] && [ ! -L "$nonce_path" ] || fail "ticket nonce could not be reserved"
    chmod 0700 "$nonce_path" || fail "ticket nonce could not be secured"
}

current_restore_epoch() {
    [ -f "$RESTORE_EPOCH_FILE" ] && [ ! -L "$RESTORE_EPOCH_FILE" ] || fail "approval restore epoch is unavailable"
    restore_epoch=$(tr -d '\r\n' < "$RESTORE_EPOCH_FILE")
    printf '%s' "$restore_epoch" | grep -Eq '^[0-9]+$' || fail "approval restore epoch is malformed"
    printf '%s' "$restore_epoch"
}

valid_approval_generation() {
    [ "$#" -eq 1 ] || return 1
    printf '%s' "$1" | grep -Eq '^[a-f0-9]{32}$'
}

valid_positive_id() {
    [ "$#" -eq 1 ] || return 1
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

verify_supplied_generation() {
    [ -f "$TICKET" ] && [ ! -L "$TICKET" ] || fail "ticket ${SHORT} is missing or expired"
    valid_approval_generation "$GENERATION" || fail "approval generation is invalid"
    ticket_generation=$(jq -er '.approval_generation | select(type == "string")' "$TICKET" 2>/dev/null) || \
        fail "ticket ${SHORT} approval generation is invalid"
    valid_approval_generation "$ticket_generation" || fail "ticket ${SHORT} approval generation is invalid"
    [ "$ticket_generation" = "$GENERATION" ] || \
        fail "approval generation does not match ticket ${SHORT}"
}

verify_supplied_message_id() {
    # A callback carries the Telegram message id as well as the approval
    # generation. When supplied, bind both values to the ticket while the
    # transition lock is held; this closes the window where cleanup can replace
    # a ticket between the watcher's two reads.
    [ -n "$MESSAGE_ID" ] || return 0
    valid_positive_id "$MESSAGE_ID" || fail "approval message id is invalid"
    ticket_message_id=$(jq -er '.tg_message_id | select(type == "number" and floor == .) | tostring' \
        "$TICKET" 2>/dev/null) || fail "ticket ${SHORT} Telegram message id is invalid"
    valid_positive_id "$ticket_message_id" || fail "ticket ${SHORT} Telegram message id is invalid"
    [ "$ticket_message_id" = "$MESSAGE_ID" ] || \
        fail "approval message id does not match ticket ${SHORT}"
}

ensure_ticket_nonce

verify_marker() {
    [ -f "$MARKER" ] && [ ! -L "$MARKER" ] || fail "ticket ${SHORT} is not approved"
    [ -f "$TICKET" ] && [ ! -L "$TICKET" ] || fail "ticket ${SHORT} is missing"
    marker_epoch=$(current_restore_epoch)
    ticket_epoch=$(jq -er '.restore_epoch | select(type == "number" and floor == .)' "$TICKET" 2>/dev/null) ||
        fail "ticket ${SHORT} restore epoch is invalid"
    [ "$ticket_epoch" = "$marker_epoch" ] || fail "ticket ${SHORT} belongs to a prior restore epoch"
    ticket_generation=$(jq -er '.approval_generation | select(type == "string")' "$TICKET" 2>/dev/null) || \
        fail "ticket ${SHORT} approval generation is invalid"
    valid_approval_generation "$ticket_generation" || fail "ticket ${SHORT} approval generation is invalid"
    jq -e --arg id "$SHORT" --arg actor "$(jq -r '.approval.actor_user_id // empty' "$TICKET")" \
        --arg chat "$(jq -r '.approval.chat_id // empty' "$TICKET")" \
        --arg generation "$ticket_generation" \
        --argjson epoch "$marker_epoch" \
        '.ticket == $id and .state == "approved_audited" and .actor_user_id == $actor and .chat_id == $chat and .approval_generation == $generation and (.approved_at | type == "number") and .restore_epoch == $epoch and (.restore_epoch | type == "number" and floor == .)' \
        "$MARKER" >/dev/null 2>&1 || fail "ticket ${SHORT} approval marker is invalid"
    verify_receipt
    approval_audit_found=1
    if [ -d "$AUDIT_DIR" ] && [ ! -L "$AUDIT_DIR" ]; then
        for audit_file in "$AUDIT_DIR"/*.jsonl; do
            [ -f "$audit_file" ] && [ ! -L "$audit_file" ] || continue
            if jq -e --arg ticket "$SHORT" \
                'select(.kind == "approve" and (.reason | type == "string") and (.reason | contains("ticket=" + $ticket)))' \
                "$audit_file" >/dev/null 2>&1; then
                approval_audit_found=0
                break
            fi
        done
    fi
    [ "$approval_audit_found" -eq 0 ] || fail "ticket ${SHORT} approval audit is missing"
    EXP=$(jq -r '.expires_at // 0' "$TICKET")
    NOW=$(date -u +%s)
    [ "$NOW" -le "$EXP" ] || fail "ticket ${SHORT} expired"
}

verify_receipt() {
    [ -f "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || fail "ticket ${SHORT} was not sealed by the Telegram broker"
    expected_digest=$(cat "$RECEIPT")
    actual_digest=$(sha256sum "$TICKET" | cut -d' ' -f1)
    [ -n "$expected_digest" ] && [ "$actual_digest" = "$expected_digest" ] || fail "ticket ${SHORT} changed after notification"
}

if [ "$ACTION" = "verify" ]; then
    verify_marker
    [ ! -e "$CLAIM" ] && [ ! -L "$CLAIM" ] || fail "ticket ${SHORT} is already claimed for application"
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
    APPROVAL_LOCK_MAX_ATTEMPTS=600
    while ! mkdir "$LOCK" 2>/dev/null; do
        LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
        # QEMU-backed acceptance and a cold HA start can make the durable
        # approval transaction exceed the old ten-second ceiling. Keep the
        # wait bounded, but allow valid concurrent callbacks to observe the
        # committed idempotent result instead of being rejected mid-flight.
        [ "$LOCK_ATTEMPTS" -lt "$APPROVAL_LOCK_MAX_ATTEMPTS" ] || fail "ticket ${SHORT} is already being transitioned"
        sleep 0.1
    done
    printf '%s\n' "$$" > "$LOCK/owner" || {
        rmdir "$LOCK" 2>/dev/null || true
        fail "ticket ${SHORT} transition lock is unavailable"
    }
    chmod 0600 "$LOCK/owner" || {
        rm -f -- "$LOCK/owner" 2>/dev/null || true
        rmdir "$LOCK" 2>/dev/null || true
        fail "ticket ${SHORT} transition lock is unavailable"
    }
    approval_lock_held=1
}

acquire_quota_lock() {
    quota_attempts=0
    while ! mkdir "$ACTION_QUOTA_LOCK" 2>/dev/null; do
        quota_attempts=$((quota_attempts + 1))
        [ "$quota_attempts" -le 100 ] || fail "capability action quota is busy"
        sleep 0.1
    done
    printf '%s\n' "$$" > "$ACTION_QUOTA_LOCK/owner" || {
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        fail "capability action quota lock is unavailable"
    }
    chmod 0600 "$ACTION_QUOTA_LOCK/owner" || {
        rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        fail "capability action quota lock is unavailable"
    }
    quota_lock_held=1
}

validate_action_quota_config() {
    case "$ACTION_LIMIT" in
        ''|*[!0-9]*) fail "capability action limit is invalid" ;;
    esac
    [ "$ACTION_LIMIT" -ge 1 ] && [ "$ACTION_LIMIT" -le 1000 ] || \
        fail "capability action limit is outside the safe range"
}

ticket_admission_count() {
    count=0
    if [ -d "$ACTION_ADMISSION_DIR" ] && [ ! -L "$ACTION_ADMISSION_DIR" ]; then
        for admission in "$ACTION_ADMISSION_DIR"/*.json; do
            [ -f "$admission" ] && [ ! -L "$admission" ] || continue
            if jq -e --argjson hour "$1" \
                '.hour_window == $hour and (.ticket | type == "string")' \
                "$admission" >/dev/null 2>&1; then
                count=$((count + 1))
            fi
        done
    fi
    if [ -d "$CLAIMS_DIR" ] && [ ! -L "$CLAIMS_DIR" ]; then
        for claim_dir in "$CLAIMS_DIR"/*.claim; do
            [ -d "$claim_dir" ] && [ ! -L "$claim_dir" ] || continue
            claim_short=$(basename "$claim_dir" .claim)
            [ -f "$ACTION_ADMISSION_DIR/${claim_short}.json" ] && continue
            claim_quota="$claim_dir/quota.json"
            if jq -e --argjson hour "$1" '.hour_window == $hour' "$claim_quota" >/dev/null 2>&1; then
                count=$((count + 1))
            else
                # An incomplete claim is safer to count against the current
                # window than to ignore and under-enforce the action budget.
                count=$((count + 1))
            fi
        done
    fi
    printf '%s' "$count"
}

claim_with_admission() {
    validate_action_quota_config
    [ -f "$TICKET" ] && [ ! -L "$TICKET" ] || fail "ticket ${SHORT} is missing or expired"
    acquire_lock
    verify_marker
    [ ! -e "$CLAIM" ] && [ ! -L "$CLAIM" ] || fail "ticket ${SHORT} is already claimed"
    acquire_quota_lock
    now=$(date -u +%s)
    hour_window=$((now / 3600))
    if [ -f "$ACTION_QUOTA_FILE" ] && [ ! -L "$ACTION_QUOTA_FILE" ]; then
        quota=$(cat "$ACTION_QUOTA_FILE")
    else
        quota='{}'
    fi
    printf '%s' "$quota" | jq -e 'type == "object"' >/dev/null 2>&1 || fail "capability action quota state is invalid"
    global_requests=$(printf '%s' "$quota" | jq -r --argjson hour "$hour_window" \
        'if .hour_window == $hour then (.requests_hour // 0) else 0 end')
    case "$global_requests" in
        ''|*[!0-9]*) fail "capability action quota state is invalid" ;;
    esac
    admission_count=$(ticket_admission_count "$hour_window")
    total_requests=$((global_requests + admission_count))
    [ "$total_requests" -lt "$ACTION_LIMIT" ] || fail "capability hourly action budget exceeded"
    mkdir -p "$CLAIMS_DIR"
    mkdir "$CLAIM" 2>/dev/null || fail "ticket ${SHORT} is already claimed"
    admission_tmp="$CLAIM/.quota.json.tmp"
    jq -nc --arg ticket "$SHORT" --argjson hour "$hour_window" --argjson created "$now" \
        '{ticket:$ticket,hour_window:$hour,created_at:$created}' > "$admission_tmp" || fail "ticket admission could not be recorded"
    chmod 0600 "$admission_tmp"
    mv "$admission_tmp" "$CLAIM/quota.json"
    admission_tmp=""
    sync
    echo "CLAIMED_ADMITTED ${SHORT}"
}

if [ "$ACTION" = "claim_admit" ]; then
    claim_with_admission
    exit 0
fi

if [ "$ACTION" = "claim" ]; then
    [ -f "$TICKET" ] || fail "ticket ${SHORT} is missing or expired"
    acquire_lock
    verify_marker
    [ ! -e "$CLAIM" ] || fail "ticket ${SHORT} is already claimed"
    mkdir -p "$CLAIMS_DIR"
    mkdir "$CLAIM" 2>/dev/null || fail "ticket ${SHORT} is already claimed"
    echo "CLAIMED ${SHORT}"
    exit 0
fi

if [ "$ACTION" = "complete" ]; then
    acquire_lock
    verify_marker
    [ -d "$CLAIM" ] && [ ! -L "$CLAIM" ] || fail "ticket ${SHORT} is not claimed"
    claim_quota="$CLAIM/quota.json"
    if [ -f "$claim_quota" ] && [ ! -L "$claim_quota" ]; then
        if [ -e "$ACTION_ADMISSION_DIR" ] || [ -L "$ACTION_ADMISSION_DIR" ]; then
            [ -d "$ACTION_ADMISSION_DIR" ] && [ ! -L "$ACTION_ADMISSION_DIR" ] || \
                fail "capability action admission directory is unsafe"
        else
            mkdir "$ACTION_ADMISSION_DIR" 2>/dev/null || fail "capability action admission directory could not be created"
            chmod 0700 "$ACTION_ADMISSION_DIR"
        fi
        admission_file="$ACTION_ADMISSION_DIR/${SHORT}.json"
        if [ -e "$admission_file" ] || [ -L "$admission_file" ]; then
            [ -f "$admission_file" ] && [ ! -L "$admission_file" ] || \
                fail "capability action admission record is unsafe"
            jq -e --arg ticket "$SHORT" \
                '.ticket == $ticket and (.hour_window | type == "number" and floor == .)' \
                "$admission_file" >/dev/null 2>&1 || \
                fail "capability action admission record is invalid"
        else
            admission_tmp="${ACTION_ADMISSION_DIR}/.${SHORT}.XXXXXX"
            admission_tmp=$(mktemp "$admission_tmp")
            jq -c --arg ticket "$SHORT" '. + {ticket:$ticket}' "$claim_quota" > "$admission_tmp" || fail "ticket admission could not be finalized"
            chmod 0600 "$admission_tmp"
            mv "$admission_tmp" "$admission_file"
            admission_tmp=""
            sync
        fi
    fi
    rm -f "$MARKER" "$TICKET" "$RECEIPT"
    rm -f "$claim_quota"
    rmdir "$CLAIM" || fail "ticket ${SHORT} claim could not be cleared"
    echo "COMPLETED ${SHORT}"
    exit 0
fi

[ -f "$TICKET" ] || fail "ticket ${SHORT} is missing or expired"
acquire_lock
verify_supplied_generation
verify_supplied_message_id
verify_receipt
current_restore_epoch_value=$(current_restore_epoch)
ticket_restore_epoch=$(jq -er '.restore_epoch | select(type == "number" and floor == .)' "$TICKET" 2>/dev/null) ||
    fail "ticket ${SHORT} restore epoch is invalid"
[ "$ticket_restore_epoch" = "$current_restore_epoch_value" ] ||
    fail "ticket ${SHORT} belongs to a prior restore epoch"

EXP=$(jq -r '.expires_at // 0' "$TICKET")
NOW=$(date -u +%s)
[ "$NOW" -le "$EXP" ] || fail "ticket ${SHORT} expired"
EXPECTED_ACTOR=$(jq -r '.approval.actor_user_id // empty' "$TICKET")
EXPECTED_CHAT=$(jq -r '.approval.chat_id // empty' "$TICKET")
[ -n "$EXPECTED_ACTOR" ] && [ "$ACTOR" = "$EXPECTED_ACTOR" ] || fail "actor is not authorized for ticket ${SHORT}"
[ -n "$EXPECTED_CHAT" ] && [ "$CHAT" = "$EXPECTED_CHAT" ] || fail "chat is not authorized for ticket ${SHORT}"
[ ! -e "$CLAIM" ] && [ ! -L "$CLAIM" ] || fail "ticket ${SHORT} is being applied"
if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
    if [ -f "$MARKER" ] && [ ! -L "$MARKER" ] && jq -e --arg id "$SHORT" \
        --arg actor "$ACTOR" --arg chat "$CHAT" --arg generation "$ticket_generation" \
        --argjson epoch "$current_restore_epoch_value" \
        '.ticket == $id and .state == "approval_pending" and .actor_user_id == $actor and .chat_id == $chat and .approval_generation == $generation and (.approved_at | type == "number") and .restore_epoch == $epoch and (.restore_epoch | type == "number" and floor == .)' \
        "$MARKER" >/dev/null 2>&1; then
        rm -f "$MARKER"
    elif [ "$ACTION" = "approve" ] && [ -f "$MARKER" ] && [ ! -L "$MARKER" ] && \
        jq -e --arg id "$SHORT" --arg actor "$ACTOR" --arg chat "$CHAT" \
        --arg generation "$ticket_generation" --argjson epoch "$current_restore_epoch_value" \
        '.ticket == $id and .state == "approved_audited" and .actor_user_id == $actor and .chat_id == $chat and .approval_generation == $generation and (.approved_at | type == "number") and .restore_epoch == $epoch and (.restore_epoch | type == "number" and floor == .)' \
        "$MARKER" >/dev/null 2>&1; then
        # A watcher can restart after the audited approval marker is durable but
        # before the capability broker claims it. Revalidate the marker, ticket,
        # receipt, audit, epoch, and expiry under this same transition lock, then
        # let the caller resume the one-shot apply path.
        verify_marker
        echo "ALREADY_APPROVED ${SHORT}"
        exit 0
    else
        fail "ticket ${SHORT} was already approved"
    fi
fi

case "$ACTION" in
    approve)
        APPROVE_SERVICE=$(jq -er '.service | select(type == "string")' "$TICKET") || \
            fail "ticket ${SHORT} has an invalid service; approval retained as pending"
        APPROVE_PAYLOAD=$(jq -ce '.payload | select(type == "object")' "$TICKET") || \
            fail "ticket ${SHORT} has an invalid payload; approval retained as pending"
        mkdir -p /data/approved
        TMP=$(mktemp "/data/approved/.${SHORT}.XXXXXX")
        jq -nc --arg ticket "$SHORT" --arg actor_user_id "$ACTOR" --arg chat_id "$CHAT" \
            --arg generation "$ticket_generation" \
            --argjson approved_at "$NOW" --argjson restore_epoch "$current_restore_epoch_value" \
            '{ticket:$ticket,state:"approval_pending",actor_user_id:$actor_user_id,chat_id:$chat_id,approval_generation:$generation,approved_at:$approved_at,restore_epoch:$restore_epoch}' > "$TMP"
        chmod 0640 "$TMP"
        sync
        mv "$TMP" "$MARKER"
        if ! /usr/local/bin/zc-audit-write approve "$APPROVE_SERVICE" "$APPROVE_PAYLOAD" \
            "source=telegram;actor=${ACTOR};chat=${CHAT};ticket=${SHORT}"; then
            rm -f "$MARKER"
            fail "approval audit could not be persisted; ticket retained"
        fi
        TMP=$(mktemp "/data/approved/.${SHORT}.XXXXXX")
        jq -nc --arg ticket "$SHORT" --arg actor_user_id "$ACTOR" --arg chat_id "$CHAT" \
            --arg generation "$ticket_generation" \
            --argjson approved_at "$NOW" --argjson restore_epoch "$current_restore_epoch_value" \
            '{ticket:$ticket,state:"approved_audited",actor_user_id:$actor_user_id,chat_id:$chat_id,approval_generation:$generation,approved_at:$approved_at,restore_epoch:$restore_epoch}' > "$TMP"
        chmod 0640 "$TMP"
        sync
        mv "$TMP" "$MARKER"
        sync
        echo "APPROVED ${SHORT}"
        ;;
    reject)
        # Rejection is a terminal user decision, so it must be recorded before
        # the sealed ticket is removed. If the audit store is unavailable,
        # fail closed and retain the ticket for recovery.
        [ -x /usr/local/bin/zc-audit-write ] || fail "audit store unavailable; rejection retained"
        REJECT_SERVICE=$(jq -er '.service | select(type == "string")' "$TICKET") || \
            fail "ticket ${SHORT} has an invalid service; rejection retained"
        REJECT_PAYLOAD=$(jq -ce '.payload | select(type == "object")' "$TICKET") || \
            fail "ticket ${SHORT} has an invalid payload; rejection retained"
        /usr/local/bin/zc-audit-write reject "$REJECT_SERVICE" "$REJECT_PAYLOAD" \
            "source=telegram;actor=${ACTOR};chat=${CHAT};ticket=${SHORT}" || \
            fail "rejection audit could not be persisted; rejection retained"
        rm -f "$TICKET" "$MARKER" "$RECEIPT"
        echo "REJECTED ${SHORT}"
        ;;
esac
