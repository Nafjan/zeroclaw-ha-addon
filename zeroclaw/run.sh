#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS app — root provider profile broker release
# Writes, scheduling, generic HTTP, and the built-in Telegram transport are
# disabled by default; enabled writes remain broker- and policy-gated.

ADDON_VERSION="${ZEROCLAW_ADDON_VERSION-}"
printf '%s' "${ADDON_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || {
    bashio::log.fatal "missing or invalid baked app version; refusing to start"
    exit 1
}
STATE_SCHEMA="${ZEROCLAW_STATE_SCHEMA-}"
printf '%s' "${STATE_SCHEMA}" | grep -Eq '^[1-9][0-9]{0,2}$' || {
    bashio::log.fatal "missing or invalid baked state schema; refusing to start"
    exit 1
}
bashio::log.info "ZeroClaw v${ADDON_VERSION} starting..."

# ==============================================================
# Bashio config reads (all configured options)
# ==============================================================
OPENROUTER_KEY="$(bashio::config 'openrouter_api_key')"
NVIDIA_KEY="$(bashio::config 'nvidia_api_key')"
ARK_KEY="$(bashio::config 'ark_api_key')"
PROVIDER_KEY_MODE="$(bashio::config 'provider_key_mode')"
LEGACY_HA_TOKEN="$(bashio::config 'ha_token')"
# The legacy option is migration metadata only.  Never let a saved Core token
# become the broker credential; the Supervisor-issued token is authoritative.
HA_TOKEN="${SUPERVISOR_TOKEN:-}"
TELEGRAM_TOKEN="$(bashio::config 'telegram_bot_token')"
TELEGRAM_USERS="$(bashio::config 'telegram_allowed_users')"
if [ -z "${PROVIDER_KEY_MODE}" ]; then
    bashio::log.warning "provider_key_mode is absent in existing options; using the broker default."
    PROVIDER_KEY_MODE="broker"
fi
DEFAULT_MODEL="$(bashio::config 'default_model')"
COMPLEX_MODEL="$(bashio::config 'complex_model')"
OPENROUTER_AUTO_MODEL="$(bashio::config 'openrouter_auto_model')"
OPENROUTER_FUSION_PRESET="$(bashio::config 'openrouter_fusion_preset')"
OPENROUTER_AUTO_COST_TIER="$(bashio::config 'openrouter_auto_cost_tier')"
NVIDIA_MODEL="$(bashio::config 'nvidia_model')"
ARK_FAST_MODEL="$(bashio::config 'ark_fast_model')"
ARK_REASONING_MODEL="$(bashio::config 'ark_reasoning_model')"
ARK_PRO_MODEL="$(bashio::config 'ark_pro_model')"
OPENROUTER_FREE_MODEL="$(bashio::config 'openrouter_free_model')"
OPENROUTER_FREE_ROUTER_MODEL="$(bashio::config 'openrouter_free_router_model')"
NVIDIA_FREE_MODEL="$(bashio::config 'nvidia_free_model')"
ARK_FREE_MODEL="$(bashio::config 'ark_free_model')"

# New routing options are defaulted at runtime so an existing Supervisor
# options object that predates them still gets the safe, documented route
# shape on its next restart.
OPENROUTER_AUTO_MODEL="${OPENROUTER_AUTO_MODEL:-openrouter/auto}"
OPENROUTER_FUSION_PRESET="${OPENROUTER_FUSION_PRESET:-general-budget}"
OPENROUTER_AUTO_COST_TIER="${OPENROUTER_AUTO_COST_TIER:-medium}"
OPENROUTER_FREE_ROUTER_MODEL="${OPENROUTER_FREE_ROUTER_MODEL:-openrouter/free}"
PROVIDER_FALLBACK_ENABLED="$(bashio::config 'provider_fallback_enabled')"
PROVIDER_FREE_FALLBACK_ENABLED="$(bashio::config 'provider_free_fallback_enabled')"
NVIDIA_FALLBACK_ENABLED="$(bashio::config 'provider_nvidia_fallback_enabled')"
ARK_FALLBACK_ENABLED="$(bashio::config 'provider_ark_fallback_enabled')"
LOG_LEVEL="$(bashio::config 'log_level')"

DAILY_COST_LIMIT="$(bashio::config 'daily_cost_limit_usd')"
MONTHLY_COST_LIMIT="$(bashio::config 'monthly_cost_limit_usd')"
MAX_ACTIONS_PER_HOUR="$(bashio::config 'max_actions_per_hour')"
PROVIDER_MAX_REQUESTS_HOUR="$(bashio::config 'provider_max_requests_per_hour')"
PROVIDER_DAILY_TOKEN_BUDGET="$(bashio::config 'provider_daily_token_budget')"
PROVIDER_OPENROUTER_MAX_REQUESTS_HOUR="$(bashio::config 'provider_openrouter_max_requests_per_hour')"
PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET="$(bashio::config 'provider_openrouter_daily_token_budget')"
PROVIDER_NVIDIA_MAX_REQUESTS_HOUR="$(bashio::config 'provider_nvidia_max_requests_per_hour')"
PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET="$(bashio::config 'provider_nvidia_daily_token_budget')"
PROVIDER_ARK_MAX_REQUESTS_HOUR="$(bashio::config 'provider_ark_max_requests_per_hour')"
PROVIDER_ARK_DAILY_TOKEN_BUDGET="$(bashio::config 'provider_ark_daily_token_budget')"
MAX_TOOL_ITER="$(bashio::config 'max_tool_iterations')"
MAX_HISTORY_MSGS="$(bashio::config 'max_history_messages')"
MAX_CONTEXT_TOKENS="$(bashio::config 'max_context_tokens')"
PROVIDER_MAX_TOKENS="$(bashio::config 'provider_max_tokens')"
PROVIDER_MAX_INPUT_TOKENS="$(bashio::config 'provider_max_input_tokens')"
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

# Creation helpers still exist in the image for migration compatibility, but
# this release does not expose a host-config writer. Ignore an old saved
# option instead of advertising a switch that could write outside the typed
# broker boundary.
LEGACY_ENABLE_CREATION="$(bashio::config 'enable_creation_skill' 2>/dev/null || true)"
ENABLE_CREATION=false
if [ "${LEGACY_ENABLE_CREATION}" = "true" ]; then
    bashio::log.warning "enable_creation_skill is retired in this release; ignoring the saved option."
fi
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

# Existing Supervisor options objects can predate these fields.  Keep the
# migration defaults explicit, then reject malformed values before any
# user-controlled string is used by a generated helper or policy function.
DAILY_REPORT_TIME="${DAILY_REPORT_TIME:-08:00}"
QUIET_HOURS="${QUIET_HOURS:-23:00-06:00}"
ENABLE_LEARNING="${ENABLE_LEARNING:-false}"
case "${ENABLE_LEARNING}" in
    true|false) ;;
    *)
        bashio::log.fatal "enable_learning_loops is invalid; refusing to start"
        exit 1
        ;;
esac

validate_clock_value() {
    clock_label="$1"
    clock_value="$2"
    printf '%s' "$clock_value" | grep -Eq '^[0-9]{1,2}:[0-9]{2}$' || {
        bashio::log.fatal "${clock_label} must use H:MM or HH:MM; refusing to start"
        exit 1
    }
    clock_hour="${clock_value%%:*}"
    clock_minute="${clock_value##*:}"
    [ "$clock_hour" -ge 0 ] && [ "$clock_hour" -le 23 ] &&
        [ "$clock_minute" -ge 0 ] && [ "$clock_minute" -le 59 ] || {
        bashio::log.fatal "${clock_label} is outside the valid 24-hour range; refusing to start"
        exit 1
    }
}

validate_clock_value daily_report_time "${DAILY_REPORT_TIME}"
printf '%s' "${QUIET_HOURS}" | grep -Eq '^[0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}$' || {
    bashio::log.fatal "quiet_hours must use H:MM-H:MM; refusing to start"
    exit 1
}
QUIET_HOURS_START="${QUIET_HOURS%%-*}"
QUIET_HOURS_END="${QUIET_HOURS##*-}"
validate_clock_value quiet_hours_start "${QUIET_HOURS_START}"
validate_clock_value quiet_hours_end "${QUIET_HOURS_END}"

# The planner and the local TCP transport are intentionally untrusted.  Keep
# this security gate hard-coded: every write must be backed by a root-sealed,
# actor-bound Telegram approval before the capability broker will execute it.
POLICY_REQUIRE_APPROVAL=true

PROVIDER_MAX_REQUESTS_HOUR="${PROVIDER_MAX_REQUESTS_HOUR:-120}"
PROVIDER_DAILY_TOKEN_BUDGET="${PROVIDER_DAILY_TOKEN_BUDGET:-200000}"
PROVIDER_MAX_TOKENS="${PROVIDER_MAX_TOKENS:-2048}"
PROVIDER_MAX_INPUT_TOKENS="${PROVIDER_MAX_INPUT_TOKENS:-65536}"
# The broker reserves a worst-case 65536-input/2048-output request at its
# conservative $0.10/1K-token ceiling before contacting an upstream. Keep the
# runtime default above that one-request reservation so the documented full
# context path and its free fallback are actually usable.
DAILY_COST_LIMIT="${DAILY_COST_LIMIT:-10.0}"
MONTHLY_COST_LIMIT="${MONTHLY_COST_LIMIT:-40.0}"
PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS=100000

cost_to_micros() {
    awk -v cost="$1" 'BEGIN {
        if (cost !~ /^[0-9]+([.][0-9]{1,6})?$/) exit 1
        printf "%.0f\n", cost * 1000000
    }'
}

DAILY_COST_LIMIT_MICROS="$(cost_to_micros "${DAILY_COST_LIMIT}")" || {
    bashio::log.fatal "daily_cost_limit_usd is invalid; refusing to start"
    exit 1
}
MONTHLY_COST_LIMIT_MICROS="$(cost_to_micros "${MONTHLY_COST_LIMIT}")" || {
    bashio::log.fatal "monthly_cost_limit_usd is invalid; refusing to start"
    exit 1
}
[ "${DAILY_COST_LIMIT_MICROS}" -le 1000000000000 ] &&
    [ "${MONTHLY_COST_LIMIT_MICROS}" -le 1000000000000 ] &&
    [ "${MONTHLY_COST_LIMIT_MICROS}" -ge "${DAILY_COST_LIMIT_MICROS}" ] || {
    bashio::log.fatal "cost budgets are outside the safe range; refusing to start"
    exit 1
}
PROVIDER_OPENROUTER_MAX_REQUESTS_HOUR="${PROVIDER_OPENROUTER_MAX_REQUESTS_HOUR:-${PROVIDER_MAX_REQUESTS_HOUR}}"
PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET="${PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET:-${PROVIDER_DAILY_TOKEN_BUDGET}}"
PROVIDER_NVIDIA_MAX_REQUESTS_HOUR="${PROVIDER_NVIDIA_MAX_REQUESTS_HOUR:-60}"
PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET="${PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET:-200000}"
PROVIDER_ARK_MAX_REQUESTS_HOUR="${PROVIDER_ARK_MAX_REQUESTS_HOUR:-60}"
PROVIDER_ARK_DAILY_TOKEN_BUDGET="${PROVIDER_ARK_DAILY_TOKEN_BUDGET:-200000}"
DEFAULT_MODEL="${DEFAULT_MODEL:-~deepseek/deepseek-v4-flash-latest}"
COMPLEX_MODEL="${COMPLEX_MODEL:-openrouter/fusion}"
NVIDIA_MODEL="${NVIDIA_MODEL:-meta/llama-3.3-70b-instruct}"
ARK_FAST_MODEL="${ARK_FAST_MODEL:-deepseek-v4-flash-ga-260731}"
ARK_REASONING_MODEL="${ARK_REASONING_MODEL:-glm-5-2-260617}"
ARK_PRO_MODEL="${ARK_PRO_MODEL:-deepseek-v4-pro-ga-260813}"
PROVIDER_FALLBACK_ENABLED="${PROVIDER_FALLBACK_ENABLED:-true}"
PROVIDER_FREE_FALLBACK_ENABLED="${PROVIDER_FREE_FALLBACK_ENABLED:-false}"
NVIDIA_FALLBACK_ENABLED="${NVIDIA_FALLBACK_ENABLED:-false}"
ARK_FALLBACK_ENABLED="${ARK_FALLBACK_ENABLED:-false}"
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
case "${PROVIDER_MAX_TOKENS}" in
    ''|*[!0-9]*) bashio::log.fatal "provider_max_tokens is invalid; refusing to start"; exit 1 ;;
esac
[ "${PROVIDER_MAX_TOKENS}" -ge 512 ] && [ "${PROVIDER_MAX_TOKENS}" -le 8192 ] || {
    bashio::log.fatal "provider_max_tokens is outside the safe range; refusing to start"
    exit 1
}
case "${PROVIDER_MAX_INPUT_TOKENS}" in
    ''|*[!0-9]*) bashio::log.fatal "provider_max_input_tokens is invalid; refusing to start"; exit 1 ;;
esac
[ "${PROVIDER_MAX_INPUT_TOKENS}" -ge 1024 ] && [ "${PROVIDER_MAX_INPUT_TOKENS}" -le 128000 ] || {
    bashio::log.fatal "provider_max_input_tokens is outside the safe range; refusing to start"
    exit 1
}
# The broker reserves the configured input ceiling plus the configured output
# ceiling before contacting any provider. A profile budget that covers only
# output tokens is an accepted-but-unusable configuration, so reject it at the
# Supervisor boundary rather than failing every request later with 429.
MIN_PROVIDER_PROFILE_DAILY_BUDGET=$((PROVIDER_MAX_TOKENS + PROVIDER_MAX_INPUT_TOKENS))

validate_model_id() {
    model_label="$1"
    model_value="$2"
    [ -n "$model_value" ] || return 0
    case "$model_value" in
        *[!A-Za-z0-9._:/+%~-]*)
            bashio::log.fatal "${model_label} contains unsupported characters; refusing to start"
            exit 1
            ;;
    esac
}

for model_pair in \
    "default_model=${DEFAULT_MODEL}" \
    "complex_model=${COMPLEX_MODEL}" \
    "openrouter_auto_model=${OPENROUTER_AUTO_MODEL}" \
    "nvidia_model=${NVIDIA_MODEL}" \
    "ark_fast_model=${ARK_FAST_MODEL}" \
    "ark_reasoning_model=${ARK_REASONING_MODEL}" \
    "ark_pro_model=${ARK_PRO_MODEL}" \
    "openrouter_free_model=${OPENROUTER_FREE_MODEL}" \
    "openrouter_free_router_model=${OPENROUTER_FREE_ROUTER_MODEL}" \
    "nvidia_free_model=${NVIDIA_FREE_MODEL}" \
    "ark_free_model=${ARK_FREE_MODEL}"; do
    validate_model_id "${model_pair%%=*}" "${model_pair#*=}"
done

case "${OPENROUTER_FUSION_PRESET}" in
    general-high|general-budget|general-fast) ;;
    *) bashio::log.fatal "openrouter_fusion_preset is invalid; refusing to start"; exit 1 ;;
esac
case "${OPENROUTER_AUTO_COST_TIER}" in
    low|medium|high|xhigh|max) ;;
    *) bashio::log.fatal "openrouter_auto_cost_tier is invalid; refusing to start"; exit 1 ;;
esac

case "${DEFAULT_MODEL}:${COMPLEX_MODEL}" in
    *:free*)
        bashio::log.fatal "default and complex routes cannot be free-tier models; configure them as explicit free fallbacks"
        exit 1
        ;;
esac
validate_free_model_id() {
    free_model_label="$1"
    free_model_value="$2"
    [ -n "$free_model_value" ] || return 0
    case "$free_model_value" in
        openrouter/free|*:free) ;;
        *) bashio::log.fatal "${free_model_label} must use an explicit :free model slug or openrouter/free; refusing to start"; exit 1 ;;
    esac
}
for free_model_pair in \
    "openrouter_free_model=${OPENROUTER_FREE_MODEL}" \
    "openrouter_free_router_model=${OPENROUTER_FREE_ROUTER_MODEL}" \
    "nvidia_free_model=${NVIDIA_FREE_MODEL}" \
    "ark_free_model=${ARK_FREE_MODEL}"; do
    validate_free_model_id "${free_model_pair%%=*}" "${free_model_pair#*=}"
done

for provider_flag_pair in \
    "provider_fallback_enabled=${PROVIDER_FALLBACK_ENABLED}" \
    "provider_free_fallback_enabled=${PROVIDER_FREE_FALLBACK_ENABLED}" \
    "provider_nvidia_fallback_enabled=${NVIDIA_FALLBACK_ENABLED}" \
    "provider_ark_fallback_enabled=${ARK_FALLBACK_ENABLED}"; do
    case "${provider_flag_pair#*=}" in
        true|false) ;;
        *) bashio::log.fatal "${provider_flag_pair%%=*} is invalid; refusing to start"; exit 1 ;;
    esac
done

for budget_pair in \
    "provider_openrouter_max_requests_per_hour=${PROVIDER_OPENROUTER_MAX_REQUESTS_HOUR}" \
    "provider_openrouter_daily_token_budget=${PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET}" \
    "provider_nvidia_max_requests_per_hour=${PROVIDER_NVIDIA_MAX_REQUESTS_HOUR}" \
    "provider_nvidia_daily_token_budget=${PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET}" \
    "provider_ark_max_requests_per_hour=${PROVIDER_ARK_MAX_REQUESTS_HOUR}" \
    "provider_ark_daily_token_budget=${PROVIDER_ARK_DAILY_TOKEN_BUDGET}"; do
    budget_value="${budget_pair#*=}"
    case "$budget_value" in
        ''|*[!0-9]*) bashio::log.fatal "${budget_pair%%=*} is invalid; refusing to start"; exit 1 ;;
    esac
    [ "$budget_value" -ge 1 ] || {
        bashio::log.fatal "${budget_pair%%=*} must be positive; refusing to start"
        exit 1
    }
done
[ "${PROVIDER_OPENROUTER_MAX_REQUESTS_HOUR}" -le 1000 ] &&
    [ "${PROVIDER_NVIDIA_MAX_REQUESTS_HOUR}" -le 1000 ] &&
    [ "${PROVIDER_ARK_MAX_REQUESTS_HOUR}" -le 1000 ] || {
        bashio::log.fatal "provider profile request budgets are outside the safe range; refusing to start"
        exit 1
    }
[ "${PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET}" -ge 1024 ] &&
    [ "${PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET}" -le 10000000 ] &&
    [ "${PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET}" -ge 1024 ] &&
    [ "${PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET}" -le 10000000 ] &&
    [ "${PROVIDER_ARK_DAILY_TOKEN_BUDGET}" -ge 1024 ] &&
    [ "${PROVIDER_ARK_DAILY_TOKEN_BUDGET}" -le 10000000 ] || {
        bashio::log.fatal "provider profile token budgets are outside the safe range; refusing to start"
        exit 1
    }
