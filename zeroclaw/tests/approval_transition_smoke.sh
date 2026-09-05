#!/bin/sh
# Exercises the actor-bound approval state machine inside the image.
set -eu

NOW=$(date -u +%s)
GENERATION=11111111111111111111111111111111
BAD_GENERATION=22222222222222222222222222222222
REJECT_GENERATION=33333333333333333333333333333333
REUSE_OLD_GENERATION=44444444444444444444444444444444
REUSE_NEW_GENERATION=55555555555555555555555555555555
CALLBACK_OLD_GENERATION=66666666666666666666666666666666
CALLBACK_NEW_GENERATION=77777777777777777777777777777777
CALLBACK_SHORT=baadf00d
CALLBACK_OLD_MESSAGE_ID=100
CALLBACK_NEW_MESSAGE_ID=200
mkdir -p /data/pending /data/approved /data/approval-receipts /data/approval-receipts/.locks /data/approval-receipts/tickets /data/approval-receipts/ticket-nonces
jq -nc --argjson exp "$((NOW + 300))" --arg generation "$GENERATION" \
    '{uuid:"deadbeef",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,restore_epoch:0,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/deadbeef.json
sha256sum /data/approval-receipts/tickets/deadbeef.json | cut -d' ' -f1 > /data/approval-receipts/deadbeef.sha256

if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve deadbeef 99 42 "$GENERATION" >/dev/null 2>&1; then
    echo "wrong actor was accepted" >&2
    exit 1
fi
[ ! -f /data/approved/deadbeef.marker ]

jq -nc --argjson exp "$((NOW + 300))" --arg generation "$BAD_GENERATION" \
    '{uuid:"badc0de1",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,restore_epoch:1,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/badc0de1.json
sha256sum /data/approval-receipts/tickets/badc0de1.json | cut -d' ' -f1 > /data/approval-receipts/badc0de1.sha256
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve badc0de1 42 42 "$BAD_GENERATION" >/dev/null 2>&1; then
    echo "ticket from a prior restore epoch was accepted" >&2
    exit 1
fi
[ ! -f /data/approved/badc0de1.marker ]
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve deadbeef 42 42 "$GENERATION" >/dev/null
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify deadbeef >/dev/null
duplicate_output=$(ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve deadbeef 42 42 "$GENERATION")
printf '%s' "$duplicate_output" | grep -F 'ALREADY_APPROVED deadbeef' >/dev/null
jq -e '.actor_user_id == "42" and .chat_id == "42"' /data/approved/deadbeef.marker >/dev/null
JQ_GENERATION=$(jq -r '.approval_generation' /data/approved/deadbeef.marker)
[ "$JQ_GENERATION" = "$GENERATION" ]
grep -R -F '"kind":"approve"' /data/audit >/dev/null
echo 'tampered' > /data/approval-receipts/tickets/deadbeef.json
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh verify deadbeef >/dev/null 2>&1; then
    echo "ticket tampering was not detected" >&2
    exit 1
fi

jq -nc --argjson exp "$((NOW + 300))" --arg generation "$REJECT_GENERATION" \
    '{uuid:"cafebabe",service:"light/turn_off",payload:{entity_id:"light.kitchen"},expires_at:$exp,restore_epoch:0,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/cafebabe.json
sha256sum /data/approval-receipts/tickets/cafebabe.json | cut -d' ' -f1 > /data/approval-receipts/cafebabe.sha256
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh reject cafebabe 42 42 "$REJECT_GENERATION" >/dev/null
[ ! -f /data/approval-receipts/tickets/cafebabe.json ]
[ ! -e /data/approved/cafebabe.marker ]
[ ! -e /data/approval-receipts/cafebabe.sha256 ]
grep -R -F '"kind":"reject"' /data/audit >/dev/null

# A delayed code must not approve a replacement ticket after cleanup has
# removed the old ticket, receipt, and replay barrier for the same short id.
jq -nc --argjson exp "$((NOW + 300))" --arg generation "$REUSE_OLD_GENERATION" \
    '{uuid:"c0de0001",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,restore_epoch:0,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/c0de0001.json
