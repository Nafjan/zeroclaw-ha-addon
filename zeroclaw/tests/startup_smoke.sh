#!/bin/sh
# Runs inside the built image with a temporary /data and a fake daemon.
# This verifies entrypoint rendering without contacting Home Assistant,
# Telegram, or a provider unless the explicit real-provider round-trip mode is
# enabled below.

set -eu

cat > /data/options.json <<'JSON'
{
  "openrouter_api_key": "provider-secret",
  "provider_key_mode": "direct_temporary",
  "ha_token": "legacy-secret",
  "telegram_bot_token": "telegram-secret",
  "telegram_allowed_users": "1",
  "default_model": "~deepseek/deepseek-v4-flash-latest",
  "complex_model": "openrouter/fusion",
  "openrouter_auto_model": "openrouter/auto",
  "openrouter_fusion_preset": "general-budget",
  "openrouter_auto_cost_tier": "medium",
  "openrouter_free_model": "nvidia/nemotron-3.5-lightning:free",
  "openrouter_free_router_model": "openrouter/free",
  "nvidia_free_model": "",
  "ark_free_model": "",
  "provider_fallback_enabled": true,
  "provider_free_fallback_enabled": true,
  "provider_nvidia_fallback_enabled": false,
  "provider_ark_fallback_enabled": false,
  "log_level": "info",
  "daily_cost_limit_usd": 5.0,
  "monthly_cost_limit_usd": 20.0,
  "max_actions_per_hour": 200,
  "provider_max_requests_per_hour": 120,
  "provider_daily_token_budget": 100000,
  "max_tool_iterations": 8,
  "max_history_messages": 30,
  "max_context_tokens": 16000,
  "provider_max_tokens": 2048,
  "provider_max_input_tokens": 16384,
  "response_cache_ttl_minutes": 2,
  "conversation_retention_days": 30,
  "home_location": "Test Home",
  "home_languages": "en",
  "quiet_hours": "23:00-06:00",
  "confirmation_temp_delta_c": 3,
  "daily_report_time": "08:00",
  "daily_report_enabled": false,
  "observer_enabled": false,
  "observer_interval_minutes": 15,
  "enable_creation_skill": false,
  "enable_learning_loops": false,
  "enable_write_actions": false,
  "enable_undo": true,
  "audit_retention_days": 30,
  "policy_mode": "balanced",
  "policy_quiet_hours_require_confirm": false,
  "policy_bulk_action_threshold": 3,
  "policy_climate_delta_confirm_c": 3,
  "policy_extra_deny": [],
  "policy_extra_confirm": [],
  "policy_extra_allow": [],
  "policy_trust_enabled": true,
  "policy_trust_promote_after": 5
}
JSON

if [ "${SMOKE_ENABLE_WRITES:-false}" = "true" ]; then
    sed -i 's/"enable_write_actions": false/"enable_write_actions": true/' /data/options.json
    sed -i 's/"provider_key_mode": "direct_temporary"/"provider_key_mode": "broker"/' /data/options.json
fi
if [ "${SMOKE_EXTRA_DENY:-false}" = "true" ]; then
    sed -i 's/"enable_write_actions": false/"enable_write_actions": true/' /data/options.json
    sed -i 's/"provider_key_mode": "direct_temporary"/"provider_key_mode": "broker"/' /data/options.json
    sed -i 's/"policy_extra_deny": \[\]/"policy_extra_deny": ["light.kitchen"]/' /data/options.json
fi
if [ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ]; then
    sed -i 's/"provider_key_mode": "direct_temporary"/"provider_key_mode": "broker"/' /data/options.json
fi

mkdir -p /tmp/zeroclaw-test-bin /config
mkdir -p /data/workspace
printf 'old-config\n' > /data/config.toml
printf '3.1.3.3\n' > /data/.state-version

PROVIDER_UPSTREAM_PID=0
if [ "${SMOKE_REAL_PROVIDER_ROUNDTRIP:-false}" = "true" ]; then
    export ZEROCLAW_PROVIDER_UPSTREAM_URL='http://127.0.0.1:42633/v1/chat/completions'
    mkdir -p /data/provider
    cat > /tmp/fake-provider-handler <<'FAKE_PROVIDER'
