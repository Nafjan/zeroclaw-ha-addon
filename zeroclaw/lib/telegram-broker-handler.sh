#!/bin/bash
# Root-owned Telegram capability broker. The planner may request only typed,
# ticket-scoped approval messages; it never receives TELEGRAM_BOT_TOKEN.
set -eu
export LC_ALL=C

if [ -r /opt/zeroclaw/lib/bounded-read.sh ]; then
    # shellcheck disable=SC1091
    . /opt/zeroclaw/lib/bounded-read.sh
else
    # shellcheck disable=SC1091
    . "$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)/bounded-read.sh"
fi

TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-/run/zeroclaw/telegram-token}"
APPROVAL_CHAT="${TELEGRAM_APPROVAL_CHAT:-}"
TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"
CLIENT_AUTH_TOKEN="${TELEGRAM_CLIENT_AUTH_TOKEN:-}"
SYSTEM_AUTH_TOKEN="${TELEGRAM_SYSTEM_AUTH_TOKEN:-}"
APPROVAL_RATE_FILE="${TELEGRAM_APPROVAL_RATE_FILE:-/data/capability/telegram-approval-rate.json}"
APPROVAL_RATE_LOCK="${TELEGRAM_APPROVAL_RATE_LOCK:-/data/capability/.telegram-approval-rate.lock}"
APPROVAL_RATE_LIMIT="${TELEGRAM_APPROVAL_RATE_LIMIT:-12}"
APPROVAL_RATE_WINDOW_SECONDS="${TELEGRAM_APPROVAL_RATE_WINDOW_SECONDS:-60}"
MAX_PENDING_TICKETS="${TELEGRAM_MAX_PENDING_TICKETS:-64}"
MAX_PENDING_TICKET_BYTES="${TELEGRAM_MAX_PENDING_TICKET_BYTES:-2097152}"

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

case "$APPROVAL_RATE_LIMIT:$APPROVAL_RATE_WINDOW_SECONDS:$MAX_PENDING_TICKETS:$MAX_PENDING_TICKET_BYTES" in
    *[!0-9:]*|:*|*::*|*:::*) json_error "Telegram approval admission limits are invalid" ;;
esac
[ "$APPROVAL_RATE_LIMIT" -ge 1 ] && [ "$APPROVAL_RATE_LIMIT" -le 120 ] ||
    json_error "Telegram approval rate limit is outside the safe range"
[ "$APPROVAL_RATE_WINDOW_SECONDS" -ge 10 ] && [ "$APPROVAL_RATE_WINDOW_SECONDS" -le 3600 ] ||
    json_error "Telegram approval rate window is outside the safe range"
[ "$MAX_PENDING_TICKETS" -ge 1 ] && [ "$MAX_PENDING_TICKETS" -le 1024 ] ||
    json_error "Telegram pending-ticket limit is outside the safe range"
[ "$MAX_PENDING_TICKET_BYTES" -ge 4096 ] && [ "$MAX_PENDING_TICKET_BYTES" -le 16777216 ] ||
    json_error "Telegram pending-ticket byte limit is outside the safe range"

request=""
read_deadline=$((SECONDS + 5))
if bounded_read_line 131073 "$read_deadline"; then
    request="$BOUNDED_READ_LINE"
    read_status=0
else
    read_status=$?
fi
case "$read_status" in
    0) ;;
    2) json_error "Telegram request too large" ;;
    *) json_error "Telegram request timed out" ;;
esac
[ -n "$request" ] || json_error "empty Telegram request"
[ "${#request}" -le 131072 ] || json_error "Telegram request too large"
[ -n "$CLIENT_AUTH_TOKEN" ] || [ -n "$SYSTEM_AUTH_TOKEN" ] || \
    json_error "Telegram broker authentication is unavailable"
provided_auth=$(printf '%s' "$request" | jq -er '.auth | select(type == "string")' 2>/dev/null) || \
    json_error "Telegram broker client authentication failed"
AUTH_KIND=""
if [ -n "$CLIENT_AUTH_TOKEN" ] && [ "$provided_auth" = "$CLIENT_AUTH_TOKEN" ]; then
    AUTH_KIND=client
elif [ -n "$SYSTEM_AUTH_TOKEN" ] && [ "$provided_auth" = "$SYSTEM_AUTH_TOKEN" ]; then
    AUTH_KIND=system
else
    json_error "Telegram broker client authentication failed"
fi
request=$(printf '%s' "$request" | jq -c 'del(.auth)' 2>/dev/null) || \
    json_error "Telegram request is not valid JSON"
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