sha256sum /data/approval-receipts/tickets/c0de0001.json | cut -d' ' -f1 > /data/approval-receipts/c0de0001.sha256
mkdir -p /data/approval-receipts/ticket-nonces/c0de0001
rm -f /data/approval-receipts/tickets/c0de0001.json /data/approval-receipts/c0de0001.sha256
rmdir /data/approval-receipts/ticket-nonces/c0de0001
jq -nc --argjson exp "$((NOW + 300))" --arg generation "$REUSE_NEW_GENERATION" \
    '{uuid:"c0de0001",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,restore_epoch:0,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > /data/approval-receipts/tickets/c0de0001.json
sha256sum /data/approval-receipts/tickets/c0de0001.json | cut -d' ' -f1 > /data/approval-receipts/c0de0001.sha256
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve c0de0001 42 42 "$REUSE_OLD_GENERATION" >/dev/null 2>&1; then
    echo "delayed approval generation was accepted for a replacement ticket" >&2
    exit 1
fi
[ ! -e /data/approved/c0de0001.marker ]
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve c0de0001 42 42 "$REUSE_NEW_GENERATION" >/dev/null
jq -e --arg generation "$REUSE_NEW_GENERATION" '.approval_generation == $generation' \
    /data/approved/c0de0001.marker >/dev/null

# A callback watcher can read the delivered message id just before cleanup
# replaces the ticket, then read the replacement generation. The root
# transition must bind both callback values to the same current ticket while
# holding its lock; otherwise that mixed identity could approve the replacement.
jq -nc --argjson exp "$((NOW + 300))" --arg generation "$CALLBACK_OLD_GENERATION" \
    --argjson message "$CALLBACK_OLD_MESSAGE_ID" \
    '{uuid:"baadf00d",service:"light/turn_on",payload:{entity_id:"light.kitchen"},expires_at:$exp,restore_epoch:0,tg_message_id:$message,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > "/data/approval-receipts/tickets/${CALLBACK_SHORT}.json"
sha256sum "/data/approval-receipts/tickets/${CALLBACK_SHORT}.json" | cut -d' ' -f1 > \
    "/data/approval-receipts/${CALLBACK_SHORT}.sha256"
CALLBACK_MESSAGE_FROM_OLD_TICKET=$(jq -r '.tg_message_id' \
    "/data/approval-receipts/tickets/${CALLBACK_SHORT}.json")
jq -nc --argjson exp "$((NOW + 300))" --arg generation "$CALLBACK_NEW_GENERATION" \
    --argjson message "$CALLBACK_NEW_MESSAGE_ID" \
    '{uuid:"baadf00d",service:"switch/turn_on",payload:{entity_id:"switch.kitchen"},expires_at:$exp,restore_epoch:0,tg_message_id:$message,approval_generation:$generation,approval:{actor_user_id:"42",chat_id:"42",channel:"telegram"}}' \
    > "/data/approval-receipts/tickets/.${CALLBACK_SHORT}.replacement"
mv "/data/approval-receipts/tickets/.${CALLBACK_SHORT}.replacement" \
    "/data/approval-receipts/tickets/${CALLBACK_SHORT}.json"
sha256sum "/data/approval-receipts/tickets/${CALLBACK_SHORT}.json" | cut -d' ' -f1 > \
    "/data/approval-receipts/${CALLBACK_SHORT}.sha256"
if ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve \
    "$CALLBACK_SHORT" 42 42 "$CALLBACK_NEW_GENERATION" "$CALLBACK_MESSAGE_FROM_OLD_TICKET" >/dev/null 2>&1; then
    echo "mixed callback message and replacement generation was accepted" >&2
    exit 1
fi
[ ! -e "/data/approved/${CALLBACK_SHORT}.marker" ]
ZEROCLAW_APPROVAL_INTERNAL=1 /opt/zeroclaw/lib/approval-transition.sh approve \
    "$CALLBACK_SHORT" 42 42 "$CALLBACK_NEW_GENERATION" "$CALLBACK_NEW_MESSAGE_ID" >/dev/null
jq -e --arg generation "$CALLBACK_NEW_GENERATION" \
    '.approval_generation == $generation' "/data/approved/${CALLBACK_SHORT}.marker" >/dev/null
