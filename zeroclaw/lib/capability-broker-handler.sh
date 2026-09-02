#!/bin/bash
# ZeroClaw capability broker request handler.
#
# This process is the only runtime component that receives HA_TOKEN.  The
# planner and all agent-callable helpers use the typed client instead of
# talking to the Home Assistant API directly.
set -eu
export LC_ALL=C

if [ -r /opt/zeroclaw/lib/bounded-read.sh ]; then
    # shellcheck disable=SC1091
    . /opt/zeroclaw/lib/bounded-read.sh
else
    # shellcheck disable=SC1091
    . "$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)/bounded-read.sh"
fi

HA_URL="${HA_URL:-http://supervisor/core/api}"
TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"
ACTION_LIMIT="${CAPABILITY_MAX_ACTIONS_PER_HOUR:-200}"
ACTION_QUOTA_FILE="${CAPABILITY_QUOTA_FILE:-/data/capability/quota.json}"
ACTION_QUOTA_LOCK="${CAPABILITY_QUOTA_LOCK:-/data/capability/.quota.lock}"
ACTION_ADMISSION_DIR="${CAPABILITY_ACTION_ADMISSION_DIR:-/data/capability/action-admissions}"
OUTCOME_FILE="${ZEROCLAW_OUTCOME_FILE:-/data/capability/last-outcome.json}"
APPROVAL_OUTCOME_DIR="${ZEROCLAW_APPROVAL_OUTCOME_DIR:-/data/approval-receipts/outcomes}"
CLIENT_AUTH_TOKEN="${CAPABILITY_CLIENT_AUTH_TOKEN:-}"
HEALTH_CLIENT_AUTH_TOKEN="${CAPABILITY_HEALTH_CLIENT_AUTH_TOKEN:-}"
# Read operations are intentionally bounded independently from write quotas.
# The fixed response ceiling is applied before parsing so a hostile or noisy HA
# endpoint cannot force an unbounded shell variable allocation.
MAX_HA_RESPONSE_BYTES=262144
MAX_HA_RESPONSE_BLOCKS=$(( (MAX_HA_RESPONSE_BYTES + 511) / 512 ))
READ_LIMIT_UNITS=600
READ_QUOTA_FILE="${CAPABILITY_READ_QUOTA_FILE:-/data/capability/read-quota.json}"
READ_QUOTA_LOCK="${CAPABILITY_READ_QUOTA_LOCK:-/data/capability/.read-quota.lock}"
PLANNER_AUDIT_EVENT_LIMIT=600
PLANNER_AUDIT_BYTE_LIMIT=2097152
PLANNER_AUDIT_QUOTA_FILE="${CAPABILITY_PLANNER_AUDIT_QUOTA_FILE:-/data/audit/planner/.quota.json}"
PLANNER_AUDIT_QUOTA_LOCK="${CAPABILITY_PLANNER_AUDIT_QUOTA_LOCK:-/data/audit/planner/.quota.lock}"

json_error() {
    error="$1"
    error_code="${2:-capability_error}"
    jq -nc --arg error "$error" --arg error_code "$error_code" \
        '{ok:false,error:$error,error_code:$error_code}'
    exit 0
}

json_text() {
    jq -nc --arg result "$1" '{ok:true,result:$result}'
}

json_value() {
    jq -nc --argjson result "$1" '{ok:true,result:$result}'
}

request=""
read_deadline=$((SECONDS + 3))
if bounded_read_line 32769 "$read_deadline"; then
    request="$BOUNDED_READ_LINE"
    read_status=0
else
    read_status=$?
fi
case "$read_status" in
    0) ;;
    2) json_error "broker request too large" "request_too_large" ;;
    *) json_error "broker request timed out" "request_timeout" ;;
esac
[ -n "$request" ] || json_error "empty broker request"
[ "${#request}" -le 32768 ] || json_error "broker request too large"
[ -n "$CLIENT_AUTH_TOKEN" ] || json_error "broker client authentication is unavailable" "broker_auth_unavailable"
provided_auth=$(printf '%s' "$request" | jq -er '.auth | select(type == "string")' 2>/dev/null) || \
    json_error "broker client authentication failed" "broker_auth_failed"
auth_class=planner
if [ "$provided_auth" = "$CLIENT_AUTH_TOKEN" ]; then
    auth_class=planner
elif [ -n "$HEALTH_CLIENT_AUTH_TOKEN" ] && [ "$provided_auth" = "$HEALTH_CLIENT_AUTH_TOKEN" ]; then
    auth_class=health
else
    json_error "broker client authentication failed" "broker_auth_failed"
fi
request=$(printf '%s' "$request" | jq -c 'del(.auth)' 2>/dev/null) || \
    json_error "broker request is not valid JSON" "invalid_request"
[ -n "${HA_TOKEN:-}" ] || json_error "broker is not configured"

