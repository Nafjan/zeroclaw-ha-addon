#!/bin/sh
# Root-owned OpenAI-compatible model gateway.
#
# The planner receives only a dummy local credential. This handler owns the
# provider profiles, maps planner-visible routes to provider/model bindings,
# applies deterministic fail-closed fallback rules, and records durable
# per-profile token reservations/settlements. Streaming is deliberately not
# part of this contract: the broker buffers one non-streaming response and
# rejects stream=true until a separately qualified streaming design exists.
set -eu

UPSTREAM_URL="${PROVIDER_UPSTREAM_URL:-https://openrouter.ai/api/v1/chat/completions}"
MAX_BODY=262144
MAX_RESPONSE=1048576
MAX_TOKENS="${PROVIDER_MAX_TOKENS:-2048}"
MAX_REQUESTS_PER_HOUR="${PROVIDER_MAX_REQUESTS_PER_HOUR:-120}"
DAILY_TOKEN_BUDGET="${PROVIDER_DAILY_TOKEN_BUDGET:-100000}"
ALLOWED_MODELS="${PROVIDER_ALLOWED_MODELS:-}"
PROFILE_SPEC="${PROVIDER_PROFILE_SPEC:-}"
ROUTE_SPEC="${PROVIDER_ROUTE_SPEC:-}"
FALLBACK_ENABLED="${PROVIDER_FALLBACK_ENABLED:-true}"
FREE_FALLBACK_ENABLED="${PROVIDER_FREE_FALLBACK_ENABLED:-false}"
FUSION_PRESET="${PROVIDER_FUSION_PRESET:-general-budget}"
AUTO_COST_TIER="${PROVIDER_AUTO_COST_TIER:-medium}"
LEDGER_FILE="${PROVIDER_LEDGER_FILE:-${PROVIDER_QUOTA_FILE:-/data/provider/ledger.json}}"
LEDGER_FILE=$(printf '%s' "$LEDGER_FILE" | sed 's/[[:space:]]*$//')
LEDGER_LOCK="${PROVIDER_LEDGER_LOCK:-${PROVIDER_QUOTA_LOCK:-/data/provider/.ledger.lock}}"
LOG_FILE="${PROVIDER_LOG_FILE:-/data/logs/provider-broker.log}"
RESERVATION_TTL="${PROVIDER_RESERVATION_TTL_SECONDS:-180}"

respond() {
    status="$1"
    reason="$2"
    body="$3"
    length=$(printf '%s' "$body" | wc -c | tr -d ' ')
    printf 'HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$status" "$reason" "$length" "$body"
    exit 0
}

log_event() {
    [ -n "$LOG_FILE" ] || return 0
    printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

case "$MAX_TOKENS:$MAX_REQUESTS_PER_HOUR:$DAILY_TOKEN_BUDGET:$RESERVATION_TTL" in
    *[!0-9:]*|:*|*::*|*:::*)
        respond 503 "Service Unavailable" '{"error":"provider broker limits are invalid"}'
        ;;
esac
[ "$MAX_TOKENS" -ge 1 ] && [ "$MAX_TOKENS" -le "$DAILY_TOKEN_BUDGET" ] || \
    respond 503 "Service Unavailable" '{"error":"provider token limits are invalid"}'
[ "$MAX_REQUESTS_PER_HOUR" -ge 1 ] && [ "$MAX_REQUESTS_PER_HOUR" -le 1000 ] || \
    respond 503 "Service Unavailable" '{"error":"provider request limits are invalid"}'
[ "$RESERVATION_TTL" -ge 30 ] && [ "$RESERVATION_TTL" -le 900 ] || \
    respond 503 "Service Unavailable" '{"error":"provider reservation TTL is invalid"}'
case "$FALLBACK_ENABLED:$FREE_FALLBACK_ENABLED" in
    true:true|true:false|false:true|false:false) ;;
    *) respond 503 "Service Unavailable" '{"error":"provider fallback settings are invalid"}' ;;
esac
case "$FUSION_PRESET" in
    general-high|general-budget|general-fast) ;;
    *) respond 503 "Service Unavailable" '{"error":"provider Fusion preset is invalid"}' ;;
