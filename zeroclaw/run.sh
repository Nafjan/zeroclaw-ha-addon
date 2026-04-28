#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS Add-on v2.5.0

ADDON_VERSION="2.5.1"
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

# --- Convert comma-separated TELEGRAM_USERS to TOML array ---
# e.g. "123,456" → "123", "456"
USERS_TOML=$(echo "$TELEGRAM_USERS" | tr ',' '\n' | tr -d ' ' | \
    awk 'NF{printf "\"%s\", ", $0}' | sed 's/, $//')

# First user ID — used for cron-initiated daily reports
FIRST_USER=$(echo "$TELEGRAM_USERS" | cut -d',' -f1 | tr -d ' ')

CONFIG_DIR="/data"
WS="${CONFIG_DIR}/workspace"
HA_URL="http://172.30.32.1:8123/api"
mkdir -p "${WS}/skills/ha" /data/logs

# ==============================================================
# HA helper scripts (tokens embedded at startup)
# ==============================================================
mkdir -p /usr/local/bin

cat > /usr/local/bin/ha-lights-on << SCRIPT
#!/bin/sh
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  "${HA_URL}/template" \
  -d '{"template":"{% for l in states.light %}{% if l.state == \"on\" and l.entity_id != \"light.all_lights\" %}{{ l.name }}: {{ l.entity_id }}\n{% endif %}{% endfor %}"}'
SCRIPT

cat > /usr/local/bin/ha-ac-status << SCRIPT
#!/bin/sh
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  "${HA_URL}/template" \
  -d '{"template":"{% for c in states.climate %}{% if c.state != \"unavailable\" %}{{ c.name }}: {{ c.state }}, set:{{ c.attributes.temperature }}C, now:{{ c.attributes.current_temperature }}C\n{% endif %}{% endfor %}"}'
SCRIPT

cat > /usr/local/bin/ha-cover-status << SCRIPT
#!/bin/sh
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  "${HA_URL}/template" \
  -d '{"template":"{% for c in states.cover %}{{ c.name }}: {{ c.state }}\n{% endfor %}"}'
SCRIPT

cat > /usr/local/bin/ha-sensors << SCRIPT
#!/bin/sh
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  "${HA_URL}/template" \
  -d '{"template":"{% for s in states.sensor %}{% if \"soil\" in s.entity_id or \"moisture\" in s.entity_id or \"temperature\" in s.entity_id %}{{ s.name }}: {{ s.state }}{{ s.attributes.unit_of_measurement }}\n{% endif %}{% endfor %}"}'
SCRIPT

cat > /usr/local/bin/ha-action << SCRIPT
#!/bin/sh
# Usage: ha-action <service_path> <json_body>
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  "${HA_URL}/services/\$1" -d "\$2"
SCRIPT

cat > /usr/local/bin/ha-state << SCRIPT
#!/bin/sh
# Usage: ha-state <entity_id>
curl -s -H "Authorization: Bearer ${HA_TOKEN}" "${HA_URL}/states/\$1" | \
  jq -r '"\(.attributes.friendly_name // .entity_id): \(.state)\(if .attributes.temperature then " set:\(.attributes.temperature)C" else "" end)\(if .attributes.current_temperature then " now:\(.attributes.current_temperature)C" else "" end)"'
SCRIPT

cat > /usr/local/bin/ha-all-status << SCRIPT
#!/bin/sh
# Combined home status — lights, AC, covers in one call
echo "=LIGHTS="
ha-lights-on 2>/dev/null || echo "(none)"
echo "=AC="
ha-ac-status 2>/dev/null || echo "(unavailable)"
echo "=COVERS="
ha-cover-status 2>/dev/null || echo "(unavailable)"
SCRIPT

cat > /usr/local/bin/ha-logbook << SCRIPT
#!/bin/sh
# Usage: ha-logbook [entity_id]
# BusyBox-compatible date arithmetic
NOW=\$(date -u +%Y-%m-%dT%H:%M:%S)
AGO24=\$(date -u -d @\$(( \$(date +%s) - 86400 )) +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
        date -u -r \$(( \$(date +%s) - 86400 )) +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
        echo "\$NOW")
if [ -n "\$1" ]; then
    curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
      "${HA_URL}/logbook/\${AGO24}?entity=\$1&end_time=\${NOW}" | \
      jq -r '.[] | "\(.when): \(.name) \(.message)"' 2>/dev/null || echo "No logbook data"