valid_entity_value() {
    printf '%s' "$1" | jq -e '
      if type == "string" then
        test("^[a-z0-9_]+\\.[a-z0-9_-]+$")
      elif type == "array" then
        length > 0 and length <= 100 and
        all(.[]; type == "string" and test("^[a-z0-9_]+\\.[a-z0-9_-]+$"))
      else false end
    ' >/dev/null 2>&1
}

# This is a defense-in-depth copy of the typed capability contract. The
# Telegram broker must reject a ticket it cannot render exactly, even if a
# compromised planner bypassed the normal action helper.
validate_ticket_payload() {
    service="$1"
    payload="$2"
    case "$service" in
        light/turn_on|light/turn_off|light/toggle|\
        switch/turn_on|switch/turn_off|switch/toggle|\
        input_boolean/turn_on|input_boolean/turn_off|input_boolean/toggle|\
        cover/open_cover|cover/close_cover|cover/stop_cover)
            entity=$(printf '%s' "$payload" | jq -c '.entity_id // empty')
            [ -n "$entity" ] && valid_entity_value "$entity" || return 1
            ;;
        climate/set_temperature)
            entity=$(printf '%s' "$payload" | jq -c '.entity_id // empty')
            valid_entity_value "$entity" || return 1
            printf '%s' "$payload" | jq -e '
              (.temperature | type == "number") and
              (.temperature >= 4 and .temperature <= 40)
            ' >/dev/null 2>&1 || return 1
            ;;
        climate/set_hvac_mode)
            entity=$(printf '%s' "$payload" | jq -c '.entity_id // empty')
            valid_entity_value "$entity" || return 1
            printf '%s' "$payload" | jq -e '
              (.hvac_mode | type == "string") and
              (.hvac_mode | IN("off","heat","cool","auto","dry","fan_only"))
            ' >/dev/null 2>&1 || return 1
            ;;
        scene/turn_on)
            entity=$(printf '%s' "$payload" | jq -c '.entity_id // empty')
            valid_entity_value "$entity" || return 1
            printf '%s' "$payload" | jq -e '.entity_id | if type == "string" then startswith("scene.") else all(.[]; startswith("scene.")) end' >/dev/null 2>&1 || return 1
            ;;
        scene/reload|automation/reload)
            [ "$payload" = '{}' ] || return 1
            ;;
        scene/create)
            printf '%s' "$payload" | jq -e '
              .kind == "scene" and
              (.scene_id | type == "string" and test("^[a-z0-9_]{1,128}$")) and
              (.friendly_name | type == "string" and length >= 1 and length <= 128 and (test("[\\r\\n]") | not)) and
              (.entities | type == "object" and all(keys[]; test("^[a-z0-9_]+\\.[a-z0-9_-]+$")) and length <= 100)
            ' >/dev/null 2>&1 || return 1
            ;;
        automation/create)
            printf '%s' "$payload" | jq -e '
              .kind == "automation" and
              (.alias | type == "string" and length >= 1 and length <= 128 and (test("[\\r\\n]") | not)) and
              (.yaml | type == "string" and length >= 1 and length <= 32768 and contains("trigger:") and contains("action:"))
            ' >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

canonical_ticket_summary() {
    summary_service="$1"
    summary_payload="$2"
    summary_canonical=$(printf '%s' "$summary_payload" | jq -cS .)
    printf '%s | %s' "$summary_service" "$summary_canonical"
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

approval_rate_lock_is_stale() {
    [ -d "$APPROVAL_RATE_LOCK" ] && [ ! -L "$APPROVAL_RATE_LOCK" ] || return 1
    approval_rate_owner_file="${APPROVAL_RATE_LOCK}/owner"
    if [ -e "$approval_rate_owner_file" ]; then
        [ -f "$approval_rate_owner_file" ] && [ ! -L "$approval_rate_owner_file" ] || return 1
        approval_rate_owner_pid=$(cat "$approval_rate_owner_file" 2>/dev/null || true)
        case "$approval_rate_owner_pid" in
            ''|*[!0-9]*) return 1 ;;
        esac
        kill -0 "$approval_rate_owner_pid" 2>/dev/null && return 1
    fi
    approval_rate_lock_mtime=$(stat -c '%Y' "$APPROVAL_RATE_LOCK" 2>/dev/null || true)
    approval_rate_lock_now=$(date -u +%s)
    case "$approval_rate_lock_mtime:$approval_rate_lock_now" in
        ''|*[!0-9:]*|*:*:*) return 1 ;;
    esac
    [ "$approval_rate_lock_now" -ge "$approval_rate_lock_mtime" ] || return 1
    [ $((approval_rate_lock_now - approval_rate_lock_mtime)) -ge 120 ]
}