esac
case "$AUTO_COST_TIER" in
    low|medium|high|xhigh|max) ;;
    *) respond 503 "Service Unavailable" '{"error":"provider Auto cost tier is invalid"}' ;;
esac

# Compatibility path for the previous single-OpenRouter broker.
if [ -z "$PROFILE_SPEC" ]; then
    PROFILE_SPEC="legacy|${UPSTREAM_URL}||${MAX_REQUESTS_PER_HOUR}|${DAILY_TOKEN_BUDGET}"
    ROUTE_SPEC=""
    old_model=""
    old_models=$(printf '%s' "$ALLOWED_MODELS" | tr ',' '\n')
    while IFS= read -r old_model; do
        [ -n "$old_model" ] || continue
        if [ -z "$ROUTE_SPEC" ]; then
            ROUTE_SPEC="${old_model}|legacy|${old_model}|paid"
        else
            ROUTE_SPEC="${ROUTE_SPEC}
${old_model}|legacy|${old_model}|paid"
        fi
    done <<EOF
${old_models}
EOF
fi

request_line=""
IFS= read -r request_line || respond 400 "Bad Request" '{"error":"missing request line"}'
request_line=$(printf '%s' "$request_line" | tr -d '\r')
[ "$request_line" = "POST /v1/chat/completions HTTP/1.1" ] || \
    respond 404 "Not Found" '{"error":"route is not available"}'

content_length=""
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    case "$header" in
        Content-Length:*|content-length:*)
            content_length=$(printf '%s' "$header" | cut -d: -f2- | tr -d ' ')
            ;;
        Transfer-Encoding:*|transfer-encoding:*)
            respond 400 "Bad Request" '{"error":"chunked requests are not supported"}'
            ;;
    esac
done

printf '%s' "$content_length" | grep -Eq '^[0-9]+$' || \
    respond 411 "Length Required" '{"error":"content length is required"}'
[ "$content_length" -le "$MAX_BODY" ] || \
    respond 413 "Payload Too Large" '{"error":"request body is too large"}'

body_file=$(mktemp)
response_file=$(mktemp)
attempt_body=$(mktemp)
quota_lock_held=0
trap 'rm -f "$body_file" "$response_file" "$attempt_body" "$response_file.attempt"; [ "$quota_lock_held" -eq 1 ] && rmdir "$LEDGER_LOCK" 2>/dev/null || true' EXIT

dd of="$body_file" bs=1 count="$content_length" 2>/dev/null || \
    respond 400 "Bad Request" '{"error":"request body could not be read"}'
[ "$(wc -c < "$body_file" | tr -d ' ')" = "$content_length" ] || \
    respond 400 "Bad Request" '{"error":"request body is incomplete"}'
jq -e 'type == "object" and (.model | type == "string") and (.messages | type == "array")' \
    "$body_file" >/dev/null 2>&1 || \
    respond 400 "Bad Request" '{"error":"chat-completions JSON envelope is invalid"}'
jq -e '.stream != true' "$body_file" >/dev/null 2>&1 || \
    respond 400 "Bad Request" '{"error":"streaming is not supported by the provider broker"}'

requested_model=$(jq -r '.model' "$body_file")
requested_tokens=$(jq -r '.max_tokens // 0' "$body_file")
case "$requested_tokens" in
    ''|*[!0-9]*) respond 400 "Bad Request" '{"error":"max_tokens must be a non-negative integer"}' ;;
esac
[ "$requested_tokens" -gt 0 ] || requested_tokens="$MAX_TOKENS"
[ "$requested_tokens" -le "$MAX_TOKENS" ] || \
    respond 400 "Bad Request" '{"error":"max_tokens exceeds the broker limit"}'

