#!/bin/sh
# Agent-facing typed capability client.  It never receives an HA credential.
set -eu

PORT="${ZEROCLAW_CAPABILITY_PORT:-42618}"
HOST="127.0.0.1"

usage() {
    echo "Usage: ha-capability {read_lights|read_climate|read_covers|read_sensors|get_state|get_logbook|get_error_log|pending_count|set_outcome|call_service|audit} ..." >&2
    exit 1
}

OP="${1:-}"
[ -n "$OP" ] || usage
shift

case "$OP" in
    read_lights|read_climate|read_covers|read_sensors|get_error_log|pending_count)
        [ "$#" -eq 0 ] || usage
        REQUEST=$(jq -nc --arg operation "$OP" '{operation:$operation}')
        OUTPUT=json_text
        ;;
    set_outcome)
        [ "$#" -eq 1 ] || usage
        [ "${#1}" -le 512 ] || { echo "outcome is too long" >&2; exit 1; }
        REQUEST=$(jq -nc --arg operation "$OP" --arg text "$1" '{operation:$operation,text:$text}')
        OUTPUT=json_value
        ;;
    get_state)
        [ "$#" -eq 1 ] || usage
        REQUEST=$(jq -nc --arg operation "$OP" --arg entity_id "$1" '{operation:$operation,entity_id:$entity_id}')
        OUTPUT=json_value
        ;;
    get_logbook)
        [ "$#" -le 1 ] || usage
        if [ "$#" -eq 1 ]; then
            REQUEST=$(jq -nc --arg operation "$OP" --arg entity_id "$1" '{operation:$operation,entity_id:$entity_id}')
        else
            REQUEST=$(jq -nc --arg operation "$OP" '{operation:$operation}')
        fi
        OUTPUT=json_text
        ;;
    call_service)
        [ "$#" -eq 2 ] || usage
        [ "${ZEROCLAW_INTERNAL_ACTION:-}" = "1" ] || { echo "write capabilities are internal-only" >&2; exit 1; }
        SERVICE="$1"
        PAYLOAD="$2"
        printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "payload must be a JSON object" >&2; exit 1; }
        if [ -n "${ZEROCLAW_APPROVAL_TICKET:-}" ]; then
            REQUEST=$(jq -nc --arg operation "$OP" --arg service "$SERVICE" --argjson payload "$PAYLOAD" --arg approval_ticket "$ZEROCLAW_APPROVAL_TICKET" \
                '{operation:$operation,service:$service,payload:$payload,internal:true,approval_ticket:$approval_ticket}')
        else
            REQUEST=$(jq -nc --arg operation "$OP" --arg service "$SERVICE" --argjson payload "$PAYLOAD" \
                '{operation:$operation,service:$service,payload:$payload,internal:true}')
        fi
        OUTPUT=json_value
        ;;
    audit)
        [ "$#" -eq 4 ] || usage
        KIND="$1"
        SERVICE="$2"
        BODY="$3"
        REASON="$4"
        REQUEST=$(jq -nc --arg operation audit --arg kind "$KIND" --arg service "$SERVICE" \
            --argjson body "$BODY" --arg reason "$REASON" \
            '{operation:$operation,kind:$kind,service:$service,body:$body,reason:$reason}')
        OUTPUT=json_value
        ;;
    *)
        usage
        ;;
esac

AUTH_FILE="${ZEROCLAW_CAPABILITY_AUTH_FILE:-/run/zeroclaw/capability-client-auth}"
[ -r "$AUTH_FILE" ] || { echo "capability broker credential is unavailable" >&2; exit 1; }
AUTH=$(tr -d '\r\n' < "$AUTH_FILE") || { echo "capability broker credential could not be read" >&2; exit 1; }
[ -n "$AUTH" ] || { echo "capability broker credential is empty" >&2; exit 1; }
REQUEST=$(printf '%s' "$REQUEST" | jq -c --arg auth "$AUTH" '. + {auth:$auth}') || {
    echo "capability request could not be authenticated" >&2
    exit 1
}

RESPONSE=$(/bin/busybox nc -w 40 "$HOST" "$PORT" <<EOF
$REQUEST
EOF
) || { echo "capability broker unavailable" >&2; exit 1; }
[ -n "$RESPONSE" ] || { echo "capability broker returned no response" >&2; exit 1; }

OK=$(printf '%s' "$RESPONSE" | jq -r '.ok // false' 2>/dev/null || echo false)
if [ "$OK" != "true" ]; then
    ERROR_CODE=$(printf '%s' "$RESPONSE" | jq -r '.error_code // "capability_error"' 2>/dev/null || echo capability_error)
    printf '%s\n' "$RESPONSE" | jq -r '.error // "capability request failed"' >&2
    if [ "$OP" = call_service ]; then
        case "$ERROR_CODE" in
            execution_outcome_unknown|executed_audit_unknown|executed_approval_audit_unknown|executed_approval_outcome_unknown|executed_finalize_unknown)
                # Status 3 is reserved for a service that may already have
                # executed but whose durable outcome/approval state is
                # incomplete. Callers must not write a false failed row.
                exit 3
                ;;
        esac
    fi
    exit 1
fi

case "$OUTPUT" in
    json_value) printf '%s\n' "$RESPONSE" | jq -c '.result' ;;
    json_text) printf '%s\n' "$RESPONSE" | jq -r '.result' ;;
esac
