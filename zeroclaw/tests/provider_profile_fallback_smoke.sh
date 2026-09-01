#!/bin/sh
# Exercises provider-profile fallback, credit classification, durable settlement,
# and the no-tools free-tier containment rule.
set -eu

PORT_BASE=42636
CASE_INDEX=0
PROXY_PORT=0
OPENROUTER_PORT=0
NVIDIA_PORT=0
PROXY_PID=0
OPENROUTER_PID=0
NVIDIA_PID=0
OPENROUTER_KEY_FILE=/data/provider/openrouter-profile.key
NVIDIA_KEY_FILE=/data/provider/nvidia-profile.key
LEDGER=/data/provider/profile-ledger.json
LOCK=/data/provider/.profile-ledger.lock
PROFILE_DAILY_BUDGET=32768
REPORT_OUTPUT="${PROVIDER_CONTRACT_REPORT_OUTPUT:-/data/provider/provider-contract-report.json}"
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
if [ "${FAKE_DELAY:-0}" -gt 0 ]; then
    sleep "${FAKE_DELAY}"
fi
length=$(printf '%s' "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$FAKE_STATUS" "$FAKE_REASON" "$length" "$body"
UPSTREAM
chmod +x /tmp/provider-profile-fake-upstream

cat > /tmp/provider-profile-credit-then-free-upstream <<'UPSTREAM'
#!/bin/sh
set -eu
STATE_FILE="${SEQUENCE_STATE:?}"
LOG_FILE="${SEQUENCE_LOG:?}"
count=0
[ ! -f "$STATE_FILE" ] || count=$(cat "$STATE_FILE")
count=$((count + 1))
printf '%s\n' "$count" > "$STATE_FILE"
IFS= read -r request_line || exit 0
request_line=$(printf '%s' "$request_line" | tr -d '\r')
printf '%s\n' "$request_line" >> "$LOG_FILE"
content_length=0
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    printf '%s\n' "$header" >> "$LOG_FILE"
    case "$header" in
        Content-Length:*|content-length:*)
            content_length=$(printf '%s' "$header" | cut -d: -f2- | tr -d ' ')
            ;;
    esac
done
if [ "$content_length" -gt 0 ]; then
    dd bs=1 count="$content_length" 2>/dev/null >> "$LOG_FILE"
fi
printf '\n' >> "$LOG_FILE"
if [ "$count" -eq 1 ]; then
    status=402
    reason='Payment Required'
    body='{"error":{"code":"insufficient_quota","message":"credits exhausted"}}'
else
    status=200
    reason='OK'
    body='{"choices":[{"message":{"content":"same-profile-free-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
