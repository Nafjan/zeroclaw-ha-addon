#!/bin/sh
# ZeroClaw capability broker request handler.
#
# This process is the only runtime component that receives HA_TOKEN.  The
# planner and all agent-callable helpers use the typed client instead of
# talking to the Home Assistant API directly.
set -eu

HA_URL="${HA_URL:-http://supervisor/core/api}"
TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"
ACTION_LIMIT="${CAPABILITY_MAX_ACTIONS_PER_HOUR:-200}"
ACTION_QUOTA_FILE="${CAPABILITY_QUOTA_FILE:-/data/capability/quota.json}"
ACTION_QUOTA_LOCK="${CAPABILITY_QUOTA_LOCK:-/data/capability/.quota.lock}"
ACTION_ADMISSION_DIR="${CAPABILITY_ACTION_ADMISSION_DIR:-/data/capability/action-admissions}"
OUTCOME_FILE="${ZEROCLAW_OUTCOME_FILE:-/data/capability/last-outcome.json}"
CLIENT_AUTH_TOKEN="${CAPABILITY_CLIENT_AUTH_TOKEN:-}"

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
IFS= read -r request || true
[ -n "$request" ] || json_error "empty broker request"
[ "${#request}" -le 32768 ] || json_error "broker request too large"
[ -n "$CLIENT_AUTH_TOKEN" ] || json_error "broker client authentication is unavailable" "broker_auth_unavailable"
provided_auth=$(printf '%s' "$request" | jq -er '.auth | select(type == "string")' 2>/dev/null) || \
    json_error "broker client authentication failed" "broker_auth_failed"
[ "$provided_auth" = "$CLIENT_AUTH_TOKEN" ] || \
    json_error "broker client authentication failed" "broker_auth_failed"
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
cleanup() {
    rm -f "$HA_AUTH_FILE" "${quota_tmp:-}"
    [ "$quota_lock_held" -eq 1 ] && rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
}
trap cleanup EXIT

if ! operation=$(printf '%s' "$request" | jq -er '.operation | select(type == "string")'); then
    json_error "operation must be a string"
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

run_template() {
    template="$1"
    body=$(jq -nc --arg template "$template" '{template:$template}')
    if ! result=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 -X POST \
        --header "@${HA_AUTH_FILE}" \
        -H 'Content-Type: application/json' \
        "${HA_URL}/template" -d "$body"); then
        json_error "Home Assistant template request failed"
    fi
    json_text "$result"
}

run_json_get() {
    path="$1"
    if ! result=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
        --header "@${HA_AUTH_FILE}" "${HA_URL}/${path}"); then
        json_error "Home Assistant read request failed"
    fi
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
        if ! result=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 -G \
            --header "@${HA_AUTH_FILE}" \
            --data-urlencode "entity=${entity}" \
            --data-urlencode "end_time=${now}" \
            "${HA_URL}/logbook/${ago}"); then
            json_error "Home Assistant logbook request failed"
        fi
    else
        if ! result=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
            --header "@${HA_AUTH_FILE}" -G \
            --data-urlencode "end_time=${now}" \
            "${HA_URL}/logbook/${ago}"); then
            json_error "Home Assistant logbook request failed"
        fi
    fi
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
        rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
        json_error "capability action quota state is invalid"
    fi
    requests_hour=$(printf '%s' "$quota" | jq -r --argjson w "$hour_window" \
        'if .hour_window == $w then (.requests_hour // 0) else 0 end')
    case "$requests_hour" in
        ''|*[!0-9]*)
            quota_lock_held=0
            rmdir "$ACTION_QUOTA_LOCK" 2>/dev/null || true
            json_error "capability action quota state is invalid"
            ;;
    esac
    [ "$requests_hour" -lt "$ACTION_LIMIT" ] || {
        quota_lock_held=0
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
        if ! state=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 --header "@${HA_AUTH_FILE}" "${HA_URL}/states/${entity}"); then
            json_error "policy baseline read failed"
        fi
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
    if ! result=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 -X POST \
        --header "@${HA_AUTH_FILE}" \
        -H 'Content-Type: application/json' \
        "${HA_URL}/services/${service}" -d "$payload"); then
        audit_capability_outcome outcome_unknown "$service" "$payload" "source=capability_broker;dispatch_outcome_unknown" || true
        json_error "execution outcome could not be confirmed; claim retained for recovery" \
            execution_outcome_unknown
    fi
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
        if ! ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh complete "$approval_ticket" >/dev/null 2>&1; then
            audit_capability_outcome broker_finalize_failed "$service" "$payload" "source=capability_broker;ticket=${approval_ticket}" || true
            json_error "service executed but approval ticket could not be finalized; claim retained for recovery" \
                executed_finalize_unknown
        fi
    fi
    json_value "$result"
}

run_audit() {
    kind=$(printf '%s' "$request" | jq -er '.kind | select(type == "string")' 2>/dev/null) || json_error "audit kind must be a string"
    service=$(printf '%s' "$request" | jq -er '.service | select(type == "string")' 2>/dev/null) || json_error "audit service must be a string"
    body=$(printf '%s' "$request" | jq -ce '.body | select(type == "object" or type == "array")' 2>/dev/null) || json_error "audit body must be an object or array"
    reason=$(printf '%s' "$request" | jq -er '.reason | select(type == "string")' 2>/dev/null) || json_error "audit reason must be a string"
    printf '%s' "$kind" | grep -Eq '^[a-z][a-z0-9_]{0,31}$' || json_error "audit kind is invalid"
    printf '%s' "$service" | grep -Eq '^[a-z0-9_]+/[a-z0-9_]+$' || json_error "audit service is invalid"
    case "$kind" in
        # Planner-originated rows describe intent or a policy decision only.
        # Execution, failure, and undo outcomes are written by root-owned
        # broker paths and cannot be minted over the local TCP boundary.
        intent|deny|confirm|confirm_failed) ;;
        *) json_error "audit kind is not planner-writable" ;;
    esac
    [ "${#reason}" -le 1024 ] || json_error "audit reason is too long"
    /usr/local/bin/zc-audit-write "$kind" "$service" "$body" "$reason" || \
        json_error "audit store unavailable"
    json_value '{"recorded":true}'
}

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
        if ! result=$(curl -fsS --fail-with-body --connect-timeout 5 --max-time 30 \
            --header "@${HA_AUTH_FILE}" "${HA_URL}/error_log"); then
            json_error "Home Assistant error log request failed"
        fi
        json_text "$result"
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
