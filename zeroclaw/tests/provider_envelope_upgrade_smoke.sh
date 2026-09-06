#!/bin/sh
# Reproduce the persisted-Supervisor-options envelope mismatch without an
# external provider. The old saved input ceiling is retained for this test;
# the release default is tested separately with a loopback-only fake upstream.
set -eu

FIXTURE=/tmp/zeroclaw-upgrade-envelope.json
KEY_FILE=/data/provider/upgrade-envelope.key
UPSTREAM=/tmp/zeroclaw-upgrade-upstream
mkdir -p /data/provider
printf '%s' upgrade-envelope-secret > "$KEY_FILE"
chmod 0600 "$KEY_FILE"

fixture_json() {
    jq -nc --arg filler "$1" \
        '{model:"deepseek/deepseek-v4-flash",messages:[{role:"user",content:$filler}],max_tokens:2048}'
}

# Keep the fixture byte-identical to the sanitized live planner envelope used
# for the regression: 53,174 bytes, with no provider credentials or secrets.
base_length=$(fixture_json '' | wc -c | tr -d ' ')
filler_length=$((53174 - base_length))
[ "$filler_length" -gt 0 ]
filler=$(awk -v count="$filler_length" 'BEGIN { printf "%*s", count, "" }' | tr ' ' x)
fixture_json "$filler" > "$FIXTURE"
fixture_length=$(wc -c < "$FIXTURE" | tr -d ' ')
[ "$fixture_length" = 53174 ] || {
    echo "upgrade envelope fixture length mismatch: ${fixture_length}" >&2
    exit 1
}

cat > "$UPSTREAM" <<'UPSTREAM_EOF'
#!/bin/sh
set -eu
: > "${UPGRADE_UPSTREAM_LOG:?}"
IFS= read -r request_line || exit 0
printf '%s\n' "$request_line" >> "$UPGRADE_UPSTREAM_LOG"
content_length=0
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    printf '%s\n' "$header" >> "$UPGRADE_UPSTREAM_LOG"
    case "$header" in
        Content-Length:*|content-length:*)
            content_length=$(printf '%s' "$header" | cut -d: -f2- | tr -d ' ')
            ;;
    esac
done
if [ "$content_length" -gt 0 ]; then
    dd bs=1 count="$content_length" 2>/dev/null >> "$UPGRADE_UPSTREAM_LOG"