fi
length=$(printf '%s' "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$status" "$reason" "$length" "$body"
UPSTREAM
chmod +x /tmp/provider-profile-credit-then-free-upstream

# BusyBox nc -l -e may leave a short-lived child listener behind when its
# parent is killed.  Reusing a fixed port can therefore route a later case to
# stale fixture output or fail with EADDRINUSE.  Give each scenario a fresh
# triplet instead; the container is disposable, so bounded port allocation is
# safer than relying on implementation-specific listener teardown.
next_case_ports() {
    PROXY_PORT=$((PORT_BASE + CASE_INDEX * 3))
    OPENROUTER_PORT=$((PROXY_PORT + 1))
    NVIDIA_PORT=$((PROXY_PORT + 2))
    CASE_INDEX=$((CASE_INDEX + 1))
}

start_upstream() {
    upstream_port="$1"
    upstream_status="$2"
    upstream_reason="$3"
    upstream_body="$4"
    upstream_log="$5"
    upstream_delay="${6:-0}"
    if [ "$upstream_port" -eq "$OPENROUTER_PORT" ]; then
        OPENROUTER_PID=0
    else
        NVIDIA_PID=0
    fi
    FAKE_STATUS="$upstream_status" FAKE_REASON="$upstream_reason" \
    FAKE_BODY="$upstream_body" FAKE_LOG="$upstream_log" FAKE_DELAY="$upstream_delay" \
        /bin/busybox nc -l -p "$upstream_port" -s 127.0.0.1 \
        -e /tmp/provider-profile-fake-upstream &
    if [ "$upstream_port" -eq "$OPENROUTER_PORT" ]; then
        OPENROUTER_PID=$!
    else
        NVIDIA_PID=$!
    fi
    sleep 1
}

start_credit_then_free_upstream() {
    sequence_state="$1"
    sequence_log="$2"
    : > "$sequence_state"
    : > "$sequence_log"
    SEQUENCE_STATE="$sequence_state" SEQUENCE_LOG="$sequence_log" \
        /bin/busybox sh -c 'while true; do /bin/busybox nc -l -p "$1" -s 127.0.0.1 -e /tmp/provider-profile-credit-then-free-upstream; done' \
        sh "$OPENROUTER_PORT" &
    OPENROUTER_PID=$!
    sleep 1
}

start_proxy() {
    profile_spec="$1"
    route_spec="$2"
    PROVIDER_PROFILE_SPEC="$profile_spec" PROVIDER_ROUTE_SPEC="$route_spec" \
        PROVIDER_CLIENT_AUTH_TOKEN=provider-client-secret \
        PROVIDER_FALLBACK_ENABLED=true PROVIDER_FREE_FALLBACK_ENABLED=true \
        PROVIDER_FUSION_PRESET=general-budget PROVIDER_AUTO_COST_TIER=medium \
        PROVIDER_MAX_TOKENS=16 PROVIDER_MAX_INPUT_TOKENS="${PROVIDER_MAX_INPUT_TOKENS:-16384}" \
        PROVIDER_DAILY_COST_LIMIT_MICROS="${TEST_PROVIDER_DAILY_COST_LIMIT_MICROS:-100000000}" PROVIDER_MONTHLY_COST_LIMIT_MICROS=1000000000 \
         PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=100000 \
         PROVIDER_LEDGER_FILE="$LEDGER" \
         PROVIDER_LEDGER_LOCK="$LOCK" PROVIDER_LOG_FILE=/data/provider/profile.log \
         PROVIDER_RESERVATION_TTL_SECONDS=180 \
         PROVIDER_TOTAL_TIMEOUT_SECONDS="${TEST_PROVIDER_TOTAL_TIMEOUT_SECONDS:-70}" \
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
        printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
            "$body_length" "$request_body"
    } | /bin/busybox nc -w "${PROVIDER_TEST_CLIENT_TIMEOUT:-15}" 127.0.0.1 "$PROXY_PORT"
}

cleanup() {
    stop_listeners
}
trap cleanup EXIT

rm -f "$LEDGER" "$LOCK" /data/provider/openrouter-credit.log \
    /data/provider/nvidia-success.log /data/provider/free-success.log
NOW=$(date -u +%s)
printf '{"hour_window":%s,"day_window":%s,"requests_hour":1,"tokens_day":40}\n' \
    "$((NOW / 3600))" "$((NOW / 86400))" > "$LEDGER"

next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}
nvidia|http://127.0.0.1:$NVIDIA_PORT/v1/chat/completions|$NVIDIA_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|primary-model|paid
default-route|openrouter|alternate-model|paid
default-route|nvidia|nvidia-model|paid"
start_upstream "$OPENROUTER_PORT" 402 "Payment Required" \
    '{"error":{"code":"insufficient_quota","message":"credits exhausted"}}' \
    /data/provider/openrouter-credit.log
start_upstream "$NVIDIA_PORT" 200 OK \
    '{"choices":[{"message":{"content":"nvidia-fallback-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":3,"total_tokens":4}}' \
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

# A transient 5xx is classified separately from credit exhaustion and can
# reach an explicitly configured alternate profile.
rm -f "$LEDGER" "$LOCK" /data/provider/openrouter-5xx.log \
    /data/provider/nvidia-5xx-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}
nvidia|http://127.0.0.1:$NVIDIA_PORT/v1/chat/completions|$NVIDIA_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|primary-model|paid
default-route|nvidia|nvidia-model|paid"
start_upstream "$OPENROUTER_PORT" 503 "Service Unavailable" \
    '{"error":{"message":"upstream temporarily unavailable"}}' \
    /data/provider/openrouter-5xx.log
