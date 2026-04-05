#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS Add-on v1.1.0

ADDON_VERSION="1.1.0"
bashio::log.info "ZeroClaw v${ADDON_VERSION} starting..."

# --- Credentials ---
OPENROUTER_KEY="$(bashio::config 'openrouter_api_key')"
HA_TOKEN="$(bashio::config 'ha_token')"
TELEGRAM_TOKEN="$(bashio::config 'telegram_bot_token')"
TELEGRAM_USERS="$(bashio::config 'telegram_allowed_users')"
DEFAULT_MODEL="$(bashio::config 'default_model')"
COMPLEX_MODEL="$(bashio::config 'complex_model')"
LOG_LEVEL="$(bashio::config 'log_level')"

export ZEROCLAW_API_KEY="${OPENROUTER_KEY}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_TOKEN}"
export HA_TOKEN="${HA_TOKEN}"
export RUST_LOG="${LOG_LEVEL}"

for var in OPENROUTER_KEY TELEGRAM_TOKEN HA_TOKEN; do
    eval val=\$$var
    [ -z "$val" ] && { bashio::log.fatal "${var} not set!"; exit 1; }
done

CONFIG_DIR="/data"
mkdir -p "${CONFIG_DIR}/workspace/skills/home-assistant"

# ==============================================================
# config.toml
# ==============================================================
cat > "${CONFIG_DIR}/config.toml" << TOMLEOF
default_provider = "openrouter"
default_model = "${DEFAULT_MODEL}"
default_temperature = 0.3
provider_timeout_secs = 20

[model_providers.openrouter]
name = "openai"
base_url = "https://openrouter.ai/api/v1"
api_path = "/chat/completions"
wire_api = "chat_completions"

[[model_routes]]
hint = "fast"
provider = "openrouter"
model = "${DEFAULT_MODEL}"

[[model_routes]]
hint = "reasoning"
provider = "openrouter"
model = "${COMPLEX_MODEL}"

[channels_config]
message_timeout_secs = 60
ack_reactions = true
session_persistence = true
session_backend = "sqlite"
debounce_ms = 300

[channels_config.telegram]
bot_token = "${TELEGRAM_TOKEN}"
allowed_users = ["${TELEGRAM_USERS}"]
stream_mode = "partial"
draft_update_interval_ms = 1500
interrupt_on_new_message = true
mention_only = false

[gateway]
port = 42617
host = "0.0.0.0"
require_pairing = false
session_persistence = true

[agent]
compact_context = true
max_tool_iterations = 6
max_history_messages = 20
max_context_tokens = 12000

[autonomy]
level = "full"
workspace_only = true
max_actions_per_hour = 100

[memory]
backend = "sqlite"
auto_save = true
hygiene_enabled = true
search_mode = "bm25"
response_cache_enabled = true
response_cache_ttl_minutes = 2
snapshot_enabled = true
auto_hydrate = true

[http_request]
enabled = true
allowed_domains = ["*"]
max_response_size = 200000
timeout_secs = 10
allow_private_hosts = true

[cost]
enabled = true
daily_limit_usd = 5.0
monthly_limit_usd = 20.0
warn_at_percent = 80

[cost.enforcement]
mode = "route_down"
route_down_model = "openai/gpt-5-nano"
reserve_percent = 10

[reliability]
provider_retries = 2
provider_backoff_ms = 300
fallback_providers = ["google"]

[reliability.model_fallbacks]
"${DEFAULT_MODEL}" = ["google/gemini-2.5-flash"]
"${COMPLEX_MODEL}" = ["openai/gpt-4.1-mini"]