# Free-tier routes require an original request with no tools or tool-call
# continuation. Tool-capable turns never get downgraded to a free model.
free_eligible=0
if jq -e '
    ((.tools // []) | length) == 0 and
    ((.functions // []) | length) == 0 and
    ((.tool_choice // "none") == "none") and
    ((.function_call // "none") == "none") and
    ([(.messages // [])[]? | select(
        .role == "tool" or .role == "function" or
        ((.tool_calls // []) | length) > 0 or
        (.function_call != null)
    )] | length) == 0
' "$body_file" >/dev/null 2>&1; then
    free_eligible=1
fi

profile_record() {
    printf '%s\n' "$PROFILE_SPEC" | awk -F '|' -v profile="$1" '$1 == profile {print; exit}'
}

profile_is_blocked() {
    case ",${blocked_profiles}," in
        *,"$1",*) return 0 ;;
        *) return 1 ;;
    esac
}

block_profile() {
    if ! profile_is_blocked "$1"; then
        if [ -n "$blocked_profiles" ]; then
            blocked_profiles="${blocked_profiles},$1"
        else
            blocked_profiles="$1"
        fi
    fi
}

load_profile() {
    profile_id="$1"
    profile_line=$(profile_record "$profile_id")
    [ -n "$profile_line" ] || return 1
    PROFILE_URL=$(printf '%s' "$profile_line" | cut -d'|' -f2)
    PROFILE_KEY_FILE=$(printf '%s' "$profile_line" | cut -d'|' -f3)
    PROFILE_MAX_REQUESTS=$(printf '%s' "$profile_line" | cut -d'|' -f4)
    PROFILE_DAILY_BUDGET=$(printf '%s' "$profile_line" | cut -d'|' -f5)
    case "$PROFILE_MAX_REQUESTS:$PROFILE_DAILY_BUDGET" in
        ''|*[!0-9:]*|:*|*::*) return 1 ;;
    esac
    [ "$PROFILE_MAX_REQUESTS" -ge 1 ] || return 1
    [ "$PROFILE_DAILY_BUDGET" -ge 1 ] || return 1
    PROFILE_KEY=""
    if [ -n "$PROFILE_KEY_FILE" ] && [ -r "$PROFILE_KEY_FILE" ]; then
        PROFILE_KEY=$(tr -d '\r\n' < "$PROFILE_KEY_FILE")
    elif [ "$profile_id" = "legacy" ]; then
        PROFILE_KEY=$(printf '%s' "${OPENROUTER_KEY:-}")
    fi
    [ -n "$PROFILE_KEY" ] || return 1
    [ -n "$PROFILE_URL" ] || return 1
    return 0
}

all_credentials_leak() {
    credential=""
    while IFS='|' read -r leak_profile_id leak_profile_url leak_key_file leak_requests leak_budget; do
        [ -n "$leak_profile_id" ] || continue
        if [ -n "$leak_key_file" ] && [ -r "$leak_key_file" ]; then
            credential=$(tr -d '\r\n' < "$leak_key_file")
        elif [ "$leak_profile_id" = "legacy" ]; then
            credential="${OPENROUTER_KEY:-}"
        else
            credential=""
        fi
        [ -n "$credential" ] || continue
        if grep -F -- "$credential" "$response_file" >/dev/null 2>&1; then
            return 0
        fi
    done <<EOF
$PROFILE_SPEC
EOF
    return 1
}

write_ledger() {
    ledger_tmp="${LEDGER_FILE}.tmp.$$"
    printf '%s\n' "$1" > "$ledger_tmp" || return 1
    chmod 0600 "$ledger_tmp"
    mv -f "$ledger_tmp" "$LEDGER_FILE"
}

acquire_ledger_lock() {
    attempts=0
    while ! mkdir "$LEDGER_LOCK" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 10 ] || return 1
        sleep 1
    done
    quota_lock_held=1
    return 0
}

release_ledger_lock() {
    if [ "$quota_lock_held" -eq 1 ]; then
        rmdir "$LEDGER_LOCK" 2>/dev/null || true
        quota_lock_held=0
    fi
}

migrate_legacy_ledger() {
    [ -f "$LEDGER_FILE" ] || return 1
    legacy=$(cat "$LEDGER_FILE")
    jq -e '
        type == "object" and
        (.hour_window | type == "number" and floor == .) and
        (.day_window | type == "number" and floor == .) and
        (.requests_hour | type == "number" and floor == . and . >= 0) and
        (.tokens_day | type == "number" and floor == . and . >= 0)
    ' "$LEDGER_FILE" >/dev/null 2>&1 || return 1
    legacy_profile=$(printf '%s\n' "$PROFILE_SPEC" | awk -F '|' 'NF >= 5 {print $1; exit}')
    [ -n "$legacy_profile" ] || return 1
    legacy_hour=$(printf '%s' "$legacy" | jq -r '.hour_window')
    legacy_day=$(printf '%s' "$legacy" | jq -r '.day_window')
    legacy_requests=$(printf '%s' "$legacy" | jq -r '.requests_hour')
    legacy_tokens=$(printf '%s' "$legacy" | jq -r '.tokens_day')
    [ "$legacy_requests" -le "$MAX_REQUESTS_PER_HOUR" ] || return 1
    [ "$legacy_tokens" -le "$DAILY_TOKEN_BUDGET" ] || return 1
    migrated=$(jq -nc \
        --arg profile "$legacy_profile" \
        --argjson hour "$legacy_hour" \
        --argjson day "$legacy_day" \
        --argjson requests "$legacy_requests" \
        --argjson tokens "$legacy_tokens" \
        '{schema:1,records:(
            [range(0;$requests) as $i |
                {id:("legacy-hour-" + ($i|tostring)),created_at:0,expires_at:0,
                 hour_window:$hour,day_window:$day,route_id:"legacy",profile_id:$profile,
                 upstream_model:"legacy",reserved_tokens:0,settled_tokens:0,
                 state:"settled",settlement:"migrated_request_count",updated_at:0}] +
            (if $tokens > 0 then
                [{id:"legacy-tokens",created_at:0,expires_at:0,hour_window:$hour,
                  day_window:$day,route_id:"legacy",profile_id:$profile,
                  upstream_model:"legacy",reserved_tokens:$tokens,settled_tokens:$tokens,
                  state:"settled",settlement:"migrated_reserved_max",updated_at:0}]
             else [] end)
        )}')
    write_ledger "$migrated"
}

load_and_reconcile_ledger() {
    if [ -f "$LEDGER_FILE" ]; then
        ledger=$(cat "$LEDGER_FILE")
        if ! printf '%s' "$ledger" | jq -e '.schema == 1 and (.records | type == "array")' >/dev/null 2>&1; then
            migrate_legacy_ledger || return 1
            ledger=$(cat "$LEDGER_FILE")
        fi
    else
        ledger='{"schema":1,"records":[]}'
    fi
    printf '%s' "$ledger" | jq -e '
        type == "object" and .schema == 1 and (.records | type == "array") and
        all(.records[];
            (.id | type == "string") and
            (.profile_id | type == "string") and
            (.reserved_tokens | type == "number" and floor == . and . >= 0) and
            ((.settled_tokens // .reserved_tokens) | type == "number" and floor == . and . >= 0) and
            (.state == "reserved" or .state == "settled" or .state == "expired")
        )
    ' >/dev/null 2>&1 || return 1
    now=$(date -u +%s)
    day_window=$((now / 86400))
    reconciled=$(printf '%s' "$ledger" | jq --argjson now "$now" --argjson keep_day "$((day_window - 7))" '
        .records |= map(
            if .state == "reserved" and (.expires_at | tonumber) <= $now then
                .state = "expired" |
                .settled_tokens = .reserved_tokens |
                .settlement = "expired_reserved_max" |
                .updated_at = $now
            else . end
        ) |
        .records |= map(select(.state == "reserved" or (.day_window | tonumber) >= $keep_day))
    ') || return 1
    ledger="$reconciled"
    write_ledger "$ledger" || return 1
    return 0
}

reserve_attempt() {
    reserve_profile="$1"
    reserve_route="$2"
    reserve_upstream_model="$3"
    reserve_tokens="$4"
    reserve_id="$(date -u +%s)-$$-${attempt_number}"
    reserve_now="$(date -u +%s)"
    reserve_hour=$((reserve_now / 3600))
    reserve_day=$((reserve_now / 86400))
    reserve_expires=$((reserve_now + RESERVATION_TTL))
    acquire_ledger_lock || return 1
    if ! load_and_reconcile_ledger; then
        release_ledger_lock
        return 1
    fi
    hour_count=$(printf '%s' "$ledger" | jq -r --arg profile "$reserve_profile" --argjson hour "$reserve_hour" \
        '[.records[] | select(.profile_id == $profile and .hour_window == $hour)] | length') || {
        release_ledger_lock
        return 1
    }
    day_tokens=$(printf '%s' "$ledger" | jq -r --arg profile "$reserve_profile" --argjson day "$reserve_day" \
        '[.records[] | select(.profile_id == $profile and .day_window == $day) | (.settled_tokens // .reserved_tokens)] | add // 0') || {
        release_ledger_lock
        return 1
    }
    case "$hour_count:$day_tokens" in
        *[!0-9:]*|:*|*::*)
            release_ledger_lock
            return 1
            ;;
    esac
    [ "$hour_count" -lt "$PROFILE_MAX_REQUESTS" ] || {
        release_ledger_lock
        return 2
    }
    [ "$day_tokens" -le $((PROFILE_DAILY_BUDGET - reserve_tokens)) ] || {
        release_ledger_lock
        return 2
    }
    ledger=$(printf '%s' "$ledger" | jq \
        --arg id "$reserve_id" --arg profile "$reserve_profile" --arg route "$reserve_route" \
        --arg upstream "$reserve_upstream_model" --argjson now "$reserve_now" \
        --argjson expires "$reserve_expires" --argjson hour "$reserve_hour" --argjson day "$reserve_day" \
        --argjson reserved "$reserve_tokens" \
        '.records += [{id:$id,created_at:$now,expires_at:$expires,hour_window:$hour,day_window:$day,
                       route_id:$route,profile_id:$profile,upstream_model:$upstream,
                       reserved_tokens:$reserved,settled_tokens:null,state:"reserved",
                       settlement:null,updated_at:$now}]') || {
        release_ledger_lock
        return 1
    }
    write_ledger "$ledger" || {
        release_ledger_lock
        return 1
    }
    release_ledger_lock
    RESERVATION_ID="$reserve_id"
    return 0
}

settle_attempt() {
    settle_id="$1"
    settle_status="$2"
    settle_failure="$3"
    settle_actual="$4"
    settle_now=$(date -u +%s)
    settle_value=""
    settle_reason="$settle_failure"
    settle_hard_failure=0
    case "$settle_status" in
        2[0-9][0-9])
        case "$settle_actual" in
            ''|*[!0-9]*)
                settle_value=""
                settle_reason="reserved_max_missing_usage"
                ;;
            *)
                settle_value="$settle_actual"
                ;;
        esac
            ;;
    esac
    acquire_ledger_lock || return 1
    load_and_reconcile_ledger || {
        release_ledger_lock
        return 1
    }
    reserve_value=$(printf '%s' "$ledger" | jq -r --arg id "$settle_id" \
        '[.records[] | select(.id == $id and .state == "reserved") | .reserved_tokens] | .[0] // empty') || {
        release_ledger_lock
        return 1
    }
    case "$reserve_value" in
        ''|*[!0-9]*)
            release_ledger_lock
            return 1
            ;;
    esac
    case "$settle_status:$settle_value" in
        2[0-9][0-9]:?*)
        if [ "$settle_value" -gt "$reserve_value" ]; then
            settle_value="$reserve_value"
            settle_reason="reserved_max_usage_overrun"
            settle_hard_failure=1
        fi
            ;;
        *) settle_value="$reserve_value" ;;
    esac
    ledger=$(printf '%s' "$ledger" | jq \
        --arg id "$settle_id" --arg status "$settle_status" --arg reason "$settle_reason" \
        --argjson actual "$settle_value" --argjson now "$settle_now" \
        '.records |= map(if .id == $id and .state == "reserved" then
            .state = "settled" | .settled_tokens = $actual | .settlement = $reason |
            .http_status = ($status | tonumber? // null) | .updated_at = $now
         else . end)') || {
        release_ledger_lock
        return 1
    }
    write_ledger "$ledger" || {
        release_ledger_lock
        return 1
    }
    release_ledger_lock
    [ "$settle_hard_failure" -eq 0 ]
}

