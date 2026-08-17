#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS Add-on v3.1.3.5 — defensive stabilization release
# Writes, scheduling, generic HTTP, and the built-in Telegram transport are
# disabled by default; enabled writes remain broker- and policy-gated.

ADDON_VERSION="3.1.3.5"
bashio::log.info "ZeroClaw v${ADDON_VERSION} starting..."

# ==============================================================
# Bashio config reads (all configured options)
# ==============================================================
OPENROUTER_KEY="$(bashio::config 'openrouter_api_key')"
PROVIDER_KEY_MODE="$(bashio::config 'provider_key_mode')"
LEGACY_HA_TOKEN="$(bashio::config 'ha_token')"
HA_TOKEN="${SUPERVISOR_TOKEN:-${LEGACY_HA_TOKEN}}"
TELEGRAM_TOKEN="$(bashio::config 'telegram_bot_token')"
TELEGRAM_USERS="$(bashio::config 'telegram_allowed_users')"
if [ -z "${PROVIDER_KEY_MODE}" ]; then
    bashio::log.warning "provider_key_mode is absent in existing options; using the broker default. Set direct_temporary only for a controlled migration comparison."
    PROVIDER_KEY_MODE="broker"
fi
DEFAULT_MODEL="$(bashio::config 'default_model')"
COMPLEX_MODEL="$(bashio::config 'complex_model')"
LOG_LEVEL="$(bashio::config 'log_level')"

DAILY_COST_LIMIT="$(bashio::config 'daily_cost_limit_usd')"
MONTHLY_COST_LIMIT="$(bashio::config 'monthly_cost_limit_usd')"
MAX_ACTIONS_PER_HOUR="$(bashio::config 'max_actions_per_hour')"
PROVIDER_MAX_REQUESTS_HOUR="$(bashio::config 'provider_max_requests_per_hour')"
PROVIDER_DAILY_TOKEN_BUDGET="$(bashio::config 'provider_daily_token_budget')"
MAX_TOOL_ITER="$(bashio::config 'max_tool_iterations')"
MAX_HISTORY_MSGS="$(bashio::config 'max_history_messages')"
MAX_CONTEXT_TOKENS="$(bashio::config 'max_context_tokens')"
PROVIDER_MAX_TOKENS="$(bashio::config 'provider_max_tokens')"
RESPONSE_CACHE_TTL="$(bashio::config 'response_cache_ttl_minutes')"
CONV_RETENTION_DAYS="$(bashio::config 'conversation_retention_days')"

HOME_LOCATION="$(bashio::config 'home_location')"
HOME_LANGUAGES="$(bashio::config 'home_languages')"
QUIET_HOURS="$(bashio::config 'quiet_hours')"
CONFIRM_TEMP_DELTA="$(bashio::config 'confirmation_temp_delta_c')"

DAILY_REPORT_TIME="$(bashio::config 'daily_report_time')"
DAILY_REPORT_ENABLED="$(bashio::config 'daily_report_enabled')"
OBSERVER_ENABLED="$(bashio::config 'observer_enabled')"
OBSERVER_INTERVAL="$(bashio::config 'observer_interval_minutes')"

ENABLE_CREATION="$(bashio::config 'enable_creation_skill')"
ENABLE_LEARNING="$(bashio::config 'enable_learning_loops')"
ENABLE_WRITE_ACTIONS="$(bashio::config 'enable_write_actions')"
ENABLE_UNDO="$(bashio::config 'enable_undo')"
AUDIT_RETENTION_DAYS="$(bashio::config 'audit_retention_days')"

POLICY_MODE="$(bashio::config 'policy_mode')"
POLICY_QUIET_CONFIRM="$(bashio::config 'policy_quiet_hours_require_confirm')"
POLICY_BULK_THRESHOLD="$(bashio::config 'policy_bulk_action_threshold')"
POLICY_CLIMATE_DELTA="$(bashio::config 'policy_climate_delta_confirm_c')"
POLICY_TRUST_ENABLED="$(bashio::config 'policy_trust_enabled')"
POLICY_TRUST_PROMOTE="$(bashio::config 'policy_trust_promote_after')"

PROVIDER_MAX_REQUESTS_HOUR="${PROVIDER_MAX_REQUESTS_HOUR:-120}"
PROVIDER_DAILY_TOKEN_BUDGET="${PROVIDER_DAILY_TOKEN_BUDGET:-100000}"
MAX_ACTIONS_PER_HOUR="${MAX_ACTIONS_PER_HOUR:-200}"
case "${MAX_ACTIONS_PER_HOUR}" in
    ''|*[!0-9]*) bashio::log.fatal "max_actions_per_hour is invalid; refusing to start"; exit 1 ;;
esac
[ "${MAX_ACTIONS_PER_HOUR}" -ge 50 ] && [ "${MAX_ACTIONS_PER_HOUR}" -le 1000 ] || {
    bashio::log.fatal "max_actions_per_hour is outside the safe range; refusing to start"
    exit 1
}
case "${PROVIDER_MAX_REQUESTS_HOUR}" in
    ''|*[!0-9]*) bashio::log.fatal "provider_max_requests_per_hour is invalid; refusing to start"; exit 1 ;;
esac
case "${PROVIDER_DAILY_TOKEN_BUDGET}" in
    ''|*[!0-9]*) bashio::log.fatal "provider_daily_token_budget is invalid; refusing to start"; exit 1 ;;
esac
[ "${PROVIDER_MAX_REQUESTS_HOUR}" -ge 1 ] && [ "${PROVIDER_MAX_REQUESTS_HOUR}" -le 1000 ] || {
    bashio::log.fatal "provider_max_requests_per_hour is outside the safe range; refusing to start"
    exit 1
}
[ "${PROVIDER_DAILY_TOKEN_BUDGET}" -ge 1024 ] && [ "${PROVIDER_DAILY_TOKEN_BUDGET}" -le 10000000 ] || {
    bashio::log.fatal "provider_daily_token_budget is outside the safe range; refusing to start"
    exit 1
}

# Lists — bashio outputs newline-separated for list(str). Convert to comma-joined for shell use.
POLICY_EXTRA_DENY=$(bashio::config 'policy_extra_deny' | tr '\n' ',' | sed 's/,$//')
POLICY_EXTRA_CONFIRM=$(bashio::config 'policy_extra_confirm' | tr '\n' ',' | sed 's/,$//')
POLICY_EXTRA_ALLOW=$(bashio::config 'policy_extra_allow' | tr '\n' ',' | sed 's/,$//')

# Persisted Supervisor options can outlive the schema that created them.  Use
# conservative defaults for absent legacy policy fields, but refuse malformed
# values rather than silently weakening a gate (especially climate deltas and
# quiet-hours confirmation).
POLICY_MODE="${POLICY_MODE:-balanced}"
POLICY_QUIET_CONFIRM="${POLICY_QUIET_CONFIRM:-true}"
POLICY_BULK_THRESHOLD="${POLICY_BULK_THRESHOLD:-3}"
POLICY_CLIMATE_DELTA="${POLICY_CLIMATE_DELTA:-3}"
case "${POLICY_MODE}" in
    strict|balanced|permissive|custom) ;;
    *) bashio::log.fatal "policy_mode is invalid; refusing to start"; exit 1 ;;
esac
case "${POLICY_QUIET_CONFIRM}" in
    true|false) ;;
    *) bashio::log.fatal "policy_quiet_hours_require_confirm is invalid; refusing to start"; exit 1 ;;
esac
case "${POLICY_BULK_THRESHOLD}" in
    ''|*[!0-9]*) bashio::log.fatal "policy_bulk_action_threshold is invalid; refusing to start"; exit 1 ;;
esac
case "${POLICY_CLIMATE_DELTA}" in
    ''|*[!0-9]*) bashio::log.fatal "policy_climate_delta_confirm_c is invalid; refusing to start"; exit 1 ;;
esac
[ "${POLICY_BULK_THRESHOLD}" -ge 2 ] && [ "${POLICY_BULK_THRESHOLD}" -le 50 ] || {
    bashio::log.fatal "policy_bulk_action_threshold is outside the safe range; refusing to start"
    exit 1
}
[ "${POLICY_CLIMATE_DELTA}" -ge 1 ] && [ "${POLICY_CLIMATE_DELTA}" -le 20 ] || {
    bashio::log.fatal "policy_climate_delta_confirm_c is outside the safe range; refusing to start"
    exit 1
}

case "${PROVIDER_KEY_MODE}" in
    direct_temporary)
        # Explicit, temporary exception for existing installations that have
        # not migrated to the root-owned model broker yet.
        if [ "${ENABLE_WRITE_ACTIONS}" = "true" ]; then
            bashio::log.fatal "provider_key_mode=direct_temporary cannot be combined with write actions; migrate to broker mode first."
            exit 1
        fi
        bashio::log.warning "Provider key is in direct_temporary mode; the planner can read it. Keep production writes disabled and migrate to provider_key_mode=broker."
        export ZEROCLAW_API_KEY="${OPENROUTER_KEY}"
        ;;
    broker)
        # The planner gets only a non-secret local credential.  The root-owned
        # provider broker below attaches OPENROUTER_KEY to the fixed upstream.
        export ZEROCLAW_API_KEY="local-provider-broker"
        ;;
    *)
        bashio::log.fatal "provider_key_mode must be direct_temporary or broker."
        exit 1
        ;;
esac
export RUST_LOG="${LOG_LEVEL}"

for var in OPENROUTER_KEY TELEGRAM_TOKEN HA_TOKEN; do
    eval val=\$$var
    [ -z "$val" ] && { bashio::log.fatal "${var} not set!"; exit 1; }
done

# Telegram users → first user (the sole approval owner for this release)
FIRST_USER=$(echo "$TELEGRAM_USERS" | cut -d',' -f1 | tr -d ' ')
printf '%s' "$FIRST_USER" | grep -Eq '^[0-9]+$' || {
    bashio::log.fatal "telegram_allowed_users must begin with a numeric Telegram user ID (the approval owner)."
    exit 1
}

# Daily report time is stored and scheduled as UTC. A future timezone-aware
# option can convert it explicitly; do not bake a user's location into the
# image or entrypoint.
REPORT_HOUR=$(echo "$DAILY_REPORT_TIME" | cut -d: -f1 | sed 's/^0*//')
REPORT_MIN=$(echo "$DAILY_REPORT_TIME" | cut -d: -f2 | sed 's/^0*//')
[ -z "$REPORT_HOUR" ] && REPORT_HOUR=0
[ -z "$REPORT_MIN" ] && REPORT_MIN=0
REPORT_UTC_HOUR="${REPORT_HOUR}"

CONFIG_DIR="/data"
WS="${CONFIG_DIR}/workspace"
HA_URL="http://supervisor/core/api"
GW="http://127.0.0.1:42617"
export HA_URL
[ -d /data ] && [ ! -L /data ] || {
    bashio::log.fatal "/data must be a real persistent directory"
    exit 1
}
if [ -z "${SUPERVISOR_TOKEN:-}" ] && [ -n "${LEGACY_HA_TOKEN}" ]; then
    bashio::log.warning "Using deprecated ha_token option; migrate to the Supervisor token before enabling writes."
fi
if [ "${ENABLE_WRITE_ACTIONS}" != "true" ]; then
    bashio::log.warning "Write actions are disabled by default; enable only after reviewing the broker and policy settings."
fi
if [ "${ENABLE_CREATION}" = "true" ]; then
    bashio::log.fatal "enable_creation_skill is reserved until a broker-backed Home Assistant config writer is implemented; keep it false."
    exit 1
fi
if [ -L /data/logs ]; then
    rm -f /data/logs
