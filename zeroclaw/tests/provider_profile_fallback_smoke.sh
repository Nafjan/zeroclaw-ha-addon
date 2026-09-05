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
CURRENT_CHECK=setup
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
if [ -n "${FAKE_REFLECT_VALUE:-}" ]; then
    reflected_value=$(printf '%s' "$FAKE_REFLECT_VALUE" | base64 | tr -d '\r\n')
    body=$(jq -nc --arg reflected "$reflected_value" \
        '{choices:[{message:{content:$reflected}}],usage:{prompt_tokens:1,completion_tokens:1,total_tokens:2}}')
fi
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
    rm -f /data/provider/profile-client-rate.json \
        /data/provider/.profile-client-rate.lock
}

start_upstream() {
    upstream_port="$1"
    upstream_status="$2"
    upstream_reason="$3"
    upstream_body="$4"
    upstream_log="$5"
    upstream_delay="${6:-0}"
    upstream_reflect_value="${7:-}"
    if [ "$upstream_port" -eq "$OPENROUTER_PORT" ]; then
        OPENROUTER_PID=0
    else
        NVIDIA_PID=0
    fi
    FAKE_STATUS="$upstream_status" FAKE_REASON="$upstream_reason" \
    FAKE_BODY="$upstream_body" FAKE_LOG="$upstream_log" FAKE_DELAY="$upstream_delay" \
    FAKE_REFLECT_VALUE="$upstream_reflect_value" \
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
    # BusyBox ash may retain an assignment preceding a shell function after
    # the function returns. Capture each per-case override and clear it before
    # launching the background listener so a narrow test fixture cannot alter
    # every later provider case in this process.
    profile_max_requests="${TEST_PROVIDER_MAX_REQUESTS_PER_HOUR:-120}"
    profile_client_requests="${TEST_PROVIDER_CLIENT_REQUESTS_PER_HOUR:-120}"
    profile_input_tokens="${PROVIDER_MAX_INPUT_TOKENS:-16384}"
    profile_daily_cost_limit="${TEST_PROVIDER_DAILY_COST_LIMIT_MICROS:-100000000}"
    profile_monthly_cost_limit="${TEST_PROVIDER_MONTHLY_COST_LIMIT_MICROS:-1000000000}"
    profile_total_timeout="${TEST_PROVIDER_TOTAL_TIMEOUT_SECONDS:-70}"
    unset TEST_PROVIDER_MAX_REQUESTS_PER_HOUR TEST_PROVIDER_CLIENT_REQUESTS_PER_HOUR \
        PROVIDER_MAX_INPUT_TOKENS TEST_PROVIDER_DAILY_COST_LIMIT_MICROS \
        TEST_PROVIDER_MONTHLY_COST_LIMIT_MICROS TEST_PROVIDER_TOTAL_TIMEOUT_SECONDS
    PROVIDER_PROFILE_SPEC="$profile_spec" PROVIDER_ROUTE_SPEC="$route_spec" \
        PROVIDER_CLIENT_AUTH_TOKEN=provider-client-secret \
        PROVIDER_HEALTH_CLIENT_AUTH_TOKEN=provider-health-secret \
        PROVIDER_FALLBACK_ENABLED=true PROVIDER_FREE_FALLBACK_ENABLED=true \
        PROVIDER_FUSION_PRESET=general-budget PROVIDER_AUTO_COST_TIER=medium \
        PROVIDER_MAX_TOKENS=16 PROVIDER_MAX_INPUT_TOKENS="$profile_input_tokens" \
        PROVIDER_MAX_REQUESTS_PER_HOUR="$profile_max_requests" \
        PROVIDER_CLIENT_REQUESTS_PER_HOUR="$profile_client_requests" \
        PROVIDER_DAILY_COST_LIMIT_MICROS="$profile_daily_cost_limit" PROVIDER_MONTHLY_COST_LIMIT_MICROS="$profile_monthly_cost_limit" \
         PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=100000 \
         PROVIDER_LEDGER_FILE="$LEDGER" \
         PROVIDER_LEDGER_LOCK="$LOCK" PROVIDER_LOG_FILE=/data/provider/profile.log \
         PROVIDER_CLIENT_RATE_FILE=/data/provider/profile-client-rate.json \
         PROVIDER_CLIENT_RATE_LOCK=/data/provider/.profile-client-rate.lock \
         PROVIDER_COST_DEGRADED_FILE=/data/provider/cost-degraded \
         PROVIDER_RESERVATION_TTL_SECONDS=180 \
         PROVIDER_TOTAL_TIMEOUT_SECONDS="$profile_total_timeout" \
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
    request_auth="${2:-provider-client-secret}"
    body_length=$(printf '%s' "$request_body" | wc -c | tr -d ' ')
    {
        printf 'POST /v1/chat/completions HTTP/1.1\r\n'
        printf 'Host: 127.0.0.1\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
            "$request_auth" "$body_length" "$request_body"
    } | /bin/busybox nc -w "${PROVIDER_TEST_CLIENT_TIMEOUT:-15}" 127.0.0.1 "$PROXY_PORT"
}

