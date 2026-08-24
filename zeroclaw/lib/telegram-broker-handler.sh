#!/bin/sh
# Root-owned Telegram capability broker. The planner may request only typed,
# ticket-scoped approval messages; it never receives TELEGRAM_BOT_TOKEN.
set -eu

TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-/run/zeroclaw/telegram-token}"
APPROVAL_CHAT="${TELEGRAM_APPROVAL_CHAT:-}"
TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"

json_error() {
    jq -nc --arg error "$1" '{ok:false,error:$error}'
    exit 0
}

json_value() {
    jq -nc --argjson result "$1" '{ok:true,result:$result}'
}

json_text() {
    jq -nc --arg result "$1" '{ok:true,result:$result}'
}

request=""
IFS= read -r request || true
[ -n "$request" ] || json_error "empty Telegram request"
[ "${#request}" -le 131072 ] || json_error "Telegram request too large"
[ -r "$TOKEN_FILE" ] || json_error "Telegram broker credential is unavailable"
TOKEN=$(cat "$TOKEN_FILE")
[ -n "$TOKEN" ] || json_error "Telegram broker credential is empty"
staged_ticket=""

# Telegram puts the bot token in the endpoint path. Build that URL in a
# private curl config file rather than passing it through the child argv.
telegram_curl() {
    method="$1"
    shift
    config_file=$(mktemp)
    chmod 0600 "$config_file"
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TOKEN" "$method" > "$config_file"
    curl --connect-timeout 5 --max-time 35 --config "$config_file" "$@"
    rc=$?
    rm -f "$config_file"
    return "$rc"
}

operation=$(printf '%s' "$request" | jq -er '.operation | select(type == "string")' 2>/dev/null) || json_error "operation must be a string"

valid_chat_id() {
    printf '%s' "$1" | grep -Eq '^-?[0-9]{1,20}$'
}

valid_ticket() {
    printf '%s' "$1" | grep -Eq '^[a-f0-9]{8}$'
}

mark_delivery_state() {
    state="$1"
    now=$(date -u +%s)
    tmp=$(mktemp "${TICKET_DIR}/.${ticket}.XXXXXX")
    jq --arg state "$state" --argjson now "$now" \
        '. + {delivery_state:$state,delivery_updated_at:$now}' "$ticket_file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$ticket_file"
    sync
}

telegram_result() {
    result="$1"
    if printf '%s' "$result" | grep -F -- "$TOKEN" >/dev/null 2>&1; then
        json_error "Telegram response contained broker credential"
    fi
    if ! printf '%s' "$result" | jq -e '.ok == true' >/dev/null 2>&1; then
        json_error "Telegram API request failed"
    fi
    printf '%s' "$result" | jq -c '.result // {}'
}

