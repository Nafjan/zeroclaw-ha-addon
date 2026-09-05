#!/bin/sh
# Contract test for the root-owned OpenAI-compatible provider broker.
# The fake upstream proves that the real key is attached only on the broker's
# outbound hop; the planner-facing response contains no credential material.
set -eu

PROXY_PORT=42631
UPSTREAM_PORT=42632
UPSTREAM_URL="http://127.0.0.1:${UPSTREAM_PORT}/v1/chat/completions"
REQUEST_BODY='{"model":"deepseek/deepseek-v4-flash","messages":[{"role":"user","content":"hello"}]}'
PROXY_PID=0
UPSTREAM_PID=0
mkdir -p /data/provider

cat > /tmp/provider-fake-upstream <<'UPSTREAM'
#!/bin/sh
set -eu
REQUEST_LOG=/data/provider-upstream-request
: > "$REQUEST_LOG"
IFS= read -r request_line || exit 0
request_line=$(printf '%s' "$request_line" | tr -d '\r')
printf '%s\n' "$request_line" >> "$REQUEST_LOG"
content_length=0
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    printf '%s\n' "$header" >> "$REQUEST_LOG"
    case "$header" in
        Content-Length:*|content-length:*)
            content_length=$(printf '%s' "$header" | cut -d: -f2- | tr -d ' ')
            ;;
    esac
done
if [ "$content_length" -gt 0 ]; then
    dd bs=1 count="$content_length" 2>/dev/null | tr -d '\n' >> "$REQUEST_LOG"
fi
printf '\n' >> "$REQUEST_LOG"
    if [ "${PROVIDER_LEAK_RESPONSE:-false}" = "true" ]; then
        body='{"choices":[{"message":{"content":"provider-secret"}}]}'
    elif [ "${PROVIDER_ENCODED_LEAK_RESPONSE:-false}" = "true" ]; then
        body='{"choices":[{"message":{"content":"cHJvdmlkZXItc2VjcmV0"}}]}'
    elif [ "${PROVIDER_PERCENT_LEAK_RESPONSE:-false}" = "true" ]; then
        body='{"choices":[{"message":{"content":"%70%72%6F%76%69%64%65%72%2D%73%65%63%72%65%74"}}]}'
    elif [ "${PROVIDER_HEX_LEAK_RESPONSE:-false}" = "true" ]; then
        body='{"choices":[{"message":{"content":"70726f76696465722d736563726574"}}]}'
    else
        body='{"choices":[{"message":{"content":"broker-ok"}}],"provider_debug":"ignored"}'