fi
# A planner-controlled symlink at the persistent root could redirect a later
# root-owned write or migration copy.  Refuse the installation rather than
# following any such entry.  The legacy logs link above is the sole tolerated
# compatibility cleanup, and it is removed before this check.
for entry in /data/* /data/.[!.]* /data/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -L "$entry" ]; then
        bashio::log.fatal "persistent root entry is a symlink: ${entry}"
        exit 1
    fi
done
mkdir -p "${WS}/skills/ha" /data/logs /data/pending /data/approved /data/audit /data/undo /data/tools /data/routines /data/provider /data/capability /data/approval-receipts/tickets
# Broker logs are root-owned state.  Remove legacy symlinks before any root
# listener opens a log path, then keep the directory unreadable to the planner.
find /data/logs -type l -exec rm -f {} \; 2>/dev/null || true
chown -R root:root /data/logs
chmod 0750 /data/logs
find /data/logs -type f -exec chmod 0640 {} \; 2>/dev/null || true
chown -R root:root /data/provider
chmod 0700 /data/provider
chown -R root:root /data/capability
chmod 0700 /data/capability

# Do not let a planner-controlled symlink hide or redirect a root-owned state
# file.  Workspace/pending/routines/tools are the only intentionally
# planner-writable trees; their contents are still rejected if symlinks are
# present because root adapters read selected files from pending state.
for state_tree in "${WS}" /data/pending /data/routines /data/tools /data/approved \
    /data/audit /data/undo /data/logs /data/provider /data/capability /data/approval-receipts /data/migrations; do
    [ -d "$state_tree" ] || continue
    if find "$state_tree" -type l -print -quit | grep -q .; then
        bashio::log.fatal "persistent state tree contains a symlink: ${state_tree}"
        exit 1
    fi
done

# Snapshot persistent state before rendering this release's config.toml. The
# version marker is root-only state; the planner must not be able to rewrite it
# and suppress or fabricate an upgrade snapshot.
VF="${CONFIG_DIR}/.state-version"
LEGACY_VF="${WS}/.last_version"
if [ ! -e "$VF" ] && [ -f "$LEGACY_VF" ]; then
    LEGACY_VERSION=$(tr -d '\r\n' < "$LEGACY_VF")
    case "$LEGACY_VERSION" in
        ''|*[!A-Za-z0-9._-]*)
            bashio::log.warning "Ignoring malformed legacy version marker; treating state as fresh."
            ;;
        *)
            printf '%s\n' "$LEGACY_VERSION" > "$VF"
            ;;
    esac
    rm -f "$LEGACY_VF"
fi
if [ -e "$VF" ] && [ ! -f "$VF" ]; then
    bashio::log.fatal "persistent version marker is not a regular file"
    exit 1
fi
if ! /opt/zeroclaw/lib/state-migrate.sh "${CONFIG_DIR}" "$VF" "${ADDON_VERSION}"; then
    bashio::log.fatal "State migration failed; refusing to start without a rollback snapshot."
    exit 1
fi
chown root:root "$VF"
chmod 0600 "$VF"

# ==============================================================
# Typed capability broker and read-only HA helpers
# ==============================================================
install -m 0755 /opt/zeroclaw/lib/capability-broker-handler.sh /usr/local/bin/ha-broker-handler
install -m 0755 /opt/zeroclaw/lib/ha-capability.sh /usr/local/bin/ha-capability
install -m 0755 /opt/zeroclaw/lib/capability-broker-entrypoint.sh /usr/local/bin/ha-broker-entrypoint

# Broker provider credentials when requested.  The direct_temporary mode is
# retained only as an explicit migration exception for existing installs.
if [ "${PROVIDER_KEY_MODE}" = "broker" ]; then
    install -m 0755 /opt/zeroclaw/lib/provider-broker-handler.sh /usr/local/bin/provider-broker-handler
    install -m 0755 /opt/zeroclaw/lib/provider-broker-entrypoint.sh /usr/local/bin/provider-broker-entrypoint
    PROVIDER_PORT=42620
    (
        export OPENROUTER_KEY
        # The endpoint remains root-controlled.  The test-only override lets
        # the real arm64 planner binary exercise this broker against a local
        # deterministic upstream without ever exposing a provider key to it.
        export PROVIDER_UPSTREAM_URL="${ZEROCLAW_PROVIDER_UPSTREAM_URL:-https://openrouter.ai/api/v1/chat/completions}"
        export PROVIDER_ALLOWED_MODELS="${DEFAULT_MODEL},${COMPLEX_MODEL},google/gemini-flash-latest,deepseek/deepseek-v4-pro"
        export PROVIDER_MAX_TOKENS
        export PROVIDER_MAX_REQUESTS_PER_HOUR="${PROVIDER_MAX_REQUESTS_HOUR}"
        export PROVIDER_DAILY_TOKEN_BUDGET="${PROVIDER_DAILY_TOKEN_BUDGET}"
        export PROVIDER_QUOTA_FILE="/data/provider/quota.json"
        export PROVIDER_QUOTA_LOCK="/data/provider/.quota.lock"
        while true; do
            if ! /bin/busybox nc -l -p "${PROVIDER_PORT}" -s 127.0.0.1 \
                -e /usr/local/bin/provider-broker-entrypoint >>/data/logs/provider-broker.log 2>&1; then
                sleep 1
            fi
        done
    ) &
fi

# BusyBox nc is a minimal local transport. The broker is the only child
# process that receives HA_TOKEN; ZeroClaw is started with HA/Telegram
# credential variables removed below.
CAPABILITY_PORT=42618
(
    export HA_TOKEN HA_URL
    export ENABLE_WRITE_ACTIONS
    export CAPABILITY_MAX_ACTIONS_PER_HOUR="${MAX_ACTIONS_PER_HOUR}"
    export CAPABILITY_QUOTA_FILE="/data/capability/quota.json"
    export CAPABILITY_QUOTA_LOCK="/data/capability/.quota.lock"
    export POLICY_MODE POLICY_QUIET_CONFIRM POLICY_BULK_THRESHOLD POLICY_CLIMATE_DELTA
    export QUIET_HOURS
    export EXTRA_DENY="${POLICY_EXTRA_DENY}"
    export EXTRA_CONFIRM="${POLICY_EXTRA_CONFIRM}"
    export EXTRA_ALLOW="${POLICY_EXTRA_ALLOW}"
    while true; do
        if ! /bin/busybox nc -l -p "${CAPABILITY_PORT}" -s 127.0.0.1 \
            -e /usr/local/bin/ha-broker-entrypoint >>/data/logs/capability-broker.log 2>&1; then
            sleep 1
        fi
    done
) &
CAPABILITY_BROKER_PID=$!

cat > /usr/local/bin/ha-lights-on << 'SCRIPT'
#!/bin/sh
exec /usr/local/bin/ha-capability read_lights
SCRIPT

cat > /usr/local/bin/ha-ac-status << 'SCRIPT'
#!/bin/sh
exec /usr/local/bin/ha-capability read_climate
SCRIPT

cat > /usr/local/bin/ha-cover-status << 'SCRIPT'
#!/bin/sh
exec /usr/local/bin/ha-capability read_covers
SCRIPT

cat > /usr/local/bin/ha-sensors << 'SCRIPT'
#!/bin/sh
exec /usr/local/bin/ha-capability read_sensors
SCRIPT

cat > /usr/local/bin/ha-state << 'SCRIPT'
#!/bin/sh
# Usage: ha-state <entity_id>
RAW=$(/usr/local/bin/ha-capability get_state "$1") || { echo "(unavailable)"; exit 1; }
printf '%s\n' "$RAW" | jq -r '"\(.attributes.friendly_name // .entity_id): \(.state)\(if .attributes.temperature then " set:\(.attributes.temperature)C" else "" end)\(if .attributes.current_temperature then " now:\(.attributes.current_temperature)C" else "" end)"'
SCRIPT

cat > /usr/local/bin/ha-all-status << 'SCRIPT'
#!/bin/sh
echo "=LIGHTS="
ha-lights-on 2>/dev/null || echo "(unavailable)"
echo "=AC="
ha-ac-status 2>/dev/null || echo "(unavailable)"
echo "=COVERS="
ha-cover-status 2>/dev/null || echo "(unavailable)"
SCRIPT

cat > /usr/local/bin/ha-logbook << 'SCRIPT'
#!/bin/sh
if [ -n "${1:-}" ]; then
    RAW=$(/usr/local/bin/ha-capability get_logbook "$1") || { echo "(unavailable)"; exit 1; }
    printf '%s\n' "$RAW" | jq -r '.[] | "\(.when): \(.name) \(.message)"' 2>/dev/null || echo "No logbook data"
else
    RAW=$(/usr/local/bin/ha-capability get_logbook) || { echo "(unavailable)"; exit 1; }
    printf '%s\n' "$RAW" | jq -r '.[-20:] | .[] | "\(.when): \(.name) \(.message)"' 2>/dev/null || echo "No logbook data"
fi
SCRIPT

cat > /usr/local/bin/ha-errors << 'SCRIPT'
#!/bin/sh
RAW=$(/usr/local/bin/ha-capability get_error_log) || { echo "(unavailable)"; exit 1; }
printf '%s\n' "$RAW" | tail -40
SCRIPT

# Compatibility name retained for the policy gate. This is no longer a raw
# REST client: the broker validates the service and payload before calling HA.
cat > /usr/local/bin/ha-action-raw << 'SCRIPT'
#!/bin/sh
# Usage: ha-action-raw <service_path> <json_body>
[ "${ZEROCLAW_INTERNAL_ACTION:-}" = "1" ] || { echo "ERROR: raw HA actions are internal-only" >&2; exit 1; }
exec /usr/local/bin/ha-capability call_service "$1" "$2"
SCRIPT

# ==============================================================
# Policy engine — options are authoritative for this defensive release
# ==============================================================
POLICY_FILE="/config/zeroclaw_policy.yaml"
if [ -f "$POLICY_FILE" ]; then
    bashio::log.warning "Legacy ${POLICY_FILE} is not parsed; use add-on policy options until the canonical broker policy is installed."
fi

# ==============================================================
# Install pure-function policy decider from /opt/zeroclaw/lib/
# (covered by zeroclaw/tests/policy_decide.bats — see CI)
# ==============================================================
install -m 0755 /opt/zeroclaw/lib/policy-decide.sh /usr/local/bin/policy-decide
install -m 0755 /opt/zeroclaw/lib/approval-transition.sh /usr/local/bin/zc-approval-transition
install -m 0755 /opt/zeroclaw/lib/state-restore.sh /usr/local/bin/state-restore

# Telegram credentials are held in a root-only runtime file and consumed by a
# root-owned broker/watcher. Agent-side helpers only send typed local requests.
mkdir -p /run/zeroclaw
chmod 0700 /run/zeroclaw
TG_USERS_FILE="/run/zeroclaw/telegram-users"
echo "${TELEGRAM_USERS}" | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9]+$' > "${TG_USERS_FILE}" || true
chown root:root "${TG_USERS_FILE}"
chmod 0600 "${TG_USERS_FILE}"
TELEGRAM_OFFSET_FILE="/run/zeroclaw/telegram-offset"
# The old offset was planner-writable.  Reset it instead of trusting a
# planner-controlled cursor; Telegram updates are harmlessly revalidated.
printf '0\n' > "${TELEGRAM_OFFSET_FILE}"
rm -f /data/.tg_users /data/.tg_offset
chown root:root "${TELEGRAM_OFFSET_FILE}"
chmod 0600 "${TELEGRAM_OFFSET_FILE}"
TELEGRAM_TOKEN_FILE="/run/zeroclaw/telegram-token"
printf '%s' "${TELEGRAM_TOKEN}" > "${TELEGRAM_TOKEN_FILE}"
chown root:root "${TELEGRAM_TOKEN_FILE}"
chmod 0600 "${TELEGRAM_TOKEN_FILE}"
install -m 0755 /opt/zeroclaw/lib/telegram-broker-handler.sh /usr/local/bin/tg-broker-handler
install -m 0755 /opt/zeroclaw/lib/telegram-capability.sh /usr/local/bin/tg-capability
install -m 0755 /opt/zeroclaw/lib/telegram-broker-entrypoint.sh /usr/local/bin/tg-broker-entrypoint
TELEGRAM_PORT=42619
(
    export TELEGRAM_TOKEN_FILE
    export TELEGRAM_APPROVAL_CHAT="${FIRST_USER}"
    while true; do
        if ! /bin/busybox nc -l -p "${TELEGRAM_PORT}" -s 127.0.0.1 \
            -e /usr/local/bin/tg-broker-entrypoint >>/data/logs/telegram-broker.log 2>&1; then
            sleep 1
        fi
    done
) &

# ==============================================================
# tg-send-approval — render a Telegram message with inline-keyboard
# chips ([✅ Approve] / [❌ Reject] / [💬 Discuss]) and persist the
# returned message_id back into the ticket so the callback watcher
# can edit-in-place after the user taps a chip.
# ==============================================================
cat > /usr/local/bin/tg-send-approval << SCRIPT
#!/bin/sh
# Usage: tg-send-approval <ticket_short_id> "<text>"
set -e
SHORT="\$1"; TEXT="\$2"
[ -z "\$SHORT" ] || [ -z "\$TEXT" ] && { echo "Usage: tg-send-approval <id8> <text>"; exit 1; }
TICKET="/data/pending/\${SHORT}.json"
[ ! -f "\$TICKET" ] && { echo "ERROR: ticket missing"; exit 1; }

RESP=\$(/usr/local/bin/tg-capability send_approval "\$SHORT" "${FIRST_USER}" "\$TEXT")

SCRIPT

# ==============================================================
# tg-callback-watcher — single owner of the Telegram bot socket.
# Long-polls ALL updates (messages + callback_query) because Telegram
# permits only one getUpdates client per bot. Replaces ZeroClaw's
# built-in Telegram channel entirely:
#   • .message      → validate sender, forward text to gateway /webhook,
#                     send the agent's response back via sendMessage
#   • .callback_query → validate sender, apply the ticket directly,
#                     edit message in place, ping agent for audit
#
# Wire format for chips: callback_data = "zcv1:<verb>:<id8>" where verb
# is one of approve|reject|discuss.
# ==============================================================
cat > /usr/local/bin/tg-callback-watcher << SCRIPT
#!/bin/sh
set -u
TOKEN=\$(cat "${TELEGRAM_TOKEN_FILE}")
OFFSET_F="/run/zeroclaw/telegram-offset"
USERS_F="${TG_USERS_FILE}"
GW="${GW}"
APPROVAL_USER="${FIRST_USER}"
APPROVAL_CHAT="${FIRST_USER}"
[ -f "\$OFFSET_F" ] || echo 0 > "\$OFFSET_F"

# Keep the Telegram bot token in a private curl config file. The URL is never
# passed as a child-process argument, which prevents token leakage through ps
# or /proc command-line inspection by a same-container observer.
telegram_curl() {
    method="\$1"
    shift
    config_file=\$(mktemp /run/zeroclaw/.telegram-curl.XXXXXX) || return 1
    chmod 0600 "\$config_file"
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "\$TOKEN" "\$method" > "\$config_file"
    curl --config "\$config_file" "\$@"
    rc=\$?
    rm -f "\$config_file"
    return "\$rc"
}

answer_cb() {
    cb_id="\$1"; text="\$2"
    telegram_curl answerCallbackQuery -s -X POST \\
        --data-urlencode "callback_query_id=\$cb_id" \\
        --data-urlencode "text=\$text" >/dev/null 2>&1 || true
}

edit_msg() {
    chat_id="\$1"; msg_id="\$2"; new_text="\$3"
    # Strip the inline keyboard by omitting reply_markup on edit.
    telegram_curl editMessageText -s -X POST \\
        -H "Content-Type: application/json" \\
        -d "\$(jq -nc --arg c "\$chat_id" --argjson m "\$msg_id" --arg t "\$new_text" \\
              '{chat_id:\$c, message_id:\$m, text:\$t}')" >/dev/null 2>&1 || true
}

send_msg() {
    chat_id="\$1"; text="\$2"
    telegram_curl sendMessage -s -X POST \\
        --data-urlencode "chat_id=\$chat_id" \\
        --data-urlencode "text=\$text" >/dev/null 2>&1 || true
}

send_typing() {
    chat_id="\$1"
    telegram_curl sendChatAction -s -X POST \\
        --data-urlencode "chat_id=\$chat_id" \\
        --data-urlencode "action=typing" >/dev/null 2>&1 || true
}

is_allowed_user() {
    uid="\$1"
    [ ! -f "\$USERS_F" ] && return 1
    grep -Fx "\$uid" "\$USERS_F" >/dev/null 2>&1
}

approval_id() {
    printf '%s' "\$1" | sed -nE 's/^[[:space:]]*[Yy][Ee][Ss][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p'
}

rejection_id() {
    printf '%s' "\$1" | sed -nE 's/^[[:space:]]*[Nn][Oo][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p'
}

apply_approved_ticket() {
    short="\$1"; actor="\$2"; chat="\$3"
    ticket="/data/approval-receipts/tickets/\${short}.json"
    kind=\$(jq -r '.payload.kind // "action"' "\$ticket")
    if [ "\$kind" = "scene" ] || [ "\$kind" = "automation" ]; then
        if ! OUT=\$(ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/ha-apply-creation "\$short" 2>&1); then
            printf '%s\n' "\$OUT"
            return 1
        fi
    else
        if ! OUT=\$(ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/ha-action-guarded --apply-ticket "\$short" 2>&1); then
            printf '%s\n' "\$OUT"
            return 1
        fi
    fi
    printf '%s\n' "\$OUT"
}

# Forward an inbound text message to the gateway and relay the response.
handle_message() {
    chat_id="\$1"; from_id="\$2"; text="\$3"
    if ! is_allowed_user "\$from_id"; then
        send_msg "\$chat_id" "Not authorized."
        return
    fi
    [ -z "\$text" ] && return

    APPROVE_ID=\$(approval_id "\$text")
    REJECT_ID=\$(rejection_id "\$text")
    if [ -n "\$APPROVE_ID" ] || [ -n "\$REJECT_ID" ]; then
        SHORT="\${APPROVE_ID:-\$REJECT_ID}"
        if [ "\$from_id" != "\$APPROVAL_USER" ] || [ "\$chat_id" != "\$APPROVAL_CHAT" ]; then
            send_msg "\$chat_id" "This approval belongs to the configured approval owner."
            return
        fi
        TICKET="/data/approval-receipts/tickets/\${SHORT}.json"
        if [ ! -f "\$TICKET" ]; then
            send_msg "\$chat_id" "Ticket \${SHORT} is expired or already actioned."
            return
        fi
        SUMMARY=\$(jq -r '.summary // "(action)"' "\$TICKET")
        if [ -n "\$APPROVE_ID" ]; then
            if ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition approve "\$SHORT" "\$from_id" "\$chat_id" >/dev/null 2>&1; then
                if OUT=\$(apply_approved_ticket "\$SHORT" "\$from_id" "\$chat_id"); then
                    send_msg "\$chat_id" "✅ Approved and applied: \${SUMMARY}
\${OUT}"
                else
                    send_msg "\$chat_id" "⚠️ Approved, but execution failed; the claim remains for recovery.
\${OUT}"
                fi
            else
                send_msg "\$chat_id" "Approval for \${SHORT} could not be applied."
            fi
        elif ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition reject "\$SHORT" "\$from_id" "\$chat_id" >/dev/null 2>&1; then
            send_msg "\$chat_id" "❌ Rejected: \${SUMMARY}"
        else
            send_msg "\$chat_id" "Rejection for \${SHORT} could not be applied."
        fi
        return
    fi

    # v3.1.3: correction-detection branch.
    # If the previous turn produced an outcome AND the user's reply opens with
    # a correction marker, fire a synthetic learning prompt to the gateway in
    # the background. The agent will produce a one-line lesson and persist it
    # via zc.lesson_add. We only fire when /data/.last_outcome exists, so a
    # bare "no" in response to a question (no outcome stored) won't trigger.
    # v3.1.3.1: regex widened to catch "they're not on", "didn't work",
    # "still off", "isn't", "nothing happened" — common real corrections that
    # don't open with the "no/wrong" markers.
    LAST_OUTCOME_FILE="/data/.last_outcome"
    if [ -f "\$LAST_OUTCOME_FILE" ]; then
        # Lowercase + trim leading whitespace for matching only
        tlc=\$(printf '%s' "\$text" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//')
        case "\$tlc" in
            no|"no "*|"no,"*|"no."*|"no!"*|wrong*|actually*|"that's wrong"*|"not that"*|"i meant"*|\
            "they're not"*|"theyre not"*|"they are not"*|"they aren't"*|"they arent"*|\
            "it's not"*|"its not"*|"it is not"*|"it isn't"*|"it isnt"*|\
            "isn't"*|"isnt"*|"didn't"*|"didnt"*|"did not"*|\
            "still off"*|"still on"*|"still not"*|"still nothing"*|\
            "nothing happened"*|"nothing changed"*|"that didn't"*|"that didnt"*|\
            "doesn't work"*|"doesnt work"*|"not working"*|"didn't work"*|"didnt work"*|\
            لا|"لا "*|"لا،"*|"لا,"*|غلط*|"ما اشتغل"*|"ماشتغل"*|"مو شغال"*|"لسه"*|"لسة"*)
                LAST=\$(cat "\$LAST_OUTCOME_FILE" 2>/dev/null)
                rm -f "\$LAST_OUTCOME_FILE"
                if [ -n "\$LAST" ]; then
                    CP="User correction received. Previous turn outcome was: \${LAST}. User just said: \${text}. Generate ONE lesson line ≤80 chars that would prevent this mistake next time, then call zc.lesson_add with it. Do not message the user — this is a silent learning hook."
                    CBODY=\$(jq -nc --arg m "\$CP" '{message:\$m}')
                    (curl -s --max-time 60 -X POST "\${GW}/webhook" \\
                        -H "Content-Type: application/json" -d "\$CBODY" >/dev/null 2>&1) &
                fi
                ;;
        esac
    fi

    send_typing "\$chat_id"
    BODY=\$(jq -nc --arg m "\$text" '{message:\$m}')
    RESP=\$(curl -s --max-time 60 -X POST "\${GW}/webhook" \\
        -H "Content-Type: application/json" -d "\$BODY" 2>/dev/null)
    REPLY=\$(echo "\$RESP" | jq -r '.response // .reply // .text // empty' 2>/dev/null)
    [ -z "\$REPLY" ] && REPLY="(no response)"
    # Telegram message limit is 4096 chars; truncate defensively.
    REPLY=\$(printf '%s' "\$REPLY" | cut -c1-4000)
    send_msg "\$chat_id" "\$REPLY"
}

while true; do
    OFFSET=\$(cat "\$OFFSET_F" 2>/dev/null || echo 0)
    # Long-poll up to 25s for both message + callback_query updates.
    # We are the SOLE poller for this bot — ZC's telegram channel is disabled.
    RESP=\$(telegram_curl getUpdates -s --max-time 30 --get \\
        --data-urlencode "offset=\$OFFSET" \\
        --data-urlencode "timeout=25" \\
        --data-urlencode 'allowed_updates=["message","callback_query"]' \\
        2>/dev/null)
    OK=\$(echo "\$RESP" | jq -r '.ok // false' 2>/dev/null)
    if [ "\$OK" != "true" ]; then
        sleep 5
        continue
    fi

    NEW_OFFSET=\$(echo "\$RESP" | jq -r '.result | (max_by(.update_id).update_id // empty)' 2>/dev/null)
    [ -n "\$NEW_OFFSET" ] && [ "\$NEW_OFFSET" != "null" ] && echo \$((NEW_OFFSET + 1)) > "\$OFFSET_F"

    echo "\$RESP" | jq -c '.result[]?' 2>/dev/null | while read -r upd; do
        # Branch on update kind. message and callback_query are mutually exclusive.
        MSG_TEXT=\$(echo "\$upd" | jq -r '.message.text // empty')
        if [ -n "\$MSG_TEXT" ]; then
            M_CHAT=\$(echo "\$upd" | jq -r '.message.chat.id // empty')
            M_FROM=\$(echo "\$upd" | jq -r '.message.from.id // empty')
            handle_message "\$M_CHAT" "\$M_FROM" "\$MSG_TEXT" &
            continue
        fi

        CB_ID=\$(echo "\$upd" | jq -r '.callback_query.id // empty')
        [ -z "\$CB_ID" ] && continue

        DATA=\$(echo "\$upd"  | jq -r '.callback_query.data // empty')
        FROM=\$(echo "\$upd"  | jq -r '.callback_query.from.id // empty')
        FROM_NAME=\$(echo "\$upd" | jq -r '.callback_query.from.first_name // "user"')
        CHAT_ID=\$(echo "\$upd" | jq -r '.callback_query.message.chat.id // empty')
        MSG_ID=\$(echo "\$upd"  | jq -r '.callback_query.message.message_id // empty')

        if ! is_allowed_user "\$FROM"; then
            answer_cb "\$CB_ID" "Not authorized."
            continue
        fi
        if [ "\$FROM" != "\$APPROVAL_USER" ] || [ "\$CHAT_ID" != "\$APPROVAL_CHAT" ]; then
            answer_cb "\$CB_ID" "This approval belongs to the configured approval owner."
            continue
        fi
        case "\$DATA" in
            zcv1:*) ;;
            *) answer_cb "\$CB_ID" "Unknown chip."; continue ;;
        esac
        VERB=\$(echo "\$DATA" | cut -d: -f2)
        SHORT=\$(echo "\$DATA" | cut -d: -f3)
        if ! printf '%s' "\$SHORT" | grep -Eq '^[a-f0-9]{8}$'; then
            answer_cb "\$CB_ID" "Invalid ticket."
            continue
        fi
        TICKET="/data/approval-receipts/tickets/\${SHORT}.json"

        if [ ! -f "\$TICKET" ]; then
            answer_cb "\$CB_ID" "Ticket expired or already actioned."
            [ -n "\$MSG_ID" ] && edit_msg "\$CHAT_ID" "\$MSG_ID" "(this approval is no longer pending)"
            continue
        fi

        SUMMARY=\$(jq -r '.summary // "(action)"' "\$TICKET")
        case "\$VERB" in
          approve)
              if ! ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition approve "\$SHORT" "\$FROM" "\$CHAT_ID" >/dev/null 2>&1; then
                  answer_cb "\$CB_ID" "Ticket is already actioned or no longer valid."
                  continue
              fi
              if OUT=\$(apply_approved_ticket "\$SHORT" "\$FROM" "\$CHAT_ID"); then
                  answer_cb "\$CB_ID" "Applied."
                  edit_msg "\$CHAT_ID" "\$MSG_ID" "✅ Approved by \${FROM_NAME}: \${SUMMARY}
\${OUT}"
                  curl -s -X POST "\${GW}/webhook" -H "Content-Type: application/json" \\
                      -d "\$(jq -nc --arg m "ZCAUTO ticket \${SHORT} approved via chip — outcome: \${OUT}" '{message:\$m}')" \\
                      >/dev/null 2>&1 || true
              else
                  answer_cb "\$CB_ID" "Execution failed; claim retained."
                  edit_msg "\$CHAT_ID" "\$MSG_ID" "⚠️ Approved by \${FROM_NAME}, but execution failed; claim retained for recovery.
\${OUT}"
                  curl -s -X POST "\${GW}/webhook" -H "Content-Type: application/json" \\
                      -d "\$(jq -nc --arg m "ZCAUTO ticket \${SHORT} approved via chip — execution failed; claim retained: \${OUT}" '{message:\$m}')" \\
                      >/dev/null 2>&1 || true
              fi
              ;;
          reject)
              if ! ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition reject "\$SHORT" "\$FROM" "\$CHAT_ID" >/dev/null 2>&1; then
                  answer_cb "\$CB_ID" "Ticket is already actioned or no longer valid."
                  continue
              fi
              answer_cb "\$CB_ID" "Rejected."
              edit_msg "\$CHAT_ID" "\$MSG_ID" "❌ Rejected by \${FROM_NAME}: \${SUMMARY}"
              ;;
          discuss)
              answer_cb "\$CB_ID" "Tell me more."
              send_msg "\$CHAT_ID" "About ticket \${SHORT} (\${SUMMARY}) — what would you like me to change or explain?"
              ;;
          *)
              answer_cb "\$CB_ID" "Unknown verb: \$VERB"
              ;;
        esac
    done
done
SCRIPT

# ==============================================================
# ha-action-guarded — the policy-enforced action gate
# The unguarded ha-action-raw is NOT in the agent's allowed_commands.
# Decision logic lives in /usr/local/bin/policy-decide (pure shell,
# unit-tested). This wrapper handles ticket apply, climate baseline
# fetch, and execution/audit/Telegram side-effects.
# ==============================================================
cat > /usr/local/bin/ha-action-guarded << SCRIPT
#!/bin/sh
# Usage: ha-action-guarded <service_path> <json_body>
#        ha-action-guarded --apply-ticket <uuid>
# Returns:
#   0 + result    on allow
#   2 + ticket    on confirm
#   1 + reason    on deny

set -e

[ "${ENABLE_WRITE_ACTIONS}" = "true" ] || { echo "Write actions are disabled by default; the broker and policy gates must be enabled explicitly."; exit 1; }
export ZEROCLAW_INTERNAL_ACTION=1

# Export policy environment so /usr/local/bin/policy-decide sees it.
export POLICY_MODE="${POLICY_MODE}"
export POLICY_QUIET_CONFIRM="${POLICY_QUIET_CONFIRM}"
export POLICY_BULK_THRESHOLD="${POLICY_BULK_THRESHOLD}"
export POLICY_CLIMATE_DELTA="${POLICY_CLIMATE_DELTA}"
export QUIET_HOURS="${QUIET_HOURS}"
export EXTRA_DENY="${POLICY_EXTRA_DENY}"
export EXTRA_CONFIRM="${POLICY_EXTRA_CONFIRM}"
export EXTRA_ALLOW="${POLICY_EXTRA_ALLOW}"

# --- Apply-ticket short circuit ---
if [ "\$1" = "--apply-ticket" ]; then
    [ "\$(id -u)" -eq 0 ] || { echo "ERROR: ticket application is Telegram-adapter-only" >&2; exit 1; }
    UUID="\$2"
    TICKET="/data/approval-receipts/tickets/\${UUID}.json"
    [ ! -f "\$TICKET" ] && { echo "ERROR: ticket \${UUID} missing"; exit 1; }
    SVC=\$(jq -r .service "\$TICKET")
    BODY=\$(jq -c .payload "\$TICKET")
    # The root broker verifies and consumes the sealed ticket transactionally.
    # Claim state is carried by root-owned state, never by an environment
    # variable that would stop at the local TCP boundary.
    if OUT=\$(ZEROCLAW_APPROVAL_TICKET="\$UUID" /usr/local/bin/ha-action-raw "\$SVC" "\$BODY"); then
        :
    else
        /usr/local/bin/zc-audit-write failed "\$SVC" "\$BODY" "ticket=\${UUID};broker_failed" || echo "WARNING: broker failure could not be written to the audit store" >&2
        echo "ERROR: approved action failed or its outcome audit was unavailable; the claim remains for recovery" >&2
        exit 1
    fi
    echo "\$OUT"
    exit 0
fi

SERVICE="\$1"
BODY="\$2"
[ -z "\$SERVICE" ] || [ -z "\$BODY" ] && { echo "Usage: ha-action-guarded <svc> <body>"; exit 1; }

DOMAIN=\${SERVICE%%/*}
ACTION=\${SERVICE##*/}
ENTITY=\$(echo "\$BODY" | jq -r '.entity_id // ""' 2>/dev/null)