classify_failure() {
    failure_code="$1"
    if grep -Eiq 'insufficient[ _-]*quota|out[ _-]*of[ _-]*credit|payment[ _-]*required|billing|credit[ _-]*exhaust' "$response_file" 2>/dev/null; then
        FAILURE_CLASS="credit_exhausted"
        return 0
    fi
    case "$failure_code" in
        401) FAILURE_CLASS="credential_invalid" ;;
        402) FAILURE_CLASS="credit_exhausted" ;;
        408|425|429|500|501|502|503|504|505|506|507|508|509|510|511) FAILURE_CLASS="transient" ;;
        404) FAILURE_CLASS="model_unavailable" ;;
        403) FAILURE_CLASS="provider_forbidden" ;;
        400|422) FAILURE_CLASS="request_rejected" ;;
        *) FAILURE_CLASS="provider_failure" ;;
    esac
}

status_reason() {
    case "$1" in
        200) STATUS_REASON="OK" ;;
        201) STATUS_REASON="Created" ;;
        400) STATUS_REASON="Bad Request" ;;
        401) STATUS_REASON="Unauthorized" ;;
        402) STATUS_REASON="Payment Required" ;;
        403) STATUS_REASON="Forbidden" ;;
        404) STATUS_REASON="Not Found" ;;
        408) STATUS_REASON="Request Timeout" ;;
        409) STATUS_REASON="Conflict" ;;
        425) STATUS_REASON="Too Early" ;;
        429) STATUS_REASON="Too Many Requests" ;;
        500) STATUS_REASON="Internal Server Error" ;;
        502) STATUS_REASON="Bad Gateway" ;;
        503) STATUS_REASON="Service Unavailable" ;;
        504) STATUS_REASON="Gateway Timeout" ;;
        *) STATUS_REASON="Upstream Response" ;;
    esac
}

