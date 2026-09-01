#!/bin/sh
# Exercises the Telegram capability client, broker response, and ticket seal
# without contacting Telegram.
set -eu

install -m 0755 /opt/zeroclaw/lib/telegram-broker-handler.sh /usr/local/bin/tg-broker-handler
install -m 0755 /opt/zeroclaw/lib/telegram-broker-entrypoint.sh /usr/local/bin/tg-broker-entrypoint
mkdir -p /run/zeroclaw
printf '%s\n' telegram-secret > /run/zeroclaw/telegram-token
chown root:root /run/zeroclaw/telegram-token
chmod 0600 /run/zeroclaw/telegram-token
printf '%s\n' telegram-client-secret > /run/zeroclaw/telegram-client-auth
chown root:root /run/zeroclaw/telegram-client-auth
chmod 0600 /run/zeroclaw/telegram-client-auth
mkdir -p /data/audit
cat > /usr/local/bin/zc-audit-write <<'AUDIT'
#!/bin/sh
set -eu
KIND="$1"; SERVICE="$2"; BODY="$3"; REASON="$4"
DATE=$(date -u +%Y-%m-%d)
ROW=$(jq -nc --arg kind "$KIND" --arg service "$SERVICE" --arg reason "$REASON" \
    --argjson body "$BODY" '{kind:$kind,service:$service,reason:$reason,body:$body}')
printf '%s\n' "$ROW" >> "/data/audit/${DATE}.jsonl"
AUDIT
chmod 0755 /usr/local/bin/zc-audit-write

mkdir -p /tmp/fake-curl
cat > /tmp/fake-curl/curl <<'FAKE_CURL'
#!/bin/sh
if [ -f /data/telegram-fake-error ]; then
    printf '%s\n' '{"ok":false,"error_code":400,"description":"Bad Request: invalid request"}'
    exit 0
fi
if [ -f /data/telegram-fake-leak ]; then
    printf '%s\n' '{"ok":true,"result":{"message_id":123,"text":"telegram-secret"}}'
    exit 0
fi
printf '%s\n' '{"ok":true,"result":{"message_id":123}}'
FAKE_CURL
chmod +x /tmp/fake-curl/curl

mkdir -p /data/capability /data/pending /data/approval-receipts /data/approval-receipts/.locks
rm -f /data/capability/telegram-approval-rate.json /data/capability/.telegram-approval-rate.lock
jq -nc --argjson exp "$(( $(date -u +%s) + 7200 ))" \
    '{uuid:"abcdef12",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/pending/abcdef12.json

(
    export PATH="/tmp/fake-curl:$PATH"
    export TELEGRAM_TOKEN_FILE="/run/zeroclaw/telegram-token"
    export TELEGRAM_CLIENT_AUTH_TOKEN=telegram-client-secret
    export TELEGRAM_SYSTEM_AUTH_TOKEN=telegram-system-secret
    export TELEGRAM_APPROVAL_CHAT=42
    export ZEROCLAW_TELEGRAM_PORT=42629
    while true; do
        if ! /bin/busybox nc -l -p 42629 -s 127.0.0.1 -e /usr/local/bin/tg-broker-entrypoint; then
            sleep 1
        fi
    done
) &

RESPONSE=$(ZEROCLAW_TELEGRAM_PORT=42629 /opt/zeroclaw/lib/telegram-capability.sh send_approval abcdef12 42 'Approve kitchen light')
printf '%s' "$RESPONSE" | jq -e '.message_id == 123' >/dev/null
[ -f /data/approval-receipts/abcdef12.sha256 ]
[ -f /data/approval-receipts/tickets/abcdef12.json ]
test "$(stat -c '%u:%a' /data/approval-receipts/tickets/abcdef12.json)" = "0:600"
SEALED_NOW=$(date -u +%s)
SEALED_EXP=$(jq -r '.expires_at' /data/approval-receipts/tickets/abcdef12.json)
[ "$SEALED_EXP" -le "$((SEALED_NOW + 1800))" ]

if RESPONSE=$(ZEROCLAW_TELEGRAM_PORT=42629 /opt/zeroclaw/lib/telegram-capability.sh send_text 43 'unexpected recipient' 2>/dev/null); then
    echo "Telegram planner capability exposed arbitrary send_text" >&2
    exit 1
fi

SYSTEM_REQUEST=$(jq -nc '{operation:"send_system_notice",auth:"telegram-system-secret",text:"cost watchdog"}')
SYSTEM_RESPONSE=$(printf '%s\n' "$SYSTEM_REQUEST" | /bin/busybox nc -w 10 127.0.0.1 42629)
printf '%s' "$SYSTEM_RESPONSE" | jq -e '.message_id == 123' >/dev/null

if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve abcdef12 99 42 >/dev/null 2>&1; then
    echo "Telegram broker smoke accepted the wrong actor" >&2
    exit 1
fi
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve abcdef12 42 42 >/dev/null

# Telegram can return HTTP 200 with {"ok":false}; that must not seal a
# canonical ticket as delivered.  A response containing the bot credential
# must also be rejected before it reaches the planner.
for short in badcafe0 badcafe1; do
    jq -nc --argjson exp "$(( $(date -u +%s) + 300 ))" --arg uuid "$short" \
        '{uuid:$uuid,service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
        > "/data/pending/${short}.json"
done
touch /data/telegram-fake-error
if ZEROCLAW_TELEGRAM_PORT=42629 /opt/zeroclaw/lib/telegram-capability.sh send_approval badcafe0 42 'Approve kitchen light' >/dev/null 2>&1; then
    echo "Telegram HTTP-200 error was accepted" >&2
    exit 1
fi
rm -f /data/telegram-fake-error
[ ! -e /data/approval-receipts/tickets/badcafe0.json ]
[ ! -e /data/approval-receipts/badcafe0.sha256 ]

touch /data/telegram-fake-leak
if ZEROCLAW_TELEGRAM_PORT=42629 /opt/zeroclaw/lib/telegram-capability.sh send_approval badcafe1 42 'Approve kitchen light' >/dev/null 2>&1; then
    echo "Telegram credential echo was accepted" >&2
    exit 1
fi
rm -f /data/telegram-fake-leak
[ ! -e /data/approval-receipts/tickets/badcafe1.json ]
[ ! -e /data/approval-receipts/badcafe1.sha256 ]