# Bulk-action count: number of entity_ids in the body (server-side because
# we don't want to JSON-parse arrays in the pure-function decider).
BULK_COUNT=\$(echo "\$BODY" | jq -r '
    if (.entity_id | type) == "array" then (.entity_id | length)
    elif (.entity_id | type) == "string" then 1
    else 0 end
' 2>/dev/null)
if [ -n "\$BULK_COUNT" ] && [ "\$BULK_COUNT" -gt 1 ]; then
    export POLICY_BULK_COUNT="\$BULK_COUNT"
fi

# Climate baseline: live fetch from HA so the pure decider can compare.
if [ "\$DOMAIN" = "climate" ] && [ "\$ACTION" = "set_temperature" ] && [ -n "\$ENTITY" ]; then
    CUR=\$(/usr/local/bin/ha-capability get_state "\$ENTITY" 2>/dev/null | \
        jq -r '.attributes.current_temperature // .attributes.temperature // empty')
    [ -n "\$CUR" ] && export POLICY_CLIMATE_CURRENT="\$CUR"
fi

VERDICT=\$(/usr/local/bin/policy-decide "\$DOMAIN" "\$ACTION" "\$ENTITY" "\$BODY")
KIND=\${VERDICT%%:*}

# --- Audit row + execute ---
case "\$KIND" in
    allow)
        # Snapshot prev state for undo
        if [ -n "\$ENTITY" ] && [ "${ENABLE_UNDO}" = "true" ]; then
            /usr/local/bin/ha-capability get_state "\$ENTITY" \
                > "/data/undo/\$(date -u +%s)-\${ENTITY//./_}.json" 2>/dev/null || true
        fi
        if OUT=\$(/usr/local/bin/ha-action-raw "\$SERVICE" "\$BODY"); then
            echo "\$OUT"
            exit 0
        fi
        echo "ERROR: action failed or its outcome audit was unavailable; inspect broker/audit state" >&2
        exit 1 ;;
    deny)
        if ! /usr/local/bin/zc-audit-write deny "\$SERVICE" "\$BODY" "\$VERDICT"; then
            echo "ERROR: policy denied the action, but the denial audit row could not be persisted" >&2
            exit 1
        fi
        echo "DENIED by policy: \$VERDICT. Change policy_* options; the legacy YAML policy is not active."
        exit 1 ;;
    confirm)
        UUID=\$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "\$RANDOM-\$RANDOM-\$RANDOM-\$\$")
        # Short UUID for chat ergonomics
        SHORT=\$(echo "\$UUID" | cut -c1-8)
        EXP=\$(( \$(date -u +%s) + 1800 ))
        TICKET="/data/pending/\${SHORT}.json"
        SUMMARY="\${SERVICE} on \${ENTITY:-(no entity)} — \$VERDICT"
        mkdir -p /data/pending
        echo "\$BODY" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "ERROR: action payload must be an object"; exit 1; }
        TICKET_TMP=\$(mktemp "/data/pending/.\${SHORT}.XXXXXX")
        jq -nc \\
          --arg uuid "\$SHORT" --arg svc "\$SERVICE" --argjson p "\$BODY" \\
          --arg sum "\$SUMMARY" --arg verdict "\$VERDICT" \\
          --arg approval_user "${FIRST_USER}" --arg approval_chat "${FIRST_USER}" \\
          --argjson exp "\$EXP" --argjson cre \$(date -u +%s) \\
          '{uuid:\$uuid,service:\$svc,payload:\$p,summary:\$sum,expires_at:\$exp,created_at:\$cre,verdict:\$verdict,approval:{actor_user_id:\$approval_user,chat_id:\$approval_chat,channel:"telegram"}}' \\
          > "\$TICKET_TMP"
        mv "\$TICKET_TMP" "\$TICKET"
        # v3.1.2: send with inline-keyboard chips. Falls back gracefully
        # to text-only "YES <id>"/"NO <id>" if Telegram refuses markup.
        MSG="⚠️ Approval needed (\${SHORT})