acquire_approval_rate_lock() {
    approval_rate_attempts=0
    while ! mkdir "$APPROVAL_RATE_LOCK" 2>/dev/null; do
        if approval_rate_lock_is_stale; then
            rm -f -- "${APPROVAL_RATE_LOCK}/owner" 2>/dev/null || true
            rmdir "$APPROVAL_RATE_LOCK" 2>/dev/null || true
            continue
        fi
        approval_rate_attempts=$((approval_rate_attempts + 1))
        [ "$approval_rate_attempts" -le 10 ] || return 1
        sleep 1
    done
    printf '%s\n' "$$" > "${APPROVAL_RATE_LOCK}/owner" || {
        rmdir "$APPROVAL_RATE_LOCK" 2>/dev/null || true
        return 1
    }
    chmod 0600 "${APPROVAL_RATE_LOCK}/owner"
}

release_approval_rate_lock() {
    rm -f -- "${APPROVAL_RATE_LOCK}/owner" 2>/dev/null || true
    rmdir "$APPROVAL_RATE_LOCK" 2>/dev/null || true
}

write_approval_rate() {
    [ ! -L "$APPROVAL_RATE_FILE" ] || return 1
    if [ -e "$APPROVAL_RATE_FILE" ] && [ ! -f "$APPROVAL_RATE_FILE" ]; then
        return 1
    fi
    approval_rate_tmp="${APPROVAL_RATE_FILE}.tmp.$$"
    printf '%s\n' "$1" > "$approval_rate_tmp" || return 1
    chown root:root "$approval_rate_tmp" 2>/dev/null || true
    chmod 0600 "$approval_rate_tmp" || {
        rm -f "$approval_rate_tmp"
        return 1
    }
    sync -f "$approval_rate_tmp" || {
        rm -f "$approval_rate_tmp"
        return 1
    }
    mv -f "$approval_rate_tmp" "$APPROVAL_RATE_FILE" || return 1
    sync -f "$(dirname -- "$APPROVAL_RATE_FILE")" || return 1
}

admit_approval_send() {
    admission_chat="$1"
    [ -d "$(dirname -- "$APPROVAL_RATE_FILE")" ] &&
        [ ! -L "$(dirname -- "$APPROVAL_RATE_FILE")" ] || return 1
    acquire_approval_rate_lock || return 1
    if [ -e "$APPROVAL_RATE_FILE" ]; then
        [ -f "$APPROVAL_RATE_FILE" ] && [ ! -L "$APPROVAL_RATE_FILE" ] || {
            release_approval_rate_lock
            return 1
        }
        admission_state=$(cat "$APPROVAL_RATE_FILE" 2>/dev/null || true)
        printf '%s' "$admission_state" | jq -e '
            type == "object" and .schema == 1 and
            (.window_start | type == "number" and floor == . and . >= 0) and
            (.clients | type == "object") and
            all(.clients[]; type == "number" and floor == . and . >= 0)
        ' >/dev/null 2>&1 || {
            release_approval_rate_lock
            return 1
        }
    else
        admission_state='{"schema":1,"window_start":0,"clients":{}}'
    fi
    admission_now=$(date -u +%s)
    admission_start=$(printf '%s' "$admission_state" | jq -r '.window_start')
    case "$admission_now:$admission_start" in
        ''|*[!0-9:]*|*:*:*) release_approval_rate_lock; return 1 ;;
    esac
    [ "$admission_start" -le "$admission_now" ] || {
        release_approval_rate_lock
        return 1
    }
    admission_window_expired=0
    if [ $((admission_now - admission_start)) -ge "$APPROVAL_RATE_WINDOW_SECONDS" ]; then
        admission_start="$admission_now"
        admission_count=0
        admission_window_expired=1
    else
        admission_count=$(printf '%s' "$admission_state" | jq -r --arg chat "$admission_chat" '.clients[$chat] // 0') || {
            release_approval_rate_lock
            return 1
        }
    fi
    case "$admission_count" in
        ''|*[!0-9]*) release_approval_rate_lock; return 1 ;;
    esac
    [ "$admission_count" -lt "$APPROVAL_RATE_LIMIT" ] || {
        release_approval_rate_lock
        json_error "Telegram approval send rate is temporarily exhausted"
    }
    if [ "$admission_window_expired" -eq 1 ]; then
        admission_next=$(jq -nc --argjson start "$admission_start" --arg chat "$admission_chat" \
            --argjson count 1 \
            '{schema:1,window_start:$start,clients:{($chat):$count}}') || {
            release_approval_rate_lock
            return 1
        }
    else
        admission_next=$(printf '%s' "$admission_state" | jq --arg chat "$admission_chat" \
            --argjson count "$((admission_count + 1))" \
            --argjson start "$admission_start" \
            '.window_start=$start | .clients[$chat]=$count') || {
            release_approval_rate_lock
            return 1
        }
    fi
    write_approval_rate "$admission_next" || {
        release_approval_rate_lock
        return 1
    }
    release_approval_rate_lock
}

