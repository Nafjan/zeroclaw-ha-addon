#!/bin/sh
# Multiple callbacks racing for one ticket must produce exactly one approval.
set -eu

NOW=$(date -u +%s)
SHORT=feedcafe
mkdir -p /data/pending /data/approved /data/approval-receipts \
    /data/approval-receipts/.locks /data/approval-receipts/tickets \
    /data/approval-receipts/ticket-nonces /data/capability /tmp/zc-approval-race
if [ ! -f /data/.approval-restore-epoch ]; then
    printf '%s\n' 0 > /data/.approval-restore-epoch
    chmod 0600 /data/.approval-restore-epoch
fi
mkdir -p /run/zeroclaw
printf '%s\n' capability-client-secret > /run/zeroclaw/capability-client-auth
chmod 0600 /run/zeroclaw/capability-client-auth
jq -nc --argjson exp "$((NOW + 300))" \
    '{uuid:"feedcafe",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > "/data/approval-receipts/tickets/${SHORT}.json"
sha256sum "/data/approval-receipts/tickets/${SHORT}.json" | cut -d' ' -f1 > "/data/approval-receipts/${SHORT}.sha256"

pids=""
for n in $(seq 1 12); do
    (
        if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve "$SHORT" 42 42 >/dev/null 2>&1; then
            echo success
        else
            echo rejected
        fi
    ) > "/tmp/zc-approval-race/${n}.out" &
    pids="$pids $!"
done

for pid in $pids; do
    wait "$pid" || true
done

successes=$(grep -l '^success$' /tmp/zc-approval-race/*.out | wc -l)
rejections=$(grep -l '^rejected$' /tmp/zc-approval-race/*.out | wc -l)
[ "$successes" -eq 1 ]
[ "$rejections" -eq 11 ]
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify "$SHORT" >/dev/null
test -f "/data/approved/${SHORT}.marker"

# A second apply claim is one-shot: a concurrent or replayed executor must not
# be able to run the approved Home Assistant service twice.
CLAIM_SHORT=c0ffee12
jq -nc --argjson exp "$((NOW + 300))" \
    '{uuid:"c0ffee12",service:"light/turn_off",payload:{entity_id:"light.kitchen"},expires_at:$exp,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > "/data/approval-receipts/tickets/${CLAIM_SHORT}.json"
sha256sum "/data/approval-receipts/tickets/${CLAIM_SHORT}.json" | cut -d' ' -f1 > "/data/approval-receipts/${CLAIM_SHORT}.sha256"
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve "$CLAIM_SHORT" 42 42 >/dev/null
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh claim "$CLAIM_SHORT" >/dev/null
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh claim "$CLAIM_SHORT" >/dev/null 2>&1; then
    echo "duplicate apply claim was accepted" >&2
    exit 1
fi
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify "$CLAIM_SHORT" >/dev/null 2>&1; then
    echo "claimed ticket remained verifiable" >&2
    exit 1
fi
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify_claim "$CLAIM_SHORT" >/dev/null
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh complete "$CLAIM_SHORT" >/dev/null
[ ! -e "/data/approval-receipts/.claims/${CLAIM_SHORT}.claim" ]
[ ! -e "/data/approval-receipts/tickets/${CLAIM_SHORT}.json" ]

# Exercise the real one-shot apply path when the startup smoke enabled writes.
# The broker must claim a confirmed ticket itself across the TCP boundary, then
# finalize it so a second apply cannot replay the service.
if [ "${SMOKE_ENABLE_WRITES:-false}" = "true" ]; then
    APPLY_SHORT=a11e0d01
    APPLY_PORT=42638
    HA_PORT=42639
    jq -nc --argjson exp "$((NOW + 300))" \
        '{uuid:"a11e0d01",service:"switch/turn_on",payload:{entity_id:"switch.kitchen"},expires_at:$exp,tg_message_id:123,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
        > "/data/approval-receipts/tickets/${APPLY_SHORT}.json"
    sha256sum "/data/approval-receipts/tickets/${APPLY_SHORT}.json" | cut -d' ' -f1 > "/data/approval-receipts/${APPLY_SHORT}.sha256"
    ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve "$APPLY_SHORT" 42 42 >/dev/null

    cat > /tmp/approval-fake-ha <<'FAKE_HA'
#!/bin/sh
set -eu
    IFS= read -r request_line || exit 0
    case "$request_line" in
        *" /core/api/services/switch/turn_on"*) body='[]' ;;
        *" /core/api/states/"*) body='{"entity_id":"switch.kitchen","state":"off","attributes":{}}' ;;
        *) body='{}' ;;
    esac
length=$(printf '%s' "$body" | wc -c)
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$length" "$body"
FAKE_HA
    chmod +x /tmp/approval-fake-ha
    (
        # The guarded apply path makes one broker/HA request for the undo
        # snapshot and a second request for the service call. Keep the fake
        # endpoints available for both connections instead of accidentally
        # turning a successful first request into a transport failure.
        for _ in 1 2; do
            while ! /bin/busybox nc -l -p "$HA_PORT" -s 127.0.0.1 -e /tmp/approval-fake-ha; do
                sleep 1
            done
        done
    ) &
    ha_pid=$!
    sleep 1
    (
        export HA_TOKEN=apply-test-token
        export CAPABILITY_CLIENT_AUTH_TOKEN=capability-client-secret
        export HA_URL="http://127.0.0.1:${HA_PORT}/core/api"
        export ENABLE_WRITE_ACTIONS=true
        export POLICY_MODE=balanced POLICY_QUIET_CONFIRM=true POLICY_BULK_THRESHOLD=3 POLICY_CLIMATE_DELTA=3
        export QUIET_HOURS=23:00-06:00 EXTRA_DENY= EXTRA_CONFIRM= EXTRA_ALLOW=
        for _ in 1 2; do
            while ! /bin/busybox nc -l -p "$APPLY_PORT" -s 127.0.0.1 -e /usr/local/bin/ha-broker-entrypoint; do
                sleep 1
            done
        done
    ) &
    broker_pid=$!
    sleep 1
    if ! OUTPUT=$(ZEROCLAW_CAPABILITY_PORT="$APPLY_PORT" /usr/local/bin/ha-action-guarded --apply-ticket "$APPLY_SHORT"); then
        echo "approved apply path failed: $OUTPUT" >&2
        kill "$broker_pid" "$ha_pid" 2>/dev/null || true
        exit 1
    fi
    wait "$broker_pid" 2>/dev/null || true
    wait "$ha_pid" 2>/dev/null || true
    printf '%s' "$OUTPUT" | jq -e 'type == "array"' >/dev/null
    [ ! -e "/data/approval-receipts/tickets/${APPLY_SHORT}.json" ]
    [ ! -e "/data/approval-receipts/.claims/${APPLY_SHORT}.claim" ]
    grep -R -F '"kind":"broker_allow"' /data/audit >/dev/null
    grep -R -F '"kind":"apply"' /data/audit >/dev/null
    if ZEROCLAW_CAPABILITY_PORT="$APPLY_PORT" /usr/local/bin/ha-action-guarded --apply-ticket "$APPLY_SHORT" >/dev/null 2>&1; then
        echo "completed approval was replayable" >&2
        exit 1
    fi
fi