#!/bin/sh
set -eu
LOG=/data/provider/roundtrip-upstream-request
: > "$LOG"
IFS= read -r request_line || exit 0
request_line=$(printf '%s' "$request_line" | tr -d '\r')
printf '%s\n' "$request_line" >> "$LOG"
content_length=0
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    printf '%s\n' "$header" >> "$LOG"
    case "$header" in
        Content-Length:*|content-length:*)
            content_length=$(printf '%s' "$header" | cut -d: -f2- | tr -d ' ')
            ;;
    esac
done
if [ "$content_length" -gt 0 ]; then
    dd bs=1 count="$content_length" 2>/dev/null | tr -d '\n' >> "$LOG"
fi
printf '\n' >> "$LOG"
body='{"id":"roundtrip","choices":[{"index":0,"message":{"role":"assistant","content":"provider-roundtrip-ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
length=$(printf '%s' "$body" | wc -c | tr -d ' ')
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$length" "$body"
FAKE_PROVIDER
    chmod +x /tmp/fake-provider-handler
    (
        while true; do
            if ! /bin/busybox nc -l -p 42633 -s 127.0.0.1 -e /tmp/fake-provider-handler; then
                sleep 1
            fi
        done
    ) &
    PROVIDER_UPSTREAM_PID=$!
    sleep 1
fi

cleanup() {
    if [ "$PROVIDER_UPSTREAM_PID" -gt 0 ]; then
        kill "$PROVIDER_UPSTREAM_PID" 2>/dev/null || true
        wait "$PROVIDER_UPSTREAM_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Minimal local HA endpoint so the smoke test exercises the broker transport
# without contacting the real Supervisor.
printf '%s\n' '127.0.0.1 supervisor' >> /etc/hosts
cat > /tmp/fake-ha-handler <<'FAKE_HA'
#!/bin/sh
IFS= read -r request_line || exit 0
printf '%s\n' "$request_line" >> /tmp/zeroclaw-ha-debug
case "$request_line" in
    *" /core/api/states/"*)
        body='{"entity_id":"light.kitchen","state":"on","attributes":{"friendly_name":"Kitchen","current_temperature":24}'
        body="${body}}"
        ;;
    *" /core/api/services/"*) body='[]' ;;
    *" /core/api/template"*) body='Kitchen: light.kitchen' ;;
    *" /core/api/logbook/"*) body='[]' ;;
    *" /core/api/error_log"*) body='' ;;
    *) body='{}' ;;
esac
length=$(printf '%s' "$body" | wc -c)
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$length" "$body"
FAKE_HA
chmod +x /tmp/fake-ha-handler
(
    while true; do
        if ! /bin/busybox nc -l -p 80 -s 127.0.0.1 -e /tmp/fake-ha-handler; then
            sleep 1
        fi
    done
) &

cat > /tmp/zeroclaw-test-bin/zeroclaw <<'FAKE'
#!/bin/sh
if [ "${SMOKE_USE_REAL_BINARY:-false}" = "true" ]; then
    if grep -R -F -e 'legacy-secret' -e 'supervisor-secret' /usr/local/bin >/dev/null 2>&1; then
        printf 'LEAK\n' > /tmp/zeroclaw-helper-token-scan
    else
        printf 'CLEAN\n' > /tmp/zeroclaw-helper-token-scan
    fi
    if env | grep -E '^(HA_TOKEN|SUPERVISOR_TOKEN|TELEGRAM_BOT_TOKEN|OPENROUTER_KEY|TELEGRAM_TOKEN|LEGACY_HA_TOKEN)=' >/dev/null 2>&1; then
        printf 'CREDENTIAL_ENV_VISIBLE\n' > /tmp/zeroclaw-broker-test
    elif ps w 2>/dev/null | grep -E 'legacy-[s]ecret|supervisor-[s]ecret|telegram-[s]ecret|provider-[s]ecret' >/dev/null 2>&1; then
        printf 'CREDENTIAL_ARG_VISIBLE\n' > /tmp/zeroclaw-broker-test
    else
        printf 'BROKER_OK\n' > /tmp/zeroclaw-broker-test
    fi
    printf '%s\n' "$(id -u)" > /tmp/zeroclaw-planner-uid
    if [ "${SMOKE_REAL_PROVIDER_ROUNDTRIP:-false}" = "true" ] && [ "${1:-}" = daemon ]; then
        (
            sleep 5
            /usr/local/bin/zeroclaw --config-dir /data agent -m 'provider round-trip probe' \
                >/tmp/zeroclaw-real-provider-response 2>&1 || true
        ) &
    fi
    exec /usr/local/bin/zeroclaw "$@"