# curl supports @file header sources. Keep the credential in a root-owned
# temporary file so it is not present in the curl child process argv.
HA_AUTH_FILE=$(mktemp)
chmod 0600 "$HA_AUTH_FILE"
printf 'Authorization: Bearer %s\n' "$HA_TOKEN" > "$HA_AUTH_FILE"
quota_lock_held=0
quota_tmp=""
read_quota_lock_held=0
read_quota_tmp=""
planner_audit_lock_held=0
planner_audit_tmp=""
HA_RESPONSE_FILE=""
cleanup() {
    rm -f "$HA_AUTH_FILE" "${quota_tmp:-}" "${read_quota_tmp:-}" "${planner_audit_tmp:-}" "${HA_RESPONSE_FILE:-}"
    if [ "$quota_lock_held" -eq 1 ]; then
        rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
    fi
    if [ "$read_quota_lock_held" -eq 1 ]; then
        rm -f -- "$READ_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$READ_QUOTA_LOCK" 2>/dev/null || true
    fi
    if [ "$planner_audit_lock_held" -eq 1 ]; then
        rm -f -- "$PLANNER_AUDIT_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$PLANNER_AUDIT_QUOTA_LOCK" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if ! operation=$(printf '%s' "$request" | jq -er '.operation | select(type == "string")'); then
    json_error "operation must be a string"
fi
if [ "$auth_class" = health ]; then
    [ "$operation" = health_read_sensors ] ||
        json_error "health broker credential is restricted" "broker_auth_failed"
else
    [ "$operation" != health_read_sensors ] ||
        json_error "health broker credential is restricted" "broker_auth_failed"
fi

valid_entity_value() {
    printf '%s' "$1" | jq -e '
      if type == "string" then
        test("^[a-z0-9_]+\\.[a-z0-9_-]+$")
      elif type == "array" then
        length > 0 and length <= 100 and all(.[]; type == "string" and test("^[a-z0-9_]+\\.[a-z0-9_-]+$"))
      else false end
    ' >/dev/null 2>&1
}

get_optional_entity() {
    printf '%s' "$request" | jq -er '.entity_id // ""' 2>/dev/null || true
}

bounded_ha_curl() {
    response_error=""
    # The first two arguments are stable caller context used to keep the
    # call-sites self-documenting; only the remaining arguments belong to
    # curl.
    shift 2
    response_tmp=$(mktemp /data/capability/.ha-response.XXXXXX) || return 1
    chmod 0600 "$response_tmp"
    HA_RESPONSE_FILE="$response_tmp"
    # curl's application-level limit handles known Content-Length values;
    # ulimit is the defense for chunked or otherwise indefinite responses.
    if ! (
        ulimit -f "$MAX_HA_RESPONSE_BLOCKS" 2>/dev/null || exit 125
        curl --max-filesize "$MAX_HA_RESPONSE_BYTES" "$@"
    ) > "$response_tmp" 2>/dev/null; then
        response_error="request_failed"
        response_size=$(wc -c < "$response_tmp" 2>/dev/null | tr -d ' ' || printf '0')
        case "$response_size" in
            ''|*[!0-9]*) ;;
            *) [ "$response_size" -ge "$MAX_HA_RESPONSE_BYTES" ] && response_error="response_too_large" ;;
        esac
        return 1
    fi
    response_size=$(wc -c < "$response_tmp" | tr -d ' ')
    case "$response_size" in
        ''|*[!0-9]*) response_error="invalid_response_size"; return 1 ;;
    esac
    [ "$response_size" -le "$MAX_HA_RESPONSE_BYTES" ] || {
        response_error="response_too_large"
        return 1
    }
}

read_quota_release() {
    if [ "$read_quota_lock_held" -eq 1 ]; then
        read_quota_lock_held=0
        rm -f -- "$READ_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$READ_QUOTA_LOCK" 2>/dev/null || true
    fi
}

read_quota_acquire() {
    attempts=0
    while ! mkdir "$READ_QUOTA_LOCK" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 20 ] || json_error "capability read quota is busy" "read_quota_busy"
        sleep 0.1
    done
    printf '%s\n' "$$" > "$READ_QUOTA_LOCK/owner" || {
        rmdir "$READ_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability read quota lock is unavailable" "read_quota_unavailable"
    }
    chmod 0600 "$READ_QUOTA_LOCK/owner" || {
        rm -f -- "$READ_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$READ_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability read quota lock is unavailable" "read_quota_unavailable"
    }
    read_quota_lock_held=1
}

reserve_read_quota() {
    read_cost="$1"
    case "$read_cost" in
        ''|*[!0-9]*) json_error "capability read quota cost is invalid" "read_quota_invalid" ;;
    esac
    [ "$read_cost" -ge 1 ] || json_error "capability read quota cost is invalid" "read_quota_invalid"
    now=$(date -u +%s)
    hour_window=$((now / 3600))
    read_quota_acquire
    if [ -e "$READ_QUOTA_FILE" ]; then
        [ ! -L "$READ_QUOTA_FILE" ] && [ -f "$READ_QUOTA_FILE" ] || {
            read_quota_release
            json_error "capability read quota state is not a regular file" "read_quota_invalid"
        }
        read_quota=$(cat "$READ_QUOTA_FILE") || {
            read_quota_release
            json_error "capability read quota state is unavailable" "read_quota_unavailable"
        }
    else
        read_quota='{}'
    fi
    if ! printf '%s' "$read_quota" | jq -e 'type == "object"' >/dev/null 2>&1; then
        read_quota_release
        json_error "capability read quota state is invalid" "read_quota_invalid"
    fi
    reads_hour=$(printf '%s' "$read_quota" | jq -r --argjson w "$hour_window" \
        'if .hour_window == $w then (.units_hour // 0) else 0 end')
    case "$reads_hour" in
        ''|*[!0-9]*)
            read_quota_release
            json_error "capability read quota state is invalid" "read_quota_invalid"
            ;;
    esac
    [ "$reads_hour" -le "$((READ_LIMIT_UNITS - read_cost))" ] || {
        read_quota_release
        json_error "capability hourly read budget exceeded" "read_quota_exceeded"
    }
    read_quota_tmp="${READ_QUOTA_FILE}.tmp.$$"
    mkdir -p "$(dirname "$READ_QUOTA_FILE")"
    if ! jq -nc --argjson hour "$hour_window" \
        --argjson units "$((reads_hour + read_cost))" \
        '{hour_window:$hour,units_hour:$units}' > "$read_quota_tmp"; then
        read_quota_release
        json_error "capability read quota state could not be prepared" "read_quota_unavailable"
    fi
    chmod 0600 "$read_quota_tmp"
    mv -f "$read_quota_tmp" "$READ_QUOTA_FILE"
    read_quota_tmp=""
    read_quota_release
}

