#!/bin/sh
# The gateway health endpoint alone cannot prove that the two root capability
# brokers are still serving requests. Keep the check cheap and read-only, but
# include both process liveness and one authenticated Home Assistant read.
set -eu

pid_is_live() {
    pid_file="$1"
    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
    pid=$(tr -d '\r\n' < "$pid_file")
    printf '%s' "$pid" | grep -Eq '^[1-9][0-9]*$' || return 1
    kill -0 "$pid" 2>/dev/null
}

[ ! -e /data/capability/telegram-conflict ] || exit 1
pid_is_live /run/zeroclaw/provider-broker.pid
pid_is_live /run/zeroclaw/capability-broker.pid
curl -fsS --max-time 3 http://127.0.0.1:42617/health >/dev/null
provider_health_auth_file=/run/zeroclaw/provider-client-auth
[ -f "$provider_health_auth_file" ] && [ ! -L "$provider_health_auth_file" ] || exit 1
provider_health_token=$(tr -d '\r\n' < "$provider_health_auth_file")
printf '%s' "$provider_health_token" | grep -Eq '^[a-f0-9]{64}$' || exit 1
provider_health_config=$(mktemp)
trap 'rm -f -- "$provider_health_config"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$provider_health_token" > "$provider_health_config"
chmod 0600 "$provider_health_config"
curl -fsS --max-time 3 --config "$provider_health_config" http://127.0.0.1:42620/health >/dev/null
unset provider_health_token
/usr/local/bin/ha-capability read_sensors >/dev/null