fi
if [ "${1:-}" = daemon ]; then
    if grep -R -F -e 'legacy-secret' -e 'supervisor-secret' /usr/local/bin >/dev/null 2>&1; then
        printf 'LEAK\n' > /tmp/zeroclaw-helper-token-scan
    else
        printf 'CLEAN\n' > /tmp/zeroclaw-helper-token-scan
    fi
    if env | grep -E '^(HA_TOKEN|SUPERVISOR_TOKEN|TELEGRAM_BOT_TOKEN|OPENROUTER_KEY|TELEGRAM_TOKEN|LEGACY_HA_TOKEN)=' >/dev/null 2>&1; then
        printf 'CREDENTIAL_ENV_VISIBLE\n' > /tmp/zeroclaw-broker-test
    elif ps w 2>/dev/null | grep -E 'legacy-[s]ecret|supervisor-[s]ecret|telegram-[s]ecret|provider-[s]ecret' >/dev/null 2>&1; then
        printf 'CREDENTIAL_ARG_VISIBLE\n' > /tmp/zeroclaw-broker-test
    elif [ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ] && env | grep -F 'ZEROCLAW_API_KEY=provider-secret' >/dev/null 2>&1; then
        printf 'PROVIDER_KEY_ENV_VISIBLE\n' > /tmp/zeroclaw-broker-test
    elif [ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ] && ! env | grep -F 'ZEROCLAW_API_KEY=local-provider-broker' >/dev/null 2>&1; then
        printf 'PROVIDER_BROKER_CREDENTIAL_MISSING\n' > /tmp/zeroclaw-broker-test
    elif [ -r /data/options.json ]; then
        printf 'OPTIONS_READABLE\n' > /tmp/zeroclaw-broker-test
    elif [ -r /run/zeroclaw/telegram-token ]; then
        printf 'TELEGRAM_TOKEN_READABLE\n' > /tmp/zeroclaw-broker-test
    elif printf 'forged\n' > /data/.state-version 2>/dev/null; then
        printf 'VERSION_MARKER_WRITABLE_TO_PLANNER\n' > /tmp/zeroclaw-broker-test
    elif touch /data/audit/.planner-write-test 2>/dev/null; then
        rm -f /data/audit/.planner-write-test
        printf 'AUDIT_STORE_WRITABLE_TO_PLANNER\n' > /tmp/zeroclaw-broker-test
    elif touch /data/approval-receipts/tickets/.planner-write-test 2>/dev/null; then
        rm -f /data/approval-receipts/tickets/.planner-write-test
        printf 'APPROVAL_STORE_WRITABLE_TO_PLANNER\n' > /tmp/zeroclaw-broker-test
    elif touch /data/logs/.planner-write-test 2>/dev/null; then
        rm -f /data/logs/.planner-write-test
        printf 'BROKER_LOG_WRITABLE_TO_PLANNER\n' > /tmp/zeroclaw-broker-test
    elif touch /data/capability/.planner-write-test 2>/dev/null; then
        rm -f /data/capability/.planner-write-test
        printf 'CAPABILITY_QUOTA_WRITABLE_TO_PLANNER\n' > /tmp/zeroclaw-broker-test
    elif touch /data/capability/telegram-offset.planner-write-test 2>/dev/null; then
        rm -f /data/capability/telegram-offset.planner-write-test
        printf 'TELEGRAM_CURSOR_WRITABLE_TO_PLANNER\n' > /tmp/zeroclaw-broker-test
    elif rm -rf /data/approval-receipts 2>/dev/null; then
        printf 'ROOT_APPROVAL_STORE_REPLACED\n' > /tmp/zeroclaw-broker-test
    elif ! /usr/local/bin/ha-capability get_state light.kitchen | jq -e '.entity_id == "light.kitchen"' >/dev/null 2>&1; then
        printf 'BROKER_READ_FAILED\n' > /tmp/zeroclaw-broker-test
    elif printf '%s\n' '{"operation":"call_service","service":"light/turn_on","payload":{"entity_id":"light.kitchen"},"internal":true}' | /bin/busybox nc -w 3 127.0.0.1 42618 | jq -e '.ok == true' >/dev/null 2>&1; then
        printf 'BROKER_SOCKET_WRITE_BYPASS\n' > /tmp/zeroclaw-broker-test
    elif [ "${SMOKE_ENABLE_WRITES:-false}" != "true" ] && ZEROCLAW_INTERNAL_ACTION=1 /usr/local/bin/ha-action-raw light/turn_on '{"entity_id":"light.kitchen"}' >/dev/null 2>&1; then
        printf 'BROKER_WRITE_DISABLED_BYPASS\n' > /tmp/zeroclaw-broker-test
    elif [ "${SMOKE_ENABLE_WRITES:-false}" != "true" ]; then
        printf 'BROKER_OK\n' > /tmp/zeroclaw-broker-test
    elif /usr/local/bin/ha-capability call_service light/turn_on '{"entity_id":"light.kitchen"}' >/dev/null 2>&1; then
        printf 'BROKER_WRITE_CONTEXT_BYPASS\n' > /tmp/zeroclaw-broker-test
    elif ZEROCLAW_INTERNAL_ACTION=1 /usr/local/bin/ha-action-raw light/turn_on '{"entity_id":"light.kitchen"}' >/dev/null 2>&1; then
        printf 'BROKER_TICKET_GATE_BYPASS\n' > /tmp/zeroclaw-broker-test
    elif [ "${SMOKE_ENABLE_WRITES:-false}" = "true" ] && ! POLICY_REQUIRE_APPROVAL=true /usr/local/bin/policy-decide light turn_on light.kitchen '{"entity_id":"light.kitchen"}' | grep -E '^confirm:approval_required:' >/dev/null 2>&1; then
        printf 'BROKER_APPROVAL_POLICY_MISSING\n' > /tmp/zeroclaw-broker-test
    elif [ "${SMOKE_ENABLE_WRITES:-false}" = "true" ] && /usr/local/bin/zc-audit-write broker_allow light/turn_on '{"entity_id":"light.kitchen"}' forged >/dev/null 2>&1; then
        printf 'AUDIT_OUTCOME_CLIENT_BYPASS\n' > /tmp/zeroclaw-broker-test
    elif ZEROCLAW_INTERNAL_ACTION=1 /usr/local/bin/ha-action-raw scene/turn_on '{"entity_id":"scene.movie"}' >/dev/null 2>&1; then
        printf 'BROKER_CONFIRM_BYPASS\n' > /tmp/zeroclaw-broker-test
    else
        printf 'BROKER_OK\n' > /tmp/zeroclaw-broker-test
    fi
    printf '%s\n' "$(id -u)" > /tmp/zeroclaw-planner-uid
    [ "${SMOKE_NO_SLEEP:-false}" = "true" ] || sleep 120