planner_audit_quota_release() {
    if [ "$planner_audit_lock_held" -eq 1 ]; then
        planner_audit_lock_held=0
        rm -f -- "$PLANNER_AUDIT_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$PLANNER_AUDIT_QUOTA_LOCK" 2>/dev/null || true
    fi
}

planner_audit_quota_acquire() {
    # The quota lock lives below the audit state directory, which may not
    # exist on first use in a fresh data volume.  Create that directory before
    # attempting the atomic mkdir lock; otherwise every first audit request is
    # misreported as a busy quota.
    mkdir -p "$(dirname "$PLANNER_AUDIT_QUOTA_LOCK")" ||
        json_error "planner audit quota state is unavailable" "audit_quota_unavailable"
    attempts=0
    while ! mkdir "$PLANNER_AUDIT_QUOTA_LOCK" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 20 ] || json_error "planner audit quota is busy" "audit_quota_busy"
        sleep 0.1
    done
    printf '%s\n' "$$" > "$PLANNER_AUDIT_QUOTA_LOCK/owner" || {
        rmdir "$PLANNER_AUDIT_QUOTA_LOCK" 2>/dev/null || true
        json_error "planner audit quota lock is unavailable" "audit_quota_unavailable"
    }
    chmod 0600 "$PLANNER_AUDIT_QUOTA_LOCK/owner" || {
        rm -f -- "$PLANNER_AUDIT_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$PLANNER_AUDIT_QUOTA_LOCK" 2>/dev/null || true
        json_error "planner audit quota lock is unavailable" "audit_quota_unavailable"
    }
    planner_audit_lock_held=1
}

reserve_planner_audit() {
    planner_event_value="$1"
    event_bytes=$(printf '%s\n' "$planner_event_value" | wc -c | tr -d ' ')
    case "$event_bytes" in
        ''|*[!0-9]*) json_error "planner audit event size is invalid" "audit_quota_invalid" ;;
    esac
    [ "$event_bytes" -le "$PLANNER_AUDIT_BYTE_LIMIT" ] || \
        json_error "planner audit event is too large" "audit_quota_exceeded"
    now=$(date -u +%s)
    hour_window=$((now / 3600))
    day_window=$((now / 86400))
    planner_audit_quota_acquire
    if [ -e "$PLANNER_AUDIT_QUOTA_FILE" ]; then
        [ ! -L "$PLANNER_AUDIT_QUOTA_FILE" ] && [ -f "$PLANNER_AUDIT_QUOTA_FILE" ] || {
            planner_audit_quota_release
            json_error "planner audit quota state is not a regular file" "audit_quota_invalid"
        }
        planner_quota=$(cat "$PLANNER_AUDIT_QUOTA_FILE") || {
            planner_audit_quota_release
            json_error "planner audit quota state is unavailable" "audit_quota_unavailable"
        }
    else
        planner_quota='{}'
    fi
    if ! printf '%s' "$planner_quota" | jq -e 'type == "object"' >/dev/null 2>&1; then
        planner_audit_quota_release
        json_error "planner audit quota state is invalid" "audit_quota_invalid"
    fi
    events_hour=$(printf '%s' "$planner_quota" | jq -r --argjson w "$hour_window" \
        'if .hour_window == $w then (.events_hour // 0) else 0 end')
    bytes_day=$(printf '%s' "$planner_quota" | jq -r --argjson d "$day_window" \
        'if .day_window == $d then (.bytes_day // 0) else 0 end')
    case "$events_hour:$bytes_day" in
        *[!0-9:]*)
            planner_audit_quota_release
            json_error "planner audit quota state is invalid" "audit_quota_invalid"
            ;;
    esac
    [ "$events_hour" -lt "$PLANNER_AUDIT_EVENT_LIMIT" ] || {
        planner_audit_quota_release
        json_error "planner audit hourly event budget exceeded" "audit_quota_exceeded"
    }
    [ "$bytes_day" -le "$((PLANNER_AUDIT_BYTE_LIMIT - event_bytes))" ] || {
        planner_audit_quota_release
        json_error "planner audit daily byte budget exceeded" "audit_quota_exceeded"
    }
    planner_audit_tmp="${PLANNER_AUDIT_QUOTA_FILE}.tmp.$$"
    mkdir -p "$(dirname "$PLANNER_AUDIT_QUOTA_FILE")"
    if ! jq -nc --argjson hour "$hour_window" --argjson day "$day_window" \
        --argjson events "$((events_hour + 1))" --argjson bytes "$((bytes_day + event_bytes))" \
        '{hour_window:$hour,events_hour:$events,day_window:$day,bytes_day:$bytes}' > "$planner_audit_tmp"; then
        planner_audit_quota_release
        json_error "planner audit quota state could not be prepared" "audit_quota_unavailable"
    fi
    chmod 0600 "$planner_audit_tmp"
    mv -f "$planner_audit_tmp" "$PLANNER_AUDIT_QUOTA_FILE"
    planner_audit_tmp=""
    planner_audit_quota_release
}