extract_usage() {
    USAGE_STATE="missing"
    USAGE_COMPLETION=""
    if ! jq -e 'has("usage") and (.usage != null)' "$response_file" >/dev/null 2>&1; then
        return 0
    fi
    USAGE_COMPLETION=$(jq -r '.usage.completion_tokens // empty' "$response_file" 2>/dev/null || true)
    case "$USAGE_COMPLETION" in
        ''|*[!0-9]*)
            USAGE_STATE="invalid"
            return 0
            ;;
    esac
    if ! jq -e '(.usage.total_tokens == null or ((.usage.total_tokens | type == "number") and (.usage.total_tokens >= .usage.completion_tokens)))' \
        "$response_file" >/dev/null 2>&1; then
        USAGE_STATE="invalid"
        return 0
    fi
    USAGE_STATE="valid"
}

route_candidates=$(printf '%s\n' "$ROUTE_SPEC" | awk -F '|' -v route="$requested_model" '$1 == route {print}')
[ -n "$route_candidates" ] || respond 403 "Forbidden" '{"error":"model route is not allowed by the provider broker"}'

blocked_profiles=""
credit_exhausted_profiles=""
seen_candidates=""
attempt_number=0
last_failure="provider routes exhausted"

profile_is_credit_exhausted() {
    case ",${credit_exhausted_profiles}," in
        *,"$1",*) return 0 ;;
        *) return 1 ;;
    esac
}

