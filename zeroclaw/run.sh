#!/usr/bin/with-contenv bashio

# ZeroClaw HAOS Add-on v3.1.0 — adds creation skill + reverse triggers
# (policy engine extracted into /opt/zeroclaw/lib/policy-decide.sh, bats-tested)

ADDON_VERSION="3.1.0"
bashio::log.info "ZeroClaw v${ADDON_VERSION} starting..."

# ==============================================================
# Bashio config reads (all 36 options)
# ==============================================================
OPENROUTER_KEY="$(bashio::config 'openrouter_api_key')"
HA_TOKEN="$(bashio::config 'ha_token')"
TELEGRAM_TOKEN="$(bashio::config 'telegram_bot_token')"
TELEGRAM_USERS="$(bashio::config 'telegram_allowed_users')"
DEFAULT_MODEL="$(bashio::config 'default_model')"
COMPLEX_MODEL="$(bashio::config 'complex_model')"
LOG_LEVEL="$(bashio::config 'log_level')"

DAILY_COST_LIMIT="$(bashio::config 'daily_cost_limit_usd')"
MONTHLY_COST_LIMIT="$(bashio::config 'monthly_cost_limit_usd')"
MAX_ACTIONS_PER_HOUR="$(bashio::config 'max_actions_per_hour')"
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
ENABLE_UNDO="$(bashio::config 'enable_undo')"
AUDIT_RETENTION_DAYS="$(bashio::config 'audit_retention_days')"

POLICY_MODE="$(bashio::config 'policy_mode')"
POLICY_QUIET_CONFIRM="$(bashio::config 'policy_quiet_hours_require_confirm')"
POLICY_BULK_THRESHOLD="$(bashio::config 'policy_bulk_action_threshold')"
POLICY_CLIMATE_DELTA="$(bashio::config 'policy_climate_delta_confirm_c')"
POLICY_TRUST_ENABLED="$(bashio::config 'policy_trust_enabled')"
POLICY_TRUST_PROMOTE="$(bashio::config 'policy_trust_promote_after')"

# Lists — bashio outputs newline-separated for list(str). Convert to comma-joined for shell use.
POLICY_EXTRA_DENY=$(bashio::config 'policy_extra_deny' | tr '\n' ',' | sed 's/,$//')
POLICY_EXTRA_CONFIRM=$(bashio::config 'policy_extra_confirm' | tr '\n' ',' | sed 's/,$//')
POLICY_EXTRA_ALLOW=$(bashio::config 'policy_extra_allow' | tr '\n' ',' | sed 's/,$//')

export ZEROCLAW_API_KEY="${OPENROUTER_KEY}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_TOKEN}"
export HA_TOKEN="${HA_TOKEN}"
export RUST_LOG="${LOG_LEVEL}"

for var in OPENROUTER_KEY TELEGRAM_TOKEN HA_TOKEN; do
    eval val=\$$var
    [ -z "$val" ] && { bashio::log.fatal "${var} not set!"; exit 1; }
done

# Telegram users → TOML array + first user (for Bot API direct sends)
USERS_TOML=$(echo "$TELEGRAM_USERS" | tr ',' '\n' | tr -d ' ' | \
    awk 'NF{printf "\"%s\", ", $0}' | sed 's/, $//')
FIRST_USER=$(echo "$TELEGRAM_USERS" | cut -d',' -f1 | tr -d ' ')

# Daily report time AST → UTC for cron (HOME location is AST = UTC+3)
REPORT_HOUR=$(echo "$DAILY_REPORT_TIME" | cut -d: -f1 | sed 's/^0*//')
REPORT_MIN=$(echo "$DAILY_REPORT_TIME" | cut -d: -f2 | sed 's/^0*//')
[ -z "$REPORT_HOUR" ] && REPORT_HOUR=0
[ -z "$REPORT_MIN" ] && REPORT_MIN=0
REPORT_UTC_HOUR=$(( (REPORT_HOUR - 3 + 24) % 24 ))

