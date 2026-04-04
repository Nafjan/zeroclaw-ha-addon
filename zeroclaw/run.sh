#!/usr/bin/with-contenv bashio

# ============================================================
# ZeroClaw HAOS Add-on — v1.0.0
# ============================================================

ADDON_VERSION="1.0.1"
bashio::log.info "Starting ZeroClaw Agent v${ADDON_VERSION}..."

# --- Read credentials from HAOS encrypted options ---
OPENROUTER_KEY="$(bashio::config 'openrouter_api_key')"
HA_TOKEN="$(bashio::config 'ha_token')"
TELEGRAM_TOKEN="$(bashio::config 'telegram_bot_token')"
TELEGRAM_USERS="$(bashio::config 'telegram_allowed_users')"
DEFAULT_MODEL="$(bashio::config 'default_model')"
COMPLEX_MODEL="$(bashio::config 'complex_model')"
LOG_LEVEL="$(bashio::config 'log_level')"

# --- Set env vars ---
export ZEROCLAW_API_KEY="${OPENROUTER_KEY}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_TOKEN}"
export HA_TOKEN="${HA_TOKEN}"
export RUST_LOG="${LOG_LEVEL}"

# --- Validate ---
for var in OPENROUTER_KEY TELEGRAM_TOKEN HA_TOKEN; do
    eval val=\$$var
    if [ -z "$val" ]; then
        bashio::log.fatal "${var} not configured!"
        exit 1
    fi
done

# --- Setup ---
CONFIG_DIR="/data"
mkdir -p "${CONFIG_DIR}/workspace/skills/home-assistant"

# ============================================================
# CONFIG.TOML — Main ZeroClaw configuration
# ============================================================
cat > "${CONFIG_DIR}/config.toml" << TOMLEOF
# ZeroClaw v${ADDON_VERSION} — auto-generated
default_provider = "openrouter"
default_model = "${DEFAULT_MODEL}"
default_temperature = 0.5
provider_timeout_secs = 30

[model_providers.openrouter]
name = "openai"
base_url = "https://openrouter.ai/api/v1"
api_path = "/chat/completions"
wire_api = "chat_completions"

# --- Model routing: fast for simple, reasoning for complex ---
[[model_routes]]
hint = "fast"
provider = "openrouter"
model = "${DEFAULT_MODEL}"

[[model_routes]]
hint = "reasoning"
provider = "openrouter"
model = "${COMPLEX_MODEL}"

# --- Channels ---
[channels_config]
message_timeout_secs = 120
ack_reactions = true
session_persistence = true
session_backend = "sqlite"
debounce_ms = 500

[channels_config.telegram]
bot_token = "${TELEGRAM_TOKEN}"
allowed_users = ["${TELEGRAM_USERS}"]
stream_mode = "partial"
draft_update_interval_ms = 2000
interrupt_on_new_message = true
mention_only = false

# --- Gateway ---
[gateway]
port = 42617
host = "0.0.0.0"
require_pairing = false
session_persistence = true

# --- Agent ---
[agent]
compact_context = true
max_tool_iterations = 8
max_history_messages = 30
max_context_tokens = 16000

# --- Autonomy ---
[autonomy]
level = "full"
workspace_only = true
max_actions_per_hour = 200

# --- Memory ---
[memory]
backend = "sqlite"
auto_save = true
hygiene_enabled = true
search_mode = "bm25"
response_cache_enabled = true
response_cache_ttl_minutes = 1
snapshot_enabled = true
auto_hydrate = true

# --- HTTP Request tool ---
[http_request]
enabled = true
allowed_domains = ["*"]
max_response_size = 500000
timeout_secs = 15
allow_private_hosts = true

# --- Cost ---
[cost]
enabled = true
daily_limit_usd = 5.0
monthly_limit_usd = 20.0
warn_at_percent = 80

[cost.enforcement]
mode = "route_down"
route_down_model = "openai/gpt-4o-mini"
reserve_percent = 10

# --- Reliability ---
[reliability]
provider_retries = 3
provider_backoff_ms = 500
fallback_providers = ["openai"]

[reliability.model_fallbacks]
"openai/gpt-4o-mini" = ["google/gemini-2.5-flash"]
"anthropic/claude-sonnet-4.6" = ["openai/gpt-4o"]