fi
exit 0
FAKE
chmod +x /tmp/zeroclaw-test-bin/zeroclaw

cat > /tmp/bashio-test.sh <<'FAKE_BASHIO'
#!/bin/bash
bashio::config() {
    jq -r --arg key "$1" 'if .[$key] == null then "" elif (.[$key] | type) == "array" then (.[$key] | join("\n")) else (.[$key] | tostring) end' /data/options.json
}
bashio::log.info() { :; }
bashio::log.warning() { :; }
bashio::log.fatal() { printf '%s\n' "$*" >&2; return 1; }
source /run.sh
FAKE_BASHIO

export SUPERVISOR_TOKEN=supervisor-secret
# QEMU-backed arm64 startup includes the real entrypoint plus the broker
# contract scripts; keep the timeout generous enough for a cold CI runner.
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-120}"

set +e
PATH="/tmp/zeroclaw-test-bin:${PATH}" timeout "$SMOKE_TIMEOUT" /bin/bash /tmp/bashio-test.sh >/tmp/zeroclaw-startup.log 2>&1
run_status=$?
set -e

[ "$run_status" -eq 124 ]
[ "$(cat /tmp/zeroclaw-helper-token-scan)" = CLEAN ]
if [ "$(cat /tmp/zeroclaw-broker-test)" != BROKER_OK ]; then
    echo "broker smoke failed: $(cat /tmp/zeroclaw-broker-test)" >&2
    cat /tmp/zeroclaw-raw-debug >&2 || true
    cat /tmp/zeroclaw-ha-debug >&2 || true
    cat /data/logs/capability-broker.log >&2 || true
    exit 1