request_provider_health() {
    request_auth="$1"
    {
        printf 'GET /health HTTP/1.1\r\n'
        printf 'Host: 127.0.0.1\r\nAuthorization: Bearer %s\r\n\r\n' "$request_auth"
    } | /bin/busybox nc -w "${PROVIDER_TEST_CLIENT_TIMEOUT:-15}" 127.0.0.1 "$PROXY_PORT"
}

cleanup() {
    stop_listeners
    rm -f /data/provider/cost-degraded
}
trap 'status=$?; trap - EXIT; if [ "$status" -ne 0 ]; then
    printf "provider profile fallback smoke failed (status %s, check %s)\n" "$status" "${CURRENT_CHECK-unknown}" >&2
    for diagnostic_file in /data/provider/profile.log /data/provider/profile-ledger.json; do
        if [ -f "$diagnostic_file" ]; then
            echo "--- ${diagnostic_file} ---" >&2
            tail -80 "$diagnostic_file" 2>/dev/null |
                sed -E "s/(Bearer )[[:graph:]]+/\\1[redacted]/g; s/(openrouter|nvidia)-secret/[redacted]/g" >&2 || true
        fi
    done
fi; cleanup; exit "$status"' EXIT

CURRENT_CHECK=initial-credit-fallback
rm -f "$LEDGER" "$LOCK" /data/provider/openrouter-credit.log \
    /data/provider/nvidia-success.log /data/provider/free-success.log
NOW=$(date -u +%s)
printf '{"hour_window":%s,"day_window":%s,"requests_hour":1,"tokens_day":40}\n' \
    "$((NOW / 3600))" "$((NOW / 86400))" > "$LEDGER"

# The protected provider health endpoint must prove the handler is serving,
# without contacting an upstream or consuming a client/provider budget slot.
CURRENT_CHECK=authenticated-provider-health
rm -f "$LOCK"
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="health-route|openrouter|health-model|paid"
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
health_response=$(request_provider_health provider-health-secret)
stop_listeners

# BusyBox nc -l handles one connection and exits. Keep each assertion on a
# fresh listener so the health contract is tested independently rather than
# depending on a multi-request listener implementation.
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
planner_health_response=$(request_provider_health provider-client-secret)
stop_listeners

next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
health_chat_response=$(request_proxy '{"model":"health-model","messages":[{"role":"user","content":"health credential must not chat"}]}' provider-health-secret)
stop_listeners
printf '%s' "$health_response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$health_response" | grep -F '{"status":"ok"}' >/dev/null
printf '%s' "$planner_health_response" | grep -F 'HTTP/1.1 401 Unauthorized' >/dev/null
printf '%s' "$health_chat_response" | grep -F 'HTTP/1.1 401 Unauthorized' >/dev/null
[ ! -e /data/provider/profile-client-rate.json ]

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
jq -e '[.records[] | select(.profile_id == "nvidia")] | length == 1 and .[0].settled_tokens == 16 and .[0].settled_input_tokens == 328 and .[0].usage_floor == true' \
    "$LEDGER" >/dev/null

# The hourly request ceiling is global to the provider ledger, not a separate
# allowance per profile. A failed primary must therefore prevent a fallback
# attempt when the single global slot is already consumed.
CURRENT_CHECK=global-hour-admission
rm -f "$LEDGER" "$LOCK" /data/provider/global-hour-primary.log /data/provider/global-hour-fallback.log
next_case_ports
# Seed an already-settled request in the current global hour. This keeps the
# admission test deterministic even if a disposable BusyBox listener from the
# preceding case takes a moment to exit; the scenario is specifically about a
# consumed global slot preventing every later profile, not about re-testing
# failed-request settlement.
global_hour_now=$(date -u +%s)
jq -nc --argjson now "$global_hour_now" --argjson hour "$((global_hour_now / 3600))" \
    --argjson day "$((global_hour_now / 86400))" --arg month "$(date -u +%Y-%m)" \
    '{schema:1,records:[{id:"seed-global-hour",created_at:$now,expires_at:($now + 180),
      hour_window:$hour,day_window:$day,month_window:$month,route_id:"seed",
      profile_id:"openrouter",upstream_model:"seed-model",reserved_tokens:16,
      reserved_input_tokens:328,settled_tokens:16,settled_input_tokens:328,
      reserved_cost_micros:34400,settled_cost_micros:34400,state:"settled",
      settlement:"seeded_global_hour",updated_at:$now}],profile_quarantine:[]}' > "$LEDGER"
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}
nvidia|http://127.0.0.1:$NVIDIA_PORT/v1/chat/completions|$NVIDIA_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="global-hour-route|openrouter|global-hour-primary|paid
global-hour-route|nvidia|global-hour-fallback|paid"
start_upstream "$OPENROUTER_PORT" 402 "Payment Required" \
    '{"error":{"code":"insufficient_quota","message":"credits exhausted"}}' \
    /data/provider/global-hour-primary.log
