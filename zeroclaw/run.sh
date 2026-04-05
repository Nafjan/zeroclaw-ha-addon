#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS Add-on v1.2.0

ADDON_VERSION="1.4.0"
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
WS="${CONFIG_DIR}/workspace"
mkdir -p "${WS}/skills/ha"

# ==============================================================
# config.toml
# ==============================================================
cat > "${CONFIG_DIR}/config.toml" << TOMLEOF
default_provider = "openrouter"
default_model = "${DEFAULT_MODEL}"
default_temperature = 0.2
provider_timeout_secs = 20
provider_max_tokens = 500

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
conversation_retention_days = 30

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
fallback_providers = ["google", "openai"]

[reliability.model_fallbacks]
"${DEFAULT_MODEL}" = ["google/gemini-3.1-flash-lite-preview"]
"${COMPLEX_MODEL}" = ["openai/gpt-4.1-mini"]

[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 300
TOMLEOF

# ==============================================================
# SOUL.md — agent identity and behavioral rules ONLY
# ==============================================================
cat > "${WS}/SOUL.md" << 'SOULEOF'
You are Claw, a home automation agent. Keep replies SHORT (1-2 sentences max). Never fabricate data.

DECISION TREE — follow this for EVERY user message:

1. User wants to CONTROL a device (turn on, turn off, open, close, set temp)?
   → Use http_request to POST to the HA API. Done.

2. User wants to KNOW device status (which lights are on, temperature, curtain state)?
   → Use http_request GET /api/states to fetch live data. Filter and report.

3. User wants something else?
   → Answer directly or say you can't help.

NEVER loop on memory_recall to look up entity IDs one by one. If you need an entity ID you don't know, call GET /api/states ONCE and find it in the response.

Only use memory_recall for user preferences or past corrections, NOT for entity lookups.

RULES:
- Allowed: light, climate, cover, input_boolean, scene, script
- Blocked: lock, alarm_control_panel, siren, camera, switch
- Ask before: temp >5°C change, >3 devices, nighttime (23-06)
- When you learn something new, store it with memory_store(category="core")
SOULEOF

# ==============================================================
# TOOLS.md — how to use tools for HA control
# ==============================================================
cat > "${WS}/TOOLS.md" << TOOLSEOF
## HA API Reference

Base URL: http://172.30.32.1:8123/api
Auth: Authorization: Bearer ${HA_TOKEN}

CONTROL (POST, add Content-Type: application/json):
/services/light/turn_on      {"entity_id":"light.X"}
/services/light/turn_off     {"entity_id":"light.X"}
/services/climate/set_temperature  {"entity_id":"climate.X","temperature":N}
/services/climate/set_hvac_mode    {"entity_id":"climate.X","hvac_mode":"cool"}
/services/cover/open_cover   {"entity_id":"cover.X"}
/services/cover/close_cover  {"entity_id":"cover.X"}

QUERY (GET):
/states              → all entities (use this for status questions)
/states/ENTITY_ID    → single entity

IMPORTANT: For "which lights are on", "temperature", "status" questions — just call GET /states ONCE. Don't call memory_recall in a loop.
TOOLSEOF

# ==============================================================
# USER.md — home context
# ==============================================================
cat > "${WS}/USER.md" << 'USEREOF'
## Home context
- Owner: Yousef
- Location: Al Khobar, Saudi Arabia (AST, UTC+3)
- Platform: Home Assistant Green

## Quick reference
- "study lights" = light.study_ceiling_lamps (group of 8 ceiling lights)
- "bedroom lights" = light.bedroom (left + right bedside)
- "study AC" = climate.room_air_conditioner
- "master bedroom AC" = climate.gr_acunit_6400_02_608d
- "living room AC" = climate.gr_acunit_6400_02_10b6
- "master bedroom curtains" = cover.master_bedroom_curtains
- 7 curtains total (master bedroom, FA blackout/chiffon, hall blackout/chiffon, EH blackout/chiffon)
- All entity mappings are in memory (use memory_recall)
USEREOF

# ==============================================================
# HA Skill with callable tools
# ==============================================================
cat > "${WS}/skills/ha/SKILL.md" << SKILLEOF
---
name: "ha"
description: "Home Assistant device control"
version: "1.0.0"
tags: ["home", "automation", "iot"]
---

# Home Assistant Control

Control lights, climate, and query device states via the HA REST API.

Entity IDs are stored in agent memory. Use memory_recall to look them up.

[[tools]]
name = "light_on"
description = "Turn on a light. Provide the entity_id (e.g. light.living_room)."
kind = "http"
method = "POST"
url = "http://172.30.32.1:8123/api/services/light/turn_on"
headers = {"Authorization": "Bearer ${HA_TOKEN}", "Content-Type": "application/json"}

[[tools]]
name = "light_off"
description = "Turn off a light. Provide the entity_id."
kind = "http"
method = "POST"
url = "http://172.30.32.1:8123/api/services/light/turn_off"
headers = {"Authorization": "Bearer ${HA_TOKEN}", "Content-Type": "application/json"}

[[tools]]
name = "set_temperature"
description = "Set AC/climate temperature. Provide entity_id and temperature."
kind = "http"
method = "POST"
url = "http://172.30.32.1:8123/api/services/climate/set_temperature"
headers = {"Authorization": "Bearer ${HA_TOKEN}", "Content-Type": "application/json"}

[[tools]]
name = "get_state"
description = "Get current state of any HA entity. Provide the full entity_id."
kind = "http"
method = "GET"
url = "http://172.30.32.1:8123/api/states/{entity_id}"
headers = {"Authorization": "Bearer ${HA_TOKEN}"}

[[tools]]
name = "open_cover"
description = "Open a curtain/cover. Provide the entity_id (e.g. cover.master_bedroom_curtains)."
kind = "http"
method = "POST"
url = "http://172.30.32.1:8123/api/services/cover/open_cover"
headers = {"Authorization": "Bearer ${HA_TOKEN}", "Content-Type": "application/json"}

[[tools]]
name = "close_cover"
description = "Close a curtain/cover. Provide the entity_id."
kind = "http"
method = "POST"
url = "http://172.30.32.1:8123/api/services/cover/close_cover"
headers = {"Authorization": "Bearer ${HA_TOKEN}", "Content-Type": "application/json"}

[[tools]]
name = "stop_cover"
description = "Stop a curtain/cover mid-movement. Provide the entity_id."
kind = "http"
method = "POST"
url = "http://172.30.32.1:8123/api/services/cover/stop_cover"
headers = {"Authorization": "Bearer ${HA_TOKEN}", "Content-Type": "application/json"}

[[tools]]
name = "list_entities"
description = "List all HA entities and their states. Use sparingly — large response."
kind = "http"
method = "GET"
url = "http://172.30.32.1:8123/api/states"
headers = {"Authorization": "Bearer ${HA_TOKEN}"}
SKILLEOF

# ==============================================================
# MEMORY_SNAPSHOT.md — pre-seeded entity knowledge
# ==============================================================
cat > "${WS}/MEMORY_SNAPSHOT.md" << 'MEMEOF'
### entity_study_ceiling_lamps

light.study_ceiling_lamps — group of 8 ceiling lights in the study

### entity_study_spotlights_left

light.study_spotlights_left

### entity_study_spotlights_right

light.study_spotlights_right

### entity_living_room

light.living_room

### entity_bedroom

light.bedroom — group containing light.left_bedside and light.right_bedside

### entity_garden_lights

light.garden_lights — outdoor garden

### entity_nursery_lamp

light.nursery_ceiling_lamp

### entity_master_bathroom_left

light.master_bathroom_light_left

### entity_master_bathroom_right

light.master_bathroom_light_right

### entity_floor_lamp

light.bedroom_repeater_lamp_switch — bedroom floor lamp

### entity_olive_tree_lights

light.olive_tree_lights — group of 3 olive tree lights in living room

### entity_stairs_night_light

light.downstairs_switch_2_left — stairs/downstairs night light

### entity_upstairs_light

light.downstairs_switch_right

### entity_under_stairs

light.downstairs_switch_left

### entity_monitor_lights

light.monitor_lights — study desk monitors

### entity_tv_lights

light.tv_lights — group: light.tv_1, light.tv_2, light.tv_3

### entity_all_lights

light.all_lights — all 43 lights

### entity_study_ac

climate.room_air_conditioner — study room AC

### entity_master_bedroom_ac

climate.gr_acunit_6400_02_608d — master bedroom AC

### entity_living_room_ac

climate.gr_acunit_6400_02_10b6 — living room / downstairs AC

### entity_majlis_ac

climate.gr_acunit_6400_02_7a25 — majlis AC

### entity_hall_ac

climate.hall_ac

### entity_entrance_hall_ac

climate.entrance_hall_ac

### entity_food_area_ac

climate.food_area_ac

### entity_nursery_ac

climate.nursery — nursery AC

### entity_weather

weather.pirateweather — local weather data

### entity_master_bedroom_curtains

cover.master_bedroom_curtains — master bedroom curtains

### entity_blackout_fa_curtain

cover.blackout_fa_curtain — family area blackout curtain

### entity_chiffon_fa_curtain

cover.chiffon_fa_curtain — family area chiffon curtain

### entity_blackout_hall_curtain

cover.blackout_hall_curtain — hall blackout curtain

### entity_chiffon_hall_curtain

cover.chiffon_hall_curtain — hall chiffon curtain

### entity_chiffon_eh_curtain

cover.chiffon_eh_curtain — entrance hall chiffon curtain

### entity_blackout_eh_curtain

cover.blackout_eh_curtain — entrance hall blackout curtain

### user_language_preference

Yousef communicates in English and Arabic. Match his language.

### home_location

Al Khobar, Saudi Arabia. Timezone AST (UTC+3).
MEMEOF

bashio::log.info "Ready | ${DEFAULT_MODEL} + ${COMPLEX_MODEL}"

# --- Session clear on version change ---
VF="${WS}/.last_version"
LV=""; [ -f "$VF" ] && LV="$(cat $VF)"
if [ "$LV" != "${ADDON_VERSION}" ]; then
    bashio::log.info "Clearing sessions (${LV} -> ${ADDON_VERSION})"
    rm -rf "${CONFIG_DIR}/workspace/sessions"* "${CONFIG_DIR}/brain.db" 2>/dev/null
    echo "${ADDON_VERSION}" > "$VF"
fi

exec zeroclaw daemon --config-dir "${CONFIG_DIR}"