fi
[ "$(cat /tmp/zeroclaw-planner-uid)" -ne 0 ]
test "$(stat -c '%u:%a' /data)" = "0:1770"
test "$(stat -c '%u:%a' /data/approval-receipts/.locks)" = "0:700"
test "$(stat -c '%u:%a' /data/approval-receipts/.claims)" = "0:700"
test "$(stat -c '%u:%a' /data/approval-receipts/tickets)" = "0:700"
test "$(stat -c '%u:%a' /data/audit)" = "0:750"
test "$(stat -c '%u:%a' /data/logs)" = "0:750"
test "$(stat -c '%u:%a' /data/provider)" = "0:700"
test "$(stat -c '%u:%a' /data/capability)" = "0:700"
test "$(stat -c '%u:%a' /data/capability/telegram-replies)" = "0:700"
test "$(stat -c '%u:%a' /run/zeroclaw)" = "0:700"
test "$(stat -c '%u:%a' /data/capability/telegram-offset)" = "0:600"
test "$(stat -c '%u:%a' /run/zeroclaw/telegram-users)" = "0:600"
test -x /usr/local/bin/ha-broker-entrypoint
test -x /usr/local/bin/tg-broker-entrypoint
test -x /usr/local/bin/telegram-render
test -x /usr/local/bin/telegram-legacy-action
if [ "${SMOKE_USE_REAL_BINARY:-false}" = "true" ]; then
    ansi_escape=$(printf '\033')
    sed -E "s/${ansi_escape}\\[[0-9;]*m//g" /tmp/zeroclaw-startup.log > /tmp/startup-plain.log
    grep -F 'Config loaded path=/data/config.toml' /tmp/startup-plain.log >/dev/null
    ! grep -F 'Unknown config key' /tmp/startup-plain.log >/dev/null 2>&1
    ! grep -F 'Binding to 0.0.0.0' /tmp/startup-plain.log >/dev/null 2>&1
    grep -E 'Pairing:[[:space:]]+enabled' /tmp/startup-plain.log >/dev/null
fi
grep -F 'host = "127.0.0.1"' /data/config.toml >/dev/null
grep -F 'require_pairing = true' /data/config.toml >/dev/null
grep -F 'workspace_only = true' /data/config.toml >/dev/null
grep -F 'allowed_domains = []' /data/config.toml >/dev/null
if [ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ]; then
    grep -F 'fallback = "custom:http://127.0.0.1:42620/v1"' /data/config.toml >/dev/null
    grep -F '[providers.models."custom:http://127.0.0.1:42620/v1"]' /data/config.toml >/dev/null
    grep -F 'model = "~deepseek/deepseek-v4-flash-latest"' /data/config.toml >/dev/null
    grep -F 'model = "openrouter/fusion"' /data/config.toml >/dev/null
    grep -F '[[providers.model_routes]]' /data/config.toml >/dev/null
    test -x /usr/local/bin/provider-broker-handler
    test -x /usr/local/bin/provider-broker-entrypoint
fi
if [ "${SMOKE_REAL_PROVIDER_ROUNDTRIP:-false}" = "true" ]; then
    grep -F 'provider-roundtrip-ok' /tmp/zeroclaw-real-provider-response >/dev/null
    grep -F 'Authorization: Bearer provider-secret' /data/provider/roundtrip-upstream-request >/dev/null
    ! grep -F 'provider-secret' /tmp/zeroclaw-real-provider-response >/dev/null 2>&1
fi
test -f /data/.state-version
[ "$(find /data/migrations -type f -name config.toml -print -quit | xargs cat)" = old-config ]
/src/tests/approval_transition_smoke.sh
/src/tests/approval_concurrency_smoke.sh
/src/tests/telegram_broker_smoke.sh
if [ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ]; then
    /src/tests/provider_broker_smoke.sh
    /src/tests/provider_profile_fallback_smoke.sh
fi