[ "${PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET}" -ge "${MIN_PROVIDER_PROFILE_DAILY_BUDGET}" ] &&
    [ "${PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET}" -ge "${MIN_PROVIDER_PROFILE_DAILY_BUDGET}" ] &&
    [ "${PROVIDER_ARK_DAILY_TOKEN_BUDGET}" -ge "${MIN_PROVIDER_PROFILE_DAILY_BUDGET}" ] || {
        bashio::log.fatal "provider profile token budgets must cover maximum input plus output reservation; refusing to start"
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
POLICY_TRUST_ENABLED="${POLICY_TRUST_ENABLED:-false}"
POLICY_TRUST_PROMOTE="${POLICY_TRUST_PROMOTE:-5}"
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
case "${POLICY_TRUST_ENABLED}" in
    true|false) ;;
    *) bashio::log.fatal "policy_trust_enabled is invalid; refusing to start"; exit 1 ;;
esac
case "${POLICY_TRUST_PROMOTE}" in
    ''|*[!0-9]*) bashio::log.fatal "policy_trust_promote_after is invalid; refusing to start"; exit 1 ;;
esac
[ "${POLICY_TRUST_PROMOTE}" -ge 2 ] && [ "${POLICY_TRUST_PROMOTE}" -le 50 ] || {
    bashio::log.fatal "policy_trust_promote_after is outside the safe range; refusing to start"
    exit 1
}
# Trust promotion is retained as a schema-compatible option for migration,
# but is not implemented in the broker-only policy runtime. Never claim that
# repeated approvals can remove the mandatory approval gate.
if [ "${POLICY_TRUST_ENABLED}" = "true" ]; then
    bashio::log.warning "policy trust promotion is reserved and disabled in this release; every write still requires approval."
fi
POLICY_TRUST_ENABLED=false

case "${PROVIDER_KEY_MODE}" in
    direct_temporary)
        # Existing Supervisor options may retain the removed compatibility
        # value. Migrate it in memory before any provider credential is
        # exported; the planner must never receive a real provider key.
        bashio::log.warning "provider_key_mode=direct_temporary is retired; forcing the root-owned broker mode."
        PROVIDER_KEY_MODE="broker"
        ;;
    broker)
        # The per-start local provider credential is generated immediately
        # before the broker children are launched below. Do not retain a
        # predictable placeholder in the entrypoint environment.
        unset ZEROCLAW_API_KEY
        ;;
    *)
        bashio::log.fatal "provider_key_mode must be broker."
        exit 1
        ;;
esac
export RUST_LOG="${LOG_LEVEL}"

[ "${PROVIDER_KEY_MODE}" = "broker" ] || {
    bashio::log.fatal "provider_key_mode did not resolve to broker; refusing to start"
    exit 1
}
[ -n "${OPENROUTER_KEY}" ] || {
    bashio::log.fatal "OPENROUTER_KEY not set!"
    exit 1
}
[ -n "${HA_TOKEN}" ] || {
    bashio::log.fatal "HA_TOKEN not set!"
    exit 1
}

# Telegram is an optional transport. When configured, it must have both a bot
# token and a numeric approval owner; when absent, no Telegram child process is
# started and read-only/API operation remains available.
TELEGRAM_ENABLED=false
FIRST_USER=""
if [ -n "${TELEGRAM_TOKEN}" ] || [ -n "${TELEGRAM_USERS}" ]; then
    [ -n "${TELEGRAM_TOKEN}" ] || {
        bashio::log.fatal "telegram_bot_token is required when telegram_allowed_users is configured."
        exit 1
    }
    [ -n "${TELEGRAM_USERS}" ] || {
        bashio::log.fatal "telegram_allowed_users is required when telegram_bot_token is configured."
        exit 1
    }
    case "${TELEGRAM_TOKEN}" in
        ''|*[!A-Za-z0-9_.:-]*)
            bashio::log.fatal "telegram_bot_token contains unsupported characters"
            exit 1
            ;;
    esac
    [ "${#TELEGRAM_TOKEN}" -le 256 ] || {
        bashio::log.fatal "telegram_bot_token is too long"
        exit 1
    }
    TELEGRAM_USERS_SINGLE_LINE=$(printf '%s' "$TELEGRAM_USERS" | tr -d '\r\n')
    [ "$TELEGRAM_USERS_SINGLE_LINE" = "$TELEGRAM_USERS" ] || {
        bashio::log.fatal "telegram_allowed_users must not contain newline characters."
        exit 1
    }
    printf '%s' "$TELEGRAM_USERS" | grep -Eq '^[[:space:]]*[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*[[:space:]]*$' || {
        bashio::log.fatal "telegram_allowed_users must be a comma-separated list of numeric Telegram user IDs."
        exit 1
    }
    FIRST_USER=$(printf '%s' "$TELEGRAM_USERS" | cut -d',' -f1 | tr -d ' ')
    TELEGRAM_ENABLED=true
else
    bashio::log.info "Telegram transport disabled; no bot token or users configured."
fi

# These options remain schema-compatible for upgrades, but this supervised
# release does not create or mutate ZeroClaw-owned schedules.  Home Assistant
# automations are the only supported scheduler; keep the old switches false.
if [ "${DAILY_REPORT_ENABLED:-false}" = "true" ] || [ "${OBSERVER_ENABLED:-false}" = "true" ]; then
    bashio::log.warning "daily reports and observer scheduling are reserved and ignored; create a Home Assistant automation instead."
fi

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
    bashio::log.warning "Ignoring deprecated ha_token; the Supervisor token is required for startup."
