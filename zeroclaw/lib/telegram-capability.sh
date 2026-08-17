#!/bin/sh
# Agent-side Telegram client. It sends typed requests to the root-owned broker.
set -eu

PORT="${ZEROCLAW_TELEGRAM_PORT:-42619}"
OP="${1:-}"
shift || true

case "$OP" in
    send_approval)
        [ "$#" -eq 3 ] || { echo "Usage: tg-capability send_approval <ticket> <chat_id> <text>" >&2; exit 1; }
        REQUEST=$(jq -nc --arg operation "$OP" --arg ticket "$1" --arg chat_id "$2" --arg text "$3" \
            '{operation:$operation,ticket:$ticket,chat_id:$chat_id,text:$text}')
        ;;
    send_text)
        [ "$#" -eq 2 ] || { echo "Usage: tg-capability send_text <chat_id> <text>" >&2; exit 1; }
        REQUEST=$(jq -nc --arg operation "$OP" --arg chat_id "$1" --arg text "$2" \
            '{operation:$operation,chat_id:$chat_id,text:$text}')
        ;;
    *)
        echo "Telegram capability is not available for this operation" >&2
        exit 1
        ;;
esac

RESPONSE=$(/bin/busybox nc -w 10 127.0.0.1 "$PORT" <<EOF
$REQUEST
EOF
) || { echo "Telegram broker unavailable" >&2; exit 1; }
[ -n "$RESPONSE" ] || { echo "Telegram broker returned no response" >&2; exit 1; }
OK=$(printf '%s' "$RESPONSE" | jq -r '.ok // false' 2>/dev/null || echo false)
if [ "$OK" != true ]; then
    printf '%s\n' "$RESPONSE" | jq -r '.error // "Telegram request failed"' >&2
    exit 1
fi
printf '%s\n' "$RESPONSE" | jq -c '.result // {}'
