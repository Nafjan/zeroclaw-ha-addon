#!/bin/sh
# Telegram messages are accepted only from an allowlisted user in that user's
# private chat.  This is deliberately a small pure predicate so the watcher
# and its smoke tests share exactly the same boundary condition.

telegram_message_destination_allowed() {
    chat_type="$1"
    chat_id="$2"
    actor_user_id="$3"
    [ "$chat_type" = "private" ] && [ "$chat_id" = "$actor_user_id" ]
}
