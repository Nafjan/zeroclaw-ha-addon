#!/bin/sh
# Prove that the root broker handlers reject oversized and idle newline-
# delimited input before an untrusted peer can grow a shell string without
# bound.  This runs against the handlers as shipped in the image.
set -eu

install -m 0755 /opt/zeroclaw/lib/bounded-read.sh /usr/local/bin/bounded-read.sh
install -m 0755 /opt/zeroclaw/lib/capability-broker-handler.sh /usr/local/bin/ha-broker-handler
install -m 0755 /opt/zeroclaw/lib/capability-broker-entrypoint.sh /usr/local/bin/ha-broker-entrypoint
install -m 0755 /opt/zeroclaw/lib/provider-broker-handler.sh /usr/local/bin/provider-broker-handler
install -m 0755 /opt/zeroclaw/lib/provider-broker-entrypoint.sh /usr/local/bin/provider-broker-entrypoint
install -m 0755 /opt/zeroclaw/lib/telegram-broker-handler.sh /usr/local/bin/tg-broker-handler
install -m 0755 /opt/zeroclaw/lib/telegram-broker-entrypoint.sh /usr/local/bin/tg-broker-entrypoint

mkdir -p /data/provider /data/logs /data/audit /run/zeroclaw
printf '%s\n' telegram-test-token > /run/zeroclaw/telegram-token

{
    printf '%s' '{"auth":"cap-client","operation":"'
    head -c 33000 /dev/zero | tr '\000' a
    printf '%s\n' '"}'
} | HA_TOKEN=test-token CAPABILITY_CLIENT_AUTH_TOKEN=cap-client \
    /usr/local/bin/ha-broker-entrypoint > /data/framing-capability-response
grep -Eq '"error_code":"request_(too_large|timeout)"' /data/framing-capability-response >/dev/null

# A planner may describe an intent/deny/confirmation event for diagnostics,
# but the broker must rewrite it into a segregated telemetry record rather
# than minting an authoritative audit kind or service.
cat > /usr/local/bin/zc-audit-write <<'AUDIT'
#!/bin/sh
printf '%s\n' "$1" > /data/planner-audit-kind
printf '%s\n' "$2" >> /data/planner-audit-kind
printf '%s\n' "$3" >> /data/planner-audit-kind
AUDIT
chmod 0755 /usr/local/bin/zc-audit-write
printf '%s\n' '{"auth":"cap-client","operation":"audit","kind":"deny","service":"light/turn_on","body":{"entity_id":"light.kitchen"},"reason":"test"}' |
    HA_TOKEN=test-token CAPABILITY_CLIENT_AUTH_TOKEN=cap-client \
    /usr/local/bin/ha-broker-entrypoint > /data/planner-audit-response
grep -F '"recorded":true' /data/planner-audit-response >/dev/null
sed -n '1p' /data/planner-audit-kind | grep -Fx 'planner_event' >/dev/null
sed -n '2p' /data/planner-audit-kind | grep -Fx 'planner/telemetry' >/dev/null
sed -n '3p' /data/planner-audit-kind | grep -F '"source":"untrusted_planner"' >/dev/null

{
    printf 'GET '
    head -c 5000 /dev/zero | tr '\000' a
    printf '%s\n' ' HTTP/1.1'
} | PROVIDER_CLIENT_AUTH_TOKEN=provider-client \
    PROVIDER_ALLOWED_MODELS='test/model' PROVIDER_MAX_TOKENS=512 \
    PROVIDER_MAX_INPUT_TOKENS=1024 PROVIDER_MAX_REQUESTS_PER_HOUR=10 \
    PROVIDER_DAILY_TOKEN_BUDGET=2048 PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=1 \
    /usr/local/bin/provider-broker-entrypoint > /data/framing-provider-line-response
grep -Eq 'request line (is too large|timed out)' /data/framing-provider-line-response >/dev/null

{
    printf '%s\r\n' 'POST /v1/chat/completions HTTP/1.1'
    printf '%s' 'X-oversized: '
    head -c 9000 /dev/zero | tr '\000' a
    printf '%s\r\n\r\n' ''
} | PROVIDER_CLIENT_AUTH_TOKEN=provider-client \
    PROVIDER_ALLOWED_MODELS='test/model' PROVIDER_MAX_TOKENS=512 \
    PROVIDER_MAX_INPUT_TOKENS=1024 PROVIDER_MAX_REQUESTS_PER_HOUR=10 \
    PROVIDER_DAILY_TOKEN_BUDGET=2048 PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=1 \
    /usr/local/bin/provider-broker-entrypoint > /data/framing-provider-header-response
grep -Eq 'header (is too large|timed out)' /data/framing-provider-header-response >/dev/null

{
    printf '%s' '{"auth":"cap-client","operation":"'
    sleep 4
} | HA_TOKEN=test-token CAPABILITY_CLIENT_AUTH_TOKEN=cap-client \
    /usr/local/bin/ha-broker-entrypoint > /data/framing-idle-response
grep -F '"error_code":"request_timeout"' /data/framing-idle-response >/dev/null

echo 'BROKER_FRAMING_OK bounded_lines=true bounded_headers=true idle_timeout=true'
