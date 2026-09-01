#!/bin/sh
# Verify the root broker can prepare a session file that the unprivileged
# planner can write after startup creates the planner-owned session directory.
set -eu

SMOKE_ROOT=/data/telegram-session-smoke
rm -rf "$SMOKE_ROOT"
mkdir -p "$SMOKE_ROOT/sessions"
chown zeroclaw:zeroclaw "$SMOKE_ROOT/sessions"
chmod 0700 "$SMOKE_ROOT/sessions"
mkdir -p "$SMOKE_ROOT/locks"
chown root:root "$SMOKE_ROOT/locks"
chmod 0700 "$SMOKE_ROOT/locks"
. /opt/zeroclaw/lib/telegram-session.sh
. /opt/zeroclaw/lib/telegram-agent-turn.sh
. /opt/zeroclaw/lib/telegram-message-guard.sh
umask 077

cat > /tmp/telegram-agent-turn <<'EOF'
#!/bin/sh
set -eu
session_file=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-state-file)
            session_file="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
[ -n "$session_file" ]
active=/tmp/telegram-session-smoke-active
overlap=/tmp/telegram-session-smoke-overlap
if ! (set -C; : > "$active") 2>/dev/null; then
    : > "$overlap"
    exit 1
fi
trap 'rm -f "$active"' EXIT
sleep 1
printf '%s\n' session-write-ok > "$session_file"
printf '%s\n' agent-turn-ok
EOF
chmod 0755 /tmp/telegram-agent-turn
AGENT_BIN=/tmp/telegram-agent-turn
AGENT_CONFIG_DIR=/data
AGENT_WORKSPACE="$SMOKE_ROOT"
AGENT_SESSION_LOCK_DIR="$SMOKE_ROOT/locks"
export AGENT_BIN AGENT_CONFIG_DIR AGENT_WORKSPACE AGENT_SESSION_LOCK_DIR

telegram_message_destination_allowed private 45711625 45711625
if telegram_message_destination_allowed group -1001234567890 45711625; then
    echo 'group Telegram message was accepted' >&2
    exit 1
fi
if telegram_message_destination_allowed private 45711625 45711626; then
    echo 'Telegram chat/actor mismatch was accepted' >&2
    exit 1
fi

session_file="$SMOKE_ROOT/sessions/telegram_45711625.json"
reply=$(run_telegram_agent_turn 45711625 'hello')
test "$reply" = agent-turn-ok
test "$session_file" = "$SMOKE_ROOT/sessions/telegram_45711625.json"
test "$(stat -c '%U:%a' "$SMOKE_ROOT/sessions")" = "zeroclaw:700"
test "$(cat "$session_file")" = session-write-ok
test "$(stat -c '%U:%a' "$session_file")" = "zeroclaw:600"

session_file=$(prepare_telegram_session "$SMOKE_ROOT" 45711625)
reply=$(run_telegram_agent_turn 45711625 'hello again')
test "$reply" = agent-turn-ok
test "$(cat "$session_file")" = session-write-ok

rm -f /tmp/telegram-session-smoke-active /tmp/telegram-session-smoke-overlap
(run_telegram_agent_turn 45711625 'concurrent one' > /tmp/telegram-session-smoke-one) &
first_pid=$!
(run_telegram_agent_turn 45711625 'concurrent two' > /tmp/telegram-session-smoke-two) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
test "$(cat /tmp/telegram-session-smoke-one)" = agent-turn-ok
test "$(cat /tmp/telegram-session-smoke-two)" = agent-turn-ok
[ ! -e /tmp/telegram-session-smoke-active ]
[ ! -e /tmp/telegram-session-smoke-overlap ]

negative_session=$(prepare_telegram_session "$SMOKE_ROOT" -1001234567890)
test "$negative_session" = "$SMOKE_ROOT/sessions/telegram_-1001234567890.json"

if prepare_telegram_session "$SMOKE_ROOT" '45711625/escape' >/dev/null 2>&1; then
    echo 'invalid Telegram chat id was accepted' >&2
    exit 1
fi
if prepare_telegram_session "$SMOKE_ROOT" '45711625-escape' >/dev/null 2>&1; then
    echo 'malformed Telegram chat id was accepted' >&2
    exit 1
fi
if prepare_telegram_session "$SMOKE_ROOT" '--100' >/dev/null 2>&1; then
    echo 'malformed negative Telegram chat id was accepted' >&2
    exit 1
fi
if prepare_telegram_session "$SMOKE_ROOT" '123456789012345678901' >/dev/null 2>&1; then
    echo 'oversized Telegram chat id was accepted' >&2
    exit 1
fi
ln -s "$SMOKE_ROOT" "$SMOKE_ROOT/sessions-link"
if prepare_telegram_session "$SMOKE_ROOT/sessions-link" 1 >/dev/null 2>&1; then
    echo 'symlinked session workspace was accepted' >&2
    exit 1
fi