start_upstream "$NVIDIA_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}]}' \
    /data/provider/global-hour-fallback.log
TEST_PROVIDER_MAX_REQUESTS_PER_HOUR=1 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
global_hour_response=$(request_proxy '{"model":"global-hour-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$global_hour_response" | grep -F 'HTTP/1.1 429 Too Many Requests' >/dev/null
[ ! -f /data/provider/global-hour-fallback.log ]
jq -e '[.records[] | select(.hour_window == (now / 3600 | floor))] | length == 1' "$LEDGER" >/dev/null

# A transient 5xx is classified separately from credit exhaustion and can
# reach an explicitly configured alternate profile.
CURRENT_CHECK=transient-5xx-fallback
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
CURRENT_CHECK=credential-invalid-block
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
CURRENT_CHECK=network-timeout
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
CURRENT_CHECK=same-profile-free-fallback
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

CURRENT_CHECK=cross-profile-free-fallback
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

CURRENT_CHECK=free-router-fallback
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

# Root-accounted cost degradation must be enforced by the provider broker, not
# merely announced by the watchdog. Paid routes are skipped and an explicit
# no-tools free route is still eligible.
CURRENT_CHECK=cost-degraded-paid-route
rm -f "$LEDGER" "$LOCK" /data/provider/cost-degraded /data/provider/cost-degraded-success.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="default-route|openrouter|paid-model|paid
default-route|openrouter|openrouter/free|free"
touch /data/provider/cost-degraded
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"cost-degraded-free-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' \
    /data/provider/cost-degraded-success.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"default-route","messages":[{"role":"user","content":"status"}]}')
stop_listeners
rm -f /data/provider/cost-degraded
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'cost-degraded-free-ok' >/dev/null
grep -F '"model":"openrouter/free"' /data/provider/cost-degraded-success.log >/dev/null
! grep -F '"model":"paid-model"' /data/provider/cost-degraded-success.log >/dev/null

CURRENT_CHECK=tool-capable-free-block
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
CURRENT_CHECK=legacy-function-free-block
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
CURRENT_CHECK=router-alias-shaping
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
CURRENT_CHECK=complex-paid-model-shaping
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

# The root broker must reject an input whose raw byte size cannot fit within the
# conservative byte-for-token reservation before contacting an upstream. This
# protects both provider spend and the durable token budget.
CURRENT_CHECK=input-limit
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
printf '%s' "$response" | grep -F 'HTTP/1.1 413 Payload Too Large' >/dev/null
printf '%s' "$response" | grep -F 'provider input is too large' >/dev/null
[ ! -f /data/provider/input-limit.log ]

# Exercise the real near-boundary default instead of only a reduced fixture
# limit. The complete JSON envelope must fit under the 65,536-token admission
# ceiling and still reach the upstream.
CURRENT_CHECK=input-boundary
rm -f "$LEDGER" "$LOCK" /data/provider/input-boundary.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|200000"
ROUTE_SPEC="input-boundary-route|openrouter|input-boundary-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"input-boundary-ok"}}]}' \
    /data/provider/input-boundary.log
PROVIDER_MAX_INPUT_TOKENS=65536 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
boundary_content=$(head -c 64800 /dev/zero | tr '\0' x)
boundary_body=$(jq -nc --arg content "$boundary_content" \
    '{model:"input-boundary-route",messages:[{role:"user",content:$content}]}' )
response=$(request_proxy "$boundary_body")
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'input-boundary-ok' >/dev/null
jq -e '[.records[] | select(.upstream_model == "input-boundary-model" and .reserved_input_tokens >= 65000 and .reserved_input_tokens <= 65536)] | length == 1' \
    "$LEDGER" >/dev/null

# The root broker must reject fan-out requests instead of forwarding n>1 while
# reserving only one completion budget.
CURRENT_CHECK=fanout-rejection
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

# The byte-for-token reservation must leave room for provider tokenizer
# overhead. The fake upstream reports more prompt tokens than the old bytes/4
# heuristic but less than the conservative reservation above; a valid response
# must remain successful and settle the prompt usage durably.
CURRENT_CHECK=input-overhead
rm -f "$LEDGER" "$LOCK" /data/provider/input-overhead.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|2000"
ROUTE_SPEC="input-overhead-route|openrouter|input-overhead-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"input-overhead-ok"}}],"usage":{"prompt_tokens":260,"completion_tokens":1,"total_tokens":261}}' \
    /data/provider/input-overhead.log
PROVIDER_MAX_INPUT_TOKENS=1024 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
overhead_content=$(head -c 400 /dev/zero | tr '\0' x)
overhead_body=$(jq -nc --arg content "$overhead_content" \
    '{model:"input-overhead-route",messages:[{role:"user",content:$content}]}' )
response=$(request_proxy "$overhead_body")
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'input-overhead-ok' >/dev/null
jq -e '[.records[] | select(.upstream_model == "input-overhead-model" and .settled_input_tokens >= 260 and .settled_tokens == 16)] | length == 1' \
    "$LEDGER" >/dev/null

# A compromised upstream must not be able to reflect a provider credential in
# an encoded form. Exercise the real response scanner with a base64 payload and
# require a bounded failure settlement before the response leaves the broker.
CURRENT_CHECK=encoded-credential-reflection
rm -f "$LEDGER" "$LOCK" /data/provider/encoded-reflection.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="encoded-reflection-route|openrouter|encoded-reflection-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"unused"}}]}' \
    /data/provider/encoded-reflection.log 0 openrouter-secret
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
encoded_reflection_response=$(request_proxy '{"model":"encoded-reflection-route","messages":[{"role":"user","content":"hello"}]}' )
stop_listeners
printf '%s' "$encoded_reflection_response" | grep -F 'HTTP/1.1 502 Bad Gateway' >/dev/null
! printf '%s' "$encoded_reflection_response" | grep -F 'openrouter-secret' >/dev/null
jq -e '[.records[] | select(.profile_id == "openrouter" and .settlement == "reserved_max_credential_leak")] | length == 1' \
    "$LEDGER" >/dev/null

# Provider usage is telemetry, not permission to release a durable reservation.
# A successful response that under-reports both dimensions remains charged at
# least the admitted input/output reservation.
CURRENT_CHECK=usage-floor
rm -f "$LEDGER" "$LOCK" /data/provider/usage-floor.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|2000"
ROUTE_SPEC="usage-floor-route|openrouter|usage-floor-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"usage-floor-ok"}}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}' \
    /data/provider/usage-floor.log
PROVIDER_MAX_INPUT_TOKENS=1024 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"usage-floor-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'usage-floor-ok' >/dev/null
jq -e '[.records[] | select(.upstream_model == "usage-floor-model" and .usage_floor == true and .settled_input_tokens > 0 and .settled_tokens == 16)] | length == 1' \
    "$LEDGER" >/dev/null

# Monthly cost accounting must retain current-month settlements even when their
# day window is older than the short token/log retention horizon.
CURRENT_CHECK=monthly-ledger-retention
rm -f "$LEDGER" "$LOCK" /data/provider/monthly-retention.log
next_case_ports
retention_now=$(date -u +%s)
retention_day=$((retention_now / 86400 - 8))
retention_hour=$((retention_now / 3600 - 192))
retention_month=$(date -u +%Y-%m)
jq -nc --argjson now "$retention_now" --argjson day "$retention_day" \
    --argjson hour "$retention_hour" --arg month "$retention_month" \
    '{schema:1,records:[{id:"month-retention-seed",created_at:($now - 691200),
      expires_at:($now - 691000),hour_window:$hour,day_window:$day,month_window:$month,
      route_id:"seed",profile_id:"openrouter",upstream_model:"seed-model",
      reserved_tokens:16,reserved_input_tokens:328,settled_tokens:16,
      settled_input_tokens:328,reserved_cost_micros:100000,settled_cost_micros:100000,
      state:"settled",settlement:"seeded_month_retention",updated_at:($now - 691200)}],
      profile_quarantine:[]}' > "$LEDGER"
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|2000"
ROUTE_SPEC="monthly-retention-route|openrouter|monthly-retention-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"must-not-run"}}]}' \
    /data/provider/monthly-retention.log
