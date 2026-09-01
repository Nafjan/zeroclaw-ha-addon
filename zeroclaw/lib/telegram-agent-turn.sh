#!/bin/sh
# Run one Telegram turn as the unprivileged planner.
#
# The caller is the root-owned Telegram watcher.  The only writable state
# handed to the planner is its chat session file; credentials remain in the
# typed root brokers.
run_telegram_agent_turn() {
    chat_id="$1"
    prompt="$2"
    retry_model="${3:-}"
    session_lock_dir="${AGENT_SESSION_LOCK_DIR:-/data/capability/telegram-session-locks}"
    umask 077
    if ! session_file=$(prepare_telegram_session "$AGENT_WORKSPACE" "$chat_id"); then
        printf '%s\n' "Telegram session preparation failed for chat $chat_id" >&2
        return 74
    fi
    [ ! -L "$session_lock_dir" ] && [ -d "$session_lock_dir" ] || {
        printf '%s\n' "Telegram session lock directory is unavailable" >&2
        return 74
    }
    session_lock="$session_lock_dir/telegram_${chat_id}.lock"
    lock_attempts=0
    while ! mkdir "$session_lock" 2>/dev/null; do
        lock_attempts=$((lock_attempts + 1))
        if [ "$lock_attempts" -ge 900 ]; then
            lock_now=$(date -u +%s)
            lock_mtime=$(stat -c '%Y' "$session_lock" 2>/dev/null || printf '%s' 0)
            case "$lock_mtime" in
                ''|*[!0-9]*) lock_mtime=0 ;;
            esac
            if [ "$lock_mtime" -gt 0 ] && [ "$((lock_now - lock_mtime))" -ge 180 ]; then
                rmdir "$session_lock" 2>/dev/null || true
                lock_attempts=0
            else
                printf '%s\n' "Telegram session lock is busy for chat $chat_id" >&2
                return 75
            fi
        fi
        sleep 0.1
    done
    if [ -n "$retry_model" ]; then
        su-exec zeroclaw:zeroclaw timeout 120 "$AGENT_BIN" \
            --config-dir "$AGENT_CONFIG_DIR" agent \
            --model "$retry_model" \
            --message "$prompt" \
            --session-state-file "$session_file"
    else
        su-exec zeroclaw:zeroclaw timeout 120 "$AGENT_BIN" \
            --config-dir "$AGENT_CONFIG_DIR" agent \
            --message "$prompt" \
            --session-state-file "$session_file"
    fi
    agent_status=$?
    rmdir "$session_lock" 2>/dev/null || true
    return "$agent_status"
}
