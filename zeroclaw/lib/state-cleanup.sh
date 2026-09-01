#!/bin/sh
# Root-only cleanup for durable approval state.
#
# Planner-created pending files and short-lived undo snapshots are handled by
# the entrypoint's ordinary retention policy.  This helper handles the
# canonical root-owned ticket, approval marker, receipt, and claim state.  It
# never follows symlinks and never removes an unexpired ticket.
set -eu

DATA_DIR="${1:-/data}"
TICKET_DIR="${DATA_DIR}/approval-receipts/tickets"
RECEIPT_DIR="${DATA_DIR}/approval-receipts"
MARKER_DIR="${DATA_DIR}/approved"
CLAIM_DIR="${RECEIPT_DIR}/.claims"
LOCK_DIR="${RECEIPT_DIR}/.locks"
REPLY_CACHE_DIR="${DATA_DIR}/capability/telegram-replies"
CALLBACK_CACHE_DIR="${DATA_DIR}/capability/telegram-callbacks"
ACTION_ADMISSION_DIR="${DATA_DIR}/capability/action-admissions"
APPROVAL_OUTCOME_DIR="${RECEIPT_DIR}/outcomes"
OUTCOME_FILE="${DATA_DIR}/capability/last-outcome.json"
NOW=$(date -u +%s)
CLAIM_GRACE_SECONDS=3600
LOCK_GRACE_SECONDS=300
REPLY_CACHE_GRACE_SECONDS=604800
PENDING_APPROVAL_GRACE_SECONDS=300

[ "$(id -u)" -eq 0 ] || {
    echo "state cleanup must run as root" >&2
    exit 1
}

valid_short() {
    printf '%s' "$1" | grep -Eq '^[a-f0-9]{8}$'
}

old_enough() {
    path="$1"
    grace="$2"
    [ -e "$path" ] || [ -L "$path" ] || return 1
    mtime=$(stat -c %Y "$path" 2>/dev/null || echo 0)
    case "$mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$mtime" -le $((NOW - grace)) ]
}

remove_expired_ticket() {
    ticket="$1"
    short="$2"
    claim="${CLAIM_DIR}/${short}.claim"
    lock="${LOCK_DIR}/approval-${short}.lock"

    # A live transition owns this lock.  A claim without the lock may be an
    # in-flight HA call, so retain it until it has exceeded the recovery grace.
    mkdir "$lock" 2>/dev/null || return 0
    if [ -d "$claim" ] && ! old_enough "$claim" "$CLAIM_GRACE_SECONDS"; then
        rmdir "$lock" 2>/dev/null || true
        return 0
    fi

    rm -f "$ticket" "${MARKER_DIR}/${short}.marker" \
        "${RECEIPT_DIR}/${short}.sha256" \
        "${DATA_DIR}/pending/${short}.json"
    if [ -d "$claim" ]; then
        rmdir "$claim" 2>/dev/null || true
    fi
    rmdir "$lock" 2>/dev/null || true
}