send_approval() {
    ticket="$1"
    text="$2"
    chat_id="$3"
    ticket_json="$4"
    valid_ticket "$ticket" || json_error "invalid ticket id"
    valid_chat_id "$chat_id" || json_error "invalid chat id"
    [ -n "$APPROVAL_CHAT" ] && [ "$chat_id" = "$APPROVAL_CHAT" ] || \
        json_error "chat is not the configured approval owner"
    ticket_file="${TICKET_DIR}/${ticket}.json"
    lock="${ZEROCLAW_APPROVAL_LOCK_DIR:-/data/approval-receipts/.locks}/approval-${ticket}.lock"
    mkdir "$lock" 2>/dev/null || json_error "approval ticket is already being processed"
    trap 'rm -f "${staged_ticket:-}"; rmdir "$lock" 2>/dev/null || true' EXIT
    mkdir -p "$TICKET_DIR"
    if [ -e "$ticket_file" ] || [ -L "$ticket_file" ]; then
        [ -f "$ticket_file" ] && [ ! -L "$ticket_file" ] || json_error "approval ticket state is not a regular file"
        delivery_state=$(jq -r '.delivery_state // empty' "$ticket_file" 2>/dev/null || true)
        case "$delivery_state" in
            delivered)
                message_id=$(jq -r '.tg_message_id // empty' "$ticket_file" 2>/dev/null || true)
                printf '%s' "$message_id" | grep -Eq '^[0-9]+$' || \
                    json_error "delivered Telegram ticket has no valid message id"
                if [ ! -f "/data/approval-receipts/${ticket}.sha256" ]; then
                    sha256sum "$ticket_file" | cut -d' ' -f1 > "/data/approval-receipts/${ticket}.sha256"
                    chmod 0600 "/data/approval-receipts/${ticket}.sha256"
                    sync
                fi
                result=$(jq -nc --argjson message_id "$message_id" '{message_id:$message_id}')
                json_value "$result"
                ;;
            sending|delivery_unknown|"")
                json_error "Telegram delivery state is uncertain; manual recovery is required"
                ;;
            *)
                json_error "approval ticket already exists"
                ;;
        esac
    fi
    [ "${#ticket_json}" -le 65536 ] || json_error "approval ticket is too large"
    staged_ticket=$(mktemp "${TICKET_DIR}/.${ticket}.XXXXXX")
    # The planner sends the bounded ticket as typed request data. Never open a
    # planner-controlled pathname from this root-owned broker: pathname swaps,
    # FIFOs, devices, and symlinks must not reach a privileged copy operation.
    if ! printf '%s' "$ticket_json" | jq -ce 'select(type == "object")' > "$staged_ticket"; then
        rm -f "$staged_ticket"
        staged_ticket=""
        json_error "approval ticket JSON is invalid"
    fi
    chown root:root "$staged_ticket"
    chmod 0600 "$staged_ticket"
    if ! jq -e --arg id "$ticket" --arg owner "$APPROVAL_CHAT" '
        .uuid == $id and
        (.service | type == "string" and test("^[a-z0-9_]+/[a-z0-9_]+$")) and
        (.payload | type == "object") and
        (.expires_at | type == "number" and . >= 0 and floor == .) and
        ((.approval.actor_user_id // "") | tostring) == $owner and
        ((.approval.chat_id // "") | tostring) == $owner
    ' "$staged_ticket" >/dev/null 2>&1; then
        rm -f "$staged_ticket"
        staged_ticket=""
        json_error "approval ticket schema is invalid"
    fi
    mv "$staged_ticket" "$ticket_file"
    staged_ticket=""
    expires_at=$(jq -r '.expires_at' "$ticket_file")
    now=$(date -u +%s)
    [ "$now" -le "$expires_at" ] || {
        rm -f "$ticket_file"
        json_error "approval ticket is expired"
    }
    max_expires=$((now + 1800))
    if [ "$expires_at" -gt "$max_expires" ]; then
        tmp=$(mktemp "${TICKET_DIR}/.${ticket}.XXXXXX")
        if ! jq --argjson exp "$max_expires" '.expires_at = $exp' "$ticket_file" > "$tmp"; then
            rm -f "$tmp" "$ticket_file"
            json_error "approval ticket could not be canonicalized"
        fi
        chown root:root "$tmp"
        chmod 0600 "$tmp"
        mv "$tmp" "$ticket_file"
        expires_at="$max_expires"
    fi
    mark_delivery_state sending || json_error "approval delivery state could not be persisted"
    service=$(jq -r '.service' "$ticket_file")
    entity=$(jq -r '.payload.entity_id // "(no entity)" | if type == "array" then join(",") else tostring end' "$ticket_file")
    verdict=$(jq -r '.verdict // "policy confirmation"' "$ticket_file")
    # The planner-supplied prose is intentionally ignored.  The approval
    # message is derived from the root-owned canonical ticket so a forged or
    # stale summary cannot disguise the actual service/target being approved.
    text=$(printf 'Approval needed (%s)\nAction: %s\nTarget: %s\nPolicy: %s\nReply YES %s or NO %s. Expires in 30 min.' \
        "$ticket" "$service" "$entity" "$verdict" "$ticket" "$ticket")
    keyboard=$(jq -nc --arg id "$ticket" '{inline_keyboard:[[{text:"✅ Approve",callback_data:("zcv1:approve:" + $id)},{text:"❌ Reject",callback_data:("zcv1:reject:" + $id)}],[{text:"💬 Discuss",callback_data:("zcv1:discuss:" + $id)}]]}')
    body=$(jq -nc --arg cid "$chat_id" --arg text "$text" --argjson keyboard "$keyboard" \
        '{chat_id:$cid,text:$text,reply_markup:$keyboard}')
    if ! response=$(telegram_curl sendMessage -fsS --fail-with-body --connect-timeout 5 --max-time 15 -X POST \
        -H 'Content-Type: application/json' -d "$body"); then
        mark_delivery_state delivery_unknown || true
        json_error "Telegram sendMessage outcome is unknown; ticket retained for recovery"
    fi
    if printf '%s' "$response" | grep -F -- "$TOKEN" >/dev/null 2>&1; then
        rm -f "$ticket_file"
        json_error "Telegram response contained broker credential"
    fi
    if ! printf '%s' "$response" | jq -e '.ok == true and (.result | type == "object")' >/dev/null 2>&1; then
        rm -f "$ticket_file"
        json_error "Telegram sendMessage rejected approval"
    fi
    result=$(printf '%s' "$response" | jq -c '.result // {}')
    message_id=$(printf '%s' "$result" | jq -r '.message_id // empty')
    printf '%s' "$message_id" | grep -Eq '^[0-9]+$' || {
        rm -f "$ticket_file"
        json_error "Telegram response did not contain a message id"
    }
    now=$(date -u +%s)
    tmp=$(mktemp "${TICKET_DIR}/.${ticket}.XXXXXX")
    jq --argjson message_id "$message_id" --argjson now "$now" \
        '. + {tg_message_id:$message_id,delivery_state:"delivered",delivery_confirmed_at:$now}' "$ticket_file" > "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$ticket_file"
    sync
    mkdir -p /data/approval-receipts
    sha256sum "$ticket_file" | cut -d' ' -f1 > "/data/approval-receipts/${ticket}.sha256"
    chmod 0600 "/data/approval-receipts/${ticket}.sha256"
    json_value "$result"
}

send_text() {
    chat_id="$1"
    text="$2"
    valid_chat_id "$chat_id" || json_error "invalid chat id"
    [ -n "$APPROVAL_CHAT" ] && [ "$chat_id" = "$APPROVAL_CHAT" ] || json_error "chat is not the configured approval owner"
    body=$(jq -nc --arg cid "$chat_id" --arg text "$text" '{chat_id:$cid,text:$text}')
    if ! response=$(telegram_curl sendMessage -fsS --fail-with-body --connect-timeout 5 --max-time 15 -X POST \
        -H 'Content-Type: application/json' -d "$body"); then
        json_error "Telegram sendMessage failed"
    fi
    telegram_result "$response"
}

case "$operation" in
    send_approval)
        ticket=$(printf '%s' "$request" | jq -er '.ticket | select(type == "string")' 2>/dev/null) || json_error "ticket must be a string"
        text=$(printf '%s' "$request" | jq -er '.text | select(type == "string")' 2>/dev/null) || json_error "text must be a string"
        ticket_json=$(printf '%s' "$request" | jq -er '.ticket_json | select(type == "string")' 2>/dev/null) || json_error "ticket_json must be a string"
        chat_id=$(printf '%s' "$request" | jq -er '.chat_id | tostring' 2>/dev/null) || json_error "chat_id is required"
        send_approval "$ticket" "$text" "$chat_id" "$ticket_json"
        ;;
    send_text)
        chat_id=$(printf '%s' "$request" | jq -er '.chat_id | tostring' 2>/dev/null) || json_error "chat_id is required"
        text=$(printf '%s' "$request" | jq -er '.text | select(type == "string")' 2>/dev/null) || json_error "text must be a string"
        send_text "$chat_id" "$text"
        ;;
    *)
        json_error "operation is not available to the planner"
        ;;
esac
