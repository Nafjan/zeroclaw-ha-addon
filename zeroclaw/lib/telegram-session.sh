#!/bin/sh
# Prepare the one session file used by a Telegram chat.
#
# The Telegram watcher is a root-owned broker, while the ZeroClaw process is
# deliberately run as the unprivileged planner.  Startup creates and owns the
# fixed workspace/sessions tree before either child exists.  Per-message work
# must not perform privileged ownership changes inside planner-writable paths.
prepare_telegram_session() {
    workspace="$1"
    chat_id="$2"

    case "$chat_id" in
        -*) chat_digits=${chat_id#-} ;;
        *) chat_digits=$chat_id ;;
    esac
    case "$chat_digits" in
        ''|*[!0-9]*) return 2 ;;
    esac
    [ "${#chat_digits}" -le 20 ] || return 2
    [ -n "$workspace" ] || return 2
    [ ! -L "$workspace" ] || return 1

    session_dir="$workspace/sessions"
    session_file="$session_dir/telegram_${chat_id}.json"
    [ ! -L "$session_dir" ] || return 1
    [ ! -L "$session_file" ] || return 1

    [ -d "$session_dir" ] || return 1

    printf '%s\n' "$session_file"
}