\${SUMMARY}
Tap a chip below — or reply YES \${SHORT} / NO \${SHORT}.
Expires in 30 min."
        if ! /usr/local/bin/tg-send-approval "\${SHORT}" "\$MSG" >/dev/null 2>&1; then
            /usr/local/bin/zc-audit-write confirm_failed "\$SERVICE" "\$BODY" "ticket=\${SHORT};notification_failed" || true
            echo "ERROR: approval ticket \${SHORT} was created but could not be delivered to Telegram." >&2
            exit 1
        fi
        if ! /usr/local/bin/zc-audit-write confirm "\$SERVICE" "\$BODY" "ticket=\${SHORT};\${VERDICT}"; then
            echo "ERROR: approval ticket \${SHORT} was delivered, but its audit row could not be persisted; ticket retained" >&2
            exit 1
        fi
        echo "CONFIRM_PENDING ticket=\${SHORT} reason=\${VERDICT}"
        exit 2 ;;
esac
SCRIPT

# ==============================================================
# zc-audit-write — append structured row to /data/audit/YYYY-MM-DD.jsonl
# ==============================================================
cat > /usr/local/bin/zc-audit-write << 'SCRIPT'
#!/bin/sh
# Usage: zc-audit-write <kind> <service> <body> <reason>
set -eu
KIND="$1"; SVC="$2"; BODY="$3"; REASON="$4"
if [ "$(id -u)" -ne 0 ]; then
    exec /usr/local/bin/ha-capability audit "$KIND" "$SVC" "$BODY" "$REASON"
fi
DATE=$(date -u +%Y-%m-%d)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENTITY=$(echo "$BODY" | jq -r '.entity_id // ""' 2>/dev/null)
mkdir -p /data/audit
ROW=$(jq -nc \
  --arg ts "$TS" --arg kind "$KIND" --arg svc "$SVC" \
  --arg entity "$ENTITY" --arg reason "$REASON" --argjson body "$BODY" \
  '{ts:$ts, kind:$kind, service:$svc, entity:$entity, body:$body, reason:$reason}')
LOCK="/data/audit/.lock"
ATTEMPTS=0
while ! mkdir "$LOCK" 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 100 ] || { echo "audit store is busy" >&2; exit 1; }
    sleep 0.1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
AUDIT_FILE="/data/audit/${DATE}.jsonl"
printf '%s\n' "$ROW" >> "$AUDIT_FILE"
chown root:zeroclaw "$AUDIT_FILE"
chmod 0640 "$AUDIT_FILE"
sync
[ "$(tail -n 1 "$AUDIT_FILE")" = "$ROW" ] || { echo "audit row verification failed" >&2; exit 1; }
SCRIPT

# ==============================================================
# zc-audit-tail — last N audit rows (for observer + reports)
# ==============================================================
cat > /usr/local/bin/zc-audit-tail << 'SCRIPT'
#!/bin/sh
N="${1:-20}"
DATE=$(date -u +%Y-%m-%d)
F="/data/audit/${DATE}.jsonl"
[ -f "$F" ] || { echo "(no audit yet today)"; exit 0; }
tail -n "$N" "$F"
SCRIPT

