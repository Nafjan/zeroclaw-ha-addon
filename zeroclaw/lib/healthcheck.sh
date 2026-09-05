#!/bin/sh
# The gateway health endpoint alone cannot prove that the two root capability
# brokers are still serving requests. Keep the check cheap and read-only, but
# include both process liveness and one authenticated Home Assistant read.
set -eu

pid_is_live() {
    pid_file="$1"
    expected_process="${2:-}"
    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
    pid=$(tr -d '\r\n' < "$pid_file")
    printf '%s' "$pid" | grep -Eq '^[1-9][0-9]*$' || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -n "$expected_process" ]; then
        [ -r "/proc/$pid/cmdline" ] || return 1
        process_cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
        case "$process_cmdline" in
            *"$expected_process"*) ;;
            *) return 1 ;;
        esac
    fi
}

[ ! -e /data/capability/telegram-conflict ] || exit 1
pid_is_live /run/zeroclaw/provider-broker.pid
pid_is_live /run/zeroclaw/capability-broker.pid
curl -fsS --max-time 3 http://127.0.0.1:42617/health >/dev/null
provider_health_auth_file=/run/zeroclaw/provider-health-auth
[ -f "$provider_health_auth_file" ] && [ ! -L "$provider_health_auth_file" ] || exit 1
provider_health_token=$(tr -d '\r\n' < "$provider_health_auth_file")
printf '%s' "$provider_health_token" | grep -Eq '^[a-f0-9]{64}$' || exit 1
provider_health_config=$(mktemp)
trap 'rm -f -- "$provider_health_config"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$provider_health_token" > "$provider_health_config"
chmod 0600 "$provider_health_config"
curl -fsS --max-time 3 --config "$provider_health_config" http://127.0.0.1:42620/health >/dev/null
unset provider_health_token
if [ -e /run/zeroclaw/telegram-enabled ]; then
    [ -f /run/zeroclaw/telegram-enabled ] && [ ! -L /run/zeroclaw/telegram-enabled ] || exit 1
    [ "$(tr -d '\r\n' < /run/zeroclaw/telegram-enabled)" = true ] || exit 1
    pid_is_live /run/zeroclaw/telegram-watcher.pid tg-callback-watcher
    telegram_ready_file=/data/capability/telegram-ready
    [ -f "$telegram_ready_file" ] && [ ! -L "$telegram_ready_file" ] || exit 1
    telegram_ready_bot=$(tr -d '\r\n' < "$telegram_ready_file")
    printf '%s' "$telegram_ready_bot" | grep -Eq '^[0-9]+$' || exit 1
    unset telegram_ready_bot
    telegram_heartbeat_file=/data/capability/telegram-heartbeat
    [ -f "$telegram_heartbeat_file" ] && [ ! -L "$telegram_heartbeat_file" ] || exit 1
    telegram_heartbeat=$(tr -d '\r\n' < "$telegram_heartbeat_file")
    printf '%s' "$telegram_heartbeat" | grep -Eq '^[0-9]+$' || exit 1
    telegram_now=$(date -u +%s)
    [ "$telegram_heartbeat" -le "$telegram_now" ] || exit 1
    [ "$((telegram_now - telegram_heartbeat))" -le 180 ] || exit 1
    unset telegram_heartbeat telegram_now
fi
/usr/local/bin/ha-health-read >/dev/null
