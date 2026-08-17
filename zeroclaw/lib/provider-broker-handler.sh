#!/bin/sh
# Root-owned OpenAI-compatible model gateway.
#
# In broker mode the planner receives only a dummy local credential.  This
# handler accepts exactly one chat-completions route, validates the JSON
# envelope, and attaches the real provider key on the outbound request.
set -eu

UPSTREAM_URL="${PROVIDER_UPSTREAM_URL:-https://openrouter.ai/api/v1/chat/completions}"
# Bound prompt/input amplification independently of the planner's context
# setting. This is a 256 KiB request cap before the root-side output-token
# reservation is applied.
MAX_BODY=262144
MAX_TOKENS="${PROVIDER_MAX_TOKENS:-2048}"
MAX_REQUESTS_PER_HOUR="${PROVIDER_MAX_REQUESTS_PER_HOUR:-120}"
DAILY_TOKEN_BUDGET="${PROVIDER_DAILY_TOKEN_BUDGET:-100000}"
ALLOWED_MODELS="${PROVIDER_ALLOWED_MODELS:-}"
QUOTA_FILE="${PROVIDER_QUOTA_FILE:-/data/provider/quota.json}"
QUOTA_LOCK="${PROVIDER_QUOTA_LOCK:-/data/provider/.quota.lock}"

respond() {
    status="$1"
    reason="$2"
    body="$3"
    length=$(printf '%s' "$body" | wc -c | tr -d ' ')
    printf 'HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$status" "$reason" "$length" "$body"
    exit 0
}

case "$MAX_TOKENS:$MAX_REQUESTS_PER_HOUR:$DAILY_TOKEN_BUDGET" in
    *[!0-9:]*|:*|*::*)
        respond 503 "Service Unavailable" '{"error":"provider broker limits are invalid"}'
        ;;
esac
[ "$MAX_TOKENS" -ge 1 ] && [ "$MAX_TOKENS" -le "$DAILY_TOKEN_BUDGET" ] || \
    respond 503 "Service Unavailable" '{"error":"provider token limits are invalid"}'

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
trap 'rm -f "$body_file" "$response_file"' EXIT
# BusyBox nc -e supplies the socket as fd 0 but does not expose /dev/stdin.
dd of="$body_file" bs=1 count="$content_length" 2>/dev/null || \
    respond 400 "Bad Request" '{"error":"request body could not be read"}'
[ "$(wc -c < "$body_file" | tr -d ' ')" = "$content_length" ] || \
    respond 400 "Bad Request" '{"error":"request body is incomplete"}'
jq -e 'type == "object" and (.model | type == "string") and (.messages | type == "array")' \
    "$body_file" >/dev/null 2>&1 || \
    respond 400 "Bad Request" '{"error":"chat-completions JSON envelope is invalid"}'
[ -n "${OPENROUTER_KEY:-}" ] || respond 503 "Service Unavailable" '{"error":"provider broker is not configured"}'

model=$(jq -r '.model' "$body_file")
printf '%s\n' "$ALLOWED_MODELS" | tr ',' '\n' | grep -Fx -- "$model" >/dev/null 2>&1 || \
    respond 403 "Forbidden" '{"error":"model is not allowed by the provider broker"}'

requested_tokens=$(jq -r '.max_tokens // 0' "$body_file")
case "$requested_tokens" in
    ''|*[!0-9]*) respond 400 "Bad Request" '{"error":"max_tokens must be a non-negative integer"}' ;;
esac
[ "$requested_tokens" -gt 0 ] || requested_tokens="$MAX_TOKENS"
[ "$requested_tokens" -le "$MAX_TOKENS" ] || \
    respond 400 "Bad Request" '{"error":"max_tokens exceeds the broker limit"}'

# Reserve the requested upper bound before contacting the provider. The lock
# and usage file are root-owned, so planner requests cannot reset the budget or
# race two admissions past the limit. A request that omits max_tokens reserves
# the configured maximum, which is deliberately conservative.
quota_lock_held=0
provider_auth_file=""
cleanup() {
    rm -f "$body_file" "$response_file"
    [ -z "${provider_auth_file:-}" ] || rm -f "$provider_auth_file"
    [ "${quota_lock_held:-0}" -eq 1 ] && rmdir "$QUOTA_LOCK" 2>/dev/null || true
}
trap cleanup EXIT

