#!/bin/sh
# Agent-side Telegram client. It sends typed requests to the root-owned broker.
set -eu

PORT="${ZEROCLAW_TELEGRAM_PORT:-42619}"
OP="${1:-}"
shift || true

case "$OP" in
    send_approval)
        [ "$#" -eq 3 ] || { echo "Usage: tg-capability send_approval <ticket> <chat_id> <text>" >&2; exit 1; }
        ticket_path="/data/pending/$1.json"
        [ -f "$ticket_path" ] && [ ! -L "$ticket_path" ] || {
            echo "approval ticket is missing or is not a regular file" >&2
            exit 1
        }
        ticket_size=$(wc -c < "$ticket_path" | tr -d ' ')
        case "$ticket_size" in
            ''|*[!0-9]*) echo "approval ticket size could not be measured" >&2; exit 1 ;;
        esac
        [ "$ticket_size" -le 65536 ] || {
            echo "approval ticket is too large" >&2
            exit 1
        }
        ticket_json=$(cat "$ticket_path") || {
            echo "approval ticket could not be read" >&2
            exit 1
        }
        printf '%s' "$ticket_json" | jq -e 'type == "object"' >/dev/null 2>&1 || {
            echo "approval ticket is not valid JSON" >&2
            exit 1
        }
        REQUEST=$(jq -nc --arg operation "$OP" --arg ticket "$1" --arg chat_id "$2" \
            --arg text "$3" --arg ticket_json "$ticket_json" \
            '{operation:$operation,ticket:$ticket,chat_id:$chat_id,text:$text,ticket_json:$ticket_json}')
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

RESPONSE=$(/bin/busybox nc -w 45 127.0.0.1 "$PORT" <<EOF
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