mark_credit_exhausted() {
    if ! profile_is_credit_exhausted "$1"; then
        if [ -n "$credit_exhausted_profiles" ]; then
            credit_exhausted_profiles="${credit_exhausted_profiles},$1"
        else
            credit_exhausted_profiles="$1"
        fi
    fi
}

while IFS='|' read -r route_id profile_id upstream_model tier; do
    [ -n "$route_id" ] || continue
    [ "$route_id" = "$requested_model" ] || continue
    case "$tier" in
        paid) ;;
        free)
            [ "$FREE_FALLBACK_ENABLED" = "true" ] && [ "$free_eligible" -eq 1 ] || continue
            ;;
        *) continue ;;
    esac
    [ -n "$profile_id" ] && [ -n "$upstream_model" ] || continue
    candidate_key="${profile_id}|${upstream_model}|${tier}"
    printf '%s\n' "$seen_candidates" | grep -Fx -- "$candidate_key" >/dev/null 2>&1 && continue
    seen_candidates="${seen_candidates}
${candidate_key}"
    if [ "$FALLBACK_ENABLED" != "true" ] && [ "$attempt_number" -gt 0 ]; then
        break
    fi
    if [ "$tier" = "free" ]; then
        # A paid route can exhaust account credits while the provider's
        # explicitly free catalogue remains usable. Permit only that
        # classified transition; other profile failures still block both
        # paid and free routes.
        if profile_is_blocked "$profile_id" && ! profile_is_credit_exhausted "$profile_id"; then
            continue
        fi
    elif profile_is_blocked "$profile_id"; then
        continue
    fi
    load_profile "$profile_id" || {
        block_profile "$profile_id"
        continue
    }
    attempt_number=$((attempt_number + 1))
    if [ "$tier" = "free" ]; then
        jq -c --arg model "$upstream_model" 'del(.tools,.tool_choice,.parallel_tool_calls,.functions,.function_call) | .model = $model' \
            "$body_file" > "$attempt_body" || {
            last_failure="free route request shaping failed"
            break
        }
    elif [ "$upstream_model" = "openrouter/fusion" ]; then
        jq -c --arg model "$upstream_model" --arg preset "$FUSION_PRESET" \
            '.model = $model |
             .plugins = ((.plugins // []) | map(select((.id // "") != "fusion")) +
                         [{"id":"fusion","preset":$preset}])' \
            "$body_file" > "$attempt_body" || {
            last_failure="Fusion route request shaping failed"
            break
        }
    elif [ "$upstream_model" = "openrouter/auto" ]; then
        jq -c --arg model "$upstream_model" --arg cost_tier "$AUTO_COST_TIER" \
            '.model = $model |
             .plugins = ((.plugins // []) | map(select((.id // "") != "auto-router")) +
                         [{"id":"auto-router","cost_tier":$cost_tier}])' \
            "$body_file" > "$attempt_body" || {
            last_failure="Auto route request shaping failed"
            break
        }
    else
        jq -c --arg model "$upstream_model" '.model = $model' "$body_file" > "$attempt_body" || {
            last_failure="provider route request shaping failed"
            break
        }
    fi
    if reserve_attempt "$profile_id" "$requested_model" "$upstream_model" "$requested_tokens"; then
        reserve_status=0
    else
        reserve_status=$?
    fi
    if [ "$reserve_status" -ne 0 ]; then
        block_profile "$profile_id"
        last_failure="provider profile budget denied"
        continue
    fi
    request_auth_file=$(mktemp)
    chmod 0600 "$request_auth_file"
    printf 'Authorization: Bearer %s\n' "$PROFILE_KEY" > "$request_auth_file"
    response_file_tmp="${response_file}.attempt"
    rm -f "$response_file_tmp"
    curl_status=0
    http_code=""
    if ! http_code=$(curl -sS --connect-timeout 8 --max-time 35 \
        -o "$response_file_tmp" -w '%{http_code}' -X POST "$PROFILE_URL" \
        --header "@${request_auth_file}" \
        -H 'Content-Type: application/json' \
        -H 'HTTP-Referer: https://github.com/Nafjan/zeroclaw-ha-addon' \
        -H 'X-Title: ZeroClaw Home Assistant app' \
        --data-binary "@${attempt_body}" 2>/dev/null); then
        curl_status=1
    fi
    rm -f "$request_auth_file"
    if [ "$curl_status" -ne 0 ]; then
        : > "$response_file"
        settle_attempt "$RESERVATION_ID" "0" "reserved_max_network_failure" "" || \
            respond 503 "Service Unavailable" '{"error":"provider accounting settlement failed"}'
        block_profile "$profile_id"
        last_failure="provider network or timeout failure"
        log_event "provider route=${requested_model} profile=${profile_id} class=network"
        continue
    fi
    mv -f "$response_file_tmp" "$response_file"
    response_size=$(wc -c < "$response_file" | tr -d ' ')
    case "$response_size" in
        ''|*[!0-9]*)
            settle_attempt "$RESERVATION_ID" "0" "reserved_max_invalid_response_size" "" || \
                respond 503 "Service Unavailable" '{"error":"provider accounting settlement failed"}'
            respond 502 "Bad Gateway" '{"error":"provider response size is invalid"}'
            ;;
    esac
    [ "$response_size" -le "$MAX_RESPONSE" ] || {
        settle_attempt "$RESERVATION_ID" "0" "reserved_max_response_too_large" "" || respond 503 "Service Unavailable" '{"error":"provider accounting settlement failed"}'
        respond 502 "Bad Gateway" '{"error":"provider response is too large"}'
    }
    if all_credentials_leak; then
        settle_attempt "$RESERVATION_ID" "0" "reserved_max_credential_leak" "" || respond 503 "Service Unavailable" '{"error":"provider accounting settlement failed"}'
        respond 502 "Bad Gateway" '{"error":"provider response contained broker credential"}'
    fi
    case "$http_code" in
        2[0-9][0-9])
            extract_usage
            case "$USAGE_STATE" in
                valid)
                    settle_attempt "$RESERVATION_ID" "$http_code" "actual_usage" "$USAGE_COMPLETION" || \
                        respond 502 "Bad Gateway" '{"error":"provider accounting settlement failed"}'
                    ;;
                missing)
                    settle_attempt "$RESERVATION_ID" "$http_code" "reserved_max_missing_usage" "" || \
                        respond 502 "Bad Gateway" '{"error":"provider accounting settlement failed"}'
                    ;;
                invalid)
                    settle_attempt "$RESERVATION_ID" "$http_code" "reserved_max_invalid_usage" "999999999" || \
                        respond 502 "Bad Gateway" '{"error":"provider usage accounting is invalid"}'
                    ;;
            esac
            response_body=$(cat "$response_file")
            status_reason "$http_code"
            respond "$http_code" "$STATUS_REASON" "$response_body"
            ;;
        100|300|301|302|303|304|305|307|308)
            settle_attempt "$RESERVATION_ID" "$http_code" "reserved_max_unexpected_status" "" || respond 503 "Service Unavailable" '{"error":"provider accounting settlement failed"}'
            respond 502 "Bad Gateway" '{"error":"provider returned an unexpected response"}'
            ;;
        *)
            classify_failure "$http_code"
            settle_attempt "$RESERVATION_ID" "$http_code" "reserved_max_${FAILURE_CLASS}" "" || \
                respond 503 "Service Unavailable" '{"error":"provider accounting settlement failed"}'
            case "$FAILURE_CLASS" in
                request_rejected)
                    response_body=$(cat "$response_file")
                    status_reason "$http_code"
                    respond "$http_code" "$STATUS_REASON" "$response_body"
                    ;;
                model_unavailable)
                    # A 404 is model-specific rather than a provider-wide
                    # quota/auth failure, so an alternate model on the same
                    # profile remains eligible.  A 402 is recorded separately
                    # so an explicitly configured free route may still use
                    # that profile; 401/429/5xx and network failures block the
                    # profile for every route.
                    last_failure="$FAILURE_CLASS"
                    log_event "provider route=${requested_model} profile=${profile_id} class=${FAILURE_CLASS} status=${http_code}"
                    continue
                    ;;
                *)
                    [ "$FAILURE_CLASS" = "credit_exhausted" ] && mark_credit_exhausted "$profile_id"
                    block_profile "$profile_id"
                    last_failure="$FAILURE_CLASS"
                    log_event "provider route=${requested_model} profile=${profile_id} class=${FAILURE_CLASS} status=${http_code}"
                    continue
                    ;;
            esac
            ;;
    esac
done <<EOF
$route_candidates
EOF

log_event "provider route=${requested_model} class=exhausted reason=${last_failure} attempts=${attempt_number}"
respond 503 "Service Unavailable" '{"error":"all configured provider routes failed"}'