run_template() {
    template="$1"
    body=$(jq -nc --arg template "$template" '{template:$template}')
    if ! bounded_ha_curl "Home Assistant template request failed" "ha_response_failed" \
        -fsS --fail-with-body --connect-timeout 5 --max-time 30 -X POST \
        --header "@${HA_AUTH_FILE}" \
        -H 'Content-Type: application/json' \
        "${HA_URL}/template" -d "$body"; then
        [ "$response_error" = "response_too_large" ] && \
            json_error "Home Assistant template response is too large" "ha_response_too_large"
        json_error "Home Assistant template request failed" "ha_response_failed"
    fi
    result=$(cat "$HA_RESPONSE_FILE") || json_error "Home Assistant template response could not be read" "ha_response_failed"
    rm -f "$HA_RESPONSE_FILE"
    HA_RESPONSE_FILE=""
    json_text "$result"
}

run_json_get() {
    path="$1"
    if ! bounded_ha_curl "Home Assistant read request failed" "ha_response_failed" \
        -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
        --header "@${HA_AUTH_FILE}" "${HA_URL}/${path}"; then
        [ "$response_error" = "response_too_large" ] && \
            json_error "Home Assistant read response is too large" "ha_response_too_large"
        json_error "Home Assistant read request failed" "ha_response_failed"
    fi
    result=$(cat "$HA_RESPONSE_FILE") || json_error "Home Assistant read response could not be read" "ha_response_failed"
    rm -f "$HA_RESPONSE_FILE"
    HA_RESPONSE_FILE=""
    if ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
        json_error "Home Assistant returned invalid JSON"
    fi
    json_value "$result"
}

run_logbook() {
    entity="$1"
    now=$(date -u +%Y-%m-%dT%H:%M:%S)
    ago=$(awk 'BEGIN{print strftime("%Y-%m-%dT%H:%M:%S", systime()-86400)}')
    if [ -n "$entity" ]; then
        if ! bounded_ha_curl "Home Assistant logbook request failed" "ha_response_failed" \
            -fsS --fail-with-body --connect-timeout 5 --max-time 30 -G \
            --header "@${HA_AUTH_FILE}" \
            --data-urlencode "entity=${entity}" \
            --data-urlencode "end_time=${now}" \
            "${HA_URL}/logbook/${ago}"; then
            [ "$response_error" = "response_too_large" ] && \
                json_error "Home Assistant logbook response is too large" "ha_response_too_large"
            json_error "Home Assistant logbook request failed" "ha_response_failed"
        fi
    else
        if ! bounded_ha_curl "Home Assistant logbook request failed" "ha_response_failed" \
            -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
            --header "@${HA_AUTH_FILE}" -G \
            --data-urlencode "end_time=${now}" \
            "${HA_URL}/logbook/${ago}"; then
            [ "$response_error" = "response_too_large" ] && \
                json_error "Home Assistant logbook response is too large" "ha_response_too_large"
            json_error "Home Assistant logbook request failed" "ha_response_failed"
        fi
    fi
    result=$(cat "$HA_RESPONSE_FILE") || json_error "Home Assistant logbook response could not be read" "ha_response_failed"
    rm -f "$HA_RESPONSE_FILE"
    HA_RESPONSE_FILE=""
    json_text "$result"
}