[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 300
TOMLEOF

# ==============================================================
# MEMORY_SNAPSHOT.md — entity mappings + home context
# ==============================================================
cat > "${CONFIG_DIR}/workspace/MEMORY_SNAPSHOT.md" << 'MEMEOF'
# Entity ID Reference

## Lights
study ceiling lamps: light.study_ceiling_lamps
study spotlights left: light.study_spotlights_left
study spotlights right: light.study_spotlights_right
living room: light.living_room
bedroom: light.bedroom
left bedside: light.left_bedside
right bedside: light.right_bedside
garden lights: light.garden_lights
nursery ceiling lamp: light.nursery_ceiling_lamp
master bathroom left: light.master_bathroom_light_left
master bathroom right: light.master_bathroom_light_right
floor lamp: light.bedroom_repeater_lamp_switch
olive tree lights: light.olive_tree_lights
stairs night light: light.downstairs_switch_2_left
upstairs light: light.downstairs_switch_right
under stairs: light.downstairs_switch_left
monitor lights: light.monitor_lights
tv lights: light.tv_lights
all lights: light.all_lights

## ACs
study AC: climate.room_air_conditioner
master bedroom AC: climate.gr_acunit_6400_02_608d
living room AC: climate.gr_acunit_6400_02_10b6
majlis AC: climate.gr_acunit_6400_02_7a25
hall AC: climate.hall_ac
entrance hall AC: climate.entrance_hall_ac
food area AC: climate.food_area_ac
nursery AC: climate.nursery

## Other
weather: weather.pirateweather
MEMEOF

# ==============================================================
# SOUL.md — system prompt with few-shot examples
# ==============================================================
cat > "${CONFIG_DIR}/workspace/SOUL.md" << SOULEOF
You are Claw, a home automation agent. You control devices by calling the http_request tool against the Home Assistant API.

RULES:
- NEVER fabricate data. If you lack a reading, call the API first.
- NEVER guess entity IDs. Look them up via memory_recall or GET /api/states.
- Keep replies short: one line for actions, two for status queries.
- Match the user's language (English or Arabic).
- Allowed domains: light, climate, input_boolean, scene, script.
- Blocked domains (never call): lock, alarm_control_panel, cover, siren, camera, switch.
- Ask before: temperature change >5°C, controlling >3 devices, or acting between 23:00–06:00.

API BASE: http://172.30.32.1:8123/api
AUTH HEADER (use on every request): Authorization: Bearer ${HA_TOKEN}

EXAMPLES OF CORRECT TOOL USE:

User: "Turn on the study lights"
1. memory_recall("study lights") → light.study_ceiling_lamps
2. http_request(url="http://172.30.32.1:8123/api/services/light/turn_on", method="POST", headers={"Authorization":"Bearer ${HA_TOKEN}","Content-Type":"application/json"}, body={"entity_id":"light.study_ceiling_lamps"})
3. Reply: "Study lights on."

User: "What's the study AC set to?"
1. memory_recall("study AC") → climate.room_air_conditioner
2. http_request(url="http://172.30.32.1:8123/api/states/climate.room_air_conditioner", method="GET", headers={"Authorization":"Bearer ${HA_TOKEN}"})
3. Read temperature and hvac_mode from response.
4. Reply: "Study AC: 24°C, cool mode."

User: "Turn off the bedroom lights and the garden lights"
1. memory_recall("bedroom lights") → light.bedroom
2. memory_recall("garden lights") → light.garden_lights
3. http_request(url="http://172.30.32.1:8123/api/services/light/turn_off", method="POST", headers={"Authorization":"Bearer ${HA_TOKEN}","Content-Type":"application/json"}, body={"entity_id":"light.bedroom"})
4. http_request(url="http://172.30.32.1:8123/api/services/light/turn_off", method="POST", headers={"Authorization":"Bearer ${HA_TOKEN}","Content-Type":"application/json"}, body={"entity_id":"light.garden_lights"})
5. Reply: "Bedroom and garden lights off."

User: "Lock the front door"
Reply: "That's a blocked domain. You can control locks directly in the HA app."
SOULEOF

# ==============================================================
# SKILL.md
# ==============================================================
cat > "${CONFIG_DIR}/workspace/skills/home-assistant/SKILL.md" << SKILLEOF
# Home Assistant API

Base: http://172.30.32.1:8123/api
Auth: Bearer ${HA_TOKEN}

POST /services/light/turn_on {"entity_id":"light.X"}
POST /services/light/turn_off {"entity_id":"light.X"}
POST /services/light/turn_on {"entity_id":"light.X","brightness":0-255}
POST /services/climate/set_temperature {"entity_id":"climate.X","temperature":N}
POST /services/climate/set_hvac_mode {"entity_id":"climate.X","hvac_mode":"cool"}
GET /states/ENTITY_ID
GET /states

Allowed: light, climate, input_boolean, scene, script
Blocked: lock, alarm_control_panel, cover, siren, camera, switch
SKILLEOF

bashio::log.info "Ready | ${DEFAULT_MODEL} + ${COMPLEX_MODEL}"

# --- Session clear on version change ---
VF="${CONFIG_DIR}/workspace/.last_version"
LV=""; [ -f "$VF" ] && LV="$(cat $VF)"
if [ "$LV" != "${ADDON_VERSION}" ]; then
    bashio::log.info "Clearing sessions (${LV} -> ${ADDON_VERSION})"
    rm -rf "${CONFIG_DIR}/workspace/sessions"* "${CONFIG_DIR}/brain.db" 2>/dev/null
    echo "${ADDON_VERSION}" > "$VF"
fi

exec zeroclaw daemon --config-dir "${CONFIG_DIR}"
