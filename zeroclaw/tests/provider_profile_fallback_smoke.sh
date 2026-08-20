#!/bin/sh
# Exercises provider-profile fallback, credit classification, durable settlement,
# and the no-tools free-tier containment rule.
set -eu

PROXY_PORT=42636
OPENROUTER_PORT=42637
NVIDIA_PORT=42638
PROXY_PID=0
OPENROUTER_PID=0
NVIDIA_PID=0
OPENROUTER_KEY_FILE=/data/provider/openrouter-profile.key
NVIDIA_KEY_FILE=/data/provider/nvidia-profile.key
LEDGER=/data/provider/profile-ledger.json
LOCK=/data/provider/.profile-ledger.lock
mkdir -p /data/provider
install -m 0755 /opt/zeroclaw/lib/provider-broker-handler.sh /usr/local/bin/provider-broker-handler
install -m 0755 /opt/zeroclaw/lib/provider-broker-entrypoint.sh /usr/local/bin/provider-broker-entrypoint
printf '%s' openrouter-secret > "$OPENROUTER_KEY_FILE"
printf '%s' nvidia-secret > "$NVIDIA_KEY_FILE"
chmod 0600 "$OPENROUTER_KEY_FILE" "$NVIDIA_KEY_FILE"

cat > /tmp/provider-profile-fake-upstream <<'UPSTREAM'
#!/bin/sh
set -eu
IFS= read -r request_line || exit 0
request_line=$(printf '%s' "$request_line" | tr -d '\r')
log_file="${FAKE_LOG:-/data/provider/missing.log}"
: > "$log_file"
printf '%s\n' "$request_line" >> "$log_file"
content_length=0
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    printf '%s\n' "$header" >> "$log_file"
    case "$header" in
        Content-Length:*|content-length:*)
            content_length=$(printf '%s' "$header" | cut -d: -f2- | tr -d ' ')
            ;;
    esac
done
if [ "$content_length" -gt 0 ]; then
    dd bs=1 count="$content_length" 2>/dev/null >> "$log_file"