# ==============================================================
# zc-undo — revert last action(s) within 1h
# ==============================================================
cat > /usr/local/bin/zc-undo << SCRIPT
#!/bin/sh
# Usage: zc-undo [N]   — revert most recent N actions (default 1)
[ "${ENABLE_WRITE_ACTIONS}" = "true" ] || { echo "Write actions are disabled by default; the broker and policy gates must be enabled explicitly."; exit 1; }
[ "${ENABLE_UNDO}" != "true" ] && { echo "Undo is disabled in add-on options."; exit 1; }
N=\${1:-1}
[ "\$N" -gt 0 ] 2>/dev/null || { echo "Usage: zc-undo [positive count]"; exit 1; }
NOW=\$(date -u +%s)
CUTOFF=\$(( NOW - 3600 ))
COUNT=0
for F in \$(ls -1t /data/undo/*.json 2>/dev/null); do
    [ -f "\$F" ] || continue
    [ "\$COUNT" -ge "\$N" ] && break
    TS=\$(basename "\$F" | cut -d- -f1)
    [ "\$TS" -lt "\$CUTOFF" ] && continue
    ENTITY=\$(jq -r .entity_id "\$F" 2>/dev/null)
    DOMAIN=\${ENTITY%%.*}
    STATE=\$(jq -r .state "\$F")
    restore_step() {
        STEP_OUT=\$(/usr/local/bin/ha-action-guarded "\$1" "\$2" 2>&1) && return 0
        printf '%s\n' "\$STEP_OUT"
        return 1
    }
    RESTORE_OK=1
    case "\$DOMAIN" in
        light|switch|input_boolean)
            SVC="\${DOMAIN}/turn_\${STATE}"
            if ! restore_step "\$SVC" "{\"entity_id\":\"\$ENTITY\"}"; then RESTORE_OK=0; fi ;;
        climate)
            TEMP=\$(jq -r .attributes.temperature "\$F")
            MODE=\$(jq -r .attributes.hvac_mode "\$F")
            if [ -n "\$TEMP" ] && [ "\$TEMP" != "null" ]; then
                if ! restore_step "climate/set_temperature" "{\"entity_id\":\"\$ENTITY\",\"temperature\":\$TEMP}"; then RESTORE_OK=0; fi
            fi
            if [ "\$RESTORE_OK" = "1" ] && [ -n "\$MODE" ] && [ "\$MODE" != "null" ]; then
                if ! restore_step "climate/set_hvac_mode" "{\"entity_id\":\"\$ENTITY\",\"hvac_mode\":\"\$MODE\"}"; then RESTORE_OK=0; fi
            fi ;;
        cover)
            CSVC=\$([ "\$STATE" = "open" ] && echo "open_cover" || echo "close_cover")
            if ! restore_step "cover/\$CSVC" "{\"entity_id\":\"\$ENTITY\"}"; then RESTORE_OK=0; fi ;;
        *)
            echo "Undo is not implemented for domain \$DOMAIN."
            RESTORE_OK=0 ;;
    esac
    if [ "\$RESTORE_OK" = "1" ]; then
        # The typed broker records the actual restore service outcome. The
        # planner cannot mint a synthetic undo row after the fact.
        rm -f "\$F"
        COUNT=\$((COUNT + 1))
        echo "Reverted \$ENTITY → \$STATE"
    else
        echo "Undo for \$ENTITY was not completed; snapshot retained for retry after approval or recovery." >&2
    fi
done
[ "\$COUNT" = "0" ] && echo "Nothing to undo (no actions in last hour)."
SCRIPT

# ==============================================================
# zc-approve — agent-callable bridge for user "YES <short>" replies.
# Validates the message text matches before writing the marker.
# This is the deterministic check: the LLM cannot fabricate approvals
# because zc-approve refuses anything that isn't an exact YES <uuid>.
# ==============================================================
cat > /usr/local/bin/zc-approve << 'SCRIPT'
#!/bin/sh
# Compatibility wrapper. Telegram watcher owns the real approval transition.
# Usage: ZEROCLAW_APPROVAL_INTERNAL=1 zc-approve "YES <id>" <actor> <chat>
[ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || { echo "ERROR: approvals are Telegram-adapter-only" >&2; exit 1; }
MSG="$1"
ACTOR="$2"
CHAT="$3"
SHORT=$(echo "$MSG" | sed -nE 's/^[Yy][Ee][Ss][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p')
[ -n "$SHORT" ] || { echo "ERROR: message is not 'YES <id>'"; exit 1; }
exec /usr/local/bin/zc-approval-transition approve "$SHORT" "$ACTOR" "$CHAT"
SCRIPT

cat > /usr/local/bin/zc-reject << 'SCRIPT'
#!/bin/sh
# Compatibility wrapper. Telegram watcher owns the real rejection transition.
[ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || { echo "ERROR: approvals are Telegram-adapter-only" >&2; exit 1; }
MSG="$1"
ACTOR="$2"
CHAT="$3"
SHORT=$(echo "$MSG" | sed -nE 's/^[Nn][Oo][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p')
[ -z "$SHORT" ] && { echo "ERROR: not 'NO <id>'"; exit 1; }
exec /usr/local/bin/zc-approval-transition reject "$SHORT" "$ACTOR" "$CHAT"
SCRIPT

# ==============================================================
# v3.1.3 lessons loop — self-improvement primitives
# ==============================================================
# zc-set-outcome — agent records the one-line outcome of a completed action
# so the next user message can be classified as a correction (or not).
# Empty/missing file = no outcome to correct (greetings, status queries).
cat > /usr/local/bin/zc-set-outcome << 'SCRIPT'
#!/bin/sh
# Usage: zc-set-outcome "<one-line outcome>"
TEXT="$1"
[ -z "$TEXT" ] && exit 0
printf '%s\n' "$TEXT" > /data/.last_outcome
SCRIPT

# zc-lesson-add — append a one-line lesson to LESSONS.md (deduped, FIFO-capped).
# LESSONS.md is auto-prepended to every prompt, so growing this file
# improves the next turn at zero extra cost.
cat > /usr/local/bin/zc-lesson-add << SCRIPT
#!/bin/sh
# Usage: zc-lesson-add "<lesson text, ≤80 chars>"
TEXT="\$1"
[ -z "\$TEXT" ] && { echo "Usage: zc-lesson-add <text>"; exit 1; }
# Hard-truncate to 80 chars to keep prompt overhead bounded
TEXT=\$(printf '%s' "\$TEXT" | cut -c1-80)
LF="${WS}/LESSONS.md"
mkdir -p "${WS}"
if [ ! -f "\$LF" ]; then
    printf '# Lessons Learned (auto-prepended to every prompt)\n# Format: one short rule per line. Pinned lessons start with [PIN].\n' > "\$LF"
fi
# Dedup: skip if any existing line contains the new text as a substring
if grep -qF -- "\$TEXT" "\$LF" 2>/dev/null; then
    echo "Duplicate (skipped): \$TEXT"
    exit 0
fi
DATE=\$(date -u +%Y-%m-%d)
printf '%s %s\n' "\$DATE" "\$TEXT" >> "\$LF"
# FIFO cap: keep header (# lines) + last 50 lessons
LINES=\$(wc -l < "\$LF" 2>/dev/null || echo 0)
if [ "\$LINES" -gt 53 ]; then
    TMP=\$(mktemp)
    grep '^#' "\$LF" > "\$TMP" 2>/dev/null || true
    grep -v '^#' "\$LF" | tail -n 50 >> "\$TMP"
    mv "\$TMP" "\$LF"
fi
echo "Saved: \$TEXT"
SCRIPT

# ==============================================================
# zc-schedule — agent self-scheduling via ZeroClaw cron API
# ==============================================================
cat > /usr/local/bin/zc-schedule << SCRIPT
#!/bin/sh
# Usage: zc-schedule '<cron-expr>' '<message-to-self>' [name]
[ "${ENABLE_WRITE_ACTIONS}" = "true" ] || { echo "Scheduling is disabled by default; enable it only with broker review."; exit 1; }
CRON="\$1"; MSG="\$2"; NAME="\${3:-agent_self_\$(date +%s)}"
[ -z "\$CRON" ] || [ -z "\$MSG" ] && { echo "Usage: zc-schedule '<cron>' '<msg>' [name]"; exit 1; }
PAYLOAD=\$(jq -nc --arg n "\$NAME" --arg s "\$CRON" --arg c "\$MSG" \
    '{name:\$n, schedule:\$s, command:\$c}')
curl -s -X POST "${GW}/api/cron" -H "Content-Type: application/json" -d "\$PAYLOAD"
echo
SCRIPT

cat > /usr/local/bin/zc-schedule-once << SCRIPT
#!/bin/sh
# Usage: zc-schedule-once '<delay-minutes>' '<message-to-self>'
[ "${ENABLE_WRITE_ACTIONS}" = "true" ] || { echo "Scheduling is disabled by default; enable it only with broker review."; exit 1; }
DELAY="\$1"; MSG="\$2"
[ -z "\$DELAY" ] || [ -z "\$MSG" ] && { echo "Usage: zc-schedule-once <minutes> <msg>"; exit 1; }
TARGET=\$(date -u -d @\$(( \$(date +%s) + DELAY*60 )) +'%M %H %d %m *' 2>/dev/null)
[ -z "\$TARGET" ] && { echo "ERROR: date arithmetic failed"; exit 1; }
NAME="oneshot_\$(date +%s)"
PAYLOAD=\$(jq -nc --arg n "\$NAME" --arg s "\$TARGET" --arg c "\$MSG" \
    '{name:\$n, schedule:\$s, command:\$c, run_once:true}')
curl -s -X POST "${GW}/api/cron" -H "Content-Type: application/json" -d "\$PAYLOAD"
echo
SCRIPT

# ==============================================================
# zc-cost — surface ZeroClaw cost telemetry to the agent
# ==============================================================
cat > /usr/local/bin/zc-cost << SCRIPT
#!/bin/sh
curl -s "${GW}/api/cost" | jq -r '
"Today: \$\(.today_cost_usd // 0)  | Month: \$\(.month_cost_usd // 0)
Limit (day/month): \$\(.daily_limit_usd // "n/a") / \$\(.monthly_limit_usd // "n/a")
Tokens today: \(.today_tokens // 0)"
' 2>/dev/null || echo "Cost API not available"
SCRIPT

# ==============================================================
# world-state.sh — compact home-state header injected into prompts
# ==============================================================
cat > /usr/local/bin/zc-world-state << SCRIPT
#!/bin/sh
NOW=\$(date '+%Y-%m-%d %H:%M %Z')
DOW=\$(date +%a)
if LIGHTS_RAW=\$(/usr/local/bin/ha-lights-on 2>/dev/null); then
    LIGHTS_ON=\$(printf '%s\n' "\$LIGHTS_RAW" | awk 'NF{n++} END{print n+0}')
    LIGHTS_LIST=\$(printf '%s\n' "\$LIGHTS_RAW" | head -3 | awk -F: '{print \$1}' | tr '\n' ',' | sed 's/,$//')
else
    LIGHTS_ON="unavailable"
    LIGHTS_LIST=""
fi
if ACS_RAW=\$(/usr/local/bin/ha-ac-status 2>/dev/null); then
    ACS_ON=\$(printf '%s\n' "\$ACS_RAW" | grep -v ' off' | awk 'NF{n++} END{print n+0}')
    ACS_DETAIL=\$(printf '%s\n' "\$ACS_RAW" | grep -v ' off' | head -2 | tr '\n' ';')
else
    ACS_ON="unavailable"
    ACS_DETAIL=""
fi
LAST_AUDIT=\$(/usr/local/bin/zc-audit-tail 1 2>/dev/null | jq -r '"\(.ts) \(.kind) \(.service) \(.entity)"' 2>/dev/null)
QH_START=\$(echo "${QUIET_HOURS}" | cut -d- -f1 | cut -d: -f1 | sed 's/^0*//')
QH_END=\$(echo "${QUIET_HOURS}" | cut -d- -f2 | cut -d: -f1 | sed 's/^0*//')
NOW_H=\$(date +%H | sed 's/^0*//'); [ -z "\$NOW_H" ] && NOW_H=0
[ -z "\$QH_START" ] && QH_START=0; [ -z "\$QH_END" ] && QH_END=0
QUIET="OFF"
if [ "\$QH_START" -gt "\$QH_END" ]; then
    if [ "\$NOW_H" -ge "\$QH_START" ] || [ "\$NOW_H" -lt "\$QH_END" ]; then QUIET="ACTIVE"; fi
else
    if [ "\$NOW_H" -ge "\$QH_START" ] && [ "\$NOW_H" -lt "\$QH_END" ]; then QUIET="ACTIVE"; fi
fi
PENDING=\$(/usr/local/bin/ha-capability pending_count 2>/dev/null || echo unavailable)
cat << WSEOF
=== WORLD STATE ===
Time: \${NOW} (\${DOW}) · Location: ${HOME_LOCATION}
Lights on: \${LIGHTS_ON}\${LIGHTS_LIST:+ (\${LIGHTS_LIST})}
ACs running: \${ACS_ON}\${ACS_DETAIL:+ — \${ACS_DETAIL}}
Last action: \${LAST_AUDIT:-(none today)}
Quiet hours (${QUIET_HOURS}): \${QUIET}
Pending approvals: \${PENDING}
=== END WORLD STATE ===
WSEOF
SCRIPT

# ==============================================================
# v3.1 — Creation skill helpers (gated on enable_creation_skill)
# All three drafters write a creation ticket and exit 2; nothing
# touches HA until ha-apply-creation runs against an approved marker.
# ==============================================================
cat > /usr/local/bin/ha-create-scene << SCRIPT
#!/bin/sh
# Usage: ha-create-scene '<scene_id>' '<friendly_name>' '<json_entity_states>'
#   e.g. ha-create-scene movie_night 'Movie night' \\
#        '{"light.example":{"state":"on","brightness":76}}'
set -e
[ "${ENABLE_CREATION}" != "true" ] && { echo "Creation skill is disabled. Enable in add-on options."; exit 1; }
SID="\$1"; NAME="\$2"; STATES="\$3"
[ -z "\$SID" ] || [ -z "\$NAME" ] || [ -z "\$STATES" ] && { echo "Usage: ha-create-scene <id> <name> <json_states>"; exit 1; }
echo "\$STATES" | jq empty 2>/dev/null || { echo "ERROR: states must be valid JSON object"; exit 1; }

UUID=\$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "\$RANDOM-\$RANDOM-\$\$")
SHORT=\$(echo "\$UUID" | cut -c1-8)
EXP=\$(( \$(date -u +%s) + 1800 ))
TICKET="/data/pending/\${SHORT}.json"
mkdir -p /data/pending
SUMMARY="CREATE scene.\${SID} (\${NAME}) — \$(echo "\$STATES" | jq 'keys | length') entities"
PAYLOAD=\$(jq -nc --arg sid "\$SID" --arg name "\$NAME" --argjson states "\$STATES" \\
    '{kind:"scene",scene_id:\$sid,friendly_name:\$name,entities:\$states}')
jq -nc \\
  --arg uuid "\$SHORT" --arg svc "scene/create" --argjson p "\$PAYLOAD" \\
  --arg sum "\$SUMMARY" --arg verdict "confirm:create_scene" \\
  --arg approval_user "${FIRST_USER}" --arg approval_chat "${FIRST_USER}" \\
  --argjson exp \$EXP --argjson cre \$(date -u +%s) \\
  '{uuid:\$uuid,service:\$svc,payload:\$p,summary:\$sum,expires_at:\$exp,created_at:\$cre,verdict:\$verdict,approval:{actor_user_id:\$approval_user,chat_id:\$approval_chat,channel:"telegram"}}' \\
  > "\$TICKET"
MSG="🆕 Create scene? (\${SHORT})
\${SUMMARY}
Tap a chip — or reply YES \${SHORT} / NO \${SHORT}.
Expires in 30 min."
if ! /usr/local/bin/tg-send-approval "\${SHORT}" "\$MSG" >/dev/null 2>&1; then
    /usr/local/bin/zc-audit-write confirm_failed "scene/create" "\$PAYLOAD" "ticket=\${SHORT};notification_failed" || true
    echo "ERROR: creation ticket \${SHORT} could not be delivered to Telegram." >&2
    exit 1
fi
/usr/local/bin/zc-audit-write confirm "scene/create" "\$PAYLOAD" "creation_ticket=\${SHORT}"
echo "CONFIRM_PENDING ticket=\${SHORT} kind=create_scene"
exit 2
SCRIPT

cat > /usr/local/bin/ha-create-automation << SCRIPT
#!/bin/sh
# Usage: ha-create-automation '<alias>' '<yaml_body>'
#   yaml_body must start with 'trigger:' and 'action:' (HA automation YAML).
#   Validated by yq before queueing.
set -e
[ "${ENABLE_CREATION}" != "true" ] && { echo "Creation skill is disabled. Enable in add-on options."; exit 1; }
ALIAS="\$1"; YBODY="\$2"
[ -z "\$ALIAS" ] || [ -z "\$YBODY" ] && { echo "Usage: ha-create-automation <alias> <yaml>"; exit 1; }