CONFIG_DIR="/data"
WS="${CONFIG_DIR}/workspace"
HA_URL="http://172.30.32.1:8123/api"
GW="http://127.0.0.1:42617"
mkdir -p "${WS}/skills/ha" /data/logs /data/pending /data/approved /data/audit /data/undo /data/tools

# ==============================================================
# HA helper scripts (read-only) — tokens embedded at startup
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

cat > /usr/local/bin/ha-state << SCRIPT
#!/bin/sh
# Usage: ha-state <entity_id>
curl -s -H "Authorization: Bearer ${HA_TOKEN}" "${HA_URL}/states/\$1" | \
  jq -r '"\(.attributes.friendly_name // .entity_id): \(.state)\(if .attributes.temperature then " set:\(.attributes.temperature)C" else "" end)\(if .attributes.current_temperature then " now:\(.attributes.current_temperature)C" else "" end)"'
SCRIPT

cat > /usr/local/bin/ha-all-status << 'SCRIPT'
#!/bin/sh
echo "=LIGHTS="
ha-lights-on 2>/dev/null || echo "(none)"
echo "=AC="
ha-ac-status 2>/dev/null || echo "(unavailable)"
echo "=COVERS="
ha-cover-status 2>/dev/null || echo "(unavailable)"
SCRIPT

cat > /usr/local/bin/ha-logbook << SCRIPT
#!/bin/sh
NOW=\$(date -u +%Y-%m-%dT%H:%M:%S)
AGO24=\$(date -u -d @\$(( \$(date +%s) - 86400 )) +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "\$NOW")
if [ -n "\$1" ]; then
    curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
      "${HA_URL}/logbook/\${AGO24}?entity=\$1&end_time=\${NOW}" | \
      jq -r '.[] | "\(.when): \(.name) \(.message)"' 2>/dev/null || echo "No logbook data"