fi
printf '\n' >> "$log_file"
body="${FAKE_BODY:-}"
[ -n "$body" ] || body='{"error":"fake failure"}'
length=$(printf '%s' "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$FAKE_STATUS" "$FAKE_REASON" "$length" "$body"
UPSTREAM
chmod +x /tmp/provider-profile-fake-upstream

start_upstream() {
    upstream_port="$1"
    upstream_status="$2"
    upstream_reason="$3"
    upstream_body="$4"
    upstream_log="$5"
    if [ "$upstream_port" -eq "$OPENROUTER_PORT" ]; then
        OPENROUTER_PID=0
    else
        NVIDIA_PID=0
    fi
    FAKE_STATUS="$upstream_status" FAKE_REASON="$upstream_reason" \
        FAKE_BODY="$upstream_body" FAKE_LOG="$upstream_log" \
        /bin/busybox nc -l -p "$upstream_port" -s 127.0.0.1 \
        -e /tmp/provider-profile-fake-upstream &
    if [ "$upstream_port" -eq "$OPENROUTER_PORT" ]; then
        OPENROUTER_PID=$!
    else
        NVIDIA_PID=$!
    fi
    sleep 1
}

start_proxy() {
    profile_spec="$1"
    route_spec="$2"
    PROVIDER_PROFILE_SPEC="$profile_spec" PROVIDER_ROUTE_SPEC="$route_spec" \
        PROVIDER_FALLBACK_ENABLED=true PROVIDER_FREE_FALLBACK_ENABLED=true \
        PROVIDER_MAX_TOKENS=16 PROVIDER_LEDGER_FILE="$LEDGER" \
        PROVIDER_LEDGER_LOCK="$LOCK" PROVIDER_LOG_FILE=/data/provider/profile.log \
        PROVIDER_RESERVATION_TTL_SECONDS=180 \
        /bin/busybox nc -l -p "$PROXY_PORT" -s 127.0.0.1 \
        -e /usr/local/bin/provider-broker-entrypoint &
    PROXY_PID=$!
    sleep 1
}

stop_listeners() {
    for pid in "$PROXY_PID" "$OPENROUTER_PID" "$NVIDIA_PID"; do
        if [ "$pid" -gt 0 ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    PROXY_PID=0
    OPENROUTER_PID=0
    NVIDIA_PID=0
}

request_proxy() {
    request_body="$1"
    body_length=$(printf '%s' "$request_body" | wc -c | tr -d ' ')
    {
        printf 'POST /v1/chat/completions HTTP/1.1\r\n'
        printf 'Host: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
            "$body_length" "$request_body"
    } | /bin/busybox nc -w 15 127.0.0.1 "$PROXY_PORT"
}

cleanup() {
    stop_listeners
}
trap cleanup EXIT

rm -f "$LEDGER" "$LOCK" /data/provider/openrouter-credit.log \
    /data/provider/nvidia-success.log /data/provider/free-success.log
NOW=$(date -u +%s)
printf '{"hour_window":%s,"day_window":%s,"requests_hour":1,"tokens_day":84}\n' \
    "$((NOW / 3600))" "$((NOW / 86400))" > "$LEDGER"

PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|100
nvidia|http://127.0.0.1:$NVIDIA_PORT/v1/chat/completions|$NVIDIA_KEY_FILE|10|100"
ROUTE_SPEC="default-route|openrouter|primary-model|paid
default-route|openrouter|alternate-model|paid
default-route|nvidia|nvidia-model|paid"
start_upstream "$OPENROUTER_PORT" 402 "Payment Required" \
    '{"error":{"code":"insufficient_quota","message":"credits exhausted"}}' \
    /data/provider/openrouter-credit.log
start_upstream "$NVIDIA_PORT" 200 OK \
    '{"choices":[{"message":{"content":"nvidia-fallback-ok"}}],"usage":{"completion_tokens":3,"total_tokens":3}}' \
    /data/provider/nvidia-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'nvidia-fallback-ok' >/dev/null
grep -F '"model":"nvidia-model"' /data/provider/nvidia-success.log >/dev/null
grep -F 'Authorization: Bearer nvidia-secret' /data/provider/nvidia-success.log >/dev/null
grep -F 'Authorization: Bearer openrouter-secret' /data/provider/openrouter-credit.log >/dev/null
! printf '%s' "$response" | grep -F 'nvidia-secret' >/dev/null
! printf '%s' "$response" | grep -F 'openrouter-secret' >/dev/null
jq -e '[.records[] | select(.settlement == "migrated_reserved_max")] | length == 1' \
    "$LEDGER" >/dev/null
jq -e '[.records[] | select(.profile_id == "openrouter" and .upstream_model == "primary-model")] | length == 1 and .[0].settlement == "reserved_max_credit_exhausted"' \
    "$LEDGER" >/dev/null
jq -e '[.records[] | select(.profile_id == "nvidia")] | length == 1 and .[0].settled_tokens == 3' \
    "$LEDGER" >/dev/null

rm -f "$LEDGER" "$LOCK" /data/provider/free-success.log
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|100
nvidia|http://127.0.0.1:$NVIDIA_PORT/v1/chat/completions|$NVIDIA_KEY_FILE|10|100"
ROUTE_SPEC="default-route|nvidia|nvidia-model|paid
default-route|openrouter|free-model:free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"free-fallback-ok"}}],"usage":{"completion_tokens":1,"total_tokens":1}}' \
    /data/provider/free-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"status"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'free-fallback-ok' >/dev/null
grep -F '"model":"free-model:free"' /data/provider/free-success.log >/dev/null
! grep -F '"tools"' /data/provider/free-success.log >/dev/null
! printf '%s' "$response" | grep -F 'openrouter-secret' >/dev/null

rm -f "$LEDGER" "$LOCK" /data/provider/free-blocked.log
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|100"
ROUTE_SPEC="default-route|openrouter|free-model:free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"completion_tokens":1,"total_tokens":1}}' \
    /data/provider/free-blocked.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"turn on the light"}],"tools":[{"type":"function","function":{"name":"call_service"}}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
[ ! -f /data/provider/free-blocked.log ]

# Legacy OpenAI function-calling fields are also tool-capable. They must not
# be downgraded to a free route when the modern tools field is absent.
rm -f "$LEDGER" "$LOCK" /data/provider/function-blocked.log
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|100"
ROUTE_SPEC="default-route|openrouter|free-model:free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"completion_tokens":1,"total_tokens":1}}' \
    /data/provider/function-blocked.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
FUNCTION_BODY='{"model":"default-route","messages":[{"role":"user","content":"call a function"}],"functions":[{"name":"turn_on","parameters":{"type":"object"}}],"function_call":"auto"}'
response=$(request_proxy "$FUNCTION_BODY")
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
stop_listeners
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"completion_tokens":1,"total_tokens":1}}' \
    /data/provider/function-blocked.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
FUNCTION_MESSAGE_BODY='{"model":"default-route","messages":[{"role":"assistant","content":null,"function_call":{"name":"turn_on","arguments":"{}"}}]}'
response=$(request_proxy "$FUNCTION_MESSAGE_BODY")
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
[ ! -f /data/provider/function-blocked.log ]

echo 'provider profile fallback smoke passed'