# Validate YAML — HA automations need at minimum trigger + action.
TMPF=\$(mktemp)
printf 'alias: %s\\n%s\\n' "\$ALIAS" "\$YBODY" > "\$TMPF"
if ! yq eval '.trigger and .action' "\$TMPF" 2>/dev/null | grep -q true; then
    rm -f "\$TMPF"
    echo "ERROR: YAML must include both 'trigger:' and 'action:' keys."; exit 1
fi
YAML_ESCAPED=\$(jq -Rs . < "\$TMPF")
rm -f "\$TMPF"

UUID=\$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "\$RANDOM-\$RANDOM-\$\$")
SHORT=\$(echo "\$UUID" | cut -c1-8)
EXP=\$(( \$(date -u +%s) + 1800 ))
TICKET="/data/pending/\${SHORT}.json"
mkdir -p /data/pending
SUMMARY="CREATE automation '\${ALIAS}' (appends to /config/automations.yaml)"
PAYLOAD=\$(jq -nc --arg al "\$ALIAS" --argjson y "\$YAML_ESCAPED" \\
    '{kind:"automation",alias:\$al,yaml:\$y}')
jq -nc \\
  --arg uuid "\$SHORT" --arg svc "automation/create" --argjson p "\$PAYLOAD" \\
  --arg sum "\$SUMMARY" --arg verdict "confirm:create_automation" \\
  --arg approval_user "${FIRST_USER}" --arg approval_chat "${FIRST_USER}" \\
  --argjson exp \$EXP --argjson cre \$(date -u +%s) \\
  '{uuid:\$uuid,service:\$svc,payload:\$p,summary:\$sum,expires_at:\$exp,created_at:\$cre,verdict:\$verdict,approval:{actor_user_id:\$approval_user,chat_id:\$approval_chat,channel:"telegram"}}' \\
  > "\$TICKET"
MSG="🆕 Create automation? (\${SHORT})
\${SUMMARY}
Tap a chip — or reply YES \${SHORT} / NO \${SHORT}.
Expires in 30 min."
if ! /usr/local/bin/tg-send-approval "\${SHORT}" "\$MSG" >/dev/null 2>&1; then
    /usr/local/bin/zc-audit-write confirm_failed "automation/create" "\$PAYLOAD" "ticket=\${SHORT};notification_failed" || true
    echo "ERROR: creation ticket \${SHORT} could not be delivered to Telegram." >&2
    exit 1
fi
/usr/local/bin/zc-audit-write confirm "automation/create" "\$PAYLOAD" "creation_ticket=\${SHORT}"
echo "CONFIRM_PENDING ticket=\${SHORT} kind=create_automation"
exit 2
SCRIPT

cat > /usr/local/bin/ha-create-routine << 'SCRIPT'
#!/bin/sh
# Usage: ha-create-routine '<name>' '<json_steps_array>'
#   Routines are agent-side only — stored in /data/routines/, not sent to HA.
#   The agent invokes them later by name. No approval needed (they don't
#   touch HA until executed; each step still goes through ha-action-guarded).
set -e
NAME="$1"; STEPS="$2"
[ -z "$NAME" ] || [ -z "$STEPS" ] && { echo "Usage: ha-create-routine <name> <json_steps>"; exit 1; }
echo "$STEPS" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo "ERROR: steps must be a JSON array"; exit 1; }
mkdir -p /data/routines
SAFE=$(echo "$NAME" | tr -c 'A-Za-z0-9_' '_')
F="/data/routines/${SAFE}.json"
jq -n --arg n "$NAME" --argjson s "$STEPS" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{name:$n,steps:$s,created_at:$ts}' > "$F"
echo "Routine '$NAME' saved. Invoke with: ha-run-routine '$NAME'"
SCRIPT

cat > /usr/local/bin/ha-run-routine << 'SCRIPT'
#!/bin/sh
# Usage: ha-run-routine '<name>'   — runs each step through ha-action-guarded.
NAME="$1"
[ -z "$NAME" ] && { echo "Usage: ha-run-routine <name>"; exit 1; }
SAFE=$(echo "$NAME" | tr -c 'A-Za-z0-9_' '_')
F="/data/routines/${SAFE}.json"
[ ! -f "$F" ] && { echo "ERROR: routine '$NAME' not found"; exit 1; }
echo "Running routine: $NAME"
jq -c '.steps[]' "$F" | while read -r step; do
    SVC=$(echo "$step" | jq -r .service)
    BODY=$(echo "$step" | jq -c .payload)
    echo "  → $SVC"
    /usr/local/bin/ha-action-guarded "$SVC" "$BODY" || echo "  (step failed or pending approval)"
done
SCRIPT

cat > /usr/local/bin/ha-apply-creation << SCRIPT
#!/bin/sh
# Usage: ha-apply-creation <id8>
# Apply an approved creation ticket — scene → /config/scenes.yaml,
# automation → /config/automations.yaml + reload, routine → already saved.
set -e
[ "${ENABLE_CREATION}" != "true" ] && { echo "Creation skill is disabled."; exit 1; }
[ "${ENABLE_WRITE_ACTIONS}" != "true" ] && { echo "Write actions are disabled by default; the broker and policy gates must be enabled explicitly."; exit 1; }
[ "\$(id -u)" -eq 0 ] || { echo "ERROR: creation application is Telegram-adapter-only" >&2; exit 1; }
UUID="\$1"
MARKER="/data/approved/\${UUID}.marker"
    TICKET="/data/approval-receipts/tickets/\${UUID}.json"
ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition verify "\$UUID"
[ ! -f "\$MARKER" ] && { echo "ERROR: ticket \${UUID} not approved"; exit 1; }
[ ! -f "\$TICKET" ] && { echo "ERROR: ticket \${UUID} missing"; exit 1; }

KIND=\$(jq -r .payload.kind "\$TICKET")
case "\$KIND" in
  scene)
    SID=\$(jq -r .payload.scene_id "\$TICKET")
    NAME=\$(jq -r .payload.friendly_name "\$TICKET")
    ENTITIES=\$(jq -c .payload.entities "\$TICKET")
    SCENES_F="/config/scenes.yaml"
    [ ! -f "\$SCENES_F" ] && echo "[]" > "\$SCENES_F"
    # Append YAML scene entry. Use yq for safe merge.
    NEW=\$(jq -nc --arg id "\$SID" --arg name "\$NAME" --argjson e "\$ENTITIES" \\
          '{id:\$id,name:\$name,entities:\$e}')
    yq eval -i ". += [\$NEW]" "\$SCENES_F"
    if ! ZEROCLAW_INTERNAL_ACTION=1 ZEROCLAW_APPROVAL_TICKET="\$UUID" /usr/local/bin/ha-action-raw "scene/reload" '{}' >/dev/null 2>&1; then
        /usr/local/bin/zc-audit-write failed "scene/create" "\$ENTITIES" "scene=\${SID};ticket=\${UUID};reload_failed" || true
        echo "ERROR: scene file was updated but Home Assistant rejected scene/reload; ticket retained for inspection." >&2
        exit 1
    fi
    echo "Scene '\${NAME}' (scene.\${SID}) created and reloaded." ;;
  automation)
    ALIAS=\$(jq -r .payload.alias "\$TICKET")
    YAML=\$(jq -r .payload.yaml "\$TICKET")
    AUTOS_F="/config/automations.yaml"
    [ ! -f "\$AUTOS_F" ] && echo "[]" > "\$AUTOS_F"
    TMP=\$(mktemp)
    printf '%s\\n' "\$YAML" > "\$TMP"
    yq eval -i ". += [load(\"\$TMP\")]" "\$AUTOS_F"
    rm -f "\$TMP"
    if ! ZEROCLAW_INTERNAL_ACTION=1 ZEROCLAW_APPROVAL_TICKET="\$UUID" /usr/local/bin/ha-action-raw "automation/reload" '{}' >/dev/null 2>&1; then
        /usr/local/bin/zc-audit-write failed "automation/create" "{\"alias\":\"\${ALIAS}\"}" "ticket=\${UUID};reload_failed" || true
        echo "ERROR: automation file was updated but Home Assistant rejected automation/reload; ticket retained for inspection." >&2
        exit 1
    fi
    echo "Automation '\${ALIAS}' created and reloaded." ;;
  *)
    echo "ERROR: unknown creation kind: \$KIND"; exit 1 ;;
esac
SCRIPT

# Make every helper executable
chmod +x /usr/local/bin/ha-* /usr/local/bin/zc-* /usr/local/bin/tg-*

# ==============================================================
# config.toml
# ==============================================================
if [ "${PROVIDER_KEY_MODE}" = "broker" ]; then
    PROVIDER_NAME="custom:http://127.0.0.1:42620/v1"
    PROVIDER_BASE_URL="http://127.0.0.1:42620/v1"
else
    # Keep the migration-only direct path OpenAI-compatible as well. It is
    # deliberately never allowed together with write actions, and the native
    # 0.7.5 profile shape makes the exception easy to remove later.
    PROVIDER_NAME="custom:https://openrouter.ai/api/v1"
    PROVIDER_BASE_URL="https://openrouter.ai/api/v1"
fi
cat > "${CONFIG_DIR}/config.toml" << TOMLEOF
schema_version = 2

[providers]
fallback = "${PROVIDER_NAME}"

[providers.models."${PROVIDER_NAME}"]
base_url = "${PROVIDER_BASE_URL}"
api_path = "/chat/completions"
model = "${DEFAULT_MODEL}"
temperature = 0.2
timeout_secs = 20
wire_api = "chat_completions"
max_tokens = ${PROVIDER_MAX_TOKENS}

[[providers.model_routes]]
hint = "fast"
provider = "${PROVIDER_NAME}"
model = "${DEFAULT_MODEL}"

[[providers.model_routes]]
hint = "reasoning"
provider = "${PROVIDER_NAME}"
model = "${COMPLEX_MODEL}"

[channels]
cli = true
message_timeout_secs = 60
ack_reactions = true
session_persistence = true
session_backend = "sqlite"
debounce_ms = 300

# NOTE: ZeroClaw's built-in Telegram channel is intentionally disabled here.
# tg-callback-watcher (below) owns the Telegram bot socket exclusively because
# Telegram only allows ONE getUpdates client per bot. The watcher long-polls
# all updates, validates against /run/zeroclaw/telegram-users, forwards .message text to
# the gateway webhook, and applies .callback_query taps directly.

[gateway]
port = 42617
host = "127.0.0.1"
require_pairing = true
session_persistence = true

[agent]
compact_context = true
max_tool_iterations = ${MAX_TOOL_ITER}
max_history_messages = ${MAX_HISTORY_MSGS}
max_context_tokens = ${MAX_CONTEXT_TOKENS}

[autonomy]
level = "supervised"
workspace_only = true
max_actions_per_hour = ${MAX_ACTIONS_PER_HOUR}
allowed_commands = ["ha-lights-on", "ha-ac-status", "ha-cover-status", "ha-sensors", "ha-state", "ha-all-status", "ha-logbook", "ha-errors", "ha-action-guarded", "ha-create-scene", "ha-create-automation", "ha-create-routine", "ha-run-routine", "ha-apply-creation", "zc-schedule", "zc-schedule-once", "zc-audit-tail", "zc-undo", "zc-cost", "zc-world-state", "zc-set-outcome", "zc-lesson-add"]
require_approval_for_medium_risk = true
block_high_risk_commands = true

[memory]
backend = "sqlite"
auto_save = true
hygiene_enabled = true
search_mode = "bm25"
response_cache_enabled = true
response_cache_ttl_minutes = ${RESPONSE_CACHE_TTL}
snapshot_enabled = true
auto_hydrate = true
conversation_retention_days = ${CONV_RETENTION_DAYS}

[http_request]
enabled = false
allowed_domains = []
max_response_size = 200000
timeout_secs = 10
allow_private_hosts = false

[cost]
enabled = true
daily_limit_usd = ${DAILY_COST_LIMIT}
monthly_limit_usd = ${MONTHLY_COST_LIMIT}
warn_at_percent = 80

[cost.enforcement]
mode = "route_down"
route_down_model = "${DEFAULT_MODEL}"
reserve_percent = 10

[reliability]
provider_retries = 2
provider_backoff_ms = 300

[reliability.model_fallbacks]
"${DEFAULT_MODEL}" = ["google/gemini-flash-latest"]
"${COMPLEX_MODEL}" = ["deepseek/deepseek-v4-pro", "${DEFAULT_MODEL}"]