else
    AGO1=\$(date -u -d @\$(( \$(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "\$NOW")
    curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
      "${HA_URL}/logbook/\${AGO1}" | \
      jq -r '.[-20:] | .[] | "\(.when): \(.name) \(.message)"' 2>/dev/null || echo "No logbook data"
fi
SCRIPT

cat > /usr/local/bin/ha-errors << SCRIPT
#!/bin/sh
curl -s -H "Authorization: Bearer ${HA_TOKEN}" "${HA_URL}/error_log" | tail -40
SCRIPT

# Raw action — never called directly by the agent. ha-action-guarded calls this.
cat > /usr/local/bin/ha-action-raw << SCRIPT
#!/bin/sh
# Usage: ha-action-raw <service_path> <json_body>
curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" -H "Content-Type: application/json" \
  "${HA_URL}/services/\$1" -d "\$2"
SCRIPT

# ==============================================================
# Policy engine — /config/zeroclaw_policy.yaml seed
# ==============================================================
POLICY_FILE="/config/zeroclaw_policy.yaml"
if [ ! -f "$POLICY_FILE" ]; then
    bashio::log.info "Seeding default policy at ${POLICY_FILE}"
    mkdir -p /config
    cat > "$POLICY_FILE" << 'POLEOF'
# ZeroClaw policy — owned by you, never edited by the LLM.
# Resolution order on every action: entity_overrides → time_rules → defaults.
# Verdicts: allow (auto), confirm (Telegram approval), deny (refused).
version: 1
mode: balanced  # mirrors the add-on's policy_mode option; this file wins on conflict
defaults:
  light:        allow
  climate:      confirm_if_delta_gt: 3
  scene:        allow
  script:       allow
  switch:       confirm
  cover:        confirm
  media_player: allow
  input_boolean: allow
  input_number: allow
  input_select: allow
deny:
  - lock.*
  - alarm_control_panel.*
  - camera.*
  - device_tracker.*
confirm_always:
  bulk_action_gt: 3
  during_quiet_hours: true
  any_creation: true
  any_deletion: true
entity_overrides:
  # switch.water_heater: confirm
  # light.kids_room: confirm_after: "21:00"
time_rules: []
trust:
  enabled: true
  promote_after: 5
  promote_window_days: 14
  excluded:
    - lock.*
    - alarm_control_panel.*
    - any_creation
    - any_deletion
audit_all: true
POLEOF
fi

# ==============================================================
# Install pure-function policy decider from /opt/zeroclaw/lib/
# (covered by zeroclaw/tests/policy_decide.bats — see CI)
# ==============================================================
install -m 0755 /opt/zeroclaw/lib/policy-decide.sh /usr/local/bin/policy-decide

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
    UUID="\$2"
    MARKER="/data/approved/\${UUID}.marker"
    TICKET="/data/pending/\${UUID}.json"
    [ ! -f "\$MARKER" ] && { echo "ERROR: ticket \${UUID} not approved"; exit 1; }
    [ ! -f "\$TICKET" ] && { echo "ERROR: ticket \${UUID} missing"; exit 1; }
    SVC=\$(jq -r .service "\$TICKET")
    BODY=\$(jq -c .payload "\$TICKET")
    OUT=\$(/usr/local/bin/ha-action-raw "\$SVC" "\$BODY")
    /usr/local/bin/zc-audit-write apply "\$SVC" "\$BODY" "ticket=\${UUID}"
    rm -f "\$MARKER" "\$TICKET"
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
    CUR=\$(curl -s -H "Authorization: Bearer ${HA_TOKEN}" \
        "${HA_URL}/states/\$ENTITY" 2>/dev/null | \
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
            curl -s -H "Authorization: Bearer ${HA_TOKEN}" "${HA_URL}/states/\$ENTITY" \
                > "/data/undo/\$(date -u +%s)-\${ENTITY//./_}.json" 2>/dev/null || true
        fi
        OUT=\$(/usr/local/bin/ha-action-raw "\$SERVICE" "\$BODY")
        /usr/local/bin/zc-audit-write allow "\$SERVICE" "\$BODY" "\$VERDICT"
        echo "\$OUT"
        exit 0 ;;
    deny)
        /usr/local/bin/zc-audit-write deny "\$SERVICE" "\$BODY" "\$VERDICT"
        echo "DENIED by policy: \$VERDICT. To allow, edit /config/zeroclaw_policy.yaml or change policy_extra_allow in add-on options."
        exit 1 ;;
    confirm)
        UUID=\$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "\$RANDOM-\$RANDOM-\$RANDOM-\$\$")
        # Short UUID for chat ergonomics
        SHORT=\$(echo "\$UUID" | cut -c1-8)
        EXP=\$(( \$(date -u +%s) + 1800 ))
        TICKET="/data/pending/\${SHORT}.json"
        SUMMARY="\${SERVICE} on \${ENTITY:-(no entity)} — \$VERDICT"
        cat > "\$TICKET" << TEOF
{
  "uuid": "\${SHORT}",
  "service": "\${SERVICE}",
  "payload": \${BODY},
  "summary": "\${SUMMARY}",
  "expires_at": \${EXP},
  "created_at": \$(date -u +%s),
  "verdict": "\${VERDICT}"
}
TEOF
        # Telegram heads-up to the user
        MSG="⚠️ Approval needed (\${SHORT})
\${SUMMARY}
Reply  YES \${SHORT}  to apply, or  NO \${SHORT}  to reject.
Expires in 30 min."
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
          --data-urlencode "chat_id=${FIRST_USER}" \
          --data-urlencode "text=\${MSG}" >/dev/null 2>&1 || true
        /usr/local/bin/zc-audit-write confirm "\$SERVICE" "\$BODY" "ticket=\${SHORT};\${VERDICT}"
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
KIND="$1"; SVC="$2"; BODY="$3"; REASON="$4"
DATE=$(date -u +%Y-%m-%d)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENTITY=$(echo "$BODY" | jq -r '.entity_id // ""' 2>/dev/null)
mkdir -p /data/audit
ROW=$(jq -nc \
  --arg ts "$TS" --arg kind "$KIND" --arg svc "$SVC" \
  --arg entity "$ENTITY" --arg reason "$REASON" --argjson body "$BODY" \
  '{ts:$ts, kind:$kind, service:$svc, entity:$entity, body:$body, reason:$reason}')
echo "$ROW" >> "/data/audit/${DATE}.jsonl"
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
[ "${ENABLE_UNDO}" != "true" ] && { echo "Undo is disabled in add-on options."; exit 1; }
N=\${1:-1}
NOW=\$(date -u +%s)
CUTOFF=\$(( NOW - 3600 ))
COUNT=0
ls -1t /data/undo/*.json 2>/dev/null | while read F; do
    [ "\$COUNT" -ge "\$N" ] && break
    TS=\$(basename "\$F" | cut -d- -f1)
    [ "\$TS" -lt "\$CUTOFF" ] && continue
    ENTITY=\$(jq -r .entity_id "\$F" 2>/dev/null)
    DOMAIN=\${ENTITY%%.*}
    STATE=\$(jq -r .state "\$F")
    # Best-effort restore — domain-specific
    case "\$DOMAIN" in
        light|switch|input_boolean)
            SVC="\${DOMAIN}/turn_\${STATE}"
            /usr/local/bin/ha-action-raw "\$SVC" "{\"entity_id\":\"\$ENTITY\"}" >/dev/null 2>&1 ;;
        climate)
            TEMP=\$(jq -r .attributes.temperature "\$F")
            MODE=\$(jq -r .attributes.hvac_mode "\$F")
            [ -n "\$TEMP" ] && [ "\$TEMP" != "null" ] && \
                /usr/local/bin/ha-action-raw "climate/set_temperature" \
                "{\"entity_id\":\"\$ENTITY\",\"temperature\":\$TEMP}" >/dev/null 2>&1
            [ -n "\$MODE" ] && [ "\$MODE" != "null" ] && \
                /usr/local/bin/ha-action-raw "climate/set_hvac_mode" \
                "{\"entity_id\":\"\$ENTITY\",\"hvac_mode\":\"\$MODE\"}" >/dev/null 2>&1 ;;
        cover)
            CSVC=\$([ "\$STATE" = "open" ] && echo "open_cover" || echo "close_cover")
            /usr/local/bin/ha-action-raw "cover/\$CSVC" "{\"entity_id\":\"\$ENTITY\"}" >/dev/null 2>&1 ;;
    esac
    rm -f "\$F"
    /usr/local/bin/zc-audit-write undo "\$DOMAIN/restore" "{\"entity_id\":\"\$ENTITY\"}" "restored_to=\$STATE"
    COUNT=\$((COUNT + 1))
    echo "Reverted \$ENTITY → \$STATE"
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
# Usage: zc-approve "<verbatim user message>"
MSG="$1"
SHORT=$(echo "$MSG" | sed -nE 's/^[Yy][Ee][Ss][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p')
if [ -z "$SHORT" ]; then echo "ERROR: message is not 'YES <id>'"; exit 1; fi
TICKET="/data/pending/${SHORT}.json"
[ ! -f "$TICKET" ] && { echo "ERROR: no ticket ${SHORT}"; exit 1; }
EXP=$(jq -r .expires_at "$TICKET")
NOW=$(date -u +%s)
if [ "$NOW" -gt "$EXP" ]; then
    rm -f "$TICKET"
    echo "ERROR: ticket ${SHORT} expired"
    exit 1
fi
mkdir -p /data/approved
touch "/data/approved/${SHORT}.marker"
echo "APPROVED ${SHORT}"
SCRIPT

cat > /usr/local/bin/zc-reject << 'SCRIPT'
#!/bin/sh
MSG="$1"
SHORT=$(echo "$MSG" | sed -nE 's/^[Nn][Oo][[:space:]]+([a-f0-9]{8})[[:space:]]*$/\1/p')
[ -z "$SHORT" ] && { echo "ERROR: not 'NO <id>'"; exit 1; }
rm -f "/data/pending/${SHORT}.json" "/data/approved/${SHORT}.marker"
echo "REJECTED ${SHORT}"
SCRIPT

# ==============================================================
# zc-schedule — agent self-scheduling via ZeroClaw cron API
# ==============================================================
cat > /usr/local/bin/zc-schedule << SCRIPT
#!/bin/sh
# Usage: zc-schedule '<cron-expr>' '<message-to-self>' [name]
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
LIGHTS_ON=\$(/usr/local/bin/ha-lights-on 2>/dev/null | grep -c . || echo 0)
LIGHTS_LIST=\$(/usr/local/bin/ha-lights-on 2>/dev/null | head -3 | awk -F: '{print \$1}' | tr '\n' ',' | sed 's/,$//')
ACS_ON=\$(/usr/local/bin/ha-ac-status 2>/dev/null | grep -v ' off' | grep -c . || echo 0)
ACS_DETAIL=\$(/usr/local/bin/ha-ac-status 2>/dev/null | grep -v ' off' | head -2 | tr '\n' ';')
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
PENDING=\$(ls /data/pending/*.json 2>/dev/null | wc -l)
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
#        '{"light.living_room":{"state":"on","brightness":76}}'
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
  --argjson exp \$EXP --argjson cre \$(date -u +%s) \\
  '{uuid:\$uuid,service:\$svc,payload:\$p,summary:\$sum,expires_at:\$exp,created_at:\$cre,verdict:\$verdict}' \\
  > "\$TICKET"
MSG="🆕 Create scene? (\${SHORT})
\${SUMMARY}
Reply  YES \${SHORT}  to create, or  NO \${SHORT}  to discard.
Expires in 30 min."
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \\
  --data-urlencode "chat_id=${FIRST_USER}" --data-urlencode "text=\${MSG}" >/dev/null 2>&1 || true
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
  --argjson exp \$EXP --argjson cre \$(date -u +%s) \\
  '{uuid:\$uuid,service:\$svc,payload:\$p,summary:\$sum,expires_at:\$exp,created_at:\$cre,verdict:\$verdict}' \\
  > "\$TICKET"
MSG="🆕 Create automation? (\${SHORT})
\${SUMMARY}
Reply  YES \${SHORT}  to create, or  NO \${SHORT}  to discard.
Expires in 30 min."
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \\
  --data-urlencode "chat_id=${FIRST_USER}" --data-urlencode "text=\${MSG}" >/dev/null 2>&1 || true
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
UUID="\$1"
MARKER="/data/approved/\${UUID}.marker"
TICKET="/data/pending/\${UUID}.json"
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
    curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" \\
        "${HA_URL}/services/scene/reload" >/dev/null 2>&1 || true
    /usr/local/bin/zc-audit-write apply "scene/create" "\$ENTITIES" "scene=\${SID};ticket=\${UUID}"
    rm -f "\$MARKER" "\$TICKET"
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
    curl -s -X POST -H "Authorization: Bearer ${HA_TOKEN}" \\
        "${HA_URL}/services/automation/reload" >/dev/null 2>&1 || true
    /usr/local/bin/zc-audit-write apply "automation/create" "{\"alias\":\"\${ALIAS}\"}" "ticket=\${UUID}"
    rm -f "\$MARKER" "\$TICKET"
    echo "Automation '\${ALIAS}' created and reloaded." ;;
  *)
    echo "ERROR: unknown creation kind: \$KIND"; exit 1 ;;
esac
SCRIPT

# Make every helper executable
chmod +x /usr/local/bin/ha-* /usr/local/bin/zc-*

# ==============================================================
# config.toml
# ==============================================================
cat > "${CONFIG_DIR}/config.toml" << TOMLEOF
default_provider = "openrouter"
default_model = "${DEFAULT_MODEL}"
default_temperature = 0.2
provider_timeout_secs = 20
provider_max_tokens = ${PROVIDER_MAX_TOKENS}

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
max_tool_iterations = ${MAX_TOOL_ITER}
max_history_messages = ${MAX_HISTORY_MSGS}
max_context_tokens = ${MAX_CONTEXT_TOKENS}

[autonomy]
level = "full"
workspace_only = false
max_actions_per_hour = ${MAX_ACTIONS_PER_HOUR}
allowed_commands = ["ha-lights-on", "ha-ac-status", "ha-cover-status", "ha-sensors", "ha-state", "ha-all-status", "ha-logbook", "ha-errors", "ha-action-guarded", "ha-create-scene", "ha-create-automation", "ha-create-routine", "ha-run-routine", "ha-apply-creation", "zc-schedule", "zc-schedule-once", "zc-audit-tail", "zc-undo", "zc-cost", "zc-world-state", "zc-approve", "zc-reject", "curl", "jq", "cat", "echo", "ls", "grep", "head", "tail", "date"]
require_approval_for_medium_risk = false
block_high_risk_commands = false

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
enabled = true
allowed_domains = ["*"]
max_response_size = 200000
timeout_secs = 10
allow_private_hosts = true

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
"${COMPLEX_MODEL}" = ["${DEFAULT_MODEL}"]

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

When the user replies "YES <id>" or "NO <id>":
  1. Call zc-approve "<exact user message>"  (or zc-reject for NO)
  2. If approved, call: ha-action-guarded --apply-ticket <id>
  3. Write the resulting outcome line.

## AC actions — pre-check first
Before set_temperature / set_hvac_mode, call ha.get_entity. If state already matches request,
skip the action and write: "Study AC is already at 24°C." Save tool calls.

## Decision tree for ambiguous requests
"turn off the lights" with no scope:
  • If exactly one light is on → act, write specific outcome.
  • If multiple → ask: "Which? all / specific room / a specific light?"
"make it cooler / warmer" → call ha.get_entity first, propose ±2°C delta, then apply.

## Outcome lines (positive examples)
Lights:    "Study ceiling lamps on."   "Bedroom lights off."   "All lights off."
AC:        "Study AC → 24°C."          "Master AC off."        "Living AC → cool mode."
Covers:    "Master bedroom curtains opened."   "Hall blackout closed."
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
plain-English summary and ticket id. After they reply YES <id>:
  1. zc-approve "<verbatim YES <id>>"
  2. ha-apply-creation <id>     (for scene/automation; routines persist immediately)
  3. Write a one-line outcome.
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
  "light.living_room": {"state": "on", "brightness": 200},
  "light.tv_lights":   {"state": "on", "brightness": 80},
  "climate.living_room_ac": {"state": "cool", "temperature": 22}
}'
```
Rules:
- scene_id: lowercase + underscores only (e.g. `movie_night`, not `Movie Night`).
- States must be valid JSON; the helper rejects malformed input before queueing.
- After approval, the scene is callable via `scene.<scene_id>` in HA.

## 2. Automation — trigger → action with optional condition
Use when the user says: "every morning at 7 turn on study lights" or similar.

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
      entity_id: light.study_ceiling_lamps"
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
  {"service":"light/turn_off","payload":{"entity_id":"light.all_lights"}},
  {"service":"climate/set_temperature","payload":{"entity_id":"climate.bedroom","temperature":21}},
  {"service":"cover/close_cover","payload":{"entity_id":"cover.master_bedroom_curtains"}}
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
    e.g. ha.action_guarded 'light/turn_on' '{"entity_id":"light.study_ceiling_lamps"}'
    e.g. ha.action_guarded 'climate/set_temperature' '{"entity_id":"climate.bedroom","temperature":22}'
- ha.action_guarded --apply-ticket <id8>   — apply an approved ticket

ZC. (ZeroClaw self-tools):
- zc.schedule '<cron>' '<msg-to-self>' [name]   — recurring task
- zc.schedule_once <min> '<msg>'                — one-off delay
- zc.audit_tail [N]                              — recent actions
- zc.undo [N]                                    — revert last N actions (1h window)
- zc.cost                                        — current spend
- zc.world_state                                 — refresh world state
- zc.approve "<verbatim YES <id>>"               — bridge user approval
- zc.reject  "<verbatim NO <id>>"                — bridge user rejection

WARNING: never call http_request GET /api/states — payload too large.
TOOLSEOF

# ==============================================================
# USER.md (parameterized from add-on config)
# ==============================================================
cat > "${WS}/USER.md" << USEREOF
## Home context
- Owner: Yousef
- Location: ${HOME_LOCATION}
- Languages: ${HOME_LANGUAGES}
- Quiet hours: ${QUIET_HOURS}
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

All write actions route through ha-action-guarded which enforces the user's policy
in /config/zeroclaw_policy.yaml. The gate returns CONFIRM_PENDING for actions that
need approval; relay the ticket id to the user.

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
name = "approve"
description = "Bridge a user 'YES <id>' message to the harness. Pass the verbatim user message."
kind = "shell"
command = "zc-approve"

[[tools]]
name = "reject"
description = "Bridge a user 'NO <id>' message. Pass the verbatim user message."
kind = "shell"
command = "zc-reject"
SKILLEOF

# v3.1: append creation tools to the ha skill only when the feature is on
if [ "${ENABLE_CREATION}" = "true" ]; then
cat >> "${WS}/skills/ha/SKILL.md" << 'CRSKILLEOF'

[[tools]]
name = "create_scene"
description = "Draft a new HA scene. Args: <scene_id> '<friendly name>' '<json entity_states>'. Returns CONFIRM_PENDING ticket=<id8>; relay it to user. After 'YES <id>' approval: zc.approve then ha.apply_creation <id>."
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
# MEMORY_SNAPSHOT.md — preserved entity knowledge
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

bashio::log.info "Config ready | mode=${POLICY_MODE} | ${DEFAULT_MODEL} + ${COMPLEX_MODEL}"

# ==============================================================
# Session clear on version change
# ==============================================================
VF="${WS}/.last_version"
LV=""; [ -f "$VF" ] && LV="$(cat "$VF")"
if [ "$LV" != "${ADDON_VERSION}" ]; then
    bashio::log.info "Version change: ${LV:-fresh} → ${ADDON_VERSION}. Clearing sessions."
    rm -rf "${CONFIG_DIR}/workspace/sessions"* "${CONFIG_DIR}/brain.db" 2>/dev/null
    echo "${ADDON_VERSION}" > "$VF"
fi

# ==============================================================
# Audit/undo retention cleanup (one-shot at startup)
# ==============================================================
find /data/audit -name '*.jsonl' -mtime +"${AUDIT_RETENTION_DAYS}" -delete 2>/dev/null || true
find /data/undo  -name '*.json'  -mmin  +60                       -delete 2>/dev/null || true
find /data/pending -name '*.json' -mmin +60                        -delete 2>/dev/null || true
find /data/approved -name '*.marker' -mmin +60                     -delete 2>/dev/null || true

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

    # Hourly cleanup of expired tickets/markers/undo snapshots
    CLEAN_MSG="@noop cleanup tick"
    curl -s -X POST "${GW}/api/cron" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg n zc_pending_cleanup --arg s '0 * * * *' --arg c "$CLEAN_MSG" '{name:$n,schedule:$s,command:$c}')" >/dev/null 2>&1
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
        if [ "$OVER" = "1" ] && [ ! -f /data/.cost_degraded ]; then
            touch /data/.cost_degraded
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${FIRST_USER}" \
                --data-urlencode "text=⚠️ Cost watchdog: today's spend \$${TODAY} > 80% of \$${LIMIT}. Routing to cheap model only." >/dev/null 2>&1 || true
        fi
        # Reset flag at midnight UTC (fresh day)
        H=$(date -u +%H); M=$(date -u +%M)
        if [ "$H" = "00" ] && [ "$M" -lt 5 ]; then
            rm -f /data/.cost_degraded 2>/dev/null
        fi
    done
) &

# ==============================================================
# Start ZeroClaw with auto-restart loop
# ==============================================================
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