run_pending_count() {
    # Count canonical root-owned sealed tickets awaiting approval. Planner-
    # writable pending files are not authoritative for execution.
    count=$(find "$TICKET_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    json_value "$count"
}

run_set_outcome() {
    text=$(printf '%s' "$request" | jq -er '.text | select(type == "string")' 2>/dev/null) || \
        json_error "outcome text must be a string"
    [ "${#text}" -le 512 ] || json_error "outcome text is too long"
    [ "$(printf '%s' "$text" | tr -d '\r\n')" = "$text" ] || \
        json_error "outcome text must be one line"
    [ ! -L "$OUTCOME_FILE" ] || json_error "outcome store is not a regular file"
    outcome_dir=$(dirname "$OUTCOME_FILE")
    mkdir -p "$outcome_dir"
    outcome_tmp="${OUTCOME_FILE}.tmp.$$"
    created_at="$(date -u +%s)"
    jq -nc --arg text "$text" --argjson created_at "$created_at" \
        --argjson expires_at "$((created_at + 300))" \
        '{text:$text,created_at:$created_at,expires_at:$expires_at}' > "$outcome_tmp" || {
        rm -f "$outcome_tmp"
        json_error "outcome store could not be prepared"
    }
    chown root:root "$outcome_tmp"
    chmod 0600 "$outcome_tmp"
    mv -f "$outcome_tmp" "$OUTCOME_FILE"
    sync
    json_value '{"recorded":true}'
}

audit_capability_outcome() {
    kind="$1"
    service="$2"
    payload="$3"
    reason="$4"
    [ -x /usr/local/bin/zc-audit-write ] || return 1
    /usr/local/bin/zc-audit-write "$kind" "$service" "$payload" "$reason"
}

write_approval_outcome() {
    outcome_ticket="$1"
    outcome_service="$2"
    outcome_payload="$3"
    outcome_result="$4"
    printf '%s' "$outcome_ticket" | grep -Eq '^[a-f0-9]{8}$' || return 1
    [ ! -L "$APPROVAL_OUTCOME_DIR" ] || return 1
    if [ -e "$APPROVAL_OUTCOME_DIR" ] && [ ! -d "$APPROVAL_OUTCOME_DIR" ]; then
        return 1
    fi
    mkdir -p "$APPROVAL_OUTCOME_DIR" || return 1
    chmod 0700 "$APPROVAL_OUTCOME_DIR" 2>/dev/null || true
    outcome_file="${APPROVAL_OUTCOME_DIR}/${outcome_ticket}.json"
    [ ! -L "$outcome_file" ] || return 1
    if [ -e "$outcome_file" ]; then
        jq -e --arg service "$outcome_service" --argjson payload "$outcome_payload" \
            '.state == "applied" and .service == $service and .payload == $payload' \
            "$outcome_file" >/dev/null 2>&1
        return $?
    fi
    outcome_ticket_file="${TICKET_DIR}/${outcome_ticket}.json"
    [ -f "$outcome_ticket_file" ] && [ ! -L "$outcome_ticket_file" ] || return 1
    outcome_actor=$(jq -er '.approval.actor_user_id | tostring' "$outcome_ticket_file") || return 1
    outcome_chat=$(jq -er '.approval.chat_id | tostring' "$outcome_ticket_file") || return 1
    outcome_message_id=$(jq -er '.tg_message_id | tostring' "$outcome_ticket_file") || return 1
    printf '%s' "$outcome_message_id" | grep -Eq '^[0-9]+$' || return 1
    outcome_summary=$(printf '%s' "$outcome_payload" | jq -rS -c --arg service "$outcome_service" \
        '($service + " | " + (tojson))') || return 1
    outcome_now=$(date -u +%s)
    outcome_tmp=$(mktemp "${APPROVAL_OUTCOME_DIR}/.${outcome_ticket}.XXXXXX") || return 1
    if ! jq -nc --arg ticket "$outcome_ticket" --arg service "$outcome_service" \
        --arg actor "$outcome_actor" --arg chat "$outcome_chat" \
        --arg message_id "$outcome_message_id" \
        --arg summary "$outcome_summary" --argjson payload "$outcome_payload" \
        --argjson result "$outcome_result" --argjson now "$outcome_now" \
        '{version:1,state:"applied",ticket:$ticket,service:$service,payload:$payload,
          summary:$summary,result:$result,actor_user_id:$actor,chat_id:$chat,
          message_id:$message_id,applied_at:$now}' > "$outcome_tmp"; then
        rm -f "$outcome_tmp"
        return 1
    fi
    chown root:root "$outcome_tmp"
    chmod 0600 "$outcome_tmp"
    sync
    mv -f "$outcome_tmp" "$outcome_file"
    sync
}

validate_service_payload() {
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
        *)
            return 1
            ;;
    esac
}

verify_approval_context() {
    ticket="$1"
    service="$2"
    payload="$3"
    printf '%s' "$ticket" | grep -Eq '^[a-f0-9]{8}$' || json_error "approval ticket id is invalid"
    ticket_file="${TICKET_DIR}/${ticket}.json"
    [ -f "$ticket_file" ] && [ ! -L "$ticket_file" ] || \
        json_error "approval ticket is not valid, sealed, or actor-bound"
    ticket_service=$(jq -er '.service | select(type == "string")' "$ticket_file" 2>/dev/null) || \
        json_error "approval ticket is not valid, sealed, or actor-bound"
    ticket_payload=$(jq -ce '.payload | select(type == "object")' "$ticket_file" 2>/dev/null) || \
        json_error "approval ticket is not valid, sealed, or actor-bound"
    if [ "$ticket_service" = "$service" ]; then
        [ "$ticket_payload" = "$payload" ] || json_error "approved payload does not match the requested payload"
    else
        case "${ticket_service}:${service}" in
            scene/create:scene/reload)
                [ "$(jq -r '.payload.kind // empty' "$ticket_file")" = scene ] || json_error "scene reload is not bound to a scene ticket"
                [ "$payload" = '{}' ] || json_error "scene reload payload must be empty"
                ;;
            automation/create:automation/reload)
                [ "$(jq -r '.payload.kind // empty' "$ticket_file")" = automation ] || json_error "automation reload is not bound to an automation ticket"
                [ "$payload" = '{}' ] || json_error "automation reload payload must be empty"
                ;;
            *)
                json_error "approved ticket does not authorize this service"
                ;;
        esac
    fi

}

claim_approval_context() {
    ticket="$1"
    # Approval claim and action admission share one fixed lock order inside the
    # root transition helper (approval lock, then quota lock). An unapproved or
    # replayed ticket therefore cannot burn the action budget.
    ZEROCLAW_APPROVAL_INTERNAL=1 \
        ZEROCLAW_ACTION_QUOTA_FILE="$ACTION_QUOTA_FILE" \
        ZEROCLAW_ACTION_QUOTA_LOCK="$ACTION_QUOTA_LOCK" \
        ZEROCLAW_ACTION_ADMISSION_DIR="$ACTION_ADMISSION_DIR" \
        CAPABILITY_MAX_ACTIONS_PER_HOUR="$ACTION_LIMIT" \
        /opt/zeroclaw/lib/approval-transition.sh claim_admit "$ticket" >/dev/null 2>&1 || \
        json_error "approval ticket is not valid, sealed, actor-bound, admitted, or already claimed"
}