fi
# Home Assistant app manifests have a supported Core-version field, but no
# supported Supervisor-version minimum field.  Enforce the release floor at
# runtime through the documented Supervisor API before scrubbing the token.
# This is deliberately fail-closed: a legacy Core token, an unavailable API,
# an invalid response, or an older Supervisor must never start the planner.
supervisor_api_preflight() {
    [ -n "${SUPERVISOR_TOKEN:-}" ] || {
        bashio::log.fatal "SUPERVISOR_TOKEN is required for the Supervisor version preflight; refusing to start"
        exit 1
    }
    # Keep the token out of curl's argv and out of the curl child's inherited
    # environment. The temporary header is root-only and is removed by the
    # subshell trap on both success and failure.
    supervisor_info_json="$({
        supervisor_auth_file="$(mktemp /tmp/zeroclaw-supervisor-auth.XXXXXX)" || exit 1
        trap 'rm -f -- "$supervisor_auth_file"' EXIT
        chmod 0600 "$supervisor_auth_file"
        printf 'Authorization: Bearer %s\n' "$SUPERVISOR_TOKEN" > "$supervisor_auth_file"
        env -u SUPERVISOR_TOKEN curl -fsS --connect-timeout 5 --max-time 15 \
            --header "@${supervisor_auth_file}" \
            "http://supervisor/supervisor/info"
    })" || {
        bashio::log.fatal "Supervisor version preflight failed; refusing to start"
        exit 1
    }
    SUPERVISOR_VERSION="$(printf '%s' "${supervisor_info_json}" | jq -er '
        if ((.result? // "ok") == "ok") then
            (.data.version // .version)
        else
            empty
        end |
        select(type == "string" and test("^[0-9]{4}\\.[0-9]{1,2}([.][0-9]+)?$"))
    ' 2>/dev/null)" || {
        bashio::log.fatal "Supervisor version response is invalid; refusing to start"
        exit 1
    }
    supervisor_major="${SUPERVISOR_VERSION%%.*}"
    supervisor_minor="${SUPERVISOR_VERSION#*.}"
    supervisor_minor="${supervisor_minor%%.*}"
    if (( 10#${supervisor_major} < 2026 ||
          (10#${supervisor_major} == 2026 && 10#${supervisor_minor} < 4) )); then
        bashio::log.fatal "Supervisor ${SUPERVISOR_VERSION} is below the supported floor 2026.04.0; refusing to start"
        exit 1
    fi
    bashio::log.info "Supervisor ${SUPERVISOR_VERSION} satisfies the runtime floor >= 2026.04.0"
    unset supervisor_info_json supervisor_major supervisor_minor
}
supervisor_api_preflight
# Supervisor exports SUPERVISOR_TOKEN into the app entrypoint environment. The
# typed HA broker receives a private HA_TOKEN copy below; scrub the inherited
# name before any unrelated provider, Telegram, or helper child is born.
# Keeping this in the parent as well as in the broker subshell prevents an
# accidental future helper from retaining the Supervisor credential.
unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN
if [ "${ENABLE_WRITE_ACTIONS}" != "true" ]; then
    bashio::log.warning "Write actions are disabled by default; enable only after reviewing the broker and policy settings."
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
# Create persistent directory components one at a time.  mkdir -p would
# follow a planner-controlled intermediate symlink (for example
# workspace/skills) before the recursive inventory below could reject it.
ensure_dir_chain() {
    chain_path="$1"
    shift
    [ -d "$chain_path" ] && [ ! -L "$chain_path" ] || {
        bashio::log.fatal "persistent directory root is not a regular directory: ${chain_path}"
        exit 1
    }
    for chain_component in "$@"; do
        chain_path="${chain_path}/${chain_component}"
        if [ -L "$chain_path" ] ||
            [ -e "$chain_path" ] && [ ! -d "$chain_path" ]; then
            bashio::log.fatal "persistent directory component is unsafe: ${chain_path}"
            exit 1
        fi
        if [ ! -e "$chain_path" ]; then
            mkdir "$chain_path" || {
                bashio::log.fatal "could not create persistent directory component: ${chain_path}"
                exit 1
            }
        fi
    done
}
ensure_dir_chain /data workspace
ensure_dir_chain "${WS}" skills
ensure_dir_chain "${WS}/skills" ha
ensure_dir_chain "${WS}" sessions
ensure_dir_chain /data logs
ensure_dir_chain /data pending
ensure_dir_chain /data approved
ensure_dir_chain /data audit
ensure_dir_chain /data undo
ensure_dir_chain /data tools
ensure_dir_chain /data routines
ensure_dir_chain /data provider
ensure_dir_chain /data capability
ensure_dir_chain /data migrations
ensure_dir_chain /data approval-receipts
ensure_dir_chain /data/approval-receipts tickets
ensure_dir_chain /data/approval-receipts outcomes
ensure_dir_chain /data/approval-receipts ticket-nonces
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
mkdir -p /data/capability/telegram-replies
mkdir -p /data/capability/telegram-session-locks
mkdir -p /data/capability/action-admissions
mkdir -p /data/capability/telegram-callbacks
chown -R root:root /data/capability/telegram-replies
chmod 0700 /data/capability/telegram-replies
chown root:root /data/capability/telegram-session-locks
chmod 0700 /data/capability/telegram-session-locks
chown root:root /data/capability/action-admissions
chmod 0700 /data/capability/action-admissions
chown root:root /data/capability/telegram-callbacks
chmod 0700 /data/capability/telegram-callbacks
chown root:root /data/approval-receipts/ticket-nonces
chmod 0700 /data/approval-receipts/ticket-nonces

# Do not let a planner-controlled symlink hide or redirect a root-owned state
# file.  Workspace/pending/routines/tools are the only intentionally
# planner-writable trees; their contents are still rejected if symlinks are
# present because root adapters read selected files from pending state.
for state_tree in "${WS}" /data/pending /data/routines /data/tools /data/approved \
    /data/audit /data/undo /data/logs /data/provider /data/capability /data/approval-receipts /data/migrations; do
    [ -e "$state_tree" ] || [ -L "$state_tree" ] || continue
    if [ -L "$state_tree" ] || [ ! -d "$state_tree" ]; then
        bashio::log.fatal "persistent state tree is not a regular directory: ${state_tree}"
        exit 1
    fi
    if find "$state_tree" -type l -print -quit | grep -q .; then
        bashio::log.fatal "persistent state tree contains a symlink: ${state_tree}"
        exit 1
    fi
    special_state_entry=$(find "$state_tree" ! -type f ! -type d -print -quit 2>/dev/null) || {
        bashio::log.fatal "persistent state tree could not be inspected: ${state_tree}"
        exit 1
    }
    if [ -n "$special_state_entry" ]; then
        bashio::log.fatal "persistent state tree contains a non-regular entry: ${special_state_entry}"
        exit 1
    fi
done

# The generated action wrapper must not embed operator-supplied policy strings
# into shell source.  Keep the canonical values in a root-owned, planner-
# readable JSON file; the wrapper reloads this file for every invocation and
# never trusts ambient planner environment overrides.
POLICY_RUNTIME_FILE="${CONFIG_DIR}/policy-runtime.json"
if [ -L "${POLICY_RUNTIME_FILE}" ] ||
    [ -e "${POLICY_RUNTIME_FILE}" ] && [ ! -f "${POLICY_RUNTIME_FILE}" ]; then
    bashio::log.fatal "policy runtime file is not a regular file"
    exit 1
fi
POLICY_RUNTIME_TMP=$(mktemp "${CONFIG_DIR}/.policy-runtime.XXXXXX")
if ! jq -nc \
    --arg mode "${POLICY_MODE}" \
    --arg quiet_confirm "${POLICY_QUIET_CONFIRM}" \
    --arg quiet_hours "${QUIET_HOURS}" \
    --arg home_location "${HOME_LOCATION}" \
    --arg extra_deny "${POLICY_EXTRA_DENY}" \
    --arg extra_confirm "${POLICY_EXTRA_CONFIRM}" \
    --arg extra_allow "${POLICY_EXTRA_ALLOW}" \
    --argjson bulk_threshold "${POLICY_BULK_THRESHOLD}" \
    --argjson climate_delta "${POLICY_CLIMATE_DELTA}" \
    '{policy_mode:$mode,policy_quiet_confirm:$quiet_confirm,
      policy_bulk_threshold:$bulk_threshold,policy_climate_delta:$climate_delta,
      quiet_hours:$quiet_hours,home_location:$home_location,
      extra_deny:$extra_deny,
      extra_confirm:$extra_confirm,extra_allow:$extra_allow,
      trust_promotion:{enabled:false},
      require_approval:true}' > "${POLICY_RUNTIME_TMP}"; then
    rm -f "${POLICY_RUNTIME_TMP}"
    bashio::log.fatal "could not render the root-owned policy runtime file"
    exit 1
fi
chown root:zeroclaw "${POLICY_RUNTIME_TMP}"
chmod 0640 "${POLICY_RUNTIME_TMP}"
mv -f "${POLICY_RUNTIME_TMP}" "${POLICY_RUNTIME_FILE}"

# Snapshot persistent state before rendering this release's config.toml. The
# integer schema marker is root-only state; the planner must not be able to
# rewrite it and suppress or fabricate an upgrade snapshot. Legacy semver
# markers are inspected and preserved inside the migration snapshot by the
# migration helper, then removed only after the new schema marker is committed.
MIGRATIONS_DIR="${CONFIG_DIR}/migrations"
mkdir -p "${MIGRATIONS_DIR}"
chown root:root "${MIGRATIONS_DIR}"
chmod 0700 "${MIGRATIONS_DIR}"
# A restore journal is written before any live state is removed.  Resolve an
# untrapped interruption (SIGKILL, power loss, or container termination) before
# treating the runtime lock as stale; otherwise startup could accept a partial
# inventory or rewound quotas/audit state.
if ! /opt/zeroclaw/lib/state-restore.sh recover "${CONFIG_DIR}"; then
    bashio::log.fatal "Incomplete state restore recovery failed; refusing to start."
    exit 1
fi
RUNTIME_LOCK_DIR="${CONFIG_DIR}/.state-runtime-lock"
if [ -e "${RUNTIME_LOCK_DIR}" ]; then
    if [ -L "${RUNTIME_LOCK_DIR}" ] || [ ! -d "${RUNTIME_LOCK_DIR}" ] ||
        [ ! -f "${RUNTIME_LOCK_DIR}/pid" ]; then
        bashio::log.fatal "persistent-state runtime lock is malformed; refusing to start"
        exit 1
    fi
    runtime_lock_pid="$(cat "${RUNTIME_LOCK_DIR}/pid" 2>/dev/null || true)"
    case "${runtime_lock_pid}" in
        ''|*[!0-9]*)
            bashio::log.fatal "persistent-state runtime lock has an invalid owner; refusing to start"
            exit 1
            ;;
    esac
    if kill -0 "${runtime_lock_pid}" 2>/dev/null; then
        bashio::log.fatal "persistent-state maintenance is active; refusing to start concurrently"
        exit 1
    fi
    rm -f -- "${RUNTIME_LOCK_DIR}/pid"
    rmdir "${RUNTIME_LOCK_DIR}" 2>/dev/null || {
        bashio::log.fatal "stale persistent-state runtime lock could not be cleared"
        exit 1
    }
fi
mkdir "${RUNTIME_LOCK_DIR}" || {
    bashio::log.fatal "could not acquire persistent-state runtime lock"
    exit 1
}
printf '%s\n' "$$" > "${RUNTIME_LOCK_DIR}/pid"
chown root:root "${RUNTIME_LOCK_DIR}/pid"
chmod 0600 "${RUNTIME_LOCK_DIR}/pid"
RUNTIME_LOCK_HELD=true
release_runtime_lock() {
    if [ "${RUNTIME_LOCK_HELD:-false}" = true ]; then
        rm -f -- "${RUNTIME_LOCK_DIR}/pid"
        rmdir "${RUNTIME_LOCK_DIR}" 2>/dev/null || true
        RUNTIME_LOCK_HELD=false
    fi
}
trap release_runtime_lock EXIT
SCHEMA_FILE="${CONFIG_DIR}/.state-schema"
if ! STATE_MIGRATION_LOCK_HELD=true /opt/zeroclaw/lib/state-migrate.sh "${CONFIG_DIR}" "$SCHEMA_FILE" "${STATE_SCHEMA}"; then
    bashio::log.fatal "State migration failed; refusing to start without a rollback snapshot."
    exit 1
fi
chown root:root "$SCHEMA_FILE"
chmod 0600 "$SCHEMA_FILE"
# Reserve the old semver marker name with a root-owned tombstone.  /data is
# deliberately group-writable for the planner's narrow runtime needs, so an
# absent legacy path could otherwise be recreated by the planner and create
# ambiguity on the next restart.  state-migrate recognizes only this exact
# root-owned tombstone as inactive legacy state.
LEGACY_VERSION_TOMBSTONE="${CONFIG_DIR}/.state-version"
if [ ! -e "$LEGACY_VERSION_TOMBSTONE" ]; then
    tombstone_tmp="${LEGACY_VERSION_TOMBSTONE}.tmp.$$"
    printf 'schema-tombstone-%s\n' "$STATE_SCHEMA" > "$tombstone_tmp"
    chown root:root "$tombstone_tmp"
    chmod 0600 "$tombstone_tmp"
    mv -f "$tombstone_tmp" "$LEGACY_VERSION_TOMBSTONE"
fi
# Approval state is bound to an epoch that lives outside the restorable
# inventory. A successful state restore increments it, invalidating every
# pre-restore ticket, callback, and cached approval even when an old snapshot
# contains otherwise valid-looking state.
APPROVAL_RESTORE_EPOCH_FILE="${CONFIG_DIR}/.approval-restore-epoch"
if [ -L "$APPROVAL_RESTORE_EPOCH_FILE" ] ||
    [ -e "$APPROVAL_RESTORE_EPOCH_FILE" ] && [ ! -f "$APPROVAL_RESTORE_EPOCH_FILE" ]; then
    bashio::log.fatal "approval restore epoch is not a regular file"
    exit 1
fi
if [ -e "$APPROVAL_RESTORE_EPOCH_FILE" ]; then
    approval_restore_epoch=$(tr -d '\r\n' < "$APPROVAL_RESTORE_EPOCH_FILE")
    printf '%s' "$approval_restore_epoch" | grep -Eq '^[0-9]+$' || {
        bashio::log.fatal "approval restore epoch is malformed"
        exit 1
    }
else
    approval_restore_epoch=0
    approval_epoch_tmp="${APPROVAL_RESTORE_EPOCH_FILE}.tmp.$$"
    printf '%s\n' "$approval_restore_epoch" > "$approval_epoch_tmp"
    chown root:root "$approval_epoch_tmp"
    chmod 0600 "$approval_epoch_tmp"
    mv -f "$approval_epoch_tmp" "$APPROVAL_RESTORE_EPOCH_FILE"
fi

# ==============================================================
# Typed capability broker and read-only HA helpers
# ==============================================================
install -m 0755 /opt/zeroclaw/lib/capability-broker-handler.sh /usr/local/bin/ha-broker-handler
install -m 0755 /opt/zeroclaw/lib/ha-capability.sh /usr/local/bin/ha-capability
install -m 0755 /opt/zeroclaw/lib/capability-broker-entrypoint.sh /usr/local/bin/ha-broker-entrypoint

# BusyBox nc provides the small local transport used by the typed brokers.
# Bind it to loopback and require a fresh, per-start client credential as a
# second boundary so another process in the container cannot invoke a root
# broker merely by discovering its port. The planner is allowed to read only
# these non-provider client credentials; the root broker retains the matching
# value in its private environment.
BROKER_RUNTIME_DIR="/run/zeroclaw"
mkdir -p "${BROKER_RUNTIME_DIR}"
if [ -L "${BROKER_RUNTIME_DIR}" ] || [ ! -d "${BROKER_RUNTIME_DIR}" ]; then
    bashio::log.fatal "broker runtime directory is not a regular directory"
    exit 1
fi
chown root:zeroclaw "${BROKER_RUNTIME_DIR}"
chmod 0710 "${BROKER_RUNTIME_DIR}"

create_broker_client_auth() {
    auth_name="$1"
    auth_path="${BROKER_RUNTIME_DIR}/${auth_name}"
    [ ! -L "${auth_path}" ] || {
        bashio::log.fatal "broker auth path is a symlink: ${auth_path}"
        exit 1
    }
    if [ -e "${auth_path}" ] && [ ! -f "${auth_path}" ]; then
        bashio::log.fatal "broker auth path is not a regular file: ${auth_path}"
        exit 1
    fi
    auth_tmp=$(mktemp "${BROKER_RUNTIME_DIR}/.${auth_name}.XXXXXX") || {
        bashio::log.fatal "could not create broker auth file"
        exit 1
    }
    auth_value=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
    case "${auth_value}" in
        [a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
        *) rm -f "${auth_tmp}"; bashio::log.fatal "could not generate broker auth credential"; exit 1 ;;
    esac
    printf '%s\n' "${auth_value}" > "${auth_tmp}"
    chown root:zeroclaw "${auth_tmp}"
    chmod 0640 "${auth_tmp}"
    mv -f "${auth_tmp}" "${auth_path}"
    printf '%s' "${auth_value}"
}

create_root_client_auth() {
    auth_name="$1"
    auth_path="${BROKER_RUNTIME_DIR}/${auth_name}"
    [ ! -L "${auth_path}" ] || {
        bashio::log.fatal "root broker auth path is a symlink: ${auth_path}"
        exit 1
    }
    if [ -e "${auth_path}" ] && [ ! -f "${auth_path}" ]; then
        bashio::log.fatal "root broker auth path is not a regular file: ${auth_path}"
        exit 1
    fi
    auth_tmp=$(mktemp "${BROKER_RUNTIME_DIR}/.${auth_name}.XXXXXX") || {
        bashio::log.fatal "could not create root broker auth file"
        exit 1
    }
    auth_value=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
    case "${auth_value}" in
        [a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
        *) rm -f "${auth_tmp}"; bashio::log.fatal "could not generate root broker auth credential"; exit 1 ;;
    esac
    printf '%s\n' "${auth_value}" > "${auth_tmp}"
    chown root:root "${auth_tmp}"
    chmod 0600 "${auth_tmp}"
    mv -f "${auth_tmp}" "${auth_path}"
    printf '%s' "${auth_value}"
}

PROVIDER_CLIENT_AUTH_FILE="${BROKER_RUNTIME_DIR}/provider-client-auth"
PROVIDER_HEALTH_AUTH_FILE="${BROKER_RUNTIME_DIR}/provider-health-auth"
CAPABILITY_CLIENT_AUTH_FILE="${BROKER_RUNTIME_DIR}/capability-client-auth"
HEALTH_CLIENT_AUTH_FILE="${BROKER_RUNTIME_DIR}/health-client-auth"
TELEGRAM_CLIENT_AUTH_FILE="${BROKER_RUNTIME_DIR}/telegram-client-auth"
TELEGRAM_SYSTEM_AUTH_FILE="${BROKER_RUNTIME_DIR}/telegram-system-auth"
PROVIDER_CLIENT_AUTH_TOKEN="$(create_broker_client_auth provider-client-auth)"
PROVIDER_HEALTH_CLIENT_AUTH_TOKEN="$(create_root_client_auth provider-health-auth)"
CAPABILITY_CLIENT_AUTH_TOKEN="$(create_broker_client_auth capability-client-auth)"
HEALTH_CLIENT_AUTH_TOKEN="$(create_root_client_auth health-client-auth)"
TELEGRAM_CLIENT_AUTH_TOKEN="$(create_broker_client_auth telegram-client-auth)"
TELEGRAM_SYSTEM_AUTH_TOKEN="$(create_root_client_auth telegram-system-auth)"
[ "${PROVIDER_CLIENT_AUTH_TOKEN}" != "${PROVIDER_HEALTH_CLIENT_AUTH_TOKEN}" ] || {
    bashio::log.fatal "provider client and health credentials unexpectedly match"
    exit 1
}
if [ "${PROVIDER_KEY_MODE}" = "broker" ]; then
    # Native ZeroClaw sends ZEROCLAW_API_KEY as the Authorization bearer on
    # its OpenAI-compatible provider request. In broker mode that value is a
    # local client credential, never a provider secret.
    export ZEROCLAW_API_KEY="${PROVIDER_CLIENT_AUTH_TOKEN}"
fi

# Broker provider credentials. Provider secrets never enter the planner
# environment, including when an existing options object still contains the
# retired direct_temporary value.
if [ "${PROVIDER_KEY_MODE}" = "broker" ]; then
    install -m 0755 /opt/zeroclaw/lib/provider-broker-handler.sh /usr/local/bin/provider-broker-handler
    install -m 0755 /opt/zeroclaw/lib/provider-broker-entrypoint.sh /usr/local/bin/provider-broker-entrypoint
    PROVIDER_KEY_DIR="/data/provider/keys"
    mkdir -p "${PROVIDER_KEY_DIR}"
    printf '%s' "${OPENROUTER_KEY}" > "${PROVIDER_KEY_DIR}/openrouter.key"
    printf '%s' "${NVIDIA_KEY}" > "${PROVIDER_KEY_DIR}/nvidia.key"
    printf '%s' "${ARK_KEY}" > "${PROVIDER_KEY_DIR}/ark.key"
    chown root:root "${PROVIDER_KEY_DIR}"/*.key
    chmod 0600 "${PROVIDER_KEY_DIR}"/*.key
    chown root:root "${PROVIDER_KEY_DIR}"
    chmod 0700 "${PROVIDER_KEY_DIR}"
    PROVIDER_PORT=42620
    (
        provider_test_upstream="${ZEROCLAW_PROVIDER_UPSTREAM_URL:-}"
        unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \
            LEGACY_HA_TOKEN ZEROCLAW_API_KEY ZEROCLAW_LEGACY_ACTION_GATE ZEROCLAW_PROVIDER_UPSTREAM_URL
        export PROVIDER_CLIENT_AUTH_TOKEN PROVIDER_HEALTH_CLIENT_AUTH_TOKEN
        # Only the CI image carries this immutable marker. The exact loopback
        # endpoint is accepted solely for the deterministic real-daemon test;
        # release images always use the fixed upstream below.
        if [ -f /usr/share/zeroclaw/test-hooks-enabled ] &&
            [ ! -L /usr/share/zeroclaw/test-hooks-enabled ] &&
            [ "$(tr -d '\r\n' < /usr/share/zeroclaw/test-hooks-enabled)" = "zeroclaw-ci-test-hooks-v1" ] &&
            [ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ] &&
            [ "${SMOKE_REAL_PROVIDER_ROUNDTRIP:-false}" = "true" ] &&
            [ "${provider_test_upstream}" = "http://127.0.0.1:42633/v1/chat/completions" ]; then
            OPENROUTER_UPSTREAM_URL="${provider_test_upstream}"
        else
            OPENROUTER_UPSTREAM_URL="https://openrouter.ai/api/v1/chat/completions"
        fi
        export PROVIDER_PROFILE_SPEC="openrouter|${OPENROUTER_UPSTREAM_URL}|${PROVIDER_KEY_DIR}/openrouter.key|${PROVIDER_OPENROUTER_MAX_REQUESTS_HOUR}|${PROVIDER_OPENROUTER_DAILY_TOKEN_BUDGET}
nvidia|https://integrate.api.nvidia.com/v1/chat/completions|${PROVIDER_KEY_DIR}/nvidia.key|${PROVIDER_NVIDIA_MAX_REQUESTS_HOUR}|${PROVIDER_NVIDIA_DAILY_TOKEN_BUDGET}
ark|https://ark.ap-southeast.bytepluses.com/api/v3/chat/completions|${PROVIDER_KEY_DIR}/ark.key|${PROVIDER_ARK_MAX_REQUESTS_HOUR}|${PROVIDER_ARK_DAILY_TOKEN_BUDGET}"
        export PROVIDER_ALLOWED_MODELS="${DEFAULT_MODEL},${COMPLEX_MODEL},${OPENROUTER_AUTO_MODEL},~google/gemini-flash-latest,deepseek/deepseek-v4-pro"
        export PROVIDER_FUSION_PRESET="${OPENROUTER_FUSION_PRESET}"
        export PROVIDER_AUTO_COST_TIER="${OPENROUTER_AUTO_COST_TIER}"
        export PROVIDER_ROUTE_SPEC="${DEFAULT_MODEL}|openrouter|${DEFAULT_MODEL}|paid
${DEFAULT_MODEL}|openrouter|~google/gemini-flash-latest|paid
${COMPLEX_MODEL}|openrouter|${COMPLEX_MODEL}|paid
${COMPLEX_MODEL}|openrouter|${OPENROUTER_AUTO_MODEL}|paid
${COMPLEX_MODEL}|openrouter|deepseek/deepseek-v4-pro|paid"
        if [ "${NVIDIA_FALLBACK_ENABLED}" = "true" ]; then
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${DEFAULT_MODEL}|nvidia|${NVIDIA_MODEL}|paid
${COMPLEX_MODEL}|nvidia|${NVIDIA_MODEL}|paid"
        fi
        if [ "${ARK_FALLBACK_ENABLED}" = "true" ]; then
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${DEFAULT_MODEL}|ark|${ARK_FAST_MODEL}|paid
${COMPLEX_MODEL}|ark|${ARK_REASONING_MODEL}|paid
${COMPLEX_MODEL}|ark|${ARK_PRO_MODEL}|paid"
        fi
        if [ -n "${OPENROUTER_FREE_MODEL}" ]; then
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${DEFAULT_MODEL}|openrouter|${OPENROUTER_FREE_MODEL}|free"
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${COMPLEX_MODEL}|openrouter|${OPENROUTER_FREE_MODEL}|free"
        fi
        if [ -n "${OPENROUTER_FREE_ROUTER_MODEL}" ]; then
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${DEFAULT_MODEL}|openrouter|${OPENROUTER_FREE_ROUTER_MODEL}|free"
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${COMPLEX_MODEL}|openrouter|${OPENROUTER_FREE_ROUTER_MODEL}|free"
        fi
        if [ "${NVIDIA_FALLBACK_ENABLED}" = "true" ] && [ -n "${NVIDIA_FREE_MODEL}" ]; then
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${DEFAULT_MODEL}|nvidia|${NVIDIA_FREE_MODEL}|free"
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${COMPLEX_MODEL}|nvidia|${NVIDIA_FREE_MODEL}|free"
        fi
        if [ "${ARK_FALLBACK_ENABLED}" = "true" ] && [ -n "${ARK_FREE_MODEL}" ]; then
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${DEFAULT_MODEL}|ark|${ARK_FREE_MODEL}|free"
            PROVIDER_ROUTE_SPEC="${PROVIDER_ROUTE_SPEC}
${COMPLEX_MODEL}|ark|${ARK_FREE_MODEL}|free"
        fi
        export PROVIDER_FALLBACK_ENABLED PROVIDER_FREE_FALLBACK_ENABLED
        export PROVIDER_MAX_TOKENS PROVIDER_MAX_INPUT_TOKENS
        export PROVIDER_MAX_REQUESTS_PER_HOUR="${PROVIDER_MAX_REQUESTS_HOUR}"
        export PROVIDER_DAILY_TOKEN_BUDGET="${PROVIDER_DAILY_TOKEN_BUDGET}"
        export PROVIDER_DAILY_COST_LIMIT_MICROS="${DAILY_COST_LIMIT_MICROS}"
        export PROVIDER_MONTHLY_COST_LIMIT_MICROS="${MONTHLY_COST_LIMIT_MICROS}"
        export PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS="${PROVIDER_MAX_COST_MICROS_PER_1K_TOKENS}"
        # Reuse the legacy quota path so the broker can atomically migrate the
        # previous hourly/day counters into the durable reservation ledger.
        export PROVIDER_LEDGER_FILE="/data/provider/quota.json"
        export PROVIDER_LEDGER_LOCK="/data/provider/.ledger.lock"
        export PROVIDER_LOG_FILE="/data/logs/provider-broker.log"
        export PROVIDER_RESERVATION_TTL_SECONDS=180
        while true; do
            if ! /bin/busybox nc -l -p "${PROVIDER_PORT}" -s 127.0.0.1 \
                -e /usr/local/bin/provider-broker-entrypoint >>/data/logs/provider-broker.log 2>&1; then
                sleep 1
            fi
        done
    ) &
    PROVIDER_BROKER_PID=$!
    printf '%s\n' "${PROVIDER_BROKER_PID}" > /run/zeroclaw/provider-broker.pid
    chown root:root /run/zeroclaw/provider-broker.pid
    chmod 0600 /run/zeroclaw/provider-broker.pid
    # The provider broker has its own copies. Remove both credentials from the
    # entrypoint before any unrelated root helper is forked.
    unset PROVIDER_CLIENT_AUTH_TOKEN PROVIDER_HEALTH_CLIENT_AUTH_TOKEN
fi

# BusyBox nc is a minimal local transport. The broker is the only child
# process that receives HA_TOKEN; ZeroClaw is started with HA/Telegram
# credential variables removed below.
CAPABILITY_PORT=42618
(
    # HA_TOKEN is the only credential this broker is allowed to retain. The
    # original Supervisor-provided variable was scrubbed in the parent and is
    # explicitly removed here as a defense against reordering regressions.
    unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \
        OPENROUTER_KEY NVIDIA_KEY ARK_KEY LEGACY_HA_TOKEN \
        ZEROCLAW_PROVIDER_UPSTREAM_URL ZEROCLAW_API_KEY ZEROCLAW_LEGACY_ACTION_GATE
    export HA_TOKEN HA_URL CAPABILITY_CLIENT_AUTH_TOKEN CAPABILITY_HEALTH_CLIENT_AUTH_TOKEN="${HEALTH_CLIENT_AUTH_TOKEN}"
    export ENABLE_WRITE_ACTIONS
    export CAPABILITY_MAX_ACTIONS_PER_HOUR="${MAX_ACTIONS_PER_HOUR}"
    export CAPABILITY_QUOTA_FILE="/data/capability/quota.json"
    export CAPABILITY_QUOTA_LOCK="/data/capability/.quota.lock"
    export ZEROCLAW_APPROVAL_OUTCOME_DIR="/data/approval-receipts/outcomes"
    export POLICY_MODE POLICY_QUIET_CONFIRM POLICY_BULK_THRESHOLD POLICY_CLIMATE_DELTA POLICY_REQUIRE_APPROVAL
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
printf '%s\n' "${CAPABILITY_BROKER_PID}" > /run/zeroclaw/capability-broker.pid
chown root:root /run/zeroclaw/capability-broker.pid
chmod 0600 /run/zeroclaw/capability-broker.pid
# The background subshell has its private copy for the typed broker.  Erase
# the parent-shell copies immediately after the fork so the entrypoint itself
# cannot retain or accidentally pass the Supervisor credential to later
# helpers.
unset HA_TOKEN LEGACY_HA_TOKEN

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

cat > /usr/local/bin/ha-health-read << 'SCRIPT'
#!/bin/sh
# Root-only health lane; its credential is not readable by the planner and it
# does not consume the planner's persisted read quota.
unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \
    OPENROUTER_KEY NVIDIA_KEY ARK_KEY ZEROCLAW_API_KEY
export ZEROCLAW_CAPABILITY_AUTH_FILE=/run/zeroclaw/health-client-auth
exec /usr/local/bin/ha-capability health_read_sensors
SCRIPT
chown root:root /usr/local/bin/ha-health-read
chmod 0700 /usr/local/bin/ha-health-read

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
RESULT=$(/usr/local/bin/ha-capability get_error_log) || { echo "(unavailable)"; exit 1; }
printf '%s\n' "$RESULT" | jq -r '.detail // "Home Assistant logs are unavailable"'
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
chown root:zeroclaw /run/zeroclaw
chmod 0710 /run/zeroclaw
TG_USERS_FILE="/run/zeroclaw/telegram-users"
echo "${TELEGRAM_USERS}" | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9]+$' > "${TG_USERS_FILE}" || true
chown root:root "${TG_USERS_FILE}"
chmod 0600 "${TG_USERS_FILE}"
TELEGRAM_OFFSET_FILE="/data/capability/telegram-offset"
LEGACY_TELEGRAM_OFFSET_FILE="/run/zeroclaw/telegram-offset"
# The Telegram cursor is broker state, not ephemeral runtime state.  Preserve
# a numeric cursor from the pre-3.1.4 runtime when it is available.  A fresh
# configured bot gets a -1 sentinel; the watcher confirms and discards the
# currently queued historical updates before it begins normal polling.  This
# avoids replaying stale commands after an app replacement while refusing to
# guess a cursor that was never durably recorded.
if [ -L "${TELEGRAM_OFFSET_FILE}" ] || [ -e "${TELEGRAM_OFFSET_FILE}" ] && [ ! -f "${TELEGRAM_OFFSET_FILE}" ]; then
    bashio::log.fatal "Telegram cursor is not a regular persistent file"
    exit 1
fi
if [ ! -e "${TELEGRAM_OFFSET_FILE}" ]; then
    if [ -f "${LEGACY_TELEGRAM_OFFSET_FILE}" ] &&
        grep -Eq '^[0-9]+$' "${LEGACY_TELEGRAM_OFFSET_FILE}"; then
        cp "${LEGACY_TELEGRAM_OFFSET_FILE}" "${TELEGRAM_OFFSET_FILE}"
    elif [ "${TELEGRAM_ENABLED}" = "true" ]; then
        printf '%s\n' '-1' > "${TELEGRAM_OFFSET_FILE}"
    else
        printf '%s\n' '0' > "${TELEGRAM_OFFSET_FILE}"
    fi
fi
rm -f "${LEGACY_TELEGRAM_OFFSET_FILE}"
rm -f /data/.tg_users /data/.tg_offset
chown root:root "${TELEGRAM_OFFSET_FILE}"
chmod 0600 "${TELEGRAM_OFFSET_FILE}"
TELEGRAM_TOKEN_FILE="/run/zeroclaw/telegram-token"
printf '%s' "${TELEGRAM_TOKEN}" > "${TELEGRAM_TOKEN_FILE}"
chown root:root "${TELEGRAM_TOKEN_FILE}"
chmod 0600 "${TELEGRAM_TOKEN_FILE}"
TELEGRAM_ENABLED_FILE="/run/zeroclaw/telegram-enabled"
TELEGRAM_WATCHER_PID_FILE="/run/zeroclaw/telegram-watcher.pid"
TELEGRAM_READY_FILE="/data/capability/telegram-ready"
TELEGRAM_HEARTBEAT_FILE="/data/capability/telegram-heartbeat"
rm -f "${TELEGRAM_ENABLED_FILE}" "${TELEGRAM_WATCHER_PID_FILE}" "${TELEGRAM_READY_FILE}" "${TELEGRAM_HEARTBEAT_FILE}"
if [ "${TELEGRAM_ENABLED}" = "true" ]; then
    printf '%s\n' true > "${TELEGRAM_ENABLED_FILE}"
    chown root:root "${TELEGRAM_ENABLED_FILE}"
    chmod 0600 "${TELEGRAM_ENABLED_FILE}"
fi
TELEGRAM_CONFLICT_FILE="/data/capability/telegram-conflict"
TELEGRAM_CONFLICT_TOKEN_FILE="/data/capability/telegram-conflict.token"
if [ "${TELEGRAM_ENABLED}" = "true" ]; then
    TELEGRAM_TOKEN_HASH=$(sha256sum "${TELEGRAM_TOKEN_FILE}" | cut -d' ' -f1)
    if [ -e "${TELEGRAM_CONFLICT_FILE}" ] || [ -L "${TELEGRAM_CONFLICT_FILE}" ]; then
        if [ -L "${TELEGRAM_CONFLICT_FILE}" ] || [ ! -f "${TELEGRAM_CONFLICT_FILE}" ] ||
            [ ! -f "${TELEGRAM_CONFLICT_TOKEN_FILE}" ]; then
            bashio::log.fatal "Telegram conflict state is malformed; refusing to start"
            exit 1
        fi
        previous_conflict_token=$(cat "${TELEGRAM_CONFLICT_TOKEN_FILE}")
        if [ "$previous_conflict_token" = "$TELEGRAM_TOKEN_HASH" ]; then
            bashio::log.fatal "Telegram polling conflict is latched; stop the other poller and remove ${TELEGRAM_CONFLICT_FILE} before restarting"
            exit 1
        fi
        rm -f "${TELEGRAM_CONFLICT_FILE}" "${TELEGRAM_CONFLICT_TOKEN_FILE}"
    else
        rm -f "${TELEGRAM_CONFLICT_TOKEN_FILE}"
    fi
fi
install -m 0755 /opt/zeroclaw/lib/telegram-broker-handler.sh /usr/local/bin/tg-broker-handler
install -m 0755 /opt/zeroclaw/lib/telegram-capability.sh /usr/local/bin/tg-capability
install -m 0755 /opt/zeroclaw/lib/telegram-broker-entrypoint.sh /usr/local/bin/tg-broker-entrypoint
install -m 0755 /opt/zeroclaw/lib/telegram-render.sh /usr/local/bin/telegram-render
install -m 0755 /opt/zeroclaw/lib/telegram-legacy-action.sh /usr/local/bin/telegram-legacy-action
TELEGRAM_PORT=42619
    if [ "${TELEGRAM_ENABLED}" = "true" ]; then
    (
        unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \
            OPENROUTER_KEY NVIDIA_KEY ARK_KEY LEGACY_HA_TOKEN \
            ZEROCLAW_PROVIDER_UPSTREAM_URL ZEROCLAW_API_KEY ZEROCLAW_LEGACY_ACTION_GATE
        export TELEGRAM_TOKEN_FILE TELEGRAM_CLIENT_AUTH_TOKEN TELEGRAM_SYSTEM_AUTH_TOKEN
        export TELEGRAM_APPROVAL_CHAT="${FIRST_USER}"
        while true; do
            if ! /bin/busybox nc -l -p "${TELEGRAM_PORT}" -s 127.0.0.1 \
                -e /usr/local/bin/tg-broker-entrypoint >>/data/logs/telegram-broker.log 2>&1; then
                sleep 1
            fi
        done
    ) &
fi

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

# tg-system-notify is root-only and uses a separate credential that the planner
# cannot read. It is reserved for fixed, root-generated operational notices;
# the planner-facing tg-capability client has no arbitrary send-text operation.
cat > /usr/local/bin/tg-system-notify << 'SCRIPT'
#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo "system Telegram notices are root-only" >&2; exit 1; }
[ "$#" -eq 1 ] || { echo "Usage: tg-system-notify <text>" >&2; exit 1; }
[ "${#1}" -ge 1 ] && [ "${#1}" -le 512 ] || { echo "system notice is too long" >&2; exit 1; }
AUTH_FILE=/run/zeroclaw/telegram-system-auth
[ -r "$AUTH_FILE" ] || { echo "system Telegram credential is unavailable" >&2; exit 1; }
AUTH=$(tr -d '\r\n' < "$AUTH_FILE")
[ -n "$AUTH" ] || { echo "system Telegram credential is empty" >&2; exit 1; }
# Read the secret from the protected file directly instead of placing it in
# jq's argv, where a concurrent unprivileged planner could observe it through
# procfs. The non-secret bounded notice text may remain an argv value.
REQUEST=$(jq -nc --rawfile auth "$AUTH_FILE" --arg text "$1" \
    '{operation:"send_system_notice",auth:$auth,text:$text}')
unset AUTH
RESPONSE=$(/bin/busybox nc -w 40 127.0.0.1 42619 <<EOF
$REQUEST
EOF
) || { echo "Telegram broker unavailable" >&2; exit 1; }
[ -n "$RESPONSE" ] || { echo "Telegram broker returned no response" >&2; exit 1; }
jq -e '.ok == true' >/dev/null <<EOF
$RESPONSE
EOF
SCRIPT
chmod 0700 /usr/local/bin/tg-system-notify

# ==============================================================
# tg-callback-watcher — single owner of the Telegram bot socket.
# Long-polls ALL updates (messages + callback_query) because Telegram
# permits only one getUpdates client per bot. Replaces ZeroClaw's
# built-in Telegram channel entirely:
#   • .message      → validate sender, run the full single-message agent,
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
# The watcher reads the Telegram bot token from its private runtime file.  It
# must never inherit Supervisor, provider, or parent-process credential env.
unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \
    OPENROUTER_KEY NVIDIA_KEY ARK_KEY LEGACY_HA_TOKEN \
    ZEROCLAW_PROVIDER_UPSTREAM_URL ZEROCLAW_API_KEY ZEROCLAW_LEGACY_ACTION_GATE
TOKEN=\$(cat "${TELEGRAM_TOKEN_FILE}")
[ "\${#TOKEN}" -le 256 ] || exit 1
case "\$TOKEN" in
    ''|*[!A-Za-z0-9_.:-]*) exit 1 ;;
esac
OFFSET_F="${TELEGRAM_OFFSET_FILE}"
REPLY_CACHE_DIR="/data/capability/telegram-replies"
CALLBACK_CACHE_DIR="/data/capability/telegram-callbacks"
APPROVAL_OUTCOME_DIR="/data/approval-receipts/outcomes"
USERS_F="${TG_USERS_FILE}"
GW="${GW}"
AGENT_BIN="/usr/local/bin/zeroclaw"
AGENT_CONFIG_DIR="${CONFIG_DIR}"
AGENT_WORKSPACE="${WS}"
AGENT_SESSION_LOCK_DIR="/data/capability/telegram-session-locks"
APPROVAL_USER="${FIRST_USER}"
APPROVAL_CHAT="${FIRST_USER}"
[ -n "\$TOKEN" ] || exit 1
. /opt/zeroclaw/lib/telegram-session.sh
. /opt/zeroclaw/lib/telegram-agent-turn.sh
. /opt/zeroclaw/lib/telegram-message-guard.sh
. /opt/zeroclaw/lib/telegram-approval-format.sh
[ ! -L "\$REPLY_CACHE_DIR" ] || exit 1
if [ ! -d "\$REPLY_CACHE_DIR" ]; then
    mkdir -m 0700 "\$REPLY_CACHE_DIR" 2>/dev/null || exit 1
fi
[ ! -L "\$CALLBACK_CACHE_DIR" ] || exit 1
if [ ! -d "\$CALLBACK_CACHE_DIR" ]; then
    mkdir -m 0700 "\$CALLBACK_CACHE_DIR" 2>/dev/null || exit 1
fi
[ ! -L "\$OFFSET_F" ] && [ -f "\$OFFSET_F" ] || exit 1
BOT_ID_FILE="/data/capability/telegram-bot-id"
BOT_ID=""
BOT_ID_READY=false
READY_FILE="${TELEGRAM_READY_FILE}"
HEARTBEAT_FILE="${TELEGRAM_HEARTBEAT_FILE}"
rm -f -- "\$READY_FILE"
rm -f -- "\$HEARTBEAT_FILE"
trap 'rm -f -- "\$READY_FILE" "\$HEARTBEAT_FILE"' EXIT
[ ! -L "\$BOT_ID_FILE" ] || exit 1
if [ -e "\$BOT_ID_FILE" ] && [ ! -f "\$BOT_ID_FILE" ]; then
    exit 1
fi

telegram_response_ok() {
    response="\$1"
    [ -n "\$response" ] || return 1
    # Never log or relay a Telegram response that contains the bot token or a
    # common transport encoding of it.
    token_base64=\$(printf '%s' "\$TOKEN" | base64 | tr -d '\r\n') || return 1
    token_base64_unpadded=\$(printf '%s' "\$token_base64" | tr -d '=')
    token_base64_urlsafe=\$(printf '%s' "\$token_base64" | tr '+/' '-_')
    token_base64_urlsafe_unpadded=\$(printf '%s' "\$token_base64_urlsafe" | tr -d '=')
    token_hex=\$(printf '%s' "\$TOKEN" | od -An -tx1 -v | tr -d ' \r\n') || return 1
    token_hex_upper=\$(printf '%s' "\$token_hex" | tr 'a-f' 'A-F')
    token_percent=\$(printf '%s' "\$TOKEN" | od -An -tx1 -v | awk '{for (i=1; i<=NF; i++) printf "%%%s", toupper(\$i)}') || return 1
    token_percent_lower=\$(printf '%s' "\$token_percent" | tr 'A-F' 'a-f')
    token_percent_mixed=\$(printf '%s' "\$TOKEN" | od -An -tx1 -v | awk 'function hex_value(h, p) {
                 p = index("0123456789ABCDEF", toupper(h))
                 return p - 1
             }
             {
                 for (i=1; i<=NF; i++) {
                     h=toupper(\$i)
                     value=hex_value(substr(h,1,1))*16 + hex_value(substr(h,2,1))
                     if ((value >= 48 && value <= 57) ||
                         (value >= 65 && value <= 90) ||
                         (value >= 97 && value <= 122) ||
                         value == 45 || value == 46 || value == 95 || value == 126) {
                         printf "%c", value
                     } else {
                         printf "%%%s", h
                     }
                 }
             }') || return 1
    token_percent_mixed_lower=\$(printf '%s' "\$token_percent_mixed" | tr 'A-F' 'a-f')
    for credential_variant in \
        "\$TOKEN" "\$token_base64" "\$token_base64_unpadded" \
        "\$token_base64_urlsafe" "\$token_base64_urlsafe_unpadded" \
        "\$token_hex" "\$token_hex_upper" "\$token_percent" \
        "\$token_percent_lower" "\$token_percent_mixed" "\$token_percent_mixed_lower"; do
        [ -n "\$credential_variant" ] || continue
        if printf '%s' "\$response" | grep -F -- "\$credential_variant" >/dev/null 2>&1; then
            return 1
        fi
    done
    printf '%s' "\$response" | jq -e '.ok == true' >/dev/null 2>&1
}

telegram_polling_conflict() {
    response="\$1"
    printf '%s' "\$response" | jq -e '.ok == false and .error_code == 409' >/dev/null 2>&1
}

telegram_call_ok() {
    response=\$(telegram_curl "\$@" 2>/dev/null) || return 1
    telegram_response_ok "\$response"
}

commit_offset() {
    next_offset="\$1"
    case "\$next_offset" in
        -1) ;;
        ''|*[!0-9]*) return 1 ;;
        *) ;;
    esac
    offset_tmp="\${OFFSET_F}.tmp.\$\$"
    if ! printf '%s\n' "\$next_offset" > "\$offset_tmp"; then
        rm -f "\$offset_tmp"
        return 1
    fi
    chmod 0600 "\$offset_tmp"
    if ! mv -f "\$offset_tmp" "\$OFFSET_F"; then
        rm -f "\$offset_tmp"
        return 1
    fi
    sync
}

bootstrap_offset() {
    # Telegram's negative offset confirms all older queued updates.  Do this
    # exactly once on a fresh persistent state file, then enter normal
    # positive-offset polling.  If the API is unavailable, leave -1 intact so
    # no update is silently acknowledged.
    offset_state=\$(cat "\$OFFSET_F" 2>/dev/null || printf '%s' invalid)
    [ "\$offset_state" = "-1" ] || return 0
    bootstrap_response=\$(telegram_curl getUpdates -s --max-time 30 --get \\
        --data-urlencode 'offset=-1' \\
        --data-urlencode 'timeout=0' \\
        --data-urlencode 'allowed_updates=["message","callback_query"]' \\
        2>/dev/null) || return 1
    if ! telegram_response_ok "\$bootstrap_response"; then
        if telegram_polling_conflict "\$bootstrap_response"; then
            printf '%s\n' 'Telegram polling conflict; refusing to run alongside another poller.' >>/data/logs/telegram-broker.log
            exit 42
        fi
        return 1
    fi
    printf '%s' "\$bootstrap_response" | jq -e '.result | type == "array"' >/dev/null 2>&1 || return 1
    latest=\$(printf '%s' "\$bootstrap_response" | jq -r '.result | (max_by(.update_id).update_id // empty)' 2>/dev/null)
    case "\$latest" in
        ''|null) commit_offset 0 ;;
        *[!0-9]*) return 1 ;;
        *) commit_offset "\$((latest + 1))" ;;
    esac
}

# Keep the Telegram bot token in a private curl config file. The URL is never
# passed as a child-process argument, which prevents token leakage through ps
# or /proc command-line inspection by a same-container observer.
telegram_curl() {
    method="\$1"
    shift
    config_file=\$(mktemp /run/zeroclaw/.telegram-curl.XXXXXX) || return 1
    chmod 0600 "\$config_file"
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "\$TOKEN" "\$method" > "\$config_file"
    curl --connect-timeout 5 --max-time 35 --config "\$config_file" "\$@"
    rc=\$?
    rm -f "\$config_file"
    return "\$rc"
}

purge_telegram_replay_state() {
    # A bot token change is a new Telegram principal.  Never let its cursor or
    # cached replies inherit state from the previous bot identity.
    for cache_dir in "\$REPLY_CACHE_DIR" "\$CALLBACK_CACHE_DIR"; do
        [ ! -L "\$cache_dir" ] && [ -d "\$cache_dir" ] || continue
        for cache_file in "\$cache_dir"/*.json "\$cache_dir"/*.txt; do
            [ -f "\$cache_file" ] || [ -L "\$cache_file" ] || continue
            [ -L "\$cache_file" ] && continue
            rm -f -- "\$cache_file"
        done
    done
}

load_bot_identity() {
    bot_response=\$(telegram_curl getMe -s --max-time 15 2>/dev/null) || return 1
    telegram_response_ok "\$bot_response" || return 1
    new_bot_id=\$(printf '%s' "\$bot_response" | jq -r '.result.id // empty' 2>/dev/null) || return 1
    case "\$new_bot_id" in
        ''|*[!0-9]*) return 1 ;;
    esac
    old_bot_id=""
    if [ -e "\$BOT_ID_FILE" ]; then
        [ ! -L "\$BOT_ID_FILE" ] && [ -f "\$BOT_ID_FILE" ] || return 1
        old_bot_id=\$(cat "\$BOT_ID_FILE" 2>/dev/null) || return 1
    fi
    case "\$old_bot_id" in
        ''|*[!0-9]*) old_bot_id="" ;;
    esac
    if [ "\$old_bot_id" != "\$new_bot_id" ]; then
        purge_telegram_replay_state
        commit_offset -1 || return 1
    fi
    bot_id_tmp="\${BOT_ID_FILE}.tmp.\$\$"
    printf '%s\n' "\$new_bot_id" > "\$bot_id_tmp" || return 1
    chmod 0600 "\$bot_id_tmp"
    mv -f "\$bot_id_tmp" "\$BOT_ID_FILE" || {
        rm -f "\$bot_id_tmp"
        return 1
    }
    sync
    BOT_ID="\$new_bot_id"
    BOT_ID_READY=true
}

mark_telegram_ready() {
    # Identity alone is not readiness: the watcher must have completed cursor
    # bootstrap and received a structurally valid polling response before HA
    # may treat Telegram approvals as available.
    [ "\$BOT_ID_READY" = true ] || return 1
    [ ! -L "\$READY_FILE" ] || return 1
    ready_tmp="\${READY_FILE}.tmp.\$\$"
    if ! printf '%s\n' "\$BOT_ID" > "\$ready_tmp"; then
        rm -f "\$ready_tmp"
        return 1
    fi
    if ! chown root:root "\$ready_tmp" || ! chmod 0600 "\$ready_tmp"; then
        rm -f "\$ready_tmp"
        return 1
    fi
    if ! mv -f "\$ready_tmp" "\$READY_FILE"; then
        rm -f "\$ready_tmp"
        return 1
    fi
    heartbeat_tmp="\${HEARTBEAT_FILE}.tmp.\$\$"
    if ! printf '%s\n' "\$(date -u +%s)" > "\$heartbeat_tmp"; then
        rm -f "\$heartbeat_tmp" "\$READY_FILE"
        return 1
    fi
    if ! chown root:root "\$heartbeat_tmp" || ! chmod 0600 "\$heartbeat_tmp" ||
        ! mv -f "\$heartbeat_tmp" "\$HEARTBEAT_FILE"; then
        rm -f "\$heartbeat_tmp" "\$READY_FILE"
        return 1
    fi
    sync
}

answer_cb() {
    cb_id="\$1"; text="\$2"
    telegram_call_ok answerCallbackQuery -s -X POST \\
        --data-urlencode "callback_query_id=\$cb_id" \\
        --data-urlencode "text=\$text"
}

edit_msg() {
    chat_id="\$1"; msg_id="\$2"; new_text="\$3"
    [ -n "\$msg_id" ] || return 1
    # Strip the inline keyboard by omitting reply_markup on edit.
    telegram_call_ok editMessageText -s -X POST \\
        -H "Content-Type: application/json" \\
        -d "\$(jq -nc --arg c "\$chat_id" --argjson m "\$msg_id" --arg t "\$new_text" \\
              '{chat_id:\$c, message_id:\$m, text:\$t}')"
}

send_msg() {
    chat_id="\$1"; text="\$2"
    telegram_call_ok sendMessage -s -X POST \\
        --data-urlencode "chat_id=\$chat_id" \\
        --data-urlencode "text=\$text"
}

send_typing() {
    chat_id="\$1"
    telegram_curl sendChatAction -s -X POST \\
        --data-urlencode "chat_id=\$chat_id" \\
        --data-urlencode "action=typing" >/dev/null 2>&1 || true
}

cache_reply() {
    update_id="\$1"; chat_id="\$2"; actor_user_id="\$3"; reply="\$4"
    case "\$update_id" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ ! -L "\$REPLY_CACHE_DIR" ] && [ -d "\$REPLY_CACHE_DIR" ] || return 1
    cache_tmp="\${REPLY_CACHE_DIR}/.\${update_id}.tmp.\$\$"
    if ! jq -nc --arg bot "\$BOT_ID" --arg chat "\$chat_id" \
        --arg actor "\$actor_user_id" --arg reply "\$reply" \
        '{bot_id:\$bot,chat_id:\$chat,actor_user_id:\$actor,reply:\$reply}' > "\$cache_tmp"; then
        rm -f "\$cache_tmp"
        return 1
    fi
    chmod 0600 "\$cache_tmp"
    mv -f "\$cache_tmp" "\${REPLY_CACHE_DIR}/\${update_id}.json"
    sync
}

send_and_cache() {
    update_id="\$1"; chat_id="\$2"; actor_user_id="\$3"; reply="\$4"
    cache_reply "\$update_id" "\$chat_id" "\$actor_user_id" "\$reply" || return 1
    send_msg "\$chat_id" "\$reply"
}

send_cached_reply() {
    update_id="\$1"; chat_id="\$2"; actor_user_id="\$3"
    case "\$update_id" in
        ''|*[!0-9]*) return 1 ;;
    esac
    cached_file="\${REPLY_CACHE_DIR}/\${update_id}.json"
    [ ! -L "\$cached_file" ] && [ -f "\$cached_file" ] || return 1
    cached_reply=\$(jq -er --arg bot "\$BOT_ID" --arg chat "\$chat_id" \
        --arg actor "\$actor_user_id" \
        'select(.bot_id == \$bot and .chat_id == \$chat and
                .actor_user_id == \$actor and (.reply | type == "string")) | .reply' \
        "\$cached_file" 2>/dev/null) || {
        rm -f -- "\$cached_file"
        return 1
    }
    if sanitized_cached=\$(printf '%s' "\$cached_reply" | /usr/local/bin/telegram-render 2>/dev/null); then
        cached_reply="\$sanitized_cached"
    else
        printf '%s\n' 'blocked internal tool syntax in cached Telegram reply; replacing it with a safe status message' >>/data/logs/telegram-broker.log
        cached_reply="I couldn't confirm the result safely. Please check Home Assistant history before retrying."
        cache_reply "\$update_id" "\$chat_id" "\$actor_user_id" "\$cached_reply" || true
    fi
    send_msg "\$chat_id" "\$cached_reply"
}

cache_callback_result() {
    update_id="\$1"; chat_id="\$2"; message_id="\$3"; actor_user_id="\$4"; answer="\$5"; edit="\$6"
    case "\$update_id:\$message_id" in
        *[!0-9:]*|:*) return 1 ;;
    esac
    [ ! -L "\$CALLBACK_CACHE_DIR" ] && [ -d "\$CALLBACK_CACHE_DIR" ] || return 1
    cache_tmp="\${CALLBACK_CACHE_DIR}/.\${update_id}.tmp.\$\$"
    if ! jq -nc --arg bot "\$BOT_ID" --arg chat "\$chat_id" --arg actor "\$actor_user_id" \
        --argjson message "\$message_id" --arg answer "\$answer" --arg edit "\$edit" \
        '{bot_id:\$bot,chat_id:\$chat,actor_user_id:\$actor,message_id:\$message,answer:\$answer,edit:\$edit}' > "\$cache_tmp"; then
        rm -f "\$cache_tmp"
        return 1
    fi
    chmod 0600 "\$cache_tmp"
    mv -f "\$cache_tmp" "\${CALLBACK_CACHE_DIR}/\${update_id}.json"
    sync
}

replay_callback_result() {
    update_id="\$1"; cb_id="\$2"; chat_id="\$3"; message_id="\$4"; actor_user_id="\$5"
    cached_file="\${CALLBACK_CACHE_DIR}/\${update_id}.json"
    [ ! -L "\$cached_file" ] && [ -f "\$cached_file" ] || return 1
    cached_bot=\$(jq -r '.bot_id // empty' "\$cached_file" 2>/dev/null) || return 1
    cached_chat=\$(jq -r '.chat_id // empty' "\$cached_file" 2>/dev/null) || return 1
    cached_actor=\$(jq -r '.actor_user_id // empty' "\$cached_file" 2>/dev/null) || return 1
    cached_message=\$(jq -r '.message_id // empty' "\$cached_file" 2>/dev/null) || return 1
    [ "\$cached_bot" = "\$BOT_ID" ] && [ "\$cached_chat" = "\$chat_id" ] && \
        [ "\$cached_actor" = "\$actor_user_id" ] && [ "\$cached_message" = "\$message_id" ] || return 1
    cached_answer=\$(jq -r '.answer // empty' "\$cached_file" 2>/dev/null) || return 1
    cached_edit=\$(jq -r '.edit // empty' "\$cached_file" 2>/dev/null) || return 1
    answer_cb "\$cb_id" "\$cached_answer" || return 1
    [ -z "\$cached_edit" ] || edit_msg "\$chat_id" "\$message_id" "\$cached_edit"
}

canonical_ticket_summary() {
    summary_file="\$1"
    summary_service=\$(jq -r '.service // empty' "\$summary_file" 2>/dev/null) || return 1
    summary_payload=\$(jq -cS '.payload' "\$summary_file" 2>/dev/null) || return 1
    [ -n "\$summary_service" ] && [ -n "\$summary_payload" ] || return 1
    printf '%s | %s' "\$summary_service" "\$summary_payload"
}

approval_outcome_text() {
    outcome_file="\$1"
    expected_generation="\${2:-}"
    [ ! -L "\$outcome_file" ] && [ -f "\$outcome_file" ] || return 1
    jq -e --arg actor "\$APPROVAL_USER" --arg chat "\$APPROVAL_CHAT" \
        --arg generation "\$expected_generation" \
        '.state == "applied" and (.approval_generation | type == "string" and test("^[a-f0-9]{32}$")) and
         (\$generation == "" or .approval_generation == \$generation) and
         .actor_user_id == \$actor and .chat_id == \$chat and
         (.service | type == "string") and (.payload | type == "object")' \
        "\$outcome_file" >/dev/null 2>&1 || return 1
    outcome_summary=\$(canonical_ticket_summary "\$outcome_file") || return 1
    outcome_result=\$(jq -c '.result // null' "\$outcome_file" 2>/dev/null) || return 1
    printf '✅ Approved and applied: %s\\nHome Assistant accepted the exact service call.\\nResult: %s' \
        "\$outcome_summary" "\$outcome_result" | cut -c1-4000
}

replay_approval_message() {
    short="\$1"; update_id="\$2"; chat_id="\$3"; actor_user_id="\$4"; approval_generation="\$5"
    outcome_file="\${APPROVAL_OUTCOME_DIR}/\${short}.json"
    ticket_file="/data/approval-receipts/tickets/\${short}.json"
    if [ -e "\$ticket_file" ] || [ -L "\$ticket_file" ]; then
        [ -f "\$ticket_file" ] && [ ! -L "\$ticket_file" ] || return 1
        approval_generation_matches "\$ticket_file" "\$approval_generation" || return 1
    fi
    outcome_reply=\$(approval_outcome_text "\$outcome_file" "\$approval_generation") || return 1
    # The broker writes the outcome before finalizing the ticket. Reconcile
    # that durable result when a callback/text retry observes the interval;
    # this never replays the HA call and is safe if another process already
    # completed the transition.
    if [ -f "\$ticket_file" ] && [ ! -L "\$ticket_file" ]; then
        ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition complete "\$short" >/dev/null 2>&1 || true
    fi
    send_and_cache "\$update_id" "\$chat_id" "\$actor_user_id" "\$outcome_reply"
}

replay_approval_outcome() {
    short="\$1"; cb_id="\$2"; chat_id="\$3"; message_id="\$4"; actor_user_id="\$5"; approval_generation="\${6:-}"
    outcome_file="\${APPROVAL_OUTCOME_DIR}/\${short}.json"
    ticket_file="/data/approval-receipts/tickets/\${short}.json"
    if [ -e "\$ticket_file" ] || [ -L "\$ticket_file" ]; then
        [ -f "\$ticket_file" ] && [ ! -L "\$ticket_file" ] || return 1
        approval_generation_matches "\$ticket_file" "\$approval_generation" || return 1
    fi
    outcome_reply=\$(approval_outcome_text "\$outcome_file" "\$approval_generation") || return 1
    jq -e --arg message "\$message_id" \
        '(.message_id | tostring) == \$message' "\$outcome_file" >/dev/null 2>&1 || return 1
    if [ -f "\$ticket_file" ] && [ ! -L "\$ticket_file" ]; then
        ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition complete "\$short" >/dev/null 2>&1 || true
    fi
    answer_cb "\$cb_id" "Applied." || return 1
    edit_msg "\$chat_id" "\$message_id" "\$outcome_reply" || return 1
    cache_callback_result "\$UPDATE_ID" "\$chat_id" "\$message_id" "\$actor_user_id" "Applied." "\$outcome_reply"
}

run_agent_turn() {
    run_telegram_agent_turn "\$@"
}

is_allowed_user() {
    uid="\$1"
    [ ! -f "\$USERS_F" ] && return 1
    grep -Fx "\$uid" "\$USERS_F" >/dev/null 2>&1
}

valid_positive_id() {
    case "\$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_chat_id() {
    case "\$1" in
        ''|*[!0-9-]*) return 1 ;;
        -) return 1 ;;
        -*) valid_positive_id "\${1#-}" ;;
        *) valid_positive_id "\$1" ;;
    esac
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
    chat_id="\$1"; from_id="\$2"; chat_type="\$3"; text="\$4"; update_id="\$5"
    valid_chat_id "\$chat_id" || return 0
    valid_positive_id "\$from_id" || return 0
    case "\$update_id" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # Ordinary messages are private-chat only.  An allowlisted user must not
    # cause private household state or planner responses to be posted into a
    # group where other participants can read them.
    telegram_message_destination_allowed "\$chat_type" "\$chat_id" "\$from_id" || return 0

    # Approval replies are also cached before notification.  If Telegram
    # rejects the first delivery after a successful claim, replay sends the
    # same truthful outcome instead of reporting an unrelated expired ticket.
    cached_file="\${REPLY_CACHE_DIR}/\${update_id}.json"
    if [ ! -L "\$cached_file" ] && [ -f "\$cached_file" ]; then
        send_cached_reply "\$update_id" "\$chat_id" "\$from_id"
        return
    fi

    if ! is_allowed_user "\$from_id"; then
        # Do not persist replies for untrusted senders. A public bot can
        # receive arbitrarily many unique update IDs, and caching each denial
        # would turn Telegram traffic into an unbounded disk-write primitive.
        # Silently drop the message so an attacker cannot hold the sequential
        # update cursor hostage by making Telegram reject a denial response.
        return 0
    fi
    [ -z "\$text" ] && return

    APPROVE_REQUEST=\$(approval_request "\$text" 2>/dev/null || true)
    REJECT_REQUEST=\$(rejection_request "\$text" 2>/dev/null || true)
    APPROVE_ID=""
    APPROVE_GENERATION=""
    REJECT_ID=""
    REJECT_GENERATION=""
    if [ -n "\$APPROVE_REQUEST" ]; then
        APPROVE_ID="\${APPROVE_REQUEST%% *}"
        APPROVE_GENERATION="\${APPROVE_REQUEST#* }"
    fi
    if [ -n "\$REJECT_REQUEST" ]; then
        REJECT_ID="\${REJECT_REQUEST%% *}"
        REJECT_GENERATION="\${REJECT_REQUEST#* }"
    fi
    if [ -n "\$APPROVE_ID" ] || [ -n "\$REJECT_ID" ]; then
        SHORT="\${APPROVE_ID:-\$REJECT_ID}"
        APPROVAL_GENERATION="\${APPROVE_GENERATION:-\$REJECT_GENERATION}"
        if [ "\$from_id" != "\$APPROVAL_USER" ] || [ "\$chat_id" != "\$APPROVAL_CHAT" ]; then
            if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "This approval belongs to the configured approval owner."; then return 1; fi
            return 0
        fi
        TICKET="/data/approval-receipts/tickets/\${SHORT}.json"
        if [ ! -f "\$TICKET" ]; then
            if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "Ticket \${SHORT} is expired or already actioned."; then return 1; fi
            return 0
        fi
        if ! approval_generation_matches "\$TICKET" "\$APPROVAL_GENERATION"; then
            if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "That approval code is no longer valid for ticket \${SHORT}. Use the exact YES/NO form shown in the current Telegram approval message."; then return 1; fi
            return 0
        fi
        SUMMARY=\$(canonical_ticket_summary "\$TICKET") || return 1
        if [ -n "\$APPROVE_ID" ]; then
            if replay_approval_message "\$SHORT" "\$update_id" "\$chat_id" "\$from_id" "\$APPROVAL_GENERATION"; then
                return 0
            fi
            # A watcher restart can occur after the durable approved_audited
            # marker but before HA execution. Resume that approval instead of
            # treating the redelivery as a duplicate and abandoning it.
            if ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition approve "\$SHORT" "\$from_id" "\$chat_id" "\$APPROVAL_GENERATION" >/dev/null 2>&1; then
                if OUT=\$(apply_approved_ticket "\$SHORT" "\$from_id" "\$chat_id"); then
                    if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "✅ Approved and applied: \${SUMMARY}
\${OUT}"
                    then return 1; fi
                else
                    # A durable applied outcome may exist even when the
                    # helper returned non-zero because finalization failed.
                    # Replay that receipt before reporting uncertainty and do
                    # not issue another Home Assistant call.
                    if replay_approval_message "\$SHORT" "\$update_id" "\$chat_id" "\$from_id" "\$APPROVAL_GENERATION"; then
                        return 0
                    fi
                    if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "⚠️ Approved, but the execution outcome could not be confirmed; the claim remains for recovery. Check Home Assistant history before retrying.
\${OUT}"
                    then return 1; fi
                fi
            else
                if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "Approval for \${SHORT} could not be applied."; then return 1; fi
            fi
        elif ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition reject "\$SHORT" "\$from_id" "\$chat_id" "\$APPROVAL_GENERATION" >/dev/null 2>&1; then
            if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "❌ Rejected: \${SUMMARY}"; then return 1; fi
        else
            if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "Rejection for \${SHORT} could not be applied."; then return 1; fi
        fi
        return 0
    fi

    LEGACY_APPROVAL_ID=\$(legacy_approval_id "\$text" 2>/dev/null || true)
    LEGACY_REJECTION_ID=\$(legacy_rejection_id "\$text" 2>/dev/null || true)
    if [ -n "\$LEGACY_APPROVAL_ID" ] || [ -n "\$LEGACY_REJECTION_ID" ]; then
        if ! send_and_cache "\$update_id" "\$chat_id" "\$from_id" "This approval reply is missing its one-time code. Use the exact YES/NO form shown in the Telegram approval message."; then return 1; fi
        return 0
    fi

    # v3.1.3: correction-detection branch.
    # If the previous turn produced an outcome AND the user's reply opens with
    # a correction marker, fire a synthetic learning prompt to the gateway in
    # the background. The agent will produce a one-line lesson and persist it
    # via zc.lesson_add. We only fire when the root-owned outcome receipt exists, so a
    # bare "no" in response to a question (no outcome stored) won't trigger.
    # v3.1.3.1: regex widened to catch "they're not on", "didn't work",
    # "still off", "isn't", "nothing happened" — common real corrections that
    # don't open with the "no/wrong" markers.
    LAST_OUTCOME_FILE="/data/capability/last-outcome.json"
    if [ "${ENABLE_LEARNING}" != "true" ]; then
        LAST_OUTCOME_FILE="/data/capability/.learning-disabled"
    fi
    if [ "${ENABLE_LEARNING}" = "true" ] && [ ! -L "\$LAST_OUTCOME_FILE" ] && [ -f "\$LAST_OUTCOME_FILE" ]; then
        OUTCOME_NOW=\$(date -u +%s)
        if ! jq -e --argjson now "\$OUTCOME_NOW" \
            '(.expires_at | type == "number" and floor == . and . >= \$now)' "\$LAST_OUTCOME_FILE" >/dev/null 2>&1; then
            rm -f "\$LAST_OUTCOME_FILE"
        fi
    fi
    CORRECTION_PROMPT=""
    if [ ! -L "\$LAST_OUTCOME_FILE" ] && [ -f "\$LAST_OUTCOME_FILE" ]; then
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
                LAST=\$(jq -r '.text // empty' "\$LAST_OUTCOME_FILE" 2>/dev/null)
                rm -f "\$LAST_OUTCOME_FILE"
                if [ -n "\$LAST" ]; then
                    # Queue the learning prompt for after the foreground turn.
                    # It uses the same durable session file, so running it in the
                    # background here races the user turn for the session lock.
                    CORRECTION_PROMPT="User correction received. Previous turn outcome was: \${LAST}. User just said: \${text}. Generate ONE lesson line ≤80 chars that would prevent this mistake next time, then use the native shell tool with zc-lesson-add. Do not message the user — this is a silent learning hook."
                fi
                ;;
        esac
        rm -f "\$LAST_OUTCOME_FILE"
    fi

    send_typing "\$chat_id"
    REPLY=\$(run_agent_turn "\$chat_id" "\$text" \\
        2>>/data/logs/telegram-broker.log)
    AGENT_STATUS=\$?
    # A malformed provider-side tool call is an internal protocol failure, not
    # a user-facing reply. Do not leak commands such as a fenced tool_call into
    # Telegram, and do not imply that an action ran when it was not dispatched.
    if [ "\$AGENT_STATUS" -eq 0 ] && [ -n "\$REPLY" ] && \\
        SANITIZED=\$(printf '%s' "\$REPLY" | /usr/local/bin/telegram-render 2>/dev/null); then
        REPLY="\$SANITIZED"
    else
        printf '%s\n' "blocked internal tool syntax in Telegram reply or Telegram agent failure (status=\$AGENT_STATUS)" >>/data/logs/telegram-broker.log
        LEGACY_ACTION_REPLY=""
        # Older/non-tool-capable models sometimes return the exact guarded
        # action spelling as plain text. Recover only that bounded form; the
        # helper validates it and sends it through the root broker.
        if [ "\$AGENT_STATUS" -eq 0 ] && \
            LEGACY_ACTION_REPLY=\$(/usr/local/bin/telegram-legacy-action "\$REPLY" 2>>/data/logs/telegram-broker.log); then
            printf '%s\n' 'recovered one-line guarded action through the typed broker' >>/data/logs/telegram-broker.log
            REPLY="\$LEGACY_ACTION_REPLY"
        elif [ "\$AGENT_STATUS" -eq 0 ]; then
            # Do not launch a second model turn here. A recovery turn can race
            # the chat session and can repeat a tool request after the first
            # turn has already reached a broker. The bounded legacy parser above
            # is the only text-to-action compatibility path; all other malformed
            # output gets a truthful, non-retrying response.
            REPLY="I couldn't safely complete that request because the model returned an invalid tool request. I did not retry it. Please check Home Assistant history before retrying."
        else
            REPLY="I couldn't complete that request. I did not retry it. Please check Home Assistant history before retrying."
        fi
    fi
    [ -z "\$REPLY" ] && REPLY="I couldn't complete that request. I did not retry it. Please check Home Assistant history before retrying."
    # Telegram message limit is 4096 chars; truncate defensively.
    REPLY=\$(printf '%s' "\$REPLY" | cut -c1-4000)
    cache_reply "\$update_id" "\$chat_id" "\$from_id" "\$REPLY" || return 1
    send_msg "\$chat_id" "\$REPLY"
    if [ -n "\${CORRECTION_PROMPT:-}" ]; then
        # The foreground turn has released the per-chat lock before this hook.
        run_agent_turn "\$chat_id" "\$CORRECTION_PROMPT" \\
            >/dev/null 2>>/data/logs/telegram-broker.log || true
    fi
}

while true; do
    if [ "\$BOT_ID_READY" != true ]; then
        if ! load_bot_identity; then
            printf '%s\n' 'Telegram bot identity could not be verified; refusing to poll' >>/data/logs/telegram-broker.log
            sleep 5
            continue
        fi
    fi
    if ! bootstrap_offset; then
        printf '%s\n' 'Telegram cursor bootstrap failed; refusing to acknowledge queued updates' >>/data/logs/telegram-broker.log
        sleep 5
        continue
    fi
    OFFSET=\$(cat "\$OFFSET_F" 2>/dev/null || printf '%s' invalid)
    case "\$OFFSET" in
        ''|*[!0-9]*)
            printf '%s\n' 'Telegram cursor is invalid; refusing to poll' >>/data/logs/telegram-broker.log
            sleep 5
            continue
            ;;
    esac
    # Long-poll up to 25s for both message + callback_query updates.
    # We are the SOLE poller for this bot — ZC's telegram channel is disabled.
    if ! RESP=\$(telegram_curl getUpdates -s --max-time 30 --get \\
        --data-urlencode "offset=\$OFFSET" \\
        --data-urlencode "timeout=25" \\
        --data-urlencode 'allowed_updates=["message","callback_query"]' \\
        2>/dev/null); then
        printf '%s\n' 'Telegram polling transport failed; refusing to acknowledge queued updates' >>/data/logs/telegram-broker.log
        sleep 5
        continue
    fi
    if telegram_polling_conflict "\$RESP"; then
        printf '%s\n' 'Telegram polling conflict; refusing to run alongside another poller.' >>/data/logs/telegram-broker.log
        exit 42
    fi
    if ! printf '%s' "\$RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
        printf '%s\n' 'Telegram response was not a successful boolean result; refusing to acknowledge queued updates' >>/data/logs/telegram-broker.log
        sleep 5
        continue
    fi

    if ! printf '%s' "\$RESP" | jq -e '.result | type == "array"' >/dev/null 2>&1; then
        printf '%s\n' 'Telegram response had no valid result array; refusing to acknowledge it' >>/data/logs/telegram-broker.log
        sleep 5
        continue
    fi

    if ! mark_telegram_ready; then
        printf '%s\n' 'Telegram polling is valid but readiness could not be persisted; refusing to acknowledge the batch' >>/data/logs/telegram-broker.log
        sleep 5
        continue
    fi

    # Process the complete batch before committing its cursor.  If the
    # watcher dies while a handler is running, Telegram will redeliver the
    # batch. Root-owned response caches and approval claims make replay safe.
    BATCH_FILE=\$(mktemp /run/zeroclaw/.telegram-updates.XXXXXX) || {
        sleep 2
        continue
    }
    if ! printf '%s' "\$RESP" | jq -c '.result[]' >"\$BATCH_FILE" 2>/dev/null; then
        rm -f "\$BATCH_FILE"
        printf '%s\n' 'Telegram update batch could not be decoded; refusing to acknowledge it' >>/data/logs/telegram-broker.log
        sleep 5
        continue
    fi
    chmod 0600 "\$BATCH_FILE"
    BATCH_OK=true
    while IFS= read -r upd; do
        [ -n "\$upd" ] || continue
        UPDATE_ID=\$(printf '%s' "\$upd" | jq -r '.update_id // empty' 2>/dev/null)
        case "\$UPDATE_ID" in
            ''|*[!0-9]*)
                printf '%s\n' 'Telegram update had an invalid update_id; refusing to acknowledge batch' >>/data/logs/telegram-broker.log
                BATCH_OK=false
                break
                ;;
        esac
        # Branch on update kind. message and callback_query are mutually exclusive.
        MSG_TEXT=\$(printf '%s' "\$upd" | jq -r '.message.text // empty')
        if [ -n "\$MSG_TEXT" ]; then
            M_CHAT=\$(printf '%s' "\$upd" | jq -r '.message.chat.id // empty')
            M_FROM=\$(printf '%s' "\$upd" | jq -r '.message.from.id // empty')
            M_CHAT_TYPE=\$(printf '%s' "\$upd" | jq -r '.message.chat.type // empty')
            if ! handle_message "\$M_CHAT" "\$M_FROM" "\$M_CHAT_TYPE" "\$MSG_TEXT" "\$UPDATE_ID"; then
                printf '%s\n' "Telegram message update \$UPDATE_ID was not fully handled; cursor retained" >>/data/logs/telegram-broker.log
                BATCH_OK=false
                break
            fi
            continue
        fi

        CB_ID=\$(printf '%s' "\$upd" | jq -r '.callback_query.id // empty')
        [ -z "\$CB_ID" ] && continue

        DATA=\$(printf '%s' "\$upd" | jq -r '.callback_query.data // empty')
        FROM=\$(printf '%s' "\$upd" | jq -r '.callback_query.from.id // empty')
        FROM_NAME=\$(printf '%s' "\$upd" | jq -r '.callback_query.from.first_name // "user"')
        CHAT_ID=\$(printf '%s' "\$upd" | jq -r '.callback_query.message.chat.id // empty')
        CHAT_TYPE=\$(printf '%s' "\$upd" | jq -r '.callback_query.message.chat.type // empty')
        MSG_ID=\$(printf '%s' "\$upd" | jq -r '.callback_query.message.message_id // empty')

        if ! valid_positive_id "\$FROM" || ! valid_chat_id "\$CHAT_ID" || ! valid_positive_id "\$MSG_ID"; then
            printf '%s\n' "Telegram callback update \$UPDATE_ID had invalid actor or chat identifiers" >>/data/logs/telegram-broker.log
            answer_cb "\$CB_ID" "Invalid callback." || true
            continue
        fi
        if ! telegram_message_destination_allowed "\$CHAT_TYPE" "\$CHAT_ID" "\$FROM"; then
            answer_cb "\$CB_ID" "Private chat required." || true
            continue
        fi

        if ! is_allowed_user "\$FROM"; then
            answer_cb "\$CB_ID" "Not authorized." || true
            continue
        fi
        if [ "\$FROM" != "\$APPROVAL_USER" ] || [ "\$CHAT_ID" != "\$APPROVAL_CHAT" ]; then
            if ! answer_cb "\$CB_ID" "This approval belongs to the configured approval owner."; then BATCH_OK=false; break; fi
            continue
        fi
        if replay_callback_result "\$UPDATE_ID" "\$CB_ID" "\$CHAT_ID" "\$MSG_ID" "\$FROM"; then
            continue
        fi
        case "\$DATA" in
            zcv1:*) ;;
            *) if ! answer_cb "\$CB_ID" "Unknown chip."; then BATCH_OK=false; break; fi; continue ;;
        esac
        VERB=\$(printf '%s' "\$DATA" | cut -d: -f2)
        SHORT=\$(printf '%s' "\$DATA" | cut -d: -f3)
        if ! printf '%s' "\$SHORT" | grep -Eq '^[a-f0-9]{8}$'; then
            if ! answer_cb "\$CB_ID" "Invalid ticket."; then BATCH_OK=false; break; fi
            continue
        fi
        TICKET="/data/approval-receipts/tickets/\${SHORT}.json"

        if [ ! -f "\$TICKET" ] || [ -L "\$TICKET" ]; then
            if [ "\$VERB" = approve ] && replay_approval_outcome "\$SHORT" "\$CB_ID" "\$CHAT_ID" "\$MSG_ID" "\$FROM" ""; then
                continue
            fi
            if ! answer_cb "\$CB_ID" "Ticket expired or already actioned."; then BATCH_OK=false; break; fi
            if [ -n "\$MSG_ID" ] && ! edit_msg "\$CHAT_ID" "\$MSG_ID" "(this approval is no longer pending)"; then BATCH_OK=false; break; fi
            continue
        fi

        STORED_MSG_ID=\$(jq -r '.tg_message_id // empty' "\$TICKET" 2>/dev/null || true)
        if ! valid_positive_id "\$STORED_MSG_ID" || [ "\$STORED_MSG_ID" != "\$MSG_ID" ]; then
            if ! answer_cb "\$CB_ID" "This approval message is no longer valid."; then BATCH_OK=false; break; fi
            continue
        fi
        TICKET_GENERATION=\$(jq -r '.approval_generation // empty' "\$TICKET" 2>/dev/null || true)
        if ! valid_approval_generation "\$TICKET_GENERATION"; then
            if ! answer_cb "\$CB_ID" "This approval ticket is no longer valid."; then BATCH_OK=false; break; fi
            continue
        fi

        SUMMARY=\$(canonical_ticket_summary "\$TICKET") || { BATCH_OK=false; break; }
        CALLBACK_ANSWER=""
        CALLBACK_EDIT=""
        case "\$VERB" in
          approve)
              if replay_approval_outcome "\$SHORT" "\$CB_ID" "\$CHAT_ID" "\$MSG_ID" "\$FROM" "\$TICKET_GENERATION"; then
                  continue
              fi
              if ! ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition approve "\$SHORT" "\$FROM" "\$CHAT_ID" "\$TICKET_GENERATION" >/dev/null 2>&1; then
                  if ! answer_cb "\$CB_ID" "Ticket is already actioned or no longer valid."; then BATCH_OK=false; break; fi
                  continue
              fi
              if OUT=\$(apply_approved_ticket "\$SHORT" "\$FROM" "\$CHAT_ID"); then
                  if ! answer_cb "\$CB_ID" "Applied."; then BATCH_OK=false; break; fi
                  if ! edit_msg "\$CHAT_ID" "\$MSG_ID" "✅ Approved by \${FROM_NAME}: \${SUMMARY}
\${OUT}"
                  then BATCH_OK=false; break; fi
                   run_agent_turn "\$CHAT_ID" "ZCAUTO ticket \${SHORT} approved via chip — outcome: \${OUT}" \\
                       >/dev/null 2>>/data/logs/telegram-broker.log &
                   CALLBACK_ANSWER="Applied."
                   CALLBACK_EDIT="✅ Approved by \${FROM_NAME}: \${SUMMARY}
\${OUT}"
               else
                  # The capability broker durably records an applied outcome
                  # immediately before final ticket completion. If completion
                  # failed, prefer that truthful receipt over an unconfirmed message;
                  # the replay helper also retries idempotent cleanup
                  # without issuing a second HA service call.
                  if replay_approval_outcome "\$SHORT" "\$CB_ID" "\$CHAT_ID" "\$MSG_ID" "\$FROM" "\$TICKET_GENERATION"; then
                      continue
                  fi
                  if ! answer_cb "\$CB_ID" "Outcome unconfirmed; claim retained."; then BATCH_OK=false; break; fi
                  if ! edit_msg "\$CHAT_ID" "\$MSG_ID" "⚠️ Approved by \${FROM_NAME}, but the execution outcome could not be confirmed; claim retained for recovery. Check Home Assistant history before retrying.
\${OUT}"
                  then BATCH_OK=false; break; fi
                   run_agent_turn "\$CHAT_ID" "ZCAUTO ticket \${SHORT} approved via chip — outcome unconfirmed; claim retained: \${OUT}" \\
                       >/dev/null 2>>/data/logs/telegram-broker.log &
                   CALLBACK_ANSWER="Outcome unconfirmed; claim retained."
                   CALLBACK_EDIT="⚠️ Approved by \${FROM_NAME}, but the execution outcome could not be confirmed; claim retained for recovery. Check Home Assistant history before retrying.
\${OUT}"
               fi
              ;;
          reject)
              if ! ZEROCLAW_APPROVAL_INTERNAL=1 /usr/local/bin/zc-approval-transition reject "\$SHORT" "\$FROM" "\$CHAT_ID" "\$TICKET_GENERATION" >/dev/null 2>&1; then
                  if ! answer_cb "\$CB_ID" "Ticket is already actioned or no longer valid."; then BATCH_OK=false; break; fi
                  continue
              fi
              if ! answer_cb "\$CB_ID" "Rejected."; then BATCH_OK=false; break; fi
               if ! edit_msg "\$CHAT_ID" "\$MSG_ID" "❌ Rejected by \${FROM_NAME}: \${SUMMARY}"; then BATCH_OK=false; break; fi
               CALLBACK_ANSWER="Rejected."
               CALLBACK_EDIT="❌ Rejected by \${FROM_NAME}: \${SUMMARY}"
               ;;
          discuss)
              if ! answer_cb "\$CB_ID" "Tell me more."; then BATCH_OK=false; break; fi
               if ! send_msg "\$CHAT_ID" "About ticket \${SHORT} (\${SUMMARY}) — what would you like me to change or explain?"; then BATCH_OK=false; break; fi
               CALLBACK_ANSWER="Tell me more."
               ;;
          *)
               if ! answer_cb "\$CB_ID" "Unknown verb: \$VERB"; then BATCH_OK=false; break; fi
               CALLBACK_ANSWER="Unknown verb: \$VERB"
               ;;
        esac
        if [ -n "\$CALLBACK_ANSWER" ] && ! cache_callback_result "\$UPDATE_ID" "\$CHAT_ID" "\$MSG_ID" "\$FROM" "\$CALLBACK_ANSWER" "\$CALLBACK_EDIT"; then
            BATCH_OK=false
            break
        fi
    done <"\$BATCH_FILE"
    rm -f "\$BATCH_FILE"
    if [ "\$BATCH_OK" != "true" ]; then
        sleep 2
        continue
    fi
    NEW_OFFSET=\$(printf '%s' "\$RESP" | jq -r '.result | (max_by(.update_id).update_id // empty)' 2>/dev/null)
    case "\$NEW_OFFSET" in
        ''|null) ;;
        *[!0-9]*)
            printf '%s\\n' 'Telegram batch cursor was invalid; retaining the previous cursor' >>/data/logs/telegram-broker.log
            sleep 2
            continue
            ;;
        *)
            if ! commit_offset "\$((NEW_OFFSET + 1))"; then
                printf '%s\\n' "failed to commit Telegram update cursor: \$NEW_OFFSET" >>/data/logs/telegram-broker.log
                sleep 2
                continue
            fi
            ;;
    esac
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
#   1 + reason    on deny or a confirmed pre-execution failure
#   3 + reason    when execution may have occurred but durable outcome state
#                is incomplete; the approval claim must remain for recovery

set -e

[ "${ENABLE_WRITE_ACTIONS}" = "true" ] || { echo "Write actions are disabled by default; the broker and policy gates must be enabled explicitly."; exit 1; }
export ZEROCLAW_INTERNAL_ACTION=1

# Export policy environment so /usr/local/bin/policy-decide sees it.
POLICY_RUNTIME_FILE="${CONFIG_DIR}/policy-runtime.json"
[ -f "\$POLICY_RUNTIME_FILE" ] && [ ! -L "\$POLICY_RUNTIME_FILE" ] || {
    echo "ERROR: canonical policy runtime file is unavailable" >&2
    exit 1
}
POLICY_MODE=\$(jq -er '.policy_mode | select(type == "string")' "\$POLICY_RUNTIME_FILE") || exit 1
POLICY_QUIET_CONFIRM=\$(jq -er '.policy_quiet_confirm | select(type == "string")' "\$POLICY_RUNTIME_FILE") || exit 1
POLICY_BULK_THRESHOLD=\$(jq -er '.policy_bulk_threshold | select(type == "number" and floor == .) | tostring' "\$POLICY_RUNTIME_FILE") || exit 1
POLICY_CLIMATE_DELTA=\$(jq -er '.policy_climate_delta | select(type == "number" and floor == .) | tostring' "\$POLICY_RUNTIME_FILE") || exit 1
POLICY_REQUIRE_APPROVAL=\$(jq -er '.require_approval | select(type == "boolean")' "\$POLICY_RUNTIME_FILE") || exit 1
QUIET_HOURS=\$(jq -er '.quiet_hours | select(type == "string")' "\$POLICY_RUNTIME_FILE") || exit 1
EXTRA_DENY=\$(jq -er '.extra_deny | select(type == "string")' "\$POLICY_RUNTIME_FILE") || exit 1
EXTRA_CONFIRM=\$(jq -er '.extra_confirm | select(type == "string")' "\$POLICY_RUNTIME_FILE") || exit 1
EXTRA_ALLOW=\$(jq -er '.extra_allow | select(type == "string")' "\$POLICY_RUNTIME_FILE") || exit 1
export POLICY_MODE POLICY_QUIET_CONFIRM POLICY_BULK_THRESHOLD POLICY_CLIMATE_DELTA
export POLICY_REQUIRE_APPROVAL QUIET_HOURS EXTRA_DENY EXTRA_CONFIRM EXTRA_ALLOW

snapshot_undo_state() {
    undo_entity="\$1"
    UNDO_SNAPSHOT_COUNTER=\$((\${UNDO_SNAPSHOT_COUNTER:-0} + 1))
    undo_timestamp=\$(date -u +%s)
    undo_tmp=\$(mktemp "/data/undo/\${undo_timestamp}-\$\$-\${UNDO_SNAPSHOT_COUNTER}.XXXXXX") || return 1
    undo_file="\${undo_tmp}.json"
    [ ! -e "\$undo_file" ] && [ ! -L "\$undo_file" ] || {
        rm -f -- "\$undo_tmp"
        return 1
    }
    if ! /usr/local/bin/ha-capability get_state "\$undo_entity" > "\$undo_tmp"; then
        rm -f -- "\$undo_tmp"
        return 1
    fi
    jq -e --arg entity "\$undo_entity" \
        'type == "object" and .entity_id == \$entity' "\$undo_tmp" >/dev/null 2>&1 || {
        rm -f -- "\$undo_tmp"
        return 1
    }
    chmod 0600 "\$undo_tmp" || {
        rm -f -- "\$undo_tmp"
        return 1
    }
    if [ "\$(id -u)" -eq 0 ]; then
        chown zeroclaw:zeroclaw "\$undo_tmp" || {
            rm -f -- "\$undo_tmp"
            return 1
        }
    fi
    # Link into the final .json name without an overwrite window. The undo
    # directory is planner-writable, so a privileged mv -f would let an
    # untrusted process replace a pre-existing snapshot.
    ln "\$undo_tmp" "\$undo_file" || {
        rm -f -- "\$undo_tmp"
        return 1
    }
    rm -f -- "\$undo_tmp"
    sync || {
        rm -f -- "\$undo_file"
        return 1
    }
    printf '%s\n' "\$undo_file"
}

capture_undo_snapshots() {
    undo_body="\$1"
    undo_entities=\$(printf '%s' "\$undo_body" | jq -r '
        if (.entity_id? | type) == "string" then .entity_id
        elif (.entity_id? | type) == "array" then .entity_id[]
        else empty end
    ' 2>/dev/null) || return 1
    [ -n "\$undo_entities" ] || return 2
    undo_created_files=""
    while IFS= read -r undo_entity; do
        [ -n "\$undo_entity" ] || continue
        undo_file=\$(snapshot_undo_state "\$undo_entity") || {
            for undo_created_file in \$undo_created_files; do
                rm -f -- "\$undo_created_file"
            done
            return 1
        }
        undo_created_files="\$undo_created_files \$undo_file"
    done <<EOF
\$undo_entities
EOF
    [ -n "\$undo_created_files" ] || return 2
    return 0
}

# --- Apply-ticket short circuit ---
if [ "\$1" = "--apply-ticket" ]; then
    [ "\$(id -u)" -eq 0 ] || { echo "ERROR: ticket application is Telegram-adapter-only" >&2; exit 1; }
    UUID="\$2"
    TICKET="/data/approval-receipts/tickets/\${UUID}.json"
    [ ! -f "\$TICKET" ] && { echo "ERROR: ticket \${UUID} missing"; exit 1; }
    SVC=\$(jq -r .service "\$TICKET")
    BODY=\$(jq -c .payload "\$TICKET")
    if [ "${ENABLE_UNDO}" = "true" ]; then
        if capture_undo_snapshots "\$BODY"; then
            :
        else
            SNAPSHOT_STATUS=\$?
            if [ "\$SNAPSHOT_STATUS" -ne 2 ]; then
                /usr/local/bin/zc-audit-write undo_unavailable "\$SVC" "\$BODY" \
                    "ticket=\${UUID};before_execution" || true
                echo "ERROR: approved action was not executed because its undo snapshot could not be captured" >&2
                exit 1
            fi
        fi
    fi
    # The root broker verifies and consumes the sealed ticket transactionally.
    # Claim state is carried by root-owned state, never by an environment
    # variable that would stop at the local TCP boundary.
    STATUS=0
    OUT=\$(ZEROCLAW_APPROVAL_TICKET="\$UUID" /usr/local/bin/ha-action-raw "\$SVC" "\$BODY") || STATUS=\$?
    if [ "\$STATUS" -eq 0 ]; then
        :
    elif [ "\$STATUS" -eq 3 ]; then
        echo "ERROR: service execution occurred or may have occurred, but durable outcome state is incomplete; the claim remains for recovery. Check Home Assistant history before retrying." >&2
        exit 3
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
        if [ "${ENABLE_UNDO}" = "true" ]; then
            if capture_undo_snapshots "\$BODY"; then
                :
            else
                SNAPSHOT_STATUS=\$?
                if [ "\$SNAPSHOT_STATUS" -ne 2 ]; then
                    /usr/local/bin/zc-audit-write undo_unavailable "\$SERVICE" "\$BODY" \
                        "before_execution" || true
                    echo "ERROR: action was not executed because its undo snapshot could not be captured" >&2
                    exit 1
                fi
            fi
        fi
        if OUT=\$(/usr/local/bin/ha-action-raw "\$SERVICE" "\$BODY"); then
            echo "\$OUT"
            exit 0
        fi
        echo "ERROR: action failed before confirmation or its durable outcome state is incomplete; inspect Home Assistant history and broker/audit state" >&2
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
        # v3.1.2: send with inline-keyboard chips. The root broker renders the
        # exact generation-bound text form if an operator needs text fallback.
        MSG="⚠️ Approval needed (\${SHORT})
\${SUMMARY}
Tap a chip below — or use the exact YES/NO form shown in the root Telegram message.
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
if [ "$KIND" = "planner_event" ]; then
    # Planner-supplied telemetry is intentionally segregated from the
    # authoritative broker audit stream.  It is root-owned and not returned by
    # zc-audit-tail, so it cannot forge or pollute action evidence.
    AUDIT_DIR=/data/audit/planner
    AUDIT_OWNER=root:root
    AUDIT_MODE=0600
else
    AUDIT_DIR=/data/audit
    AUDIT_OWNER=root:zeroclaw
    AUDIT_MODE=0640
fi
ENTITY=$(echo "$BODY" | jq -r '.entity_id // ""' 2>/dev/null)
mkdir -p "$AUDIT_DIR"
ROW=$(jq -nc \
  --arg ts "$TS" --arg kind "$KIND" --arg svc "$SVC" \
  --arg entity "$ENTITY" --arg reason "$REASON" --argjson body "$BODY" \
  '{ts:$ts, kind:$kind, service:$svc, entity:$entity, body:$body, reason:$reason}')
LOCK="${AUDIT_DIR}/.lock"
ATTEMPTS=0
while ! mkdir "$LOCK" 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    [ "$ATTEMPTS" -lt 100 ] || { echo "audit store is busy" >&2; exit 1; }
    sleep 0.1
done
printf '%s\n' "$$" > "$LOCK/owner" || {
    rmdir "$LOCK" 2>/dev/null || true
    echo "audit lock owner could not be recorded" >&2
    exit 1
}
chmod 0600 "$LOCK/owner"
trap 'rm -f -- "$LOCK/owner" 2>/dev/null || true; rmdir "$LOCK" 2>/dev/null || true' EXIT
AUDIT_FILE="${AUDIT_DIR}/${DATE}.jsonl"
printf '%s\n' "$ROW" >> "$AUDIT_FILE"
chown "$AUDIT_OWNER" "$AUDIT_FILE"
chmod "$AUDIT_MODE" "$AUDIT_FILE"
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
# because zc-approve refuses anything that isn't an exact YES <id> <generation>.
# ==============================================================
cat > /usr/local/bin/zc-approve << 'SCRIPT'
#!/bin/sh
# Compatibility wrapper. Telegram watcher owns the real approval transition.
# Usage: ZEROCLAW_APPROVAL_INTERNAL=1 zc-approve "YES <id> <generation>" <actor> <chat>
[ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || { echo "ERROR: approvals are Telegram-adapter-only" >&2; exit 1; }
MSG="$1"
ACTOR="$2"
CHAT="$3"
REQUEST=$(printf '%s' "$MSG" | sed -nE 's/^[Yy][Ee][Ss][[:space:]]+([a-f0-9]{8})[[:space:]]+([a-f0-9]{32})[[:space:]]*$/\1 \2/p')
[ -n "$REQUEST" ] || { echo "ERROR: message is not 'YES <id> <generation>'"; exit 1; }
SHORT="${REQUEST%% *}"
GENERATION="${REQUEST#* }"
exec /usr/local/bin/zc-approval-transition approve "$SHORT" "$ACTOR" "$CHAT" "$GENERATION"
SCRIPT

cat > /usr/local/bin/zc-reject << 'SCRIPT'
#!/bin/sh
# Compatibility wrapper. Telegram watcher owns the real rejection transition.
[ "${ZEROCLAW_APPROVAL_INTERNAL:-}" = "1" ] || { echo "ERROR: approvals are Telegram-adapter-only" >&2; exit 1; }
MSG="$1"
ACTOR="$2"
CHAT="$3"
REQUEST=$(printf '%s' "$MSG" | sed -nE 's/^[Nn][Oo][[:space:]]+([a-f0-9]{8})[[:space:]]+([a-f0-9]{32})[[:space:]]*$/\1 \2/p')
[ -n "$REQUEST" ] || { echo "ERROR: message is not 'NO <id> <generation>'"; exit 1; }
SHORT="${REQUEST%% *}"
GENERATION="${REQUEST#* }"
exec /usr/local/bin/zc-approval-transition reject "$SHORT" "$ACTOR" "$CHAT" "$GENERATION"
SCRIPT

# ==============================================================
# v3.1.3 lessons loop — self-improvement primitives
# ==============================================================
# zc-set-outcome — agent records the one-line outcome of a completed action
# so the next user message can be classified as a correction (or not).
# Empty/missing file = no outcome to correct (greetings, status queries).
cat > /usr/local/bin/zc-set-outcome << SCRIPT
#!/bin/sh
# Usage: zc-set-outcome "<one-line outcome>"
LEARNING_ENABLED="${ENABLE_LEARNING}"
TEXT="\$1"
[ -z "\$TEXT" ] && exit 0
[ "\$LEARNING_ENABLED" = "true" ] || exit 0
exec /usr/local/bin/ha-capability set_outcome "\$TEXT" >/dev/null
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
# zc-schedule — intentionally disabled in the supervised release
# ==============================================================
cat > /usr/local/bin/zc-schedule << SCRIPT
#!/bin/sh
echo "Scheduling is disabled in the supervised release; create scheduled automations in Home Assistant." >&2
exit 1
SCRIPT

cat > /usr/local/bin/zc-schedule-once << SCRIPT
#!/bin/sh
echo "Scheduling is disabled in the supervised release; create scheduled automations in Home Assistant." >&2
exit 1
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
POLICY_RUNTIME_FILE="${CONFIG_DIR}/policy-runtime.json"
QUIET_HOURS=\$(jq -er '.quiet_hours | select(type == "string")' "\$POLICY_RUNTIME_FILE" 2>/dev/null) || {
    echo "(policy unavailable)"
    exit 1
}
HOME_LOCATION=\$(jq -er '.home_location | select(type == "string")' "\$POLICY_RUNTIME_FILE" 2>/dev/null) || {
    echo "(policy unavailable)"
    exit 1
}
QH_START=\$(echo "\$QUIET_HOURS" | cut -d- -f1 | cut -d: -f1 | sed 's/^0*//')
QH_END=\$(echo "\$QUIET_HOURS" | cut -d- -f2 | cut -d: -f1 | sed 's/^0*//')
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
Time: \${NOW} (\${DOW}) · Location: \${HOME_LOCATION}
Lights on: \${LIGHTS_ON}\${LIGHTS_LIST:+ (\${LIGHTS_LIST})}
ACs running: \${ACS_ON}\${ACS_DETAIL:+ — \${ACS_DETAIL}}
Last action: \${LAST_AUDIT:-(none today)}
Quiet hours (\${QUIET_HOURS}): \${QUIET}
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
install_generated_file() {
    generated_target="$1"
    generated_owner="$2"
    generated_mode="$3"
    generated_tmp="$4"
    generated_dir=$(dirname -- "$generated_target")
    [ -d "$generated_dir" ] && [ ! -L "$generated_dir" ] || {
        rm -f "$generated_tmp"
        bashio::log.fatal "generated-file directory is not a regular directory: ${generated_dir}"
        exit 1
    }
    if [ -e "$generated_target" ] || [ -L "$generated_target" ]; then
        [ -f "$generated_target" ] && [ ! -L "$generated_target" ] || {
            rm -f "$generated_tmp"
            bashio::log.fatal "generated-file target is not a regular file: ${generated_target}"
            exit 1
        }
    fi
    chown "$generated_owner" "$generated_tmp"
    chmod "$generated_mode" "$generated_tmp"
    mv -f "$generated_tmp" "$generated_target" || {
        rm -f "$generated_tmp"
        bashio::log.fatal "could not install generated file: ${generated_target}"
        exit 1
    }
}

write_generated_file() {
    generated_target="$1"
    generated_owner="$2"
    generated_mode="$3"
    generated_tmp=$(mktemp /run/zeroclaw/.generated.XXXXXX) || {
        bashio::log.fatal "could not stage generated file: ${generated_target}"
        exit 1
    }
    if ! cat > "$generated_tmp"; then
        rm -f "$generated_tmp"
        bashio::log.fatal "could not render generated file: ${generated_target}"
        exit 1
    fi
    install_generated_file "$generated_target" "$generated_owner" "$generated_mode" "$generated_tmp"
}

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
write_generated_file "${CONFIG_DIR}/config.toml" root:zeroclaw 0640 << TOMLEOF
schema_version = 2

[providers]
fallback = "${PROVIDER_NAME}"

[providers.models."${PROVIDER_NAME}"]
base_url = "${PROVIDER_BASE_URL}"
api_path = "/chat/completions"
model = "${DEFAULT_MODEL}"
temperature = 0.2
timeout_secs = 80
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
message_timeout_secs = 150
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
allowed_commands = ["ha-lights-on", "ha-ac-status", "ha-cover-status", "ha-sensors", "ha-state", "ha-all-status", "ha-logbook", "ha-errors", "ha-action-guarded", "ha-create-scene", "ha-create-automation", "ha-create-routine", "ha-run-routine", "ha-apply-creation", "zc-audit-tail", "zc-undo", "zc-cost", "zc-world-state", "zc-set-outcome", "zc-lesson-add"]
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
# The root provider broker owns classified cross-profile fallback and durable
# accounting. Keep the planner single-shot so it cannot retry a failed
# credential outside that policy boundary.
provider_retries = 0
provider_backoff_ms = 0

[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 300
TOMLEOF

# ==============================================================
# SOUL.md — behavior, policy literacy, world-state respect
# ==============================================================
SOUL_TMP=$(mktemp /run/zeroclaw/.generated.XXXXXX) || {
    bashio::log.fatal "could not stage SOUL.md"
    exit 1
}
cat > "$SOUL_TMP" << SOULEOF
Role: Home automation executor for ${HOME_LOCATION}.
Languages: ${HOME_LANGUAGES} — match the user's language exactly.
Output: 1-2 lines max. No preamble. No "Done." No "Sure!" / "I'll" / "Let me".

## Tool invocation protocol (gateway/channel safety)
When a Home Assistant or ZeroClaw command helper is needed, use the runtime's
structured shell tool exactly. Command helpers are valid only inside that tool;
they are never a user-facing response syntax. Only call a name directly when
it is present in the runtime's actual tool list.
Never write a tool call as Markdown, a bare shell command, or prose. If the
native shell tool is unavailable, do not print command syntax or a Markdown/XML
tool block. Explain briefly that tool execution is unavailable; never imply
that an action ran.
Do not add approved:true; the HA policy gate owns action approval. The command must be
inside the shell tool's JSON arguments so the gateway can execute it and
continue the tool loop.
After the tool result, continue until you can give the user a short final
answer. Never show internal tool results or shell syntax to the user.

## World state
A WORLD STATE block may appear in your prompt. Trust it. Don't re-fetch what's already there
(time, lights on, ACs running, quiet hours, pending approvals). To refresh manually: zc-world-state.

## Greetings
"hi" / "hello" / "hey" / "مرحبا" → reply exactly: "Hi." then stop.

## Step 1 — Resolve entity
Unknown name? Call memory_recall("<name>") first. Entity mappings are pre-loaded.
Still unknown? Reply: "I don't know '<name>'. What's the entity ID?"

## Step 2 — Status queries
Use the shell tool with the documented command:
ha-lights-on · ha-ac-status · ha-cover-status · ha-sensors · ha-all-status
ha-state <entity_id> · ha-logbook [entity_id] · ha-errors

## Step 3 — Actions go through ha-action-guarded (the policy gate)
You CANNOT call ha-action-raw directly. Every action goes through ha-action-guarded.
The gate returns one of three things:

  exit 0 → executed. Write the outcome line. e.g. "Study AC → 24°C."
  exit 2 → CONFIRM_PENDING ticket=<id8>. Tell the user that approval is pending
           and they must use the exact YES/NO form shown in the root Telegram message.
  exit 1 → DENIED. Show the user the policy reason. Don't retry.

When the user replies using the exact generation-bound YES/NO form shown in the
root-owned Telegram message, the adapter validates the actor/chat binding and
applies the transition. Never ask the model to manufacture an approval or call
an approval bridge. After a successful approval, the adapter applies the ticket
and reports the outcome.

## AC actions — pre-check first
Before set_temperature / set_hvac_mode, use the shell tool with ha-state. If state already matches request,
skip the action and write: "Study AC is already at 24°C." Save tool calls.

## Decision tree for ambiguous requests
"turn off the lights" with no scope:
  • If exactly one light is on → act, write specific outcome.
  • If multiple → ask: "Which? all / specific room / a specific light?"
"make it cooler / warmer" → use the shell tool with ha-state first, propose ±2°C delta, then apply.

## Outcome lines (positive examples)
Lights:    "Example light on."         "Example group off."    "All lights off."
AC:        "Example AC → 24°C."        "Example AC off."       "Example AC → cool mode."
Covers:    "Example curtains opened."   "Example cover closed."
Sensors:   "Soil moisture: 42% (low)."
Schedule:  "Use a Home Assistant automation for scheduled reminders."
Errors:    "Failed: <exact error from tool>"

## Scheduling
Self-scheduling is disabled in this supervised release. For a reminder or
recurring action, explain that it must be created as a Home Assistant
automation and do not claim that ZeroClaw created one.

## Audit + undo
zc-audit-tail [N]   — recent actions
zc-undo [N]         — revert last N actions within 1 hour
"undo that" / "revert" → call zc-undo 1, write what was reverted.

## Cost awareness
zc-cost — return current cost. If asked about spend, call this; never guess.

## Tool-call budget
You have ≤ ${MAX_TOOL_ITER} tool calls per turn. Budget them. Memory-first lookup before
ha-all-status or any broad query. Never call http_request GET /api/states (532KB).

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
"already at" no-op), use the native shell tool exactly once with
zc-set-outcome '<same one-line outcome>'.
The shell helper underneath is /usr/local/bin/zc-set-outcome; it records a
root-owned broker receipt under /data/capability. Never emit zc.set_outcome or
zc-set-outcome as plain text.

Do not write either command in the user-facing assistant message. If the
native shell tool is not available, do not emit a textual substitute.

If you skip the zc-set-outcome shell command the lessons loop cannot fire on the user's next reply
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
cat >> "$SOUL_TMP" << 'SOULEXT'

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
install_generated_file "${WS}/SOUL.md" zeroclaw:zeroclaw 0600 "$SOUL_TMP"

# v3.1: CREATION.md skill doc (only when enabled — keeps prompt small otherwise)
if [ "${ENABLE_CREATION}" = "true" ]; then
write_generated_file "${WS}/CREATION.md" zeroclaw:zeroclaw 0600 << 'CREATEEOF'
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

The user may add this rest_command to /config/configuration.yaml ONCE for a
simple, non-tool wake-up. Telegram turns use the full agent path below; this
compatibility webhook does not execute Home Assistant actions:
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
if [ -e "${WS}/LESSONS.md" ] || [ -L "${WS}/LESSONS.md" ]; then
    [ -f "${WS}/LESSONS.md" ] && [ ! -L "${WS}/LESSONS.md" ] || {
        bashio::log.fatal "LESSONS.md is not a regular file"
        exit 1
    }
else
    write_generated_file "${WS}/LESSONS.md" zeroclaw:zeroclaw 0600 << 'LESSEOF'
# Lessons Learned (auto-prepended to every prompt)
# This file grows over time as the user corrects mistakes.
# Format: one short rule per line. Pinned lessons start with [PIN].
LESSEOF
fi

# ==============================================================
# TOOLS.md
# ==============================================================
write_generated_file "${WS}/TOOLS.md" zeroclaw:zeroclaw 0600 << 'TOOLSEOF'
## Home Assistant command reference

The entries below are command aliases, not function-call names. Invoke every
command through the runtime's native `shell` tool. Never emit a bare `ha.*`,
`ha-*`, or `zc-*` line, Markdown/XML tool syntax, or an internal command in a
user-facing assistant turn. If the native shell tool is unavailable, say that
the action could not be executed and stop.

STATUS:
- ha-all-status     — lights + AC + covers (use for "home overview")
- ha-lights-on      — which lights are ON
- ha-ac-status      — all ACs: mode, set, current
- ha-cover-status   — all curtains
- ha-sensors        — soil/temperature sensors
- ha-state          — one entity by ID (pass entity_id)
- ha-logbook        — recent events (optionally entity_id)
- ha-errors         — bounded HA error-log availability check; details stay in HA UI

ACTIONS (all routed through the policy gate):
- command: ha-action-guarded <service_path> '<json_body>'
    e.g. ha-action-guarded 'light/turn_on' '{"entity_id":"light.example"}'
    e.g. ha-action-guarded 'climate/set_temperature' '{"entity_id":"climate.example","temperature":22}'
- command: ha-action-guarded --apply-ticket <id8>   — adapter-only approved-ticket path

ZC. (ZeroClaw self-commands; invoke through shell):
- scheduling is disabled; direct the user to a Home Assistant automation
- zc-audit-tail [N]                              — recent actions
- zc-undo [N]                                    — revert last N actions (1h window)
- zc-cost                                        — current spend
- zc-world-state                                 — refresh world state

WARNING: never call http_request GET /api/states — payload too large.
TOOLSEOF

# ==============================================================
# USER.md (parameterized from add-on config)
# ==============================================================
write_generated_file "${WS}/USER.md" zeroclaw:zeroclaw 0600 << USEREOF
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
SKILL_TMP=$(mktemp /run/zeroclaw/.generated.XXXXXX) || {
    bashio::log.fatal "could not stage HA SKILL.md"
    exit 1
}
cat > "$SKILL_TMP" << 'SKILLEOF'
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

## Command catalog — use the runtime shell tool

The entries below are command aliases, not callable tool names and not text to
send to the user. Invoke them only inside the structured shell tool.

- ha-all-status — full home overview.
- ha-lights-on — list lights that are currently on.
- ha-ac-status — current climate state.
- ha-cover-status — current covers/curtains.
- ha-sensors — soil and temperature sensors.
- ha-state <entity_id> — state of one entity.
- ha-action-guarded '<service_path>' '<json_body>' — policy-gated action.
- ha-logbook [entity_id] — recent activity.
- ha-errors — bounded Home Assistant error-log availability check; use HA UI for details.
- Scheduling is disabled; direct the user to a Home Assistant automation.
- zc-audit-tail [N] — recent audit rows.
- zc-undo [N] — revert recent actions.
- zc-cost — current cost telemetry.
- zc-world-state — compact current-home header.
- zc-set-outcome '<outcome>' — record a real action outcome exactly once.
- zc-lesson-add '<lesson>' — reserved for the correction hook.
SKILLEOF

# v3.1: append creation tools to the ha skill only when the feature is on
if [ "${ENABLE_CREATION}" = "true" ]; then
cat >> "$SKILL_TMP" << 'CRSKILLEOF'

- ha-create-scene <scene_id> '<friendly name>' '<json entity_states>' —
  draft a scene and return a confirmation ticket.
- ha-create-automation <alias> '<yaml>' — draft an automation and return a
  confirmation ticket.
- ha-create-routine <name> '<json steps>' — save an agent-side macro.
- ha-run-routine <name> — run a saved routine through the policy gate.
- ha-apply-creation <id8> — apply an approved creation ticket.
CRSKILLEOF
fi
install_generated_file "${WS}/skills/ha/SKILL.md" zeroclaw:zeroclaw 0600 "$SKILL_TMP"

# ==============================================================
# MEMORY_SNAPSHOT.md — privacy-preserving runtime note
# ==============================================================
write_generated_file "${WS}/MEMORY_SNAPSHOT.md" zeroclaw:zeroclaw 0600 << 'MEMEOF'
# Entity IDs, room names, device topology, and personal preferences are not
# shipped in the image. They are resolved from the live Home Assistant instance
# through typed read capabilities and may be persisted only after an explicit
# user-directed learning action.

Use current entity metadata and friendly names. Treat stale aliases as hints,
never as authorization to act.
MEMEOF

bashio::log.info "Config ready | mode=${POLICY_MODE} | ${DEFAULT_MODEL} + ${COMPLEX_MODEL}"

# Root helper loops do not need credentials.  Scrub them before each loop is
# forked so the typed capability brokers are the only long-lived processes
# retaining Supervisor, Telegram, or provider credentials.
scrub_unrelated_child_credentials() {
    unset SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \
        OPENROUTER_KEY NVIDIA_KEY ARK_KEY LEGACY_HA_TOKEN \
        ZEROCLAW_PROVIDER_UPSTREAM_URL ZEROCLAW_API_KEY ZEROCLAW_LEGACY_ACTION_GATE \
        PROVIDER_CLIENT_AUTH_TOKEN PROVIDER_HEALTH_CLIENT_AUTH_TOKEN CAPABILITY_CLIENT_AUTH_TOKEN CAPABILITY_HEALTH_CLIENT_AUTH_TOKEN \
        TELEGRAM_CLIENT_AUTH_TOKEN TELEGRAM_SYSTEM_AUTH_TOKEN HEALTH_CLIENT_AUTH_TOKEN
}

# ==============================================================
# Audit/undo retention cleanup (one-shot at startup).  Approval state has a
# separate root-only cleaner because canonical tickets are not planner state.
# ==============================================================
find /data/audit -name '*.jsonl' -mtime +"${AUDIT_RETENTION_DAYS}" -delete 2>/dev/null || true
find /data/undo  -name '*.json'  -mmin  +60                       -delete 2>/dev/null || true
/opt/zeroclaw/lib/state-cleanup.sh /data || \
    bashio::log.warning "root approval-state cleanup did not complete; retaining state for recovery"

# Continue expiring sealed tickets and stale claims while the app is running.
# This loop is root-owned and has no planner credentials.
(
    scrub_unrelated_child_credentials
    while true; do
        sleep 300
        /opt/zeroclaw/lib/state-cleanup.sh /data || \
            bashio::log.warning "root approval-state cleanup tick failed; retaining state for recovery"
    done
) &

# Scheduling is deliberately delegated to Home Assistant automations.  There
# is no hidden planner or gateway REST scheduler in this release.

# ==============================================================
# Telegram callback-query watcher (v3.1.2) — handles inline-keyboard
# chip taps for approval tickets. Auto-restarts on crash.
# ==============================================================
if [ "${TELEGRAM_ENABLED}" = "true" ]; then
    (
        scrub_unrelated_child_credentials
        while true; do
            # Track the actual polling process, not this restart supervisor.
            # Health must go not-ready when the watcher dies or is replaced.
            /usr/local/bin/tg-callback-watcher >>/data/logs/telegram-broker.log 2>&1 &
            watcher_child_pid=$!
            if ! printf '%s\n' "${watcher_child_pid}" > "${TELEGRAM_WATCHER_PID_FILE}" ||
                ! chown root:root "${TELEGRAM_WATCHER_PID_FILE}" ||
                ! chmod 0600 "${TELEGRAM_WATCHER_PID_FILE}"; then
                kill "${watcher_child_pid}" 2>/dev/null || true
                wait "${watcher_child_pid}" 2>/dev/null || true
                rm -f -- "${TELEGRAM_WATCHER_PID_FILE}"
                bashio::log.fatal "could not publish Telegram watcher liveness"
                exit 1
            fi
            watcher_status=0
            wait "${watcher_child_pid}" || watcher_status=$?
            rm -f -- "${TELEGRAM_WATCHER_PID_FILE}"
            if [ "$watcher_status" -eq 42 ]; then
                printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) Telegram polling conflict" > "${TELEGRAM_CONFLICT_FILE}"
                printf '%s\n' "${TELEGRAM_TOKEN_HASH}" > "${TELEGRAM_CONFLICT_TOKEN_FILE}"
                chown root:root "${TELEGRAM_CONFLICT_FILE}" "${TELEGRAM_CONFLICT_TOKEN_FILE}"
                chmod 0600 "${TELEGRAM_CONFLICT_FILE}" "${TELEGRAM_CONFLICT_TOKEN_FILE}"
                bashio::log.fatal "Telegram polling conflict; watcher is latched and will not restart"
                exit 1
            fi
            bashio::log.warning "tg-callback-watcher exited (status ${watcher_status}); restarting in 5s"
            sleep 5
        done
    ) &
fi

# The planner-facing cost endpoint is intentionally not authoritative.  The
# root watchdog reads the root-owned provider ledger that the broker reconciles
# under its own lock, so a planner cannot suppress or inflate the degradation
# decision through the loopback API.
root_provider_cost_micros() {
    [ -f /data/provider/quota.json ] && [ ! -L /data/provider/quota.json ] || return 1
    root_cost_now=$(date -u +%s)
    root_cost_day=$((root_cost_now / 86400))
    jq -er --argjson day "$root_cost_day" '
        select(
            .schema == 1 and
            (.records | type == "array") and
            all(.records[];
                (.day_window | type == "number" and floor == . and . >= 0) and
                ((.settled_cost_micros // .reserved_cost_micros // 0) |
                    type == "number" and floor == . and . >= 0)
            )
        ) |
        [ .records[] | select(.day_window == $day) |
            (.settled_cost_micros // .reserved_cost_micros // 0) ] |
        add // 0 |
        select(type == "number" and floor == . and . >= 0) |
        tostring
    ' /data/provider/quota.json
}

# ==============================================================
# Cost watchdog: every 5 min, root-accounted spend disables paid routes >80%
# ==============================================================
(
    scrub_unrelated_child_credentials
    while true; do
        sleep 300
        TODAY_COST_MICROS=$(root_provider_cost_micros 2>/dev/null || true)
        case "$TODAY_COST_MICROS" in
            ''|*[!0-9]*)
                bashio::log.warning "Cost watchdog could not read the root provider ledger; retaining the current route-degradation state"
                continue
                ;;
        esac
        WARNING_COST_MICROS=$((DAILY_COST_LIMIT_MICROS * 80 / 100))
        if [ "$TODAY_COST_MICROS" -gt "$WARNING_COST_MICROS" ]; then
            cost_degraded_new=0
            if [ ! -e /run/zeroclaw/cost-degraded ] && [ ! -L /run/zeroclaw/cost-degraded ]; then
                cost_degraded_tmp=$(mktemp /run/zeroclaw/.cost-degraded.XXXXXX 2>/dev/null || true)
                if [ -n "$cost_degraded_tmp" ]; then
                    chmod 0600 "$cost_degraded_tmp"
                    mv -f "$cost_degraded_tmp" /run/zeroclaw/cost-degraded
                    cost_degraded_new=1
                fi
            fi
            if [ "$cost_degraded_new" -eq 1 ] && [ "${TELEGRAM_ENABLED}" = "true" ]; then
                TODAY=$(awk -v micros="$TODAY_COST_MICROS" 'BEGIN { printf "%.6f", micros / 1000000 }')
                LIMIT="${DAILY_COST_LIMIT}"
                /usr/local/bin/tg-system-notify \
                    "⚠️ Cost watchdog: today's root-accounted spend \$${TODAY} > 80% of \$${LIMIT}. Paid routes are disabled; an explicit free fallback may serve read-only turns." >/dev/null 2>&1 || true
            fi
        elif [ -e /run/zeroclaw/cost-degraded ] || [ -L /run/zeroclaw/cost-degraded ]; then
            rm -f -- /run/zeroclaw/cost-degraded 2>/dev/null || true
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
unset OPENROUTER_KEY LEGACY_HA_TOKEN HA_TOKEN TELEGRAM_TOKEN SUPERVISOR_TOKEN HOMEASSISTANT_TOKEN HASSIO_TOKEN ZEROCLAW_PROVIDER_UPSTREAM_URL ZEROCLAW_LEGACY_ACTION_GATE NVIDIA_KEY ARK_KEY \
    PROVIDER_CLIENT_AUTH_TOKEN PROVIDER_HEALTH_CLIENT_AUTH_TOKEN CAPABILITY_CLIENT_AUTH_TOKEN CAPABILITY_HEALTH_CLIENT_AUTH_TOKEN \
    TELEGRAM_CLIENT_AUTH_TOKEN TELEGRAM_SYSTEM_AUTH_TOKEN HEALTH_CLIENT_AUTH_TOKEN
# Keep the persistent mount point root-owned and sticky.  ZeroClaw needs to
# create a small amount of runtime metadata directly under its config dir, so
# the group may create entries; the sticky bit prevents the planner from
# unlinking or replacing any root-owned audit/approval/migration/config entry.
# These explicitly listed trees have root-owned, sticky top-level mount points
# and planner-owned contents; the broker state remains outside the write
# boundary. Keeping the top-level directory root-owned prevents a planner from
# replacing a path component while privileged migration/restore code runs.
chown root:zeroclaw /data
chmod 1770 /data
# Undo snapshots are caller-owned, untrusted input. The broker re-evaluates
# every restore service and records the real HA outcome; keeping the contents
# planner-writable makes the advertised undo tool functional without granting
# the planner access to trusted audit or approval state.
for planner_tree in "${WS}" "${WS}/sessions" /data/pending /data/routines /data/tools /data/undo; do
    mkdir -p "$planner_tree"
    find "$planner_tree" -type d -exec chown zeroclaw:zeroclaw {} \; 2>/dev/null || true
    find "$planner_tree" -type d -exec chmod 0700 {} \; 2>/dev/null || true
    find "$planner_tree" -type f -exec chown zeroclaw:zeroclaw {} \; 2>/dev/null || true
    find "$planner_tree" -type f -exec chmod 0600 {} \; 2>/dev/null || true
    chown root:zeroclaw "$planner_tree"
    chmod 1770 "$planner_tree"
done
# Pending approval drafts are planner-owned and untrusted. Keep their bounded
# retention cleanup in the same unprivileged account so a planner-controlled
# directory replacement can never redirect a root delete outside that tree.
(
    scrub_unrelated_child_credentials
    exec su-exec zeroclaw:zeroclaw /bin/sh -c '
        while true; do
            sleep 300
            if [ -d /data/pending ] && [ ! -L /data/pending ]; then
                find /data/pending -maxdepth 1 -type f -name "*.json" -mmin +60 -delete 2>/dev/null || true
            fi
        done
    '
) &
# Older releases stored correction state in planner-writable /data. Remove
# only that exact legacy path; current correction state is root-owned broker
# state under /data/capability and is never read from a planner-owned path.
rm -f /data/.last_outcome
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
if [ "${ENABLE_LEARNING}" != "true" ]; then
    rm -f /data/capability/last-outcome.json
fi
find /data/capability -type l -exec rm -f {} \; 2>/dev/null || true
chown -R root:root /data/capability
chmod 0700 /data/capability
find /data/capability -type f -exec chmod 0600 {} \; 2>/dev/null || true
mkdir -p /data/approved /data/approval-receipts /data/approval-receipts/tickets /data/approval-receipts/outcomes /data/approval-receipts/ticket-nonces
chown root:root /data/approved /data/approval-receipts
chmod 0700 /data/approved /data/approval-receipts
chown -R root:root /data/approval-receipts
chmod 0700 /data/approval-receipts/tickets
chown root:root /data/approval-receipts/outcomes
chmod 0700 /data/approval-receipts/outcomes
chown root:root /data/approval-receipts/ticket-nonces
chmod 0700 /data/approval-receipts/ticket-nonces
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
mkdir -p /data/audit/planner
chown root:root /data/audit/planner
chmod 0700 /data/audit/planner
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
# data.  Correction state is broker-owned under /data/capability.
find /data -maxdepth 1 -type f \
    ! -name options.json ! -name config.toml ! -name .state-version ! -name .state-schema \
    -exec chown root:zeroclaw {} \; -exec chmod 0640 {} \; 2>/dev/null || true
if [ -f /data/.state-schema ]; then
    chown root:root /data/.state-schema
    chmod 0600 /data/.state-schema
fi
if [ -f /data/.state-version ]; then
    chown root:root /data/.state-version
    chmod 0600 /data/.state-version
fi

CRASH_COUNT=0
while true; do
    env -u HA_TOKEN -u SUPERVISOR_TOKEN -u TELEGRAM_BOT_TOKEN \
        -u OPENROUTER_KEY -u TELEGRAM_TOKEN -u LEGACY_HA_TOKEN -u ZEROCLAW_LEGACY_ACTION_GATE \
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