start_upstream "$NVIDIA_PORT" 200 OK \
    '{"choices":[{"message":{"content":"nvidia-5xx-fallback-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":3,"total_tokens":4}}' \
    /data/provider/nvidia-5xx-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'nvidia-5xx-fallback-ok' >/dev/null
jq -e '[.records[] | select(.profile_id == "openrouter" and .upstream_model == "primary-model")] | length == 1 and .[0].settlement == "reserved_max_transient"' \
    "$LEDGER" >/dev/null

# A credential failure blocks every later route on the same profile; it is not
# silently treated as a transient or credit-exhaustion fallback.
rm -f "$LEDGER" "$LOCK" /data/provider/openrouter-401.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|auth-primary|paid
default-route|openrouter|auth-alternate|paid"
start_upstream "$OPENROUTER_PORT" 401 Unauthorized \
    '{"error":{"message":"invalid api key"}}' /data/provider/openrouter-401.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
jq -e '[.records[] | select(.profile_id == "openrouter" and .upstream_model == "auth-primary")] | length == 1 and .[0].settlement == "reserved_max_credential_invalid"' \
    "$LEDGER" >/dev/null

# A real upstream timeout/network failure is settled and classified before the
# broker tries to return its fail-closed response.
rm -f "$LEDGER" "$LOCK" /data/provider/openrouter-timeout.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|timeout-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-time-out"}}]}' \
    /data/provider/openrouter-timeout.log 25
TEST_PROVIDER_TOTAL_TIMEOUT_SECONDS=20 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
PROVIDER_TEST_CLIENT_TIMEOUT=30 response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
grep -F 'class=network' /data/provider/profile.log >/dev/null
jq -e '[.records[] | select(.profile_id == "openrouter" and .upstream_model == "timeout-model")] | length == 1 and .[0].settlement == "reserved_max_network_failure"' \
    "$LEDGER" >/dev/null

# A paid OpenRouter credit failure must still reach an explicitly configured
# free route on the same root-owned profile. This is the user-facing
# out-of-credits fallback path, and it remains limited to a no-tools request.
rm -f "$LEDGER" "$LOCK" /data/provider/same-profile-free.state /data/provider/same-profile-free.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|primary-model|paid
default-route|openrouter|nvidia/nemotron-3.5-lightning:free|free"
start_credit_then_free_upstream /data/provider/same-profile-free.state /data/provider/same-profile-free.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"status"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'same-profile-free-ok' >/dev/null
[ "$(cat /data/provider/same-profile-free.state)" = 2 ]
grep -F '"model":"nvidia/nemotron-3.5-lightning:free"' /data/provider/same-profile-free.log >/dev/null

rm -f "$LEDGER" "$LOCK" /data/provider/free-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}
nvidia|http://127.0.0.1:$NVIDIA_PORT/v1/chat/completions|$NVIDIA_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|nvidia|nvidia-model|paid
default-route|openrouter|nvidia/nemotron-3.5-lightning:free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"free-fallback-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/free-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"status"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'free-fallback-ok' >/dev/null
grep -F '"model":"nvidia/nemotron-3.5-lightning:free"' /data/provider/free-success.log >/dev/null
! grep -F '"tools"' /data/provider/free-success.log >/dev/null
! printf '%s' "$response" | grep -F 'openrouter-secret' >/dev/null

rm -f "$LEDGER" "$LOCK" /data/provider/free-router-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|openrouter/free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"free-router-fallback-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/free-router-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"status"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'free-router-fallback-ok' >/dev/null
grep -F '"model":"openrouter/free"' /data/provider/free-router-success.log >/dev/null
! grep -F '"tools"' /data/provider/free-router-success.log >/dev/null
! printf '%s' "$response" | grep -F 'openrouter-secret' >/dev/null