acquire_action_quota_lock() {
    attempts=0
    while ! mkdir "$ACTION_QUOTA_LOCK" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 20 ] || json_error "capability action quota is busy"
        sleep 0.1
    done
    printf '%s\n' "$$" > "$ACTION_QUOTA_LOCK/owner" || {
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability action quota lock is unavailable"
    }
    chmod 0600 "$ACTION_QUOTA_LOCK/owner" || {
        rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability action quota lock is unavailable"
    }
    quota_lock_held=1
}

reserve_action_quota() {
    case "$ACTION_LIMIT" in
        ''|*[!0-9]*) json_error "capability action limit is invalid" ;;
    esac
    [ "$ACTION_LIMIT" -ge 1 ] && [ "$ACTION_LIMIT" -le 1000 ] || \
        json_error "capability action limit is outside the safe range"

    now=$(date -u +%s)
    hour_window=$((now / 3600))
    acquire_action_quota_lock
    if [ -f "$ACTION_QUOTA_FILE" ]; then
        quota=$(cat "$ACTION_QUOTA_FILE")
    else
        quota='{}'
    fi
    if ! printf '%s' "$quota" | jq -e 'type == "object"' >/dev/null 2>&1; then
        quota_lock_held=0
        rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability action quota state is invalid"
    fi
    requests_hour=$(printf '%s' "$quota" | jq -r --argjson w "$hour_window" \
        'if .hour_window == $w then (.requests_hour // 0) else 0 end')
    case "$requests_hour" in
        ''|*[!0-9]*)
            quota_lock_held=0
            rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
            rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
            json_error "capability action quota state is invalid"
            ;;
    esac
    [ "$requests_hour" -lt "$ACTION_LIMIT" ] || {
        quota_lock_held=0
        rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability hourly action budget exceeded"
    }
    quota_tmp="${ACTION_QUOTA_FILE}.tmp.$$"
    mkdir -p "$(dirname "$ACTION_QUOTA_FILE")"
    jq -nc --argjson hour "$hour_window" \
        --argjson requests "$((requests_hour + 1))" \
        '{hour_window:$hour,requests_hour:$requests}' > "$quota_tmp"
    chmod 0600 "$quota_tmp"
    mv -f "$quota_tmp" "$ACTION_QUOTA_FILE"
    quota_tmp=""
    quota_lock_held=0
    rm -f -- "$ACTION_QUOTA_LOCK/owner" 2>/dev/null || true
    rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
}

authorize_service() {
    service="$1"
    payload="$2"
    domain=${service%%/*}
    action=${service##*/}
    entity=$(printf '%s' "$payload" | jq -r '.entity_id // ""' 2>/dev/null)
    bulk_count=$(printf '%s' "$payload" | jq -r '
      if (.entity_id | type) == "array" then (.entity_id | length)
      elif (.entity_id | type) == "string" then 1
      else 0 end
    ' 2>/dev/null)
    export POLICY_BULK_COUNT="$bulk_count"
    unset POLICY_CLIMATE_CURRENT
    if [ "$domain" = climate ] && [ "$action" = set_temperature ] && [ -n "$entity" ]; then
        if ! bounded_ha_curl "Home Assistant policy baseline read failed" "policy_baseline_failed" \
            -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
            --header "@${HA_AUTH_FILE}" "${HA_URL}/states/${entity}"; then
            json_error "policy baseline read failed" "policy_baseline_failed"
        fi
        state=$(cat "$HA_RESPONSE_FILE") || json_error "policy baseline read failed" "policy_baseline_failed"
        rm -f "$HA_RESPONSE_FILE"
        HA_RESPONSE_FILE=""
        current=$(printf '%s' "$state" | jq -r '.attributes.current_temperature // .attributes.temperature // empty')
        [ -n "$current" ] && export POLICY_CLIMATE_CURRENT="$current"
    fi
    if ! verdict=$(/opt/zeroclaw/lib/policy-decide.sh "$domain" "$action" "$entity" "$payload"); then
        json_error "policy evaluation failed closed"
    fi
    case "$verdict" in
        allow:*)
            approval_ticket=$(printf '%s' "$request" | jq -r '.approval_ticket // empty')
            if [ -n "$approval_ticket" ]; then
                printf '%s' "$approval_ticket" | grep -Eq '^[a-f0-9]{8}$' || \
                    json_error "approval ticket id is invalid"
                verify_approval_context "$approval_ticket" "$service" "$payload"
                claim_approval_context "$approval_ticket"
            fi
            audit_capability_outcome intent "$service" "$payload" "source=capability_broker;${verdict}" || \
                json_error "audit store unavailable; action not attempted"
            ;;
        confirm:*)
            approval_ticket=$(printf '%s' "$request" | jq -r '.approval_ticket // empty')
            if [ -z "$approval_ticket" ]; then
                audit_capability_outcome confirm_failed "$service" "$payload" \
                    "source=capability_broker;approval_required;$verdict" || true
                json_error "confirmation is required before this capability can execute"
            fi
            printf '%s' "$approval_ticket" | grep -Eq '^[a-f0-9]{8}$' || \
                json_error "approval ticket id is invalid"
            verify_approval_context "$approval_ticket" "$service" "$payload"
            claim_approval_context "$approval_ticket"
            audit_capability_outcome intent "$service" "$payload" "source=capability_broker;ticket=${approval_ticket};${verdict}" || \
                json_error "audit store unavailable; action not attempted"
            ;;
        deny:*)
            audit_capability_outcome deny "$service" "$payload" "source=capability_broker;${verdict}" || \
                json_error "audit store unavailable"
            audit_capability_outcome broker_deny "$service" "$payload" "source=capability_broker;${verdict}" || true
            json_error "policy denied capability: ${verdict}"
            ;;
        *)
            json_error "policy returned an invalid verdict"
            ;;
    esac
}