admit_pending_ticket_capacity() {
    incoming_bytes="$1"
    case "$incoming_bytes" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -d "$TICKET_DIR" ] && [ ! -L "$TICKET_DIR" ] || return 1
    pending_count=0
    pending_bytes=0
    for pending_ticket in "$TICKET_DIR"/*.json; do
        [ -f "$pending_ticket" ] && [ ! -L "$pending_ticket" ] || continue
        pending_count=$((pending_count + 1))
        [ "$pending_count" -lt "$MAX_PENDING_TICKETS" ] || return 2
        pending_size=$(stat -c '%s' "$pending_ticket" 2>/dev/null || true)
        case "$pending_size" in
            ''|*[!0-9]*) return 1 ;;
        esac
        pending_bytes=$((pending_bytes + pending_size))
        [ "$pending_bytes" -le "$MAX_PENDING_TICKET_BYTES" ] || return 2
    done
    [ "$pending_count" -lt "$MAX_PENDING_TICKETS" ] || return 2
    [ $((pending_bytes + incoming_bytes)) -le "$MAX_PENDING_TICKET_BYTES" ] || return 2
    return 0
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
    ticket_bytes=${#ticket_json}
    if admit_pending_ticket_capacity "$ticket_bytes"; then
        :
    else
        capacity_status=$?
        case "$capacity_status" in
            2) json_error "Telegram approval backlog is full" ;;
            *) json_error "Telegram approval admission state is unavailable" ;;
        esac
    fi
    admit_approval_send "$chat_id" ||
        json_error "Telegram approval admission state is unavailable"
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
    service=$(jq -r '.service' "$staged_ticket")
    payload=$(jq -c '.payload' "$staged_ticket")
    validate_ticket_payload "$service" "$payload" || {
        rm -f "$staged_ticket"
        staged_ticket=""
        json_error "approval ticket service or payload is not allowed"
    }
    [ "${#payload}" -le 4096 ] || {
        rm -f "$staged_ticket"
        staged_ticket=""
        json_error "approval payload is too large to render exactly"
    }
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
    payload=$(jq -cS '.payload' "$ticket_file")
    summary=$(canonical_ticket_summary "$service" "$payload")
    # The planner-supplied prose is intentionally ignored. The root broker
    # renders the exact canonical payload and uses a
    # fixed safety statement, so an operator cannot approve hidden parameters
    # or planner-controlled policy prose.
    text=$(printf 'Approval needed (%s)\nAction: %s\nParameters: %s\nSafety gate: approval is required for this exact action.\nReply YES %s or NO %s. Expires in 30 min.' \
        "$ticket" "$service" "$payload" "$ticket" "$ticket")
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

send_system_notice() {
    text="$1"
    [ "$AUTH_KIND" = system ] || json_error "system Telegram notice is not available to the planner"
    [ -n "$APPROVAL_CHAT" ] || json_error "Telegram approval owner is not configured"
    [ "${#text}" -ge 1 ] && [ "${#text}" -le 512 ] || json_error "system notice is too long"
    body=$(jq -nc --arg cid "$APPROVAL_CHAT" --arg text "System notice: $text" '{chat_id:$cid,text:$text}')
    if ! response=$(telegram_curl sendMessage -fsS --fail-with-body --connect-timeout 5 --max-time 15 -X POST \
        -H 'Content-Type: application/json' -d "$body"); then
        json_error "Telegram sendMessage failed"
    fi
    telegram_result "$response"
}

case "$operation" in
    send_approval)
        [ "$AUTH_KIND" = client ] || json_error "approval delivery is not available to the system notifier"
        ticket=$(printf '%s' "$request" | jq -er '.ticket | select(type == "string")' 2>/dev/null) || json_error "ticket must be a string"
        text=$(printf '%s' "$request" | jq -er '.text | select(type == "string")' 2>/dev/null) || json_error "text must be a string"
        ticket_json=$(printf '%s' "$request" | jq -er '.ticket_json | select(type == "string")' 2>/dev/null) || json_error "ticket_json must be a string"
        chat_id=$(printf '%s' "$request" | jq -er '.chat_id | tostring' 2>/dev/null) || json_error "chat_id is required"
        send_approval "$ticket" "$text" "$chat_id" "$ticket_json"
        ;;
    send_system_notice)
        text=$(printf '%s' "$request" | jq -er '.text | select(type == "string")' 2>/dev/null) || json_error "text must be a string"
        send_system_notice "$text"
        ;;
    *)
        json_error "operation is not available to the planner"
        ;;
esac