fi
printf '\n' >> "$UPGRADE_UPSTREAM_LOG"
body='{"choices":[{"message":{"content":"upgrade-envelope-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
body_length=$(printf '%s' "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$body_length" "$body"
UPSTREAM_EOF
chmod 0755 "$UPSTREAM"

start_upstream() {
    upgrade_upstream_port="$1"
    upgrade_upstream_log="$2"
    rm -f "$upgrade_upstream_log"
    UPGRADE_UPSTREAM_LOG="$upgrade_upstream_log" \
        /bin/busybox nc -l -p "$upgrade_upstream_port" -s 127.0.0.1 -e "$UPSTREAM" &
    UPGRADE_UPSTREAM_PID=$!
    sleep 1
}

stop_upstream() {
    if [ "${UPGRADE_UPSTREAM_PID:-0}" -gt 0 ]; then
        kill "$UPGRADE_UPSTREAM_PID" 2>/dev/null || true
        wait "$UPGRADE_UPSTREAM_PID" 2>/dev/null || true
    fi
    UPGRADE_UPSTREAM_PID=0
}

request_case() {
    input_tokens="$1"
    upstream_port="$2"
    response_file="$3"
    ledger_file="$4"
    client_rate_file="$5"
    profile_spec="openrouter|http://127.0.0.1:${upstream_port}/v1/chat/completions|${KEY_FILE}|120|200000"
    route_spec='deepseek/deepseek-v4-flash|openrouter|deepseek/deepseek-v4-flash|paid'
    body_length=$(wc -c < "$FIXTURE" | tr -d ' ')
    {
        printf 'POST /v1/chat/completions HTTP/1.1\r\n'
        printf 'Host: 127.0.0.1\r\nAuthorization: Bearer upgrade-envelope-client\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n' "$body_length"
        cat "$FIXTURE"
    } | \
        PROVIDER_PROFILE_SPEC="$profile_spec" \
        PROVIDER_ROUTE_SPEC="$route_spec" \
        PROVIDER_CLIENT_AUTH_TOKEN=upgrade-envelope-client \
        PROVIDER_FALLBACK_ENABLED=false \
        PROVIDER_FREE_FALLBACK_ENABLED=false \
        PROVIDER_MAX_TOKENS=2048 \
        PROVIDER_MAX_INPUT_TOKENS="$input_tokens" \
        PROVIDER_MAX_REQUESTS_PER_HOUR=120 \
        PROVIDER_CLIENT_REQUESTS_PER_HOUR=120 \
        PROVIDER_DAILY_TOKEN_BUDGET=200000 \
        PROVIDER_DAILY_COST_LIMIT_MICROS=10000000 \
        PROVIDER_MONTHLY_COST_LIMIT_MICROS=40000000 \
        PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=100000 \
        PROVIDER_LEDGER_FILE="$ledger_file" \
        PROVIDER_LEDGER_LOCK="${ledger_file}.lock" \
        PROVIDER_CLIENT_RATE_FILE="$client_rate_file" \
        PROVIDER_CLIENT_RATE_LOCK="${client_rate_file}.lock" \
        PROVIDER_LOG_FILE="${response_file}.broker.log" \
        PROVIDER_COST_DEGRADED_FILE="${response_file}.cost-degraded" \
        PROVIDER_TOTAL_TIMEOUT_SECONDS=20 \
        /opt/zeroclaw/lib/provider-broker-handler.sh > "$response_file"
}

OLD_LEDGER=/data/provider/upgrade-old-ledger.json
OLD_LEDGER_BEFORE=/data/provider/upgrade-old-ledger.before
printf '%s\n' '{"schema":1,"records":[]}' > "$OLD_LEDGER"
cp "$OLD_LEDGER" "$OLD_LEDGER_BEFORE"
start_upstream 42710 /data/provider/upgrade-old-upstream.log
request_case 32768 42710 /data/provider/upgrade-old-response "$OLD_LEDGER" /data/provider/upgrade-old-client-rate.json
stop_upstream
grep -F 'HTTP/1.1 413 Payload Too Large' /data/provider/upgrade-old-response >/dev/null
[ ! -s /data/provider/upgrade-old-upstream.log ] || {
    echo 'stale persisted envelope unexpectedly contacted the upstream' >&2
    exit 1
}
cmp -s "$OLD_LEDGER" "$OLD_LEDGER_BEFORE" || {
    echo 'stale persisted envelope changed the provider budget ledger' >&2
    exit 1
}

NEW_LEDGER=/data/provider/upgrade-release-ledger.json
start_upstream 42711 /data/provider/upgrade-release-upstream.log
request_case 65536 42711 /data/provider/upgrade-release-response "$NEW_LEDGER" /data/provider/upgrade-release-client-rate.json
stop_upstream
grep -F 'HTTP/1.1 200 OK' /data/provider/upgrade-release-response >/dev/null
grep -F 'POST /v1/chat/completions HTTP/1.1' /data/provider/upgrade-release-upstream.log >/dev/null
! grep -F 'upgrade-envelope-secret' /data/provider/upgrade-release-upstream.log >/dev/null 2>&1

printf 'UPGRADE_OPTIONS_OK fixture_bytes=%s stale_input_tokens=32768 stale_effective_bytes=32512 release_input_tokens=65536 release_effective_bytes=65280 stale_upstream_calls=0 external_provider_calls=0 budgets=unchanged\n' \
    "$fixture_length"