rm -f "$LEDGER" "$LOCK" /data/provider/free-blocked.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|free-model:free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/free-blocked.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"turn on the light"}],"tools":[{"type":"function","function":{"name":"call_service"}}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
[ ! -f /data/provider/free-blocked.log ]

# Legacy OpenAI function-calling fields are also tool-capable. They must not
# be downgraded to a free route when the modern tools field is absent.
rm -f "$LEDGER" "$LOCK" /data/provider/function-blocked.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|free-model:free|free"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/function-blocked.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
FUNCTION_BODY='{"model":"default-route","messages":[{"role":"user","content":"call a function"}],"functions":[{"name":"turn_on","parameters":{"type":"object"}}],"function_call":"auto"}'
response=$(request_proxy "$FUNCTION_BODY")
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
stop_listeners
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/function-blocked.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
FUNCTION_MESSAGE_BODY='{"model":"default-route","messages":[{"role":"assistant","content":null,"function_call":{"name":"turn_on","arguments":"{}"}}]}'
response=$(request_proxy "$FUNCTION_MESSAGE_BODY")
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
[ ! -f /data/provider/function-blocked.log ]

# Router aliases are shaped by the root broker so the planner cannot choose
# a more expensive Fusion preset or an unbounded Auto tier.
rm -f "$LEDGER" "$LOCK" /data/provider/deepseek-latest-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|~deepseek/deepseek-v4-flash-latest|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"deepseek-latest-shaped"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/deepseek-latest-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'deepseek-latest-shaped' >/dev/null
grep -F '"model":"~deepseek/deepseek-v4-flash-latest"' /data/provider/deepseek-latest-success.log >/dev/null

rm -f "$LEDGER" "$LOCK" /data/provider/fusion-success.log /data/provider/auto-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="fusion-route|openrouter|openrouter/fusion|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"fusion-shaped"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/fusion-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"fusion-route","messages":[{"role":"user","content":"compare"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
grep -F '"model":"openrouter/fusion"' /data/provider/fusion-success.log >/dev/null
grep -F '"id":"fusion"' /data/provider/fusion-success.log >/dev/null
grep -F '"preset":"general-budget"' /data/provider/fusion-success.log >/dev/null

rm -f "$LEDGER" "$LOCK"
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="auto-route|openrouter|openrouter/auto|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"auto-shaped"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/auto-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"auto-route","messages":[{"role":"user","content":"plan"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
grep -F '"model":"openrouter/auto"' /data/provider/auto-success.log >/dev/null
grep -F '"id":"auto-router"' /data/provider/auto-success.log >/dev/null
grep -F '"cost_tier":"medium"' /data/provider/auto-success.log >/dev/null

# The configured complex paid fallback is also bound to the root OpenRouter
# profile and must be shaped as the exact upstream model ID.
rm -f "$LEDGER" "$LOCK" /data/provider/pro-model-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="complex-route|openrouter|deepseek/deepseek-v4-pro|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"pro-model-shaped"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/pro-model-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"complex-route","messages":[{"role":"user","content":"reason"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'pro-model-shaped' >/dev/null
grep -F '"model":"deepseek/deepseek-v4-pro"' /data/provider/pro-model-success.log >/dev/null

# The root broker must reject an oversized input estimate before contacting an
# upstream.  This protects both provider spend and the durable token budget.
rm -f "$LEDGER" "$LOCK" /data/provider/input-limit.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="input-limit-route|openrouter|input-limit-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/input-limit.log
PROVIDER_MAX_INPUT_TOKENS=1024 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
large_content=$(head -c 5000 /dev/zero | tr '\0' x)
large_body=$(jq -nc --arg content "$large_content" \
    '{model:"input-limit-route",messages:[{role:"user",content:$content}]}' )
response=$(request_proxy "$large_body")
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 400 Bad Request' >/dev/null
printf '%s' "$response" | grep -F 'provider input token estimate exceeds the broker limit' >/dev/null
[ ! -f /data/provider/input-limit.log ]

# The root broker must reject fan-out requests instead of forwarding n>1 while
# reserving only one completion budget.
rm -f "$LEDGER" "$LOCK" /data/provider/n-invalid.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="n-invalid-route|openrouter|n-invalid-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/n-invalid.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
n_invalid_response=$(request_proxy '{"model":"n-invalid-route","messages":[{"role":"user","content":"hello"}],"n":2}')
stop_listeners
printf '%s' "$n_invalid_response" | grep -F 'HTTP/1.1 400 Bad Request' >/dev/null
[ ! -f /data/provider/n-invalid.log ]

# The estimate must also leave room for provider tokenizer overhead.  The
# fake upstream reports more prompt tokens than the old bytes/4 heuristic but
# less than the conservative reservation above; a valid response must remain
# successful and settle the prompt usage durably.
rm -f "$LEDGER" "$LOCK" /data/provider/input-overhead.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|2000"
ROUTE_SPEC="input-overhead-route|openrouter|input-overhead-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"input-overhead-ok"}}],"usage":{"prompt_tokens":260,"completion_tokens":1,"total_tokens":261}}' \
    /data/provider/input-overhead.log
PROVIDER_MAX_INPUT_TOKENS=1024 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
overhead_content=$(head -c 800 /dev/zero | tr '\0' x)
overhead_body=$(jq -nc --arg content "$overhead_content" \
    '{model:"input-overhead-route",messages:[{role:"user",content:$content}]}' )
response=$(request_proxy "$overhead_body")
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'input-overhead-ok' >/dev/null
jq -e '[.records[] | select(.upstream_model == "input-overhead-model" and .settled_input_tokens == 260)] | length == 1' \
    "$LEDGER" >/dev/null

# Dollar limits are enforced by the root broker before the upstream call. A
# request whose conservative reservation exceeds the configured daily cap
# must not spend provider credits or contact the upstream.
rm -f "$LEDGER" "$LOCK" /data/provider/cost-limit.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="cost-limit-route|openrouter|cost-limit-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/cost-limit.log
TEST_PROVIDER_DAILY_COST_LIMIT_MICROS=10000 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
cost_limit_response=$(request_proxy '{"model":"cost-limit-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$cost_limit_response" | grep -F 'HTTP/1.1 429 Too Many Requests' >/dev/null
[ ! -f /data/provider/cost-limit.log ]

suite_sha256=$(sha256sum "$0" | awk '{print $1}')
ledger_sha256=$(sha256sum "$LEDGER" | awk '{print $1}')
tested_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
report_tmp="${REPORT_OUTPUT}.tmp.$$"
jq -n \
    --arg candidate_commit "${CANARY_CANDIDATE_COMMIT:-}" \
    --arg tested_at "$tested_at" \
    --arg suite_sha256 "$suite_sha256" \
    --arg ledger_sha256 "$ledger_sha256" \
    '{
      schema_version: 1,
      status: "passed",
      candidate_commit: $candidate_commit,
      tested_at: $tested_at,
      suite: {name: "provider_profile_fallback_smoke.sh", sha256: $suite_sha256},
      routes: {
        primary: {profile: "openrouter", model: "~deepseek/deepseek-v4-flash-latest", tier: "paid"},
        complex: {profile: "openrouter", model: "openrouter/fusion", tier: "paid", preset: "general-budget"},
        complex_auto: {profile: "openrouter", model: "openrouter/auto", tier: "paid", cost_tier: "medium"},
        complex_pro: {profile: "openrouter", model: "deepseek/deepseek-v4-pro", tier: "paid"},
        free_model: {profile: "openrouter", model: "nvidia/nemotron-3.5-lightning:free", tier: "free"},
        free_router: {profile: "openrouter", model: "openrouter/free", tier: "free"}
      },
      classification: {
        credit_exhausted_402: true,
        network_timeout: true,
        transient_5xx: true,
        credential_401_blocks_same_profile_fallback: true
      },
      safety: {
        free_route_no_tools_only: true,
        tool_capable_never_free: true
      },
      accounting: {
        reservation_recorded: true,
        success_settlement_recorded: true,
        failure_settlement_recorded: true,
        budget_denied_before_upstream: true,
        ledger_schema: 1,
        ledger_sha256: $ledger_sha256
      }
    }' > "$report_tmp"
chmod 0640 "$report_tmp"
mv -f "$report_tmp" "$REPORT_OUTPUT"

echo 'provider profile fallback smoke passed'
