#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS Add-on v1.2.0

ADDON_VERSION="2.0.0"
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
route_down_model = "openai/gpt-4.1-nano"
reserve_percent = 10

[reliability]
provider_retries = 2
provider_backoff_ms = 300
fallback_providers = ["google", "openai"]

[reliability.model_fallbacks]
"moonshotai/kimi-k2.5" = ["openai/gpt-4.1-nano"]
"${COMPLEX_MODEL}" = ["moonshotai/kimi-k2.5"]

[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 300
TOMLEOF

# ==============================================================
# SOUL.md — agent identity and behavioral rules ONLY
# ==============================================================
cat > "${WS}/SOUL.md" << 'SOULEOF'
You are Claw, a home automation agent. You ONLY report data from tool calls. You NEVER invent readings.

## RULES
1. Every value you report MUST come from a tool call response. No exceptions.
2. Use the ha.* skill tools — they return clean, filtered data. NEVER use raw http_request with GET /api/states (too large).
3. For "which lights are on" → call ha.lights_on. For AC status → call ha.ac_status. For sensors → call ha.sensor_status.
4. For actions: ha.light_on, ha.light_off, ha.set_temperature, ha.open_cover, ha.close_cover.
5. For "turn off ALL lights" → use entity_id "light.all_lights" with ha.light_off.
6. Keep replies short: 1-2 sentences. Match user's language.
7. Allowed: light, climate, cover. Blocked: lock, alarm, siren, camera, switch.
8. When you learn something new, store it with memory_store(category="core").
9. If a tool fails, say "Couldn't reach HA" — never guess.

## WRONG:
- Inventing sensor values without calling ha.sensor_status
- Saying "lights might be on" without calling ha.lights_on
- Using http_request GET /api/states (532KB response, will be truncated and wrong)

## RIGHT:
- "Which lights are on?" → call ha.lights_on → report the list
- "Turn off everything" → call ha.light_off with {"entity_id":"light.all_lights"} → "All lights off."
- "AC status?" → call ha.ac_status → report temps and modes
SOULEOF

# ==============================================================
# TOOLS.md — how to use tools for HA control
# ==============================================================
cat > "${WS}/TOOLS.md" << 'TOOLSEOF'
## Available ha.* tools

STATUS QUERIES (return clean text, not raw JSON):
- ha.lights_on — which lights are currently on
- ha.ac_status — all AC temperatures and modes
- ha.cover_status — curtain open/closed states
- ha.sensor_status — soil moisture and temperature sensors
- ha.get_entity — get one specific entity by ID

CONTROL ACTIONS (pass JSON body as argument):
- ha.light_on '{"entity_id":"light.X"}'
- ha.light_off '{"entity_id":"light.X"}'  (use light.all_lights for all)
- ha.set_temperature '{"entity_id":"climate.X","temperature":N}'
- ha.set_hvac_mode '{"entity_id":"climate.X","hvac_mode":"cool"}'
- ha.open_cover '{"entity_id":"cover.X"}'
- ha.close_cover '{"entity_id":"cover.X"}'

DO NOT use raw http_request with GET /api/states — it returns 532KB of data that will be truncated.
Use ha.* tools instead — they return filtered, clean responses.
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
description: "Home Assistant device control and status"
version: "2.0.0"
tags: ["home", "automation"]
---

# Home Assistant Control

[[tools]]
name = "lights_on"
description = "List which lights are currently ON. Returns only lit lights with friendly names."
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/template' -d '{\"template\": \"{% for l in states.light %}{% if l.state == \\\\\"on\\\\\" and l.entity_id != \\\\\"light.all_lights\\\\\" %}{{ l.name }}: {{ l.entity_id }}\\n{% endif %}{% endfor %}\"}'"

[[tools]]
name = "ac_status"
description = "Get status of all ACs/climate devices. Shows temperature and mode."
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/template' -d '{\"template\": \"{% for c in states.climate %}{% if c.state != \\\\\"unavailable\\\\\" %}{{ c.name }}: {{ c.state }}, set:{{ c.attributes.temperature }}°C, current:{{ c.attributes.current_temperature }}°C\\n{% endif %}{% endfor %}\"}'"

[[tools]]
name = "cover_status"
description = "Get status of all curtains/covers. Shows open/closed state."
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/template' -d '{\"template\": \"{% for c in states.cover %}{{ c.name }}: {{ c.state }}\\n{% endfor %}\"}'"

[[tools]]
name = "sensor_status"
description = "Get soil moisture and temperature sensors. For garden/plant monitoring."
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/template' -d '{\"template\": \"{% for s in states.sensor %}{% if \\\\\"soil\\\\\" in s.entity_id or \\\\\"moisture\\\\\" in s.entity_id %}{{ s.name }}: {{ s.state }}{{ s.attributes.unit_of_measurement }}\\n{% endif %}{% endfor %}\"}'"

[[tools]]
name = "light_on"
description = "Turn on a light. Pass entity_id as body: {\"entity_id\":\"light.X\"}"
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/services/light/turn_on' -d"

[[tools]]
name = "light_off"
description = "Turn off a light. Pass entity_id as body: {\"entity_id\":\"light.X\"}. Use light.all_lights to turn off ALL lights."
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/services/light/turn_off' -d"

[[tools]]
name = "set_temperature"
description = "Set AC temperature. Body: {\"entity_id\":\"climate.X\",\"temperature\":N}"
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/services/climate/set_temperature' -d"

[[tools]]
name = "set_hvac_mode"
description = "Set AC mode (cool/heat/auto/dry/off). Body: {\"entity_id\":\"climate.X\",\"hvac_mode\":\"cool\"}"
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/services/climate/set_hvac_mode' -d"

[[tools]]
name = "open_cover"
description = "Open curtain. Body: {\"entity_id\":\"cover.X\"}"
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/services/cover/open_cover' -d"

[[tools]]
name = "close_cover"
description = "Close curtain. Body: {\"entity_id\":\"cover.X\"}"
kind = "shell"
command = "curl -s -X POST -H 'Authorization: Bearer ${HA_TOKEN}' -H 'Content-Type: application/json' 'http://172.30.32.1:8123/api/services/cover/close_cover' -d"

[[tools]]
name = "get_entity"
description = "Get state of ONE specific entity by ID. Returns JSON with state and attributes."
kind = "shell"
command = "curl -s -H 'Authorization: Bearer ${HA_TOKEN}' 'http://172.30.32.1:8123/api/states/'"
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
