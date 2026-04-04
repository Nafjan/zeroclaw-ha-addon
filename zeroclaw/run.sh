#!/usr/bin/with-contenv bashio

# ============================================================
# ZeroClaw HAOS Add-on Startup Script
# Reads secrets from HAOS encrypted options → env vars
# ============================================================

bashio::log.info "Starting ZeroClaw Agent v0.1.0..."

# --- Read credentials from HAOS add-on config (encrypted) ---
export ZEROCLAW_OPENROUTER_KEY="$(bashio::config 'openrouter_api_key')"
export ZEROCLAW_HA_TOKEN="$(bashio::config 'ha_token')"
export ZEROCLAW_TELEGRAM_TOKEN="$(bashio::config 'telegram_bot_token')"

# --- Read non-secret config ---
MQTT_HOST="$(bashio::config 'mqtt_host')"
MQTT_PORT="$(bashio::config 'mqtt_port')"
DEFAULT_MODEL="$(bashio::config 'default_model')"
COMPLEX_MODEL="$(bashio::config 'complex_model')"
LOG_LEVEL="$(bashio::config 'log_level')"

export ZEROCLAW_MQTT_HOST="${MQTT_HOST}"
export ZEROCLAW_MQTT_PORT="${MQTT_PORT}"
export ZEROCLAW_DEFAULT_MODEL="${DEFAULT_MODEL}"
export ZEROCLAW_COMPLEX_MODEL="${COMPLEX_MODEL}"
export RUST_LOG="${LOG_LEVEL}"

# --- Read Telegram allowed users (comma-separated string) ---
export ZEROCLAW_TELEGRAM_ALLOWED_USERS="$(bashio::config 'telegram_allowed_users')"

# --- Validate required credentials ---
if [ -z "${ZEROCLAW_OPENROUTER_KEY}" ]; then
    bashio::log.fatal "OpenRouter API key not configured!"
    exit 1
fi

if [ -z "${ZEROCLAW_HA_TOKEN}" ]; then
    bashio::log.fatal "Home Assistant token not configured!"
    exit 1
fi

if [ -z "${ZEROCLAW_TELEGRAM_TOKEN}" ]; then
    bashio::log.fatal "Telegram bot token not configured!"
    exit 1
fi

bashio::log.info "Credentials loaded from HAOS encrypted options"
bashio::log.info "MQTT broker: ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Default model: ${DEFAULT_MODEL}"
bashio::log.info "Complex model: ${COMPLEX_MODEL}"
bashio::log.info "Log level: ${LOG_LEVEL}"

# --- Start ZeroClaw ---
exec zeroclaw start --config /data/config.toml