if [ -d "$TICKET_DIR" ]; then
    for ticket in "$TICKET_DIR"/*.json; do
        [ -f "$ticket" ] || [ -L "$ticket" ] || continue
        [ -L "$ticket" ] && continue
        short=$(basename "$ticket" .json)
        valid_short "$short" || continue
        if ! expires=$(jq -er '.expires_at | select(type == "number" and floor == . and . >= 0)' \
            "$ticket" 2>/dev/null); then
            # Malformed or unreadable canonical state is retained for manual
            # recovery; cleanup must fail closed rather than treat it as old.
            continue
        fi
        case "$expires" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$expires" -lt "$NOW" ] || continue
        remove_expired_ticket "$ticket" "$short"
    done
fi

# Remove old orphaned artifacts left by a crash after completion.  A fresh
# marker/receipt without its canonical ticket is not actionable, but a grace
# period avoids racing a just-completed broker transition.
for artifact_dir in "$MARKER_DIR" "$RECEIPT_DIR"; do
    [ -d "$artifact_dir" ] || continue
    for artifact in "$artifact_dir"/*.marker "$artifact_dir"/*.sha256; do
        [ -f "$artifact" ] || [ -L "$artifact" ] || continue
        [ -L "$artifact" ] && continue
        short=$(basename "$artifact")
        short=${short%.marker}
        short=${short%.sha256}
        valid_short "$short" || continue
        [ -e "${TICKET_DIR}/${short}.json" ] && continue
        old_enough "$artifact" "$CLAIM_GRACE_SECONDS" || continue
        rm -f "$artifact"
    done
done

if [ -d "$CLAIM_DIR" ]; then
    for claim in "$CLAIM_DIR"/*.claim; do
        [ -d "$claim" ] || [ -L "$claim" ] || continue
        [ -L "$claim" ] && continue
        short=$(basename "$claim" .claim)
        valid_short "$short" || continue
        [ -e "${TICKET_DIR}/${short}.json" ] && continue
        old_enough "$claim" "$CLAIM_GRACE_SECONDS" || continue
        rmdir "$claim" 2>/dev/null || true
    done
fi

# Approval uses a two-phase marker: approval_pending is deliberately not
# claimable.  Reclaim only an old pending marker after taking the same ticket
# lock used by the transition helper so a killed approval can be retried.
if [ -d "$MARKER_DIR" ]; then
    for marker in "$MARKER_DIR"/*.marker; do
        [ -f "$marker" ] && [ ! -L "$marker" ] || continue
        short=$(basename "$marker" .marker)
        valid_short "$short" || continue
        jq -e '.state == "approval_pending"' "$marker" >/dev/null 2>&1 || continue
        old_enough "$marker" "$PENDING_APPROVAL_GRACE_SECONDS" || continue
        lock="${LOCK_DIR}/approval-${short}.lock"
        mkdir "$lock" 2>/dev/null || continue
        rm -f "$marker"
        rmdir "$lock" 2>/dev/null || true
    done
fi

# A killed transition can leave an empty lock directory behind.  Only clear
# locks older than the bounded transition timeout; active locks are retained.
if [ -d "$LOCK_DIR" ]; then
    for lock in "$LOCK_DIR"/approval-*.lock; do
        [ -d "$lock" ] || [ -L "$lock" ] || continue
        [ -L "$lock" ] && continue
        old_enough "$lock" "$LOCK_GRACE_SECONDS" || continue
        rmdir "$lock" 2>/dev/null || true
    done
fi

# A rendered Telegram reply is retained long enough to make a failed delivery
# retry idempotent across a watcher restart.  It is not an approval record and
# must not grow without bound; cleanup never follows a cache symlink.
if [ -d "$REPLY_CACHE_DIR" ] && [ ! -L "$REPLY_CACHE_DIR" ]; then
    for reply in "$REPLY_CACHE_DIR"/*.json "$REPLY_CACHE_DIR"/*.txt; do
        [ -f "$reply" ] || [ -L "$reply" ] || continue
        [ -L "$reply" ] && continue
        old_enough "$reply" "$REPLY_CACHE_GRACE_SECONDS" || continue
        rm -f "$reply"
    done
fi

if [ -d "$CALLBACK_CACHE_DIR" ] && [ ! -L "$CALLBACK_CACHE_DIR" ]; then
    for callback in "$CALLBACK_CACHE_DIR"/*.json; do
        [ -f "$callback" ] || [ -L "$callback" ] || continue
        [ -L "$callback" ] && continue
        old_enough "$callback" "$REPLY_CACHE_GRACE_SECONDS" || continue
        rm -f "$callback"
    done
fi

# Completed action admissions are the durable hourly quota record for
# Telegram-approved writes.  Keep them through the retention horizon so a
# restart cannot reset the budget, and never follow a symlink.
if [ -d "$ACTION_ADMISSION_DIR" ] && [ ! -L "$ACTION_ADMISSION_DIR" ]; then
    for admission in "$ACTION_ADMISSION_DIR"/*.json; do
        [ -f "$admission" ] || [ -L "$admission" ] || continue
        [ -L "$admission" ] && continue
        old_enough "$admission" "$REPLY_CACHE_GRACE_SECONDS" || continue
        rm -f "$admission"
    done
fi

# Durable approval outcomes bridge the interval between a successful HA call
# and Telegram callback delivery. Retain them for replay, and only remove
# completed receipts after the same bounded recovery horizon.
if [ -d "$APPROVAL_OUTCOME_DIR" ] && [ ! -L "$APPROVAL_OUTCOME_DIR" ]; then
    for outcome in "$APPROVAL_OUTCOME_DIR"/*.json; do
        [ -f "$outcome" ] || [ -L "$outcome" ] || continue
        [ -L "$outcome" ] && continue
        short=$(basename "$outcome" .json)
        valid_short "$short" || continue
        [ -e "${TICKET_DIR}/${short}.json" ] && continue
        old_enough "$outcome" "$REPLY_CACHE_GRACE_SECONDS" || continue
        rm -f "$outcome"
    done
fi

# A correction receipt is valid only for the bounded turn immediately after
# the action that created it.  Remove expired receipts here as a second line
# of defense; the Telegram watcher also consumes the receipt on the next
# ordinary message, whether or not it matches a correction marker.
if [ -f "$OUTCOME_FILE" ] && [ ! -L "$OUTCOME_FILE" ]; then
    if expires=$(jq -er '.expires_at | select(type == "number" and floor == . and . >= 0)' \
        "$OUTCOME_FILE" 2>/dev/null); then
        case "$expires" in
            ''|*[!0-9]*) ;;
            *) [ "$expires" -le "$NOW" ] && rm -f "$OUTCOME_FILE" ;;
        esac
    fi
fi