TEST_PROVIDER_DAILY_COST_LIMIT_MICROS=1000000 TEST_PROVIDER_MONTHLY_COST_LIMIT_MICROS=100000 \
    PROVIDER_MAX_INPUT_TOKENS=1024 \
    start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"monthly-retention-route","messages":[{"role":"user","content":"hello"}]}')
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 429 Too Many Requests' >/dev/null
[ ! -f /data/provider/monthly-retention.log ]
jq -e '[.records[] | select(.id == "month-retention-seed" and .month_window == (now | strftime("%Y-%m")))] | length == 1' \
    "$LEDGER" >/dev/null

# A provider that exceeds the admitted completion/input reservation is a hard
# anomaly.  Quarantine the profile durably so a fresh broker connection cannot
# immediately retry against the same untrusted accounting boundary.
CURRENT_CHECK=accounting-overrun-quarantine
rm -f "$LEDGER" "$LOCK" /data/provider/overrun.log /data/provider/overrun-second.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|2000"
ROUTE_SPEC="overrun-route|openrouter|overrun-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"overrun"}}],"usage":{"prompt_tokens":1,"completion_tokens":32,"total_tokens":33}}' \
    /data/provider/overrun.log
PROVIDER_MAX_INPUT_TOKENS=1024 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
overrun_response=$(request_proxy '{"model":"overrun-route","messages":[{"role":"user","content":"hello"}]}' )
stop_listeners
printf '%s' "$overrun_response" | grep -F 'HTTP/1.1 503 Service Unavailable' >/dev/null
jq -e '[.records[] | select(.profile_id == "openrouter" and .settlement == "usage_overrun")] | length == 1' \
    "$LEDGER" >/dev/null