run_service() {
    service="$1"
    payload="$2"
    approval_ticket=$(printf '%s' "$request" | jq -r '.approval_ticket // empty')
    if [ -z "$approval_ticket" ]; then
        reserve_action_quota
    fi
    if ! bounded_ha_curl "Home Assistant service request failed" "service_request_failed" \
        -fsS --fail-with-body --connect-timeout 5 --max-time 30 -X POST \
        --header "@${HA_AUTH_FILE}" \
        -H 'Content-Type: application/json' \
        "${HA_URL}/services/${service}" -d "$payload"; then
        audit_capability_outcome outcome_unknown "$service" "$payload" "source=capability_broker;dispatch_outcome_unknown" || true
        json_error "execution outcome could not be confirmed; claim retained for recovery" \
            execution_outcome_unknown
    fi
    result=$(cat "$HA_RESPONSE_FILE") || {
        rm -f "$HA_RESPONSE_FILE"
        HA_RESPONSE_FILE=""
        audit_capability_outcome outcome_unknown "$service" "$payload" "source=capability_broker;response_read_failed" || true
        json_error "execution outcome could not be confirmed; claim retained for recovery" execution_outcome_unknown
    }
    rm -f "$HA_RESPONSE_FILE"
    HA_RESPONSE_FILE=""
    if [ -z "$result" ]; then
        result='[]'
    fi
    if ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
        audit_capability_outcome outcome_unknown "$service" "$payload" "source=capability_broker;invalid_service_response" || true
        json_error "execution outcome could not be confirmed; claim retained for recovery" \
            execution_outcome_unknown
    fi
    if ! audit_capability_outcome broker_allow "$service" "$payload" "source=capability_broker"; then
        # HA has already accepted the service call. Do not manufacture a
        # failed outcome when the durable audit write is unavailable.
        audit_capability_outcome outcome_unknown "$service" "$payload" \
            "source=capability_broker;service_executed_audit_unavailable" || true
        json_error "service executed but broker outcome audit could not be persisted; claim retained for recovery" \
            executed_audit_unknown
    fi
    if [ -n "$approval_ticket" ]; then
        if ! audit_capability_outcome apply "$service" "$payload" "source=capability_broker;ticket=${approval_ticket}"; then
            audit_capability_outcome outcome_unknown "$service" "$payload" \
                "source=capability_broker;approval_outcome_audit_unavailable;ticket=${approval_ticket}" || true
            json_error "service executed but approval outcome audit could not be persisted; claim retained for recovery" \
                executed_approval_audit_unknown
        fi
        if ! write_approval_outcome "$approval_ticket" "$service" "$payload" "$result"; then
            audit_capability_outcome outcome_unknown "$service" "$payload" \
                "source=capability_broker;approval_outcome_receipt_unavailable;ticket=${approval_ticket}" || true
            json_error "service executed but its durable approval outcome receipt could not be persisted; claim retained for recovery" \
                executed_approval_outcome_unknown
        fi
        if ! ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh complete "$approval_ticket" >/dev/null 2>&1; then
            audit_capability_outcome broker_finalize_failed "$service" "$payload" "source=capability_broker;ticket=${approval_ticket}" || true
            json_error "service executed but approval ticket could not be finalized; claim retained for recovery" \
                executed_finalize_unknown
        fi
    fi
    json_value "$result"
}

run_audit() {
    requested_kind=$(printf '%s' "$request" | jq -er '.kind | select(type == "string")' 2>/dev/null) || json_error "audit kind must be a string"
    requested_service=$(printf '%s' "$request" | jq -er '.service | select(type == "string")' 2>/dev/null) || json_error "audit service must be a string"
    body=$(printf '%s' "$request" | jq -ce '.body | select(type == "object" or type == "array")' 2>/dev/null) || json_error "audit body must be an object or array"
    reason=$(printf '%s' "$request" | jq -er '.reason | select(type == "string")' 2>/dev/null) || json_error "audit reason must be a string"
    printf '%s' "$requested_kind" | grep -Eq '^[a-z][a-z0-9_]{0,31}$' || json_error "audit kind is invalid"
    printf '%s' "$requested_service" | grep -Eq '^[a-z0-9_]+/[a-z0-9_]+$' || json_error "audit service is invalid"
    case "$requested_kind" in
        # Planner-originated records are deliberately stored as a separate,
        # untrusted telemetry kind.  The requested kind/service/body/reason
        # are retained for diagnosis, but can never be mistaken for a broker
        # decision, execution outcome, approval, or failure row.
        intent|deny|confirm|confirm_failed) ;;
        *) json_error "audit kind is not planner-writable" ;;
    esac
    [ "${#reason}" -le 1024 ] || json_error "audit reason is too long"
    planner_event=$(jq -nc \
        --arg requested_kind "$requested_kind" \
        --arg requested_service "$requested_service" \
        --arg requested_reason "$reason" \
        --argjson requested_body "$body" \
        '{source:"untrusted_planner",event:"audit_request",requested_kind:$requested_kind,
          requested_service:$requested_service,requested_body:$requested_body,
          requested_reason:$requested_reason}') || json_error "audit event could not be prepared"
    reserve_planner_audit "$planner_event"
    /usr/local/bin/zc-audit-write planner_event "planner/telemetry" "$planner_event" \
        "source=untrusted_planner" || \
        json_error "audit store unavailable"
    json_value '{"recorded":true}'
}