[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 300
TOMLEOF

# ==============================================================
# SOUL.md — behavior, policy literacy, world-state respect
# ==============================================================
cat > "${WS}/SOUL.md" << SOULEOF
Role: Home automation executor for ${HOME_LOCATION}.
Languages: ${HOME_LANGUAGES} — match the user's language exactly.
Output: 1-2 lines max. No preamble. No "Done." No "Sure!" / "I'll" / "Let me".

## World state
A WORLD STATE block may appear in your prompt. Trust it. Don't re-fetch what's already there
(time, lights on, ACs running, quiet hours, pending approvals). To refresh manually: zc-world-state.

## Greetings
"hi" / "hello" / "hey" / "مرحبا" → reply exactly: "Hi." then stop.

## Step 1 — Resolve entity
Unknown name? Call memory_recall("<name>") first. Entity mappings are pre-loaded.
Still unknown? Reply: "I don't know '<name>'. What's the entity ID?"

## Step 2 — Status queries
ha.lights_on · ha.ac_status · ha.cover_status · ha.sensor_status · ha.all_status
ha.get_entity <entity_id> · ha.logbook [entity_id] · ha.error_log

## Step 3 — Actions go through ha.action_guarded (the policy gate)
You CANNOT call ha-action-raw directly. Every action goes through ha-action-guarded.
The gate returns one of three things:

  exit 0 → executed. Write the outcome line. e.g. "Study AC → 24°C."
  exit 2 → CONFIRM_PENDING ticket=<id8>. Tell the user:
           "Approval needed (id <id8>). Reply YES <id8> on Telegram to proceed."
  exit 1 → DENIED. Show the user the policy reason. Don't retry.

When the user replies "YES <id>" or "NO <id>", the root-owned Telegram
adapter validates the actor/chat binding and applies the transition. Never ask
the model to manufacture an approval or call an approval bridge. After a
successful approval, the adapter applies the ticket and reports the outcome.

## AC actions — pre-check first
Before set_temperature / set_hvac_mode, call ha.get_entity. If state already matches request,
skip the action and write: "Study AC is already at 24°C." Save tool calls.

## Decision tree for ambiguous requests
"turn off the lights" with no scope:
  • If exactly one light is on → act, write specific outcome.
  • If multiple → ask: "Which? all / specific room / a specific light?"
"make it cooler / warmer" → call ha.get_entity first, propose ±2°C delta, then apply.

## Outcome lines (positive examples)
Lights:    "Example light on."         "Example group off."    "All lights off."
AC:        "Example AC → 24°C."        "Example AC off."       "Example AC → cool mode."
Covers:    "Example curtains opened."   "Example cover closed."
Sensors:   "Soil moisture: 42% (low)."
Schedule:  "Reminder set for 23:00 — check ACs."
Errors:    "Failed: <exact error from tool>"

## Self-scheduling
zc-schedule '<cron>' '<message-to-self>' — recurring (e.g. '0 8 * * *').
zc-schedule-once <minutes> '<msg>'         — one-off delay.
The message is delivered to YOU as a normal user message at the scheduled time.

## Audit + undo
zc-audit-tail [N]   — recent actions
zc-undo [N]         — revert last N actions within 1 hour
"undo that" / "revert" → call zc-undo 1, write what was reverted.

## Cost awareness
zc-cost — return current cost. If asked about spend, call this; never guess.

## Tool-call budget
You have ≤ ${MAX_TOOL_ITER} tool calls per turn. Budget them. Memory-first lookup before
ha.list_entities or any broad query. Never call http_request GET /api/states (532KB).

## Model routing
Default route is fast (${DEFAULT_MODEL}). Switch to the reasoning route when ANY of:
- Message contains: create, automate, schedule, why, debug, plan, every, "all of"
- This turn already used ≥ 3 tool calls
- Message mixes Arabic and English with technical terms
- Drafting a scene, automation, or routine

To switch routes, prepend your first scratchpad/reasoning line with the literal token
[[reasoning]]. The runtime reads it; it does not appear in your reply to the user.

## Outcome tracking (lessons loop) — REQUIRED after real actions
After every turn that produced a real action (NOT a status query, greeting, or
"already at" no-op), invoke the registered tool exactly once:
    zc.set_outcome "<the same one-line outcome you just wrote to the user>"
This is a real tool — call it like ha.action_guarded or memory_recall. The shell
helper underneath is /usr/local/bin/zc-set-outcome; it writes /data/.last_outcome.

Concrete example for a turn that just turned on a light:
  ha.action_guarded 'light/turn_on' '{"entity_id":"light.example"}'
  → "Example light on."
  zc.set_outcome "Example light on."

If you skip zc.set_outcome the lessons loop cannot fire on the user's next reply
and the agent will not learn from corrections. Skipping it is a SOUL violation.

The runtime detects a correction in the user's NEXT message (e.g. "no", "wrong",
"actually", "they're not on", "didn't work", "still off", "لا", "غلط") and
silently writes a lesson to LESSONS.md, which auto-prepends to your prompt on the
next turn. Do NOT call zc.lesson_add yourself unless invoked by an explicit
"User correction received." synthetic prompt — that hook is reserved for the
runtime.

## Allowed action domains
light, climate, cover, scene, script, input_boolean, input_number, input_select, media_player

## Hard-blocked (policy will refuse)
lock.*, alarm_control_panel.*, camera.*, device_tracker.*

## Policy literacy
Some actions need approval. When the gate says CONFIRM, explain it clearly so the user can
decide quickly. Keep summaries one-line and concrete.

## Lessons (auto-loaded from LESSONS.md if present)
SOULEOF

# v3.1: Creation skill paragraph appended only when enabled
if [ "${ENABLE_CREATION}" = "true" ]; then
cat >> "${WS}/SOUL.md" << 'SOULEXT'

## Creation skill (v3.1, enabled)
You can propose new HA objects. Every creation is approval-gated and persistent
(scenes append to /config/scenes.yaml, automations to /config/automations.yaml).
- ha-create-scene <id> '<friendly name>' '<json entity_states>'
- ha-create-automation <alias> '<yaml with trigger: and action: keys>'
- ha-create-routine <name> '<json steps array>'   (agent-side macro)
Each create-* helper returns CONFIRM_PENDING ticket=<id>. Tell the user the
plain-English summary and ticket id. The Telegram adapter validates the bound
user's YES/NO reply and applies approved scene/automation tickets. Do not call
an approval bridge from the model. Write a one-line outcome after the adapter
reports success.
See CREATION.md for templates and validation rules.
SOULEXT
fi

# v3.1: CREATION.md skill doc (only when enabled — keeps prompt small otherwise)
if [ "${ENABLE_CREATION}" = "true" ]; then
cat > "${WS}/CREATION.md" << 'CREATEEOF'
# Creation Skill (v3.1)

You may draft three kinds of HA objects. All go through the standard approval
ticket flow — nothing is created in HA until the user replies YES <id> and you
call `ha-apply-creation <id>`.

## 1. Scene — group of entity states activated by name
Use when the user says: "create a scene called X that...".

Template:
```
ha-create-scene <scene_id> '<friendly name>' '{
  "light.example": {"state": "on", "brightness": 200},
  "light.example_secondary": {"state": "on", "brightness": 80},
  "climate.example": {"state": "cool", "temperature": 22}
}'
```
Rules:
- scene_id: lowercase + underscores only (e.g. `movie_night`, not `Movie Night`).
- States must be valid JSON; the helper rejects malformed input before queueing.
- After approval, the scene is callable via `scene.<scene_id>` in HA.

## 2. Automation — trigger → action with optional condition
Use when the user says: "every morning at 7 turn on a light" or similar.

Template:
```
ha-create-automation '<alias>' "trigger:
  - platform: time
    at: '07:00:00'
condition:
  - condition: time
    weekday: [mon, tue, wed, thu, fri]
action:
  - service: light.turn_on
    target:
      entity_id: light.example"
```
Rules:
- YAML must contain BOTH `trigger:` and `action:` keys (validated by yq).
- Use `service:` (not `action:`) inside the action list — that's HA's syntax.
- For complex conditional + agent-evaluated automations, prefer the
  reverse-trigger pattern (see below).

## 3. Routine — agent-side macro (no HA persistence)
Use for multi-step sequences that don't need HA's automation engine.

Template:
```
ha-create-routine 'good_night' '[
  {"service":"light/turn_off","payload":{"entity_id":"light.example_group"}},
  {"service":"climate/set_temperature","payload":{"entity_id":"climate.example","temperature":21}},
  {"service":"cover/close_cover","payload":{"entity_id":"cover.example"}}
]'
```
Then invoke later: `ha-run-routine 'good_night'` — each step runs through
ha-action-guarded, so policy still applies per step.

## Reverse-trigger pattern (HA fires → agent decides → asks user)
For "every night at 11 IF any AC is on, ASK me before turning it off":
1. Have HA call the ZeroClaw webhook at 23:00 with a structured message.
2. The agent receives that message, calls zc-world-state to evaluate the
   condition with current state, and drafts an action ticket if needed.
3. User approves or denies in chat.

The user must add this rest_command to /config/configuration.yaml ONCE:
```yaml
rest_command:
  zeroclaw_message:
    url: http://<addon-ip>:42617/webhook
    method: POST
    headers:
      content-type: application/json
    payload: '{"message": "{{ message }}"}'
```
Then any HA automation can wake the agent:
```yaml
trigger:
  - platform: time
    at: '23:00:00'
action:
  - service: rest_command.zeroclaw_message
    data:
      message: "23:00 check — any AC still on? Ask if so."
```

## Pitfalls
- DO NOT call ha-apply-creation before the user approves — it will refuse.
- DO NOT auto-deploy automations the user only said they "might" want.
- Keep automations narrow and explainable — one trigger, one action, one alias.
- If the user wants to delete a created automation, instruct them to remove it
  from /config/automations.yaml manually. The agent does NOT delete persistent
  HA objects (deletion is a prohibited action).
CREATEEOF
fi

# Empty LESSONS.md (auto-hydrated by ZeroClaw on startup)
[ ! -f "${WS}/LESSONS.md" ] && cat > "${WS}/LESSONS.md" << 'LESSEOF'
# Lessons Learned (auto-prepended to every prompt)
# This file grows over time as the user corrects mistakes.
# Format: one short rule per line. Pinned lessons start with [PIN].
LESSEOF

# ==============================================================
# TOOLS.md
# ==============================================================
cat > "${WS}/TOOLS.md" << 'TOOLSEOF'
## ha.* tool reference (read-only and guarded action)

STATUS:
- ha.all_status     — lights + AC + covers (use for "home overview")
- ha.lights_on      — which lights are ON
- ha.ac_status      — all ACs: mode, set, current
- ha.cover_status   — all curtains
- ha.sensor_status  — soil/temperature sensors
- ha.get_entity     — one entity by ID (pass entity_id)
- ha.logbook        — recent events (optionally entity_id)
- ha.error_log      — HA system error log

ACTIONS (all routed through the policy gate):
- ha.action_guarded <service_path> '<json_body>'
    e.g. ha.action_guarded 'light/turn_on' '{"entity_id":"light.example"}'
    e.g. ha.action_guarded 'climate/set_temperature' '{"entity_id":"climate.example","temperature":22}'
- ha.action_guarded --apply-ticket <id8>   — apply an approved ticket

ZC. (ZeroClaw self-tools):
- zc.schedule '<cron>' '<msg-to-self>' [name]   — recurring task
- zc.schedule_once <min> '<msg>'                — one-off delay
- zc.audit_tail [N]                              — recent actions
- zc.undo [N]                                    — revert last N actions (1h window)
- zc.cost                                        — current spend
- zc.world_state                                 — refresh world state

WARNING: never call http_request GET /api/states — payload too large.
TOOLSEOF

# ==============================================================
# USER.md (parameterized from add-on config)
# ==============================================================
cat > "${WS}/USER.md" << USEREOF
## Home context
- Location: ${HOME_LOCATION:-not configured}
- Languages: ${HOME_LANGUAGES:-en}
- Quiet hours: ${QUIET_HOURS:-not configured}
- Platform details are intentionally resolved at runtime and are not embedded in the image.

## Entity resolution
Resolve entity IDs through typed Home Assistant read capabilities and current aliases.
Do not rely on hardcoded entity IDs or a stale topology snapshot.
USEREOF

# ==============================================================
# SKILL.md — ha skill, all actions go through ha-action-guarded
# ==============================================================
cat > "${WS}/skills/ha/SKILL.md" << 'SKILLEOF'
---
name: "ha"
description: "Home Assistant device control — read-only queries and policy-gated actions"
version: "3.1.0"
tags: ["home", "automation", "policy"]
---

# Home Assistant Control (v3.0 policy-gated)

All write actions route through ha-action-guarded and the root-owned capability
broker, which enforce the configured policy options. The legacy
/config/zeroclaw_policy.yaml is not parsed. The gate returns CONFIRM_PENDING for
actions that need approval; relay the ticket id to the user.

[[tools]]
name = "all_status"
description = "Full home overview: lights on, AC status, and cover/curtain states."
kind = "shell"
command = "ha-all-status"

[[tools]]
name = "lights_on"
description = "List which lights are currently ON."
kind = "shell"
command = "ha-lights-on"

[[tools]]
name = "ac_status"
description = "All AC/climate status: mode, set temperature, current temperature."
kind = "shell"
command = "ha-ac-status"

[[tools]]
name = "cover_status"
description = "All curtain/cover status."
kind = "shell"
command = "ha-cover-status"

[[tools]]
name = "sensor_status"
description = "Soil moisture and temperature sensors."
kind = "shell"
command = "ha-sensors"

[[tools]]
name = "get_entity"
description = "State of one entity. Pass entity_id, e.g. 'climate.room_air_conditioner'"
kind = "shell"
command = "ha-state"

[[tools]]
name = "action_guarded"
description = "Policy-gated action. Args: <service_path> '<json_body>'. May return CONFIRM_PENDING ticket=<id8> — relay it to the user. To apply an approved ticket: '--apply-ticket <id8>'."
kind = "shell"
command = "ha-action-guarded"

[[tools]]
name = "logbook"
description = "Recent device activity. Pass entity_id to filter."
kind = "shell"
command = "ha-logbook"

[[tools]]
name = "error_log"
description = "Home Assistant system error log."
kind = "shell"
command = "ha-errors"

[[tools]]
name = "schedule"
description = "Schedule a future message to yourself (cron expression). Args: '<cron>' '<message>' [name]"
kind = "shell"
command = "zc-schedule"

[[tools]]
name = "schedule_once"
description = "Schedule a one-off message to yourself in N minutes. Args: <minutes> '<message>'"
kind = "shell"
command = "zc-schedule-once"

[[tools]]
name = "audit_tail"
description = "Recent audit log rows. Optional N (default 20)."
kind = "shell"
command = "zc-audit-tail"