acquire_quota_lock() {
    attempts=0
    while ! mkdir "$QUOTA_LOCK" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -le 10 ] || respond 503 "Service Unavailable" '{"error":"provider quota is busy"}'
        sleep 1
    done
    quota_lock_held=1
}

reserve_quota() {
    now=$(date -u +%s)
    hour_window=$((now / 3600))
    day_window=$((now / 86400))
    acquire_quota_lock
    if [ -f "$QUOTA_FILE" ]; then
        quota=$(cat "$QUOTA_FILE")
    else
        quota='{}'
    fi
    if ! printf '%s' "$quota" | jq -e 'type == "object"' >/dev/null 2>&1; then
        quota_lock_held=0
        rmdir "$QUOTA_LOCK" 2>/dev/null || true
        respond 503 "Service Unavailable" '{"error":"provider quota state is invalid"}'
    fi
    requests_hour=$(printf '%s' "$quota" | jq -r --argjson w "$hour_window" 'if .hour_window == $w then (.requests_hour // 0) else 0 end')
    tokens_day=$(printf '%s' "$quota" | jq -r --argjson w "$day_window" 'if .day_window == $w then (.tokens_day // 0) else 0 end')
    case "$requests_hour:$tokens_day" in
        *[!0-9:]*|:*)
            quota_lock_held=0
            rmdir "$QUOTA_LOCK" 2>/dev/null || true
            respond 503 "Service Unavailable" '{"error":"provider quota state is invalid"}'
            ;;
    esac
    [ "$requests_hour" -lt "$MAX_REQUESTS_PER_HOUR" ] || {
        quota_lock_held=0
        rmdir "$QUOTA_LOCK" 2>/dev/null || true
        respond 429 "Too Many Requests" '{"error":"provider hourly request budget exceeded"}'
    }
    [ "$tokens_day" -le $((DAILY_TOKEN_BUDGET - requested_tokens)) ] || {
        quota_lock_held=0
        rmdir "$QUOTA_LOCK" 2>/dev/null || true
        respond 429 "Too Many Requests" '{"error":"provider daily token budget exceeded"}'
    }
    quota_tmp="${QUOTA_FILE}.tmp.$$"
    mkdir -p "$(dirname "$QUOTA_FILE")"
    jq -nc --argjson hour "$hour_window" --argjson day "$day_window" \
        --argjson requests "$((requests_hour + 1))" \
        --argjson tokens "$((tokens_day + requested_tokens))" \
        '{hour_window:$hour,requests_hour:$requests,day_window:$day,tokens_day:$tokens}' > "$quota_tmp"
    chmod 0600 "$quota_tmp"
    mv -f "$quota_tmp" "$QUOTA_FILE"
    rmdir "$QUOTA_LOCK"
    quota_lock_held=0
}

reserve_quota

# Do not put the provider credential in curl's argv.  The header file is
# private to this root-owned handler and is removed on exit.
provider_auth_file=$(mktemp)
chmod 0600 "$provider_auth_file"
printf 'Authorization: Bearer %s\n' "$OPENROUTER_KEY" > "$provider_auth_file"

http_code=$(curl -sS --connect-timeout 10 --max-time 120 \
    -o "$response_file" -w '%{http_code}' -X POST "$UPSTREAM_URL" \
    --header "@${provider_auth_file}" \
    -H 'Content-Type: application/json' \
    -H 'HTTP-Referer: https://github.com/Nafjan/zeroclaw-ha-addon' \
    -H 'X-Title: ZeroClaw Home Assistant app' \
    --data-binary "@${body_file}" 2>/dev/null) || \
    respond 502 "Bad Gateway" '{"error":"provider request failed"}'

printf '%s' "$http_code" | grep -Eq '^[0-9]{3}$' || \
    respond 502 "Bad Gateway" '{"error":"provider returned an invalid status"}'
case "$http_code" in
    200) reason="OK" ;;
    201) reason="Created" ;;
    400) reason="Bad Request" ;;
    401) reason="Unauthorized" ;;
    403) reason="Forbidden" ;;
    429) reason="Too Many Requests" ;;
    500) reason="Internal Server Error" ;;
    502) reason="Bad Gateway" ;;
    503) reason="Service Unavailable" ;;
    *) reason="Upstream Response" ;;
esac
if grep -F -- "$OPENROUTER_KEY" "$response_file" >/dev/null 2>&1; then
    respond 502 "Bad Gateway" '{"error":"provider response contained broker credential"}'
fi
response_body=$(cat "$response_file")
respond "$http_code" "$reason" "$response_body"
