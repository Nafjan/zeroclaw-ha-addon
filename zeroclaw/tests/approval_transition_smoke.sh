#!/bin/sh
# Exercises the actor-bound approval state machine inside the image.
set -eu

NOW=$(date -u +%s)
mkdir -p /data/pending /data/approved /data/approval-receipts /data/approval-receipts/.locks /data/approval-receipts/tickets
jq -nc --argjson exp "$((NOW + 300))" \
    '{uuid:"deadbeef",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/deadbeef.json
sha256sum /data/approval-receipts/tickets/deadbeef.json | cut -d' ' -f1 > /data/approval-receipts/deadbeef.sha256

if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve deadbeef 99 42 >/dev/null 2>&1; then
    echo "wrong actor was accepted" >&2
    exit 1
fi
[ ! -f /data/approved/deadbeef.marker ]
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve deadbeef 42 42 >/dev/null
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify deadbeef >/dev/null
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve deadbeef 42 42 >/dev/null 2>&1; then
    echo "duplicate approval was accepted" >&2
    exit 1
fi
jq -e '.actor_user_id == "42" and .chat_id == "42"' /data/approved/deadbeef.marker >/dev/null
echo 'tampered' > /data/approval-receipts/tickets/deadbeef.json
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify deadbeef >/dev/null 2>&1; then
    echo "ticket tampering was not detected" >&2
    exit 1
fi

jq -nc --argjson exp "$((NOW + 300))" \
    '{uuid:"cafebabe",service:"light/turn_off",payload:{entity_id:"light.kitchen"},expires_at:$exp,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/cafebabe.json
sha256sum /data/approval-receipts/tickets/cafebabe.json | cut -d' ' -f1 > /data/approval-receipts/cafebabe.sha256
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh reject cafebabe 42 42 >/dev/null
[ ! -f /data/approval-receipts/tickets/cafebabe.json ]
[ ! -e /data/approved/cafebabe.marker ]
[ ! -e /data/approval-receipts/cafebabe.sha256 ]
grep -R -F '"kind":"reject"' /data/audit >/dev/null