jq -e '.profile_quarantine | any(.[]; .profile_id == "openrouter" and .reason == "usage_overrun" and .until > now)' \
    "$LEDGER" >/dev/null

next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|2000"
ROUTE_SPEC="overrun-route|openrouter|overrun-second-model|paid"
PROVIDER_MAX_INPUT_TOKENS=1024 start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
overrun_second_response=$(request_proxy '{"model":"overrun-route","messages":[{"role":"user","content":"retry"}]}' )
stop_listeners
printf '%s' "$overrun_second_response" | grep -F 'HTTP/1.1 429 Too Many Requests' >/dev/null
[ ! -f /data/provider/overrun-second.log ]

# Provider-reported paid cost is untrusted. A syntactically valid understated
# value must not reduce the conservative cost reservation used by later budget
# admission decisions.
CURRENT_CHECK=cost-floor
rm -f "$LEDGER" "$LOCK" /data/provider/cost-floor.log
next_case_ports
PROFILE_SPEC="openrouter|http://127.0.0.1:$OPENROUTER_PORT/v1/chat/completions|$OPENROUTER_KEY_FILE|10|${PROFILE_DAILY_BUDGET}"
ROUTE_SPEC="cost-floor-route|openrouter|cost-floor-model|paid"
start_upstream "$OPENROUTER_PORT" 200 OK \
    '{"choices":[{"message":{"content":"cost-floor-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"cost":0}}' \
    /data/provider/cost-floor.log
start_proxy "$PROFILE_SPEC" "$ROUTE_SPEC"
response=$(request_proxy '{"model":"cost-floor-route","messages":[{"role":"user","content":"hello"}]}' )
stop_listeners
printf '%s' "$response" | grep -F 'HTTP/1.1 200 OK' >/dev/null
printf '%s' "$response" | grep -F 'cost-floor-ok' >/dev/null
jq -e '[.records[] | select(.upstream_model == "cost-floor-model" and .settled_cost_micros > 0 and .settlement == "reserved_cost_floor")] | length == 1' \
    "$LEDGER" >/dev/null

# Dollar limits are enforced by the root broker before the upstream call. A
# request whose conservative reservation exceeds the configured daily cap
# must not spend provider credits or contact the upstream.
CURRENT_CHECK=cost-limit
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

CURRENT_CHECK=contract-report
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
        credential_401_blocks_same_profile_fallback: true,
        profile_quarantine_after_accounting_overrun: true
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
        encoded_credential_reflection_blocked: true,
        ledger_schema: 1,
        ledger_sha256: $ledger_sha256
      },
      limits: {
        max_input_tokens: 65536,
        max_output_tokens: 2048,
        profile_daily_token_budget: 200000,
        global_daily_token_budget: 200000,
        global_requests_per_hour: 120,
        client_requests_per_hour: 120,
        daily_cost_limit_micros: 10000000,
        monthly_cost_limit_micros: 40000000,
        max_cost_micros_per_1k_tokens: 100000
      }
    }' > "$report_tmp"
chmod 0640 "$report_tmp"
mv -f "$report_tmp" "$REPORT_OUTPUT"

echo 'provider profile fallback smoke passed'