[[tools]]
name = "undo"
description = "Revert the last N actions within the last hour (default 1)."
kind = "shell"
command = "zc-undo"

[[tools]]
name = "cost"
description = "Current cost telemetry (today, month, limits)."
kind = "shell"
command = "zc-cost"

[[tools]]
name = "world_state"
description = "Compact home-state header (time, lights, ACs, quiet hours, pending approvals)."
kind = "shell"
command = "zc-world-state"

[[tools]]
name = "set_outcome"
description = "Record the one-line outcome of a real action so the lessons loop can detect a user correction in the NEXT message. Call EXACTLY ONCE per action turn with the same outcome line you wrote to the user. Do NOT call after status queries, greetings, or 'already at' no-ops."
kind = "shell"
command = "zc-set-outcome"

[[tools]]
name = "lesson_add"
description = "Append a one-line lesson (≤80 chars) to LESSONS.md. Reserved for the synthetic 'User correction received.' prompt — do not call from regular turns."
kind = "shell"
command = "zc-lesson-add"
SKILLEOF

# v3.1: append creation tools to the ha skill only when the feature is on
if [ "${ENABLE_CREATION}" = "true" ]; then
cat >> "${WS}/skills/ha/SKILL.md" << 'CRSKILLEOF'

[[tools]]
name = "create_scene"
description = "Draft a new HA scene. Args: <scene_id> '<friendly name>' '<json entity_states>'. Returns CONFIRM_PENDING ticket=<id8>; relay it to user. The Telegram adapter owns approval and applies the ticket after the bound user confirms."
kind = "shell"
command = "ha-create-scene"

[[tools]]
name = "create_automation"
description = "Draft a new HA automation. Args: <alias> '<yaml with trigger: and action: keys>'. Returns CONFIRM_PENDING ticket=<id8>. yq validates the YAML before queueing."
kind = "shell"
command = "ha-create-automation"

[[tools]]
name = "create_routine"
description = "Save an agent-side macro of action steps. Args: <name> '<json array of {service,payload}>'. No approval — but each step still goes through ha-action-guarded when run."
kind = "shell"
command = "ha-create-routine"

[[tools]]
name = "run_routine"
description = "Run a previously-saved routine by name. Each step goes through ha-action-guarded."
kind = "shell"
command = "ha-run-routine"

[[tools]]
name = "apply_creation"
description = "Apply an APPROVED creation ticket. Args: <id8>. Persists scene → /config/scenes.yaml or automation → /config/automations.yaml then reloads HA."
kind = "shell"
command = "ha-apply-creation"
CRSKILLEOF
fi

# ==============================================================
# MEMORY_SNAPSHOT.md — privacy-preserving runtime note
# ==============================================================
cat > "${WS}/MEMORY_SNAPSHOT.md" << 'MEMEOF'
# Entity IDs, room names, device topology, and personal preferences are not
# shipped in the image. They are resolved from the live Home Assistant instance
# through typed read capabilities and may be persisted only after an explicit
# user-directed learning action.

Use current entity metadata and friendly names. Treat stale aliases as hints,
never as authorization to act.
MEMEOF

bashio::log.info "Config ready | mode=${POLICY_MODE} | ${DEFAULT_MODEL} + ${COMPLEX_MODEL}"

# ==============================================================
# Audit/undo retention cleanup (one-shot at startup).  Approval state has a
# separate root-only cleaner because canonical tickets are not planner state.
# ==============================================================
find /data/audit -name '*.jsonl' -mtime +"${AUDIT_RETENTION_DAYS}" -delete 2>/dev/null || true
find /data/undo  -name '*.json'  -mmin  +60                       -delete 2>/dev/null || true
find /data/pending -name '*.json' -mmin +60                        -delete 2>/dev/null || true
/opt/zeroclaw/lib/state-cleanup.sh /data || \
    bashio::log.warning "root approval-state cleanup did not complete; retaining state for recovery"

# Continue expiring sealed tickets and stale claims while the app is running.
# This loop is root-owned and has no planner credentials.
(
    while true; do
        sleep 300
        /opt/zeroclaw/lib/state-cleanup.sh /data || \
            bashio::log.warning "root approval-state cleanup tick failed; retaining state for recovery"
    done
) &

# ==============================================================
# Post-startup seeder: waits for gateway, registers crons via REST.
# ==============================================================
(
    bashio::log.info "Cron seeder waiting for gateway..."
    for i in $(seq 1 60); do
        if curl -sf "${GW}/health" >/dev/null 2>&1; then
            bashio::log.info "Gateway up — seeding cron entries"
            break
        fi
        sleep 2
    done

    # Idempotent: list existing cron entries and remove ours by name before re-adding.
    EXISTING=$(curl -s "${GW}/api/cron" 2>/dev/null)
    for NAME in zc_daily_report zc_observer zc_cost_check zc_undo_cleanup zc_pending_cleanup; do
        ID=$(echo "$EXISTING" | jq -r ".[] | select(.name==\"$NAME\") | .id" 2>/dev/null | head -n1)
        [ -n "$ID" ] && [ "$ID" != "null" ] && \
            curl -s -X DELETE "${GW}/api/cron/${ID}" >/dev/null 2>&1 || true
    done

    if [ "${DAILY_REPORT_ENABLED}" = "true" ]; then
        DAILY_CRON="${REPORT_MIN} ${REPORT_UTC_HOUR} * * *"
        DAILY_MSG="DAILY REPORT. Compose a 5-line home digest covering: (1) AC usage in last 24h via zc-audit-tail 50, (2) anything in ha.error_log, (3) pending approvals, (4) cost so far via zc-cost, (5) one specific suggestion. Send to Telegram."
        curl -s -X POST "${GW}/api/cron" -H "Content-Type: application/json" \
            -d "$(jq -nc --arg n zc_daily_report --arg s "$DAILY_CRON" --arg c "$DAILY_MSG" '{name:$n,schedule:$s,command:$c}')" >/dev/null 2>&1
        bashio::log.info "Daily report cron seeded: ${DAILY_CRON} UTC"
    fi

    if [ "${OBSERVER_ENABLED}" = "true" ]; then
        OBS_CRON="*/${OBSERVER_INTERVAL} * * * *"
        OBS_MSG="OBSERVER TICK. Read zc-world-state and zc-audit-tail 20. If you notice an anomaly, a repeating pattern worth automating, a forgotten device, or a condition the user would want to know about, send a one-line note to Telegram. If nothing notable, respond with the literal token NOOP and do not message."
        curl -s -X POST "${GW}/api/cron" -H "Content-Type: application/json" \
            -d "$(jq -nc --arg n zc_observer --arg s "$OBS_CRON" --arg c "$OBS_MSG" '{name:$n,schedule:$s,command:$c}')" >/dev/null 2>&1
        bashio::log.info "Observer cron seeded: every ${OBSERVER_INTERVAL}m"
    fi

    # Expiry is handled by the root-only state-cleanup loop above.  Do not
    # delegate canonical approval cleanup to the untrusted planner cron.
) &

# ==============================================================
# Telegram callback-query watcher (v3.1.2) — handles inline-keyboard
# chip taps for approval tickets. Auto-restarts on crash.
# ==============================================================
(
    while true; do
        /usr/local/bin/tg-callback-watcher 2>&1 | while read -r line; do
            bashio::log.info "[tg-cb] $line"
        done
        bashio::log.warning "tg-callback-watcher exited; restarting in 5s"
        sleep 5
    done
) &

# ==============================================================
# Cost watchdog: every 5 min, set degrade flag if >80% of daily limit
# ==============================================================
(
    while true; do
        sleep 300
        TODAY=$(curl -s "${GW}/api/cost" 2>/dev/null | jq -r '.today_cost_usd // 0')
        LIMIT="${DAILY_COST_LIMIT}"
        OVER=$(awk -v t="$TODAY" -v l="$LIMIT" 'BEGIN{print (t > 0.8*l) ? 1 : 0}')
        if [ "$OVER" = "1" ] && [ ! -f /run/zeroclaw/cost-degraded ]; then
            touch /run/zeroclaw/cost-degraded
            /usr/local/bin/tg-capability send_text "${FIRST_USER}" \
                "⚠️ Cost watchdog: today's spend \$${TODAY} > 80% of \$${LIMIT}. Routing to cheap model only." >/dev/null 2>&1 || true
        fi
        # Reset flag at midnight UTC (fresh day)
        H=$(date -u +%H); M=$(date -u +%M)
        if [ "$H" = "00" ] && [ "$M" -lt 5 ]; then
            rm -f /run/zeroclaw/cost-degraded 2>/dev/null
        fi
    done
) &

# ==============================================================
# Start ZeroClaw with auto-restart loop
# ==============================================================
# Keep Supervisor options (which contain provider, HA, and Telegram secrets)
# outside the planner's read access. The app state itself is owned by the
# dedicated unprivileged planner account.
# All credential-bearing helper processes have been started above. Drop the
# copies held by the root entrypoint before it launches the planner, so the
# typed brokers are the only long-lived processes retaining these values.
unset OPENROUTER_KEY LEGACY_HA_TOKEN HA_TOKEN TELEGRAM_TOKEN SUPERVISOR_TOKEN ZEROCLAW_PROVIDER_UPSTREAM_URL
# Keep the persistent mount point root-owned and sticky.  ZeroClaw needs to
# create a small amount of runtime metadata directly under its config dir, so
# the group may create entries; the sticky bit prevents the planner from
# unlinking or replacing any root-owned audit/approval/migration/config entry.
# Only these explicitly listed trees are planner-owned; the broker state
# remains outside its write boundary.
chown root:zeroclaw /data
chmod 1770 /data
# Undo snapshots are caller-owned, untrusted input. The broker re-evaluates
# every restore service and records the real HA outcome; keeping the directory
# planner-writable makes the advertised undo tool functional without granting
# the planner access to trusted audit or approval state.
for planner_tree in "${WS}" /data/pending /data/routines /data/tools /data/undo; do
    mkdir -p "$planner_tree"
    chown -R zeroclaw:zeroclaw "$planner_tree"
    find "$planner_tree" -type d -exec chmod 0700 {} \; 2>/dev/null || true
    find "$planner_tree" -type f -exec chmod 0600 {} \; 2>/dev/null || true
done
if [ ! -e /data/.last_outcome ]; then
    : > /data/.last_outcome
fi
chown zeroclaw:zeroclaw /data/.last_outcome
chmod 0600 /data/.last_outcome
if [ -L /data/logs ]; then
    rm -f /data/logs
fi
mkdir -p /data/logs
find /data/logs -type l -exec rm -f {} \; 2>/dev/null || true
chown -R root:root /data/logs
chmod 0750 /data/logs
find /data/logs -type f -exec chmod 0640 {} \; 2>/dev/null || true
mkdir -p /data/provider
find /data/provider -type l -exec rm -f {} \; 2>/dev/null || true
chown -R root:root /data/provider
chmod 0700 /data/provider
find /data/provider -type f -exec chmod 0600 {} \; 2>/dev/null || true
mkdir -p /data/capability
find /data/capability -type l -exec rm -f {} \; 2>/dev/null || true
chown -R root:root /data/capability
chmod 0700 /data/capability
find /data/capability -type f -exec chmod 0600 {} \; 2>/dev/null || true
mkdir -p /data/approved /data/approval-receipts /data/approval-receipts/tickets
chown root:root /data/approved /data/approval-receipts
chmod 0700 /data/approved /data/approval-receipts
chown -R root:root /data/approval-receipts
chmod 0700 /data/approval-receipts/tickets
mkdir -p /data/approval-receipts/.locks
chown root:root /data/approval-receipts/.locks
chmod 0700 /data/approval-receipts/.locks
mkdir -p /data/approval-receipts/.claims
chown root:root /data/approval-receipts/.claims
chmod 0700 /data/approval-receipts/.claims
mkdir -p /data/audit
chown root:zeroclaw /data/audit
chmod 0750 /data/audit
find /data/audit -type f -exec chown root:zeroclaw {} \; -exec chmod 0640 {} \; 2>/dev/null || true
mkdir -p /data/migrations
chown root:root /data/migrations
chmod 0700 /data/migrations
if [ -f /data/options.json ]; then
    chown root:root /data/options.json
    chmod 0600 /data/options.json
fi
if [ -f /data/config.toml ]; then
    chown root:zeroclaw /data/config.toml
    chmod 0640 /data/config.toml
fi
# Preserve any legacy root-level state as root-owned, read-only-to-planner
# data.  The explicitly writable .last_outcome is handled above.
find /data -maxdepth 1 -type f \
    ! -name options.json ! -name config.toml ! -name .last_outcome ! -name .state-version \
    -exec chown root:zeroclaw {} \; -exec chmod 0640 {} \; 2>/dev/null || true
chown root:root /data/.state-version
chmod 0600 /data/.state-version

CRASH_COUNT=0
while true; do
    env -u HA_TOKEN -u SUPERVISOR_TOKEN -u TELEGRAM_BOT_TOKEN \
        -u OPENROUTER_KEY -u TELEGRAM_TOKEN -u LEGACY_HA_TOKEN \
        su-exec zeroclaw:zeroclaw \
        zeroclaw daemon --config-dir "${CONFIG_DIR}"
    EXIT_CODE=$?
    CRASH_COUNT=$((CRASH_COUNT + 1))
    bashio::log.warning "ZeroClaw exited (code ${EXIT_CODE}, restart #${CRASH_COUNT})"
    if [ $CRASH_COUNT -ge 10 ]; then
        bashio::log.fatal "ZeroClaw crashed 10 times — giving up. Check logs."
        exit 1
    fi
    bashio::log.info "Restarting in 5s..."
    sleep 5
done