case "$operation" in
    read_lights|read_climate|read_covers|read_sensors|get_state)
        reserve_read_quota 1
        ;;
    get_logbook|get_error_log)
        # Logbook and error-log responses are both larger and more expensive
        # for HA/Core to assemble, so charge them a higher bounded cost.
        reserve_read_quota 10
        ;;
esac

case "$operation" in
    read_lights)
        run_template '{% for l in states.light %}{% if l.state == "on" and l.entity_id != "light.all_lights" %}{{ l.name }}: {{ l.entity_id }}\n{% endif %}{% endfor %}'
        ;;
    read_climate)
        run_template '{% for c in states.climate %}{% if c.state != "unavailable" %}{{ c.name }}: {{ c.state }}, set:{{ c.attributes.temperature }}C, now:{{ c.attributes.current_temperature }}C\n{% endif %}{% endfor %}'
        ;;
    read_covers)
        run_template '{% for c in states.cover %}{{ c.name }}: {{ c.state }}\n{% endfor %}'
        ;;
    read_sensors)
        run_template '{% for s in states.sensor %}{% if "soil" in s.entity_id or "moisture" in s.entity_id or "temperature" in s.entity_id %}{{ s.name }}: {{ s.state }}{{ s.attributes.unit_of_measurement }}\n{% endif %}{% endfor %}'
        ;;
    health_read_sensors)
        # The Supervisor health process uses a root-only client credential and
        # is intentionally exempt from the planner's read quota.  Keep the
        # response bounded by the same broker template path.
        run_template '{% for s in states.sensor %}{% if "soil" in s.entity_id or "moisture" in s.entity_id or "temperature" in s.entity_id %}{{ s.name }}: {{ s.state }}{{ s.attributes.unit_of_measurement }}\n{% endif %}{% endfor %}'
        ;;
    get_state)
        entity=$(printf '%s' "$request" | jq -er '.entity_id | select(type == "string")' 2>/dev/null) || json_error "entity_id must be a string"
        valid_entity_value "\"${entity}\"" || json_error "entity_id is invalid"
        run_json_get "states/${entity}"
        ;;
    get_logbook)
        entity=$(get_optional_entity)
        if [ -n "$entity" ]; then
            valid_entity_value "\"${entity}\"" || json_error "entity_id is invalid"
        fi
        run_logbook "$entity"
        ;;
    get_error_log)
        # Home Assistant's /error_log endpoint is an opaque plaintext body and
        # may contain paths, usernames, tokens, request data, and exception
        # payloads. It is not safe to forward that body across the broker to
        # the untrusted planner/provider. Perform the bounded health check but
        # return only a fixed, non-sensitive result; detailed diagnostics stay
        # in the Home Assistant UI/logs.
        if ! bounded_ha_curl "Home Assistant error log request failed" "ha_response_failed" \
            -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
            --header "@${HA_AUTH_FILE}" "${HA_URL}/error_log"; then
            [ "$response_error" = "response_too_large" ] && \
                json_error "Home Assistant error log response is too large" "ha_response_too_large"
            json_error "Home Assistant error log request failed" "ha_response_failed"
        fi
        rm -f "$HA_RESPONSE_FILE"
        HA_RESPONSE_FILE=""
        json_value '{"available":true,"detail":"Detailed Home Assistant error logs remain in Home Assistant Settings > System > Logs."}'
        ;;
    pending_count)
        run_pending_count
        ;;
    set_outcome)
        run_set_outcome
        ;;
    call_service)
        [ "${ENABLE_WRITE_ACTIONS:-false}" = "true" ] || json_error "write capability is disabled"
        internal=$(printf '%s' "$request" | jq -r '.internal // false' 2>/dev/null)
        [ "$internal" = true ] || json_error "write capability requires an internal action context"
        approval_ticket=$(printf '%s' "$request" | jq -r '.approval_ticket // empty' 2>/dev/null)
        [ -n "$approval_ticket" ] || json_error "approved Telegram ticket is required"
        service=$(printf '%s' "$request" | jq -er '.service | select(type == "string")' 2>/dev/null) || json_error "service must be a string"
        payload=$(printf '%s' "$request" | jq -ce 'if (.payload // {}) | type == "object" then (.payload // {}) else error("payload must be an object") end' 2>/dev/null) || json_error "payload must be an object"
        case "$service" in
            */*) ;;
            *) json_error "service must use domain/action form" ;;
        esac
        validate_service_payload "$service" "$payload" || \
            json_error "service or payload is not allowed by the broker"
        authorize_service "$service" "$payload"
        run_service "$service" "$payload"
        ;;
    audit)
        run_audit
        ;;
    *)
        json_error "unknown capability"
        ;;
esac