fi
length=$(printf '%s' "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$length" "$body"
UPSTREAM
chmod +x /tmp/provider-fake-upstream

start_upstream() {
    /bin/busybox nc -l -p "$UPSTREAM_PORT" -s 127.0.0.1 -e /tmp/provider-fake-upstream &
    UPSTREAM_PID=$!
    sleep 1
}

start_proxy() {
    PROVIDER_UPSTREAM_URL="$UPSTREAM_URL" OPENROUTER_KEY=provider-secret \
        PROVIDER_CLIENT_AUTH_TOKEN=provider-client-secret \
        PROVIDER_ALLOWED_MODELS='deepseek/deepseek-v4-flash' \
        PROVIDER_MAX_TOKENS=2048 PROVIDER_MAX_INPUT_TOKENS=16384 \
        PROVIDER_MAX_REQUESTS_PER_HOUR="${TEST_PROVIDER_MAX_REQUESTS_PER_HOUR:-120}" \
        PROVIDER_CLIENT_REQUESTS_PER_HOUR="${TEST_PROVIDER_CLIENT_REQUESTS_PER_HOUR:-120}" \
        PROVIDER_DAILY_TOKEN_BUDGET=32768 \
        PROVIDER_DAILY_COST_LIMIT_MICROS=100000000 PROVIDER_MONTHLY_COST_LIMIT_MICROS=1000000000 \
        PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=100000 PROVIDER_QUOTA_FILE=/data/provider/quota.json \
        PROVIDER_QUOTA_LOCK=/data/provider/.quota.lock \
        PROVIDER_CLIENT_RATE_FILE=/data/provider/client-rate.json PROVIDER_CLIENT_RATE_LOCK=/data/provider/.client-rate.lock \
        /bin/busybox nc -l -p "$PROXY_PORT" -s 127.0.0.1 -e /usr/local/bin/provider-broker-entrypoint &
    PROXY_PID=$!
    sleep 1
}

stop_listeners() {
    if [ "$PROXY_PID" -gt 0 ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    if [ "$UPSTREAM_PID" -gt 0 ]; then
        kill "$UPSTREAM_PID" 2>/dev/null || true
        wait "$UPSTREAM_PID" 2>/dev/null || true
    fi
    PROXY_PID=0
    UPSTREAM_PID=0
}

cleanup() {
    stop_listeners
}
trap cleanup EXIT

start_upstream
rm -f /data/provider/quota.json /data/provider/.quota.lock
start_proxy
body_length=$(printf '%s' "$REQUEST_BODY" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-response
stop_listeners

grep -F 'HTTP/1.1 200 OK' /data/provider-response >/dev/null
grep -F '"broker-ok"' /data/provider-response >/dev/null
grep -F 'Authorization: Bearer provider-secret' /data/provider-upstream-request >/dev/null
grep -F '"model":"deepseek/deepseek-v4-flash"' /data/provider-upstream-request >/dev/null
grep -F '"max_tokens":2048' /data/provider-upstream-request >/dev/null
! grep -F 'provider-secret' /data/provider-response >/dev/null 2>&1
! grep -F 'provider_debug' /data/provider-response >/dev/null 2>&1

# A process that only discovers the loopback port must not be able to invoke
# the root broker without the fresh client credential.
start_proxy
body_length=$(printf '%s' "$REQUEST_BODY" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-missing-auth-response
stop_listeners
grep -F 'HTTP/1.1 401 Unauthorized' /data/provider-missing-auth-response >/dev/null

start_proxy
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer wrong-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-wrong-auth-response
stop_listeners
grep -F 'HTTP/1.1 401 Unauthorized' /data/provider-wrong-auth-response >/dev/null

# The route and envelope checks must fail closed before any upstream call.
start_proxy
    printf 'GET /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\n\r\n' |
    /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-route-response
stop_listeners
grep -F 'HTTP/1.1 404 Not Found' /data/provider-route-response >/dev/null

# Authenticated malformed/model-rejected requests consume a separate bounded
# client admission budget before validation, so they cannot churn the root
# broker without being counted.
rm -f /data/provider/client-rate.json /data/provider/.client-rate.lock
for response_file in /data/provider-client-admission-1 /data/provider-client-admission-2; do
    TEST_PROVIDER_CLIENT_REQUESTS_PER_HOUR=2 start_proxy
    admission_body='{"model":"unapproved/model","messages":[]}'
    admission_length=$(printf '%s' "$admission_body" | wc -c | tr -d ' ')
    {
        printf 'POST /v1/chat/completions HTTP/1.1\r\n'
        printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Length: %s\r\n\r\n%s' "$admission_length" "$admission_body"
    } | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > "$response_file"
    stop_listeners
    grep -F 'HTTP/1.1 403 Forbidden' "$response_file" >/dev/null
done
TEST_PROVIDER_CLIENT_REQUESTS_PER_HOUR=2 start_proxy
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Length: %s\r\n\r\n%s' "$admission_length" "$admission_body"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-client-admission-3
stop_listeners
grep -F 'HTTP/1.1 429 Too Many Requests' /data/provider-client-admission-3 >/dev/null

start_proxy
UNALLOWED_BODY='{"model":"unapproved/model","messages":[]}'
body_length=$(printf '%s' "$UNALLOWED_BODY" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$UNALLOWED_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-model-response
stop_listeners
grep -F 'HTTP/1.1 403 Forbidden' /data/provider-model-response >/dev/null

start_proxy
TOO_MANY_TOKENS='{"model":"deepseek/deepseek-v4-flash","messages":[],"max_tokens":2049}'
body_length=$(printf '%s' "$TOO_MANY_TOKENS" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$TOO_MANY_TOKENS"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-token-response
stop_listeners
grep -F 'HTTP/1.1 400 Bad Request' /data/provider-token-response >/dev/null

start_proxy
printf 'POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Length: 2\r\n\r\n{}' |
    /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-envelope-response
stop_listeners
grep -F 'HTTP/1.1 400 Bad Request' /data/provider-envelope-response >/dev/null

# A compromised/misconfigured upstream must not be able to echo the real key
# back through the planner-facing model gateway.
PROVIDER_LEAK_RESPONSE=true start_upstream
start_proxy
body_length=$(printf '%s' "$REQUEST_BODY" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-leak-response
stop_listeners
grep -F 'HTTP/1.1 502 Bad Gateway' /data/provider-leak-response >/dev/null
! grep -F 'provider-secret' /data/provider-leak-response >/dev/null 2>&1

PROVIDER_ENCODED_LEAK_RESPONSE=true start_upstream
start_proxy
body_length=$(printf '%s' "$REQUEST_BODY" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-encoded-leak-response
stop_listeners
grep -F 'HTTP/1.1 502 Bad Gateway' /data/provider-encoded-leak-response >/dev/null
! grep -F 'provider-secret' /data/provider-encoded-leak-response >/dev/null 2>&1

PROVIDER_PERCENT_LEAK_RESPONSE=true start_upstream
start_proxy
body_length=$(printf '%s' "$REQUEST_BODY" | wc -c | tr -d ' ')
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-percent-leak-response
stop_listeners
grep -F 'HTTP/1.1 502 Bad Gateway' /data/provider-percent-leak-response >/dev/null
! grep -F 'provider-secret' /data/provider-percent-leak-response >/dev/null 2>&1

PROVIDER_HEX_LEAK_RESPONSE=true start_upstream
start_proxy
{
    printf 'POST /v1/chat/completions HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\nAuthorization: Bearer provider-client-secret\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$body_length" "$REQUEST_BODY"
} | /bin/busybox nc -w 10 127.0.0.1 "$PROXY_PORT" > /data/provider-hex-leak-response
stop_listeners
grep -F 'HTTP/1.1 502 Bad Gateway' /data/provider-hex-leak-response >/dev/null
! grep -F 'provider-secret' /data/provider-hex-leak-response >/dev/null 2>&1

echo 'provider broker smoke passed'