else
    AGO1=\$(date -u -d @\$(( \$(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
            date -u -r \$(( \$(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
            echo "\$NOW")
    curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
      "${HA_URL}/logbook/\${AGO1}" | \
      jq -r '.[-20:] | .[] | "\(.when): \(.name) \(.message)"' 2>/dev/null || echo "No logbook data"
fi
SCRIPT

cat > /usr/local/bin/ha-errors << SCRIPT
#!/bin/sh
curl -s -H "Authorization: Bearer ${HA_TOKEN}" "${HA_URL}/error_log" | tail -40
SCRIPT

# ==============================================================
# Daily check-in script (run by crond at 8am AST = 5am UTC)
# Tokens embedded at container startup; safe at runtime.
# ==============================================================
cat > /usr/local/bin/ha-daily-report << SCRIPT
#!/bin/sh
LOG="/data/logs/daily-report.log"
DATE=\$(date '+%Y-%m-%d %H:%M')
echo "--- Daily report \${DATE} ---" >> "\$LOG"

LIGHTS=\$(ha-lights-on 2>/dev/null)
LIGHTS_COUNT=\$(printf '%s\n' "\$LIGHTS" | grep -c . 2>/dev/null || echo 0)
AC=\$(ha-ac-status 2>/dev/null | head -5)
ERRS=\$(ha-errors 2>/dev/null | grep -i "error\|warning\|exception" | tail -3)

MSG="ZeroClaw daily check — \${DATE} AST
💡 Lights on: \${LIGHTS_COUNT}
❄️ AC: \$(echo "\$AC" | head -2)
⚠️ Errors: \${ERRS:-none}

Send 'daily insights' for AI analysis."

# Send via Telegram Bot API
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\":\"${FIRST_USER}\",\"text\":\"\$(echo "\$MSG" | head -10 | tr '\n' ' ' | sed 's/\"/\\\"/g')\"}" \
  >> "\$LOG" 2>&1

# Ask ZeroClaw to generate an AI insight (gateway API best-effort)
curl -s -X POST "http://localhost:42617/api/message" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"telegram\",\"user_id\":\"${FIRST_USER}\",\"content\":\"DAILY_CHECKIN: Use ha.error_log to check for issues, then ha.lights_on and ha.ac_status for current state. Based on patterns in your memory, suggest one specific improvement to home automation. Max 2 sentences.\"}" \
  >> "\$LOG" 2>&1 || true
echo "Done." >> "\$LOG"
SCRIPT

chmod +x /usr/local/bin/ha-*

# ==============================================================
# config.toml
# ==============================================================
cat > "${CONFIG_DIR}/config.toml" << TOMLEOF
default_provider = "openrouter"
default_model = "${DEFAULT_MODEL}"
default_temperature = 0.2
provider_timeout_secs = 20
provider_max_tokens = 2048

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
allowed_users = [${USERS_TOML}]
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
workspace_only = false
max_actions_per_hour = 200
allowed_commands = ["ha-lights-on", "ha-ac-status", "ha-cover-status", "ha-sensors", "ha-action", "ha-state", "ha-all-status", "ha-logbook", "ha-errors", "curl", "jq", "cat", "echo", "ls", "grep", "head", "tail", "date"]
require_approval_for_medium_risk = false
block_high_risk_commands = false

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
route_down_model = "${DEFAULT_MODEL}"
reserve_percent = 10

[reliability]
provider_retries = 2
provider_backoff_ms = 300

[reliability.model_fallbacks]
"${COMPLEX_MODEL}" = ["${DEFAULT_MODEL}"]

[observability]
backend = "log"
runtime_trace_mode = "rolling"
runtime_trace_max_entries = 300
TOMLEOF

# ==============================================================
# SOUL.md — behavioral rules (concise, testable)
# ==============================================================
cat > "${WS}/SOUL.md" << 'SOULEOF'
Role: Home automation executor. Call tools. Write the outcome. Nothing else.
Language: Match the user — English or Arabic. Output: 1-2 lines max.

## Greetings
"hi" / "hello" / "hey" / "مرحبا" → write exactly: "Hi." — then stop. No other words.

## Step 1 — Resolve entity
Unknown entity name? Call memory_recall("<name>") first. Entity mappings are pre-loaded.
Still unknown? Write: "I don't know '<name>'. What's the entity ID?"

## Step 2 — Status queries → call tool → paste output (max 150 chars)
ha.lights_on     — which lights are on
ha.ac_status     — all AC states
ha.cover_status  — curtain states
ha.sensor_status — soil/moisture sensors
ha.all_status    — everything at once
ha.get_entity <entity_id> — one entity
ha.logbook [entity_id]   — recent events
ha.error_log             — HA system errors

## Step 3 — Action requests

### Lights
Call ha.light_on or ha.light_off → write this exact line:
  "Study ceiling lamps on."   /   "Bedroom lights off."   /   "All lights off."

### AC — ALWAYS check state first with ha.get_entity, then decide:
  • Already in requested state → write: "Study AC is already on — 24°C, cool mode." (skip action)
  • Needs change → call action, then write:
      set_temperature  → "Study AC → 24°C."
      set_hvac_mode    → "Study AC → cool mode."   or   "Study AC off."

### Covers
Call ha.open_cover or ha.close_cover → write:
  "Master bedroom curtains opened."   /   "Hall blackout curtain closed."

### Errors
Tool returns error text → write: "Failed: [exact error from tool]"

## THE RULE: after every action tool call, write the specific outcome line above. That is your entire response. No preamble. No explanation. No "Done."

## Blocked from all requests:
- Writing "Done." ← forbidden, always write the specific outcome
- Writing "Let me", "Sure!", "I'll", "Here's", "Certainly", "Of course"
- Calling http_request GET /api/states (532KB — breaks context; use ha.* tools)
- Guessing entity IDs without checking memory first
- More than 4 tool calls per turn

## Allowed domains: light, climate, cover, input_boolean, scene, script
## Blocked domains: lock, alarm_control_panel, siren, camera, switch
## Confirm before: AC temp change >5°C from current, nighttime (23:00–06:00) actions on 3+ devices

## Learning: user corrects or teaches new entity →
memory_store(key="entity_<slug>", value="<entity_id> — <description>", category="core")
SOULEOF

# ==============================================================
# TOOLS.md
# ==============================================================
cat > "${WS}/TOOLS.md" << 'TOOLSEOF'
## ha.* tool reference

STATUS QUERIES (clean text output, not raw JSON):
- ha.all_status    — lights + AC + covers in one call (use for "home overview")
- ha.lights_on     — which lights are currently ON
- ha.ac_status     — all ACs: mode, set temp, current temp
- ha.cover_status  — all curtains: open / closed
- ha.sensor_status — soil moisture and temperature sensors
- ha.get_entity    — one entity by ID (pass entity_id as arg)
- ha.logbook       — recent events (optionally pass entity_id to filter)
- ha.error_log     — Home Assistant system error log

CONTROL ACTIONS:
- ha.light_on       '{"entity_id":"light.X"}'
- ha.light_off      '{"entity_id":"light.X"}' — light.all_lights turns off everything
- ha.set_temperature '{"entity_id":"climate.X","temperature":N}'
- ha.set_hvac_mode  '{"entity_id":"climate.X","hvac_mode":"cool"}'
- ha.open_cover     '{"entity_id":"cover.X"}'
- ha.close_cover    '{"entity_id":"cover.X"}'

WARNING: Never call http_request with GET /api/states — 532KB payload breaks the context.
TOOLSEOF

# ==============================================================
# USER.md
# ==============================================================
cat > "${WS}/USER.md" << 'USEREOF'
## Home context
- Owner: Yousef
- Location: Al Khobar, Saudi Arabia (AST = UTC+3)
- Platform: Home Assistant Green

## Quick alias reference
- "study lights" → light.study_ceiling_lamps
- "bedroom lights" → light.bedroom
- "study AC" → climate.room_air_conditioner
- "master bedroom AC" → climate.gr_acunit_6400_02_608d
- "living room AC" / "downstairs AC" → climate.gr_acunit_6400_02_10b6
- "master bedroom curtains" → cover.master_bedroom_curtains
- 7 curtains total, all entity mappings in memory (use memory_recall)
USEREOF

# ==============================================================
# SKILL.md with callable ha.* tools
# ==============================================================
cat > "${WS}/skills/ha/SKILL.md" << 'SKILLEOF'
---
name: "ha"
description: "Home Assistant device control and status queries"
version: "2.1.0"
tags: ["home", "automation"]
---

# Home Assistant Control

Use these tools for ALL device interactions. They return clean, filtered data.

[[tools]]
name = "all_status"
description = "Full home overview: lights on, AC status, and cover/curtain states. Use this for 'home status', 'what's on', 'overview' questions."
kind = "shell"
command = "ha-all-status"

[[tools]]
name = "lights_on"
description = "List which lights are currently ON. Returns light names and entity IDs."
kind = "shell"
command = "ha-lights-on"

[[tools]]
name = "ac_status"
description = "Get all AC/climate status: mode, set temperature, current temperature."
kind = "shell"
command = "ha-ac-status"

[[tools]]
name = "cover_status"
description = "Get all curtain/cover status: open or closed."
kind = "shell"
command = "ha-cover-status"

[[tools]]
name = "sensor_status"
description = "Get soil moisture and temperature sensors."
kind = "shell"
command = "ha-sensors"

[[tools]]
name = "get_entity"
description = "Get state of one entity. Pass entity_id as argument, e.g. 'climate.room_air_conditioner'"
kind = "shell"
command = "ha-state"

[[tools]]
name = "light_on"
description = "Turn on a light. Pass JSON body, e.g. '{\"entity_id\":\"light.study_ceiling_lamps\"}'"
kind = "shell"
command = "ha-action light/turn_on"

[[tools]]
name = "light_off"
description = "Turn off a light. Use light.all_lights to turn off ALL lights. Pass JSON body."
kind = "shell"
command = "ha-action light/turn_off"

[[tools]]
name = "set_temperature"
description = "Set AC temperature. Pass JSON: '{\"entity_id\":\"climate.X\",\"temperature\":24}'"
kind = "shell"
command = "ha-action climate/set_temperature"

[[tools]]
name = "set_hvac_mode"
description = "Set AC mode (cool/heat/auto/off). Pass JSON: '{\"entity_id\":\"climate.X\",\"hvac_mode\":\"cool\"}'"
kind = "shell"
command = "ha-action climate/set_hvac_mode"

[[tools]]
name = "open_cover"
description = "Open a curtain/cover. Pass JSON: '{\"entity_id\":\"cover.X\"}'"
kind = "shell"
command = "ha-action cover/open_cover"

[[tools]]
name = "close_cover"
description = "Close a curtain/cover. Pass JSON: '{\"entity_id\":\"cover.X\"}'"
kind = "shell"
command = "ha-action cover/close_cover"

[[tools]]
name = "logbook"
description = "Get recent device activity (last hour). Pass entity_id to filter, e.g. 'light.study_ceiling_lamps'"
kind = "shell"
command = "ha-logbook"

[[tools]]
name = "error_log"
description = "Get Home Assistant system error log — recent errors and warnings."
kind = "shell"
command = "ha-errors"
SKILLEOF

# ==============================================================
# MEMORY_SNAPSHOT.md — pre-seeded entity knowledge
# ==============================================================
cat > "${WS}/MEMORY_SNAPSHOT.md" << 'MEMEOF'
### entity_study_ceiling_lamps
light.study_ceiling_lamps — group of 8 ceiling lights in the study
aliases: study lights, study ceiling, study room lights

### entity_study_spotlights_left
light.study_spotlights_left

### entity_study_spotlights_right
light.study_spotlights_right

### entity_living_room
light.living_room

### entity_bedroom
light.bedroom — group: light.left_bedside + light.right_bedside
aliases: bedroom lights, bedroom

### entity_garden_lights
light.garden_lights — outdoor garden lights

### entity_nursery_lamp
light.nursery_ceiling_lamp
aliases: nursery light, baby room light

### entity_master_bathroom_left
light.master_bathroom_light_left

### entity_master_bathroom_right
light.master_bathroom_light_right

### entity_floor_lamp
light.bedroom_repeater_lamp_switch — bedroom floor lamp
aliases: floor lamp, bedroom lamp

### entity_olive_tree_lights
light.olive_tree_lights — group of 3 olive tree lights in living room
aliases: olive lights, tree lights

### entity_stairs_night_light
light.downstairs_switch_2_left — stairs night light
aliases: stairs light, night light, downstairs night light

### entity_upstairs_light
light.downstairs_switch_right — upstairs light
aliases: upstairs, stairs upstairs

### entity_under_stairs_light
light.downstairs_switch_left — under stairs light
aliases: under stairs

### stairs_lights
Three stair-area lights:
- light.downstairs_switch_2_left (stairs night light)
- light.downstairs_switch_right (upstairs light)
- light.downstairs_switch_left (under stairs light)

### entity_monitor_lights
light.monitor_lights — study desk monitor backlights
aliases: monitor lights, desk lights

### entity_tv_lights
light.tv_lights — group: light.tv_1, light.tv_2, light.tv_3
aliases: TV lights, television lights

### entity_all_lights
light.all_lights — all 43 lights in the house
aliases: all lights, every light, everything

### entity_study_ac
climate.room_air_conditioner — study room AC
aliases: study AC, office AC

### entity_master_bedroom_ac
climate.gr_acunit_6400_02_608d — master bedroom AC
aliases: master AC, bedroom AC, main bedroom AC

### entity_living_room_ac
climate.gr_acunit_6400_02_10b6 — living room / downstairs AC
aliases: living room AC, downstairs AC, lounge AC

### entity_majlis_ac
climate.gr_acunit_6400_02_7a25 — majlis AC
aliases: majlis, sitting room AC

### entity_hall_ac
climate.hall_ac — hall AC
aliases: hall, hallway AC

### entity_entrance_hall_ac
climate.entrance_hall_ac — entrance hall AC
aliases: entrance AC, front hall AC

### entity_food_area_ac
climate.food_area_ac — food area / dining AC
aliases: dining AC, food area

### entity_nursery_ac
climate.nursery — nursery AC
aliases: nursery AC, baby room AC

### entity_weather
weather.pirateweather — local weather data
weather.forecast_home — HA weather forecast

### entity_master_bedroom_curtains
cover.master_bedroom_curtains — master bedroom curtains
aliases: master curtains, bedroom curtains

### entity_blackout_fa_curtain
cover.blackout_fa_curtain — family area blackout curtain
aliases: family area blackout, FA blackout

### entity_chiffon_fa_curtain
cover.chiffon_fa_curtain — family area chiffon curtain
aliases: family area chiffon, FA chiffon

### entity_blackout_hall_curtain
cover.blackout_hall_curtain — hall blackout curtain
aliases: hall blackout

### entity_chiffon_hall_curtain
cover.chiffon_hall_curtain — hall chiffon curtain
aliases: hall chiffon

### entity_chiffon_eh_curtain
cover.chiffon_eh_curtain — entrance hall chiffon curtain
aliases: entrance chiffon, EH chiffon

### entity_blackout_eh_curtain
cover.blackout_eh_curtain — entrance hall blackout curtain
aliases: entrance blackout, EH blackout

### user_language_preference
Yousef communicates in English and Arabic. Always match his language.

### home_location
Al Khobar, Saudi Arabia. Timezone AST (UTC+3). Saudi working week: Sun–Thu.
MEMEOF

bashio::log.info "Config ready | ${DEFAULT_MODEL} + ${COMPLEX_MODEL}"

# --- Session clear on version change ---
VF="${WS}/.last_version"
LV=""; [ -f "$VF" ] && LV="$(cat "$VF")"
if [ "$LV" != "${ADDON_VERSION}" ]; then
    bashio::log.info "Version change: ${LV} → ${ADDON_VERSION}. Clearing sessions."
    rm -rf "${CONFIG_DIR}/workspace/sessions"* "${CONFIG_DIR}/brain.db" 2>/dev/null
    echo "${ADDON_VERSION}" > "$VF"
fi

# --- Daily check-in cron (8am AST = 5am UTC) ---
mkdir -p /etc/crontabs
cat > /etc/crontabs/root << 'CRONEOF'
# ZeroClaw daily check-in — 8am AST (5am UTC)
0 5 * * * /usr/local/bin/ha-daily-report
# Keep log file under 1MB
0 4 * * 0 truncate -s 0 /data/logs/daily-report.log
CRONEOF

busybox crond -b -l 8 -L /data/logs/crond.log
bashio::log.info "Crond started (daily check-in at 08:00 AST)"

# --- Start ZeroClaw with auto-restart ---
CRASH_COUNT=0
while true; do
    zeroclaw daemon --config-dir "${CONFIG_DIR}"
    EXIT_CODE=$?
    CRASH_COUNT=$((CRASH_COUNT + 1))
    bashio::log.warn "ZeroClaw exited (code ${EXIT_CODE}, restart #${CRASH_COUNT})"
    if [ $CRASH_COUNT -ge 10 ]; then
        bashio::log.fatal "ZeroClaw crashed 10 times — giving up. Check logs."
        exit 1
    fi
    bashio::log.info "Restarting in 5s..."
    sleep 5
done