# --- Observability ---
[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 500
TOMLEOF

# ============================================================
# MEMORY_SNAPSHOT.md — Pre-seeded entity mappings
# ============================================================
cat > "${CONFIG_DIR}/workspace/MEMORY_SNAPSHOT.md" << 'MEMEOF'
# Home Assistant Entity Mappings

## Lights
- study ceiling lamps / study lights: light.study_ceiling_lamps
- study spotlights left: light.study_spotlights_left
- study spotlights right: light.study_spotlights_right
- living room light: light.living_room
- bedroom lights: light.bedroom (group: light.left_bedside, light.right_bedside)
- left bedside: light.left_bedside
- right bedside: light.right_bedside
- garden lights: light.garden_lights
- nursery ceiling lamp: light.nursery_ceiling_lamp
- master bathroom left: light.master_bathroom_light_left
- master bathroom right: light.master_bathroom_light_right
- floor lamp / bedroom lamp: light.bedroom_repeater_lamp_switch
- olive tree lights: light.olive_tree_lights (group of 3)
- stairs night light / downstairs night light: light.downstairs_switch_2_left
- upstairs light: light.downstairs_switch_right
- under stairs light: light.downstairs_switch_left
- monitor lights: light.monitor_lights
- tv lights: light.tv_lights (group: light.tv_1, light.tv_2, light.tv_3)
- all lights: light.all_lights (group of all 43 lights)

## Climate (ACs)
- study AC: climate.room_air_conditioner
- master bedroom AC: climate.gr_acunit_6400_02_608d
- living room AC / downstairs AC: climate.gr_acunit_6400_02_10b6
- majlis AC: climate.gr_acunit_6400_02_7a25
- hall AC: climate.hall_ac
- entrance hall AC: climate.entrance_hall_ac
- food area AC: climate.food_area_ac
- nursery AC: climate.nursery

## Weather
- pirateweather: weather.pirateweather
- home forecast: weather.forecast_home

## Vacuums (read-only)
- Winky (Roborock A15): sensor.roborock_us_506135217_a15_*
- Kreacher (Roborock S6): often unavailable
- Dobby 2.0 (Roborock S5): often unavailable
MEMEOF

# ============================================================
# SOUL.md — Compressed system prompt (~1.5K tokens)
# ============================================================
cat > "${CONFIG_DIR}/workspace/SOUL.md" << SOULEOF
# Claw — Home Assistant Agent

You control Home Assistant via the http_request tool.

## CRITICAL RULES
1. NEVER invent data. If you don't have a sensor reading, say "I don't have that data" and offer to look it up via the API.
2. ALWAYS use http_request to get real data before answering questions about device states, temperatures, or sensor values.
3. NEVER guess entity IDs. Use memory_recall first. If not in memory, query GET /states to find it.
4. When you make an API call and it succeeds, report what the API actually returned — not what you think it should be.

## Entity IDs
Your memory has entity mappings pre-loaded. Use memory_recall("study lights") to find IDs.
If memory has no match, query GET /api/states to discover entities.

## API
Base: http://172.30.32.1:8123/api
Auth header for ALL requests: Authorization: Bearer ${HA_TOKEN}
Content-Type for POST: application/json

Common calls:
- POST /services/light/turn_on {"entity_id": "light.X"}
- POST /services/light/turn_off {"entity_id": "light.X"}
- POST /services/climate/set_temperature {"entity_id": "climate.X", "temperature": N}
- POST /services/climate/set_hvac_mode {"entity_id": "climate.X", "hvac_mode": "cool|heat|auto|dry|off"}
- GET /states/ENTITY_ID (get specific entity — preferred)
- GET /states (all entities — use only when searching)

## Style
- One sentence for simple actions: "Study lights on."
- Include values for state queries: "Study AC: 24°C, cool mode."
- Same language as user (English or Arabic).
- If something fails, say what happened clearly.

## Safety
- Allowed: light, climate, input_boolean, scene, script
- BLOCKED: lock, alarm_control_panel, cover, siren, camera, switch
- Confirm before: temp >5°C change, >3 entities, nighttime (23-06)
SOULEOF

# ============================================================
# SKILL.md — HA control skill
# ============================================================
cat > "${CONFIG_DIR}/workspace/skills/home-assistant/SKILL.md" << SKILLEOF
# Home Assistant Control Skill

API: http://172.30.32.1:8123/api
Auth: Bearer ${HA_TOKEN}

## Light control
POST /services/light/turn_on with {"entity_id": "light.X"}
POST /services/light/turn_off with {"entity_id": "light.X"}
POST /services/light/turn_on with {"entity_id": "light.X", "brightness": 0-255}

## Climate control
POST /services/climate/set_temperature with {"entity_id": "climate.X", "temperature": N}
POST /services/climate/set_hvac_mode with {"entity_id": "climate.X", "hvac_mode": "cool"}

## State queries
GET /states/ENTITY_ID
GET /states (all entities — use sparingly)

## Safety
ALLOWED: light, climate, input_boolean, scene, script
BLOCKED: lock, alarm_control_panel, cover, siren, camera, switch
SKILLEOF

bashio::log.info "Config generated | Default: ${DEFAULT_MODEL} | Complex: ${COMPLEX_MODEL}"

# ============================================================
# Session management — clear on version change
# ============================================================
VERSION_FILE="${CONFIG_DIR}/workspace/.last_version"
if [ -f "${VERSION_FILE}" ]; then
    LAST_VERSION="$(cat ${VERSION_FILE})"
else
    LAST_VERSION=""
fi
if [ "${LAST_VERSION}" != "${ADDON_VERSION}" ]; then
    bashio::log.info "Version changed (${LAST_VERSION} -> ${ADDON_VERSION}), clearing sessions"
    rm -f "${CONFIG_DIR}/workspace/sessions"*.db 2>/dev/null
    rm -f "${CONFIG_DIR}/workspace/sessions"*.jsonl 2>/dev/null
    rm -rf "${CONFIG_DIR}/workspace/sessions" 2>/dev/null
    rm -f "${CONFIG_DIR}/brain.db" 2>/dev/null
    echo "${ADDON_VERSION}" > "${VERSION_FILE}"
fi

# ============================================================
# Start daemon
# ============================================================
exec zeroclaw daemon --config-dir "${CONFIG_DIR}"
