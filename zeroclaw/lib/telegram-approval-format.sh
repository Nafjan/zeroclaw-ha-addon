#!/bin/sh
# Shared, side-effect-free parser and generation check for Telegram text
# approvals. The root broker seals a fresh approval_generation into every
# ticket and renders it in the operator message. Binding text approvals to
# that generation prevents a delayed message from a recycled ticket id from
# approving a different action.

approval_request() {
    parsed_request=$(printf '%s' "$1" | sed -nE \
        's/^[[:space:]]*[Yy][Ee][Ss][[:space:]]+([a-f0-9]{8})[[:space:]]+([a-f0-9]{32})[[:space:]]*$/\1 \2/p')
    [ -n "$parsed_request" ] || return 1
    printf '%s' "$parsed_request"
}

rejection_request() {
    parsed_request=$(printf '%s' "$1" | sed -nE \
        's/^[[:space:]]*[Nn][Oo][[:space:]]+([a-f0-9]{8})[[:space:]]+([a-f0-9]{32})[[:space:]]*$/\1 \2/p')
    [ -n "$parsed_request" ] || return 1
    printf '%s' "$parsed_request"
}

# Recognize the retired two-token form so the watcher can give an actionable
# reply instead of forwarding it as an ordinary agent turn. It never grants
# approval and deliberately does not accept a generation.
legacy_approval_id() {
    printf '%s' "$1" | sed -nE \
        's/^[[:space:]]*[Yy][Ee][Ss][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p'
}

legacy_rejection_id() {
    printf '%s' "$1" | sed -nE \
        's/^[[:space:]]*[Nn][Oo][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p'
}

valid_approval_generation() {
    [ "$#" -eq 1 ] || return 1
    printf '%s' "$1" | grep -Eq '^[a-f0-9]{32}$'
}

approval_generation_matches() {
    [ "$#" -eq 2 ] || return 1
    ticket_file="$1"
    supplied_generation="$2"
    [ -f "$ticket_file" ] && [ ! -L "$ticket_file" ] || return 1
    valid_approval_generation "$supplied_generation" || return 1
    ticket_generation=$(jq -r '.approval_generation // empty' "$ticket_file" 2>/dev/null) || return 1
    valid_approval_generation "$ticket_generation" || return 1
    [ "$ticket_generation" = "$supplied_generation" ]
}
