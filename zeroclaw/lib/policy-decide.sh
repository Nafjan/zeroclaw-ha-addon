#!/bin/sh
# policy-decide.sh — pure, stateless ZeroClaw policy decision function.
#
# Given an HA service call (domain/action/entity) and policy environment,
# prints a single verdict line to stdout:
#
#   allow:<reason>
#   deny:<reason>
#   confirm:<reason>
#
# No side effects. No HA API calls. No file writes. No tickets created here.
# The caller (ha-action-guarded) is responsible for executing, auditing, and
# drafting confirmation tickets.
#
# Usage:
#   policy-decide.sh <domain> <action> <entity> [body_json]
#
# Environment (all optional; sensible defaults):
#   POLICY_MODE                  strict|balanced|permissive|custom  (default: balanced)
#   POLICY_QUIET_CONFIRM         true|false                          (default: true)
#   POLICY_BULK_THRESHOLD        integer                             (default: 3)
#   POLICY_CLIMATE_DELTA         integer (°C)                        (default: 3)
#   QUIET_HOURS                  HH:MM-HH:MM                         (default: 23:00-06:00)
#   EXTRA_DENY                   comma-separated globs               (default: "")
#   EXTRA_CONFIRM                comma-separated globs               (default: "")
#   EXTRA_ALLOW                  comma-separated globs               (default: "")
#
# Test/override hooks (let CI exercise time-dependent paths deterministically):
#   POLICY_NOW_HOUR              0-23, override for `date +%H`
#   POLICY_CLIMATE_CURRENT       float, override for current temp lookup
#                                (when unset for set_temperature, verdict is
#                                 allow:climate_no_baseline)
#   POLICY_BULK_COUNT            integer, override for entity_id list length
#                                (when set ≥ POLICY_BULK_THRESHOLD, forces confirm)
#
# Exit codes: always 0; the verdict prefix tells the caller what happened.

set -eu

POLICY_MODE="${POLICY_MODE:-balanced}"
POLICY_QUIET_CONFIRM="${POLICY_QUIET_CONFIRM:-true}"
POLICY_BULK_THRESHOLD="${POLICY_BULK_THRESHOLD:-3}"
POLICY_CLIMATE_DELTA="${POLICY_CLIMATE_DELTA:-3}"
QUIET_HOURS="${QUIET_HOURS:-23:00-06:00}"
EXTRA_DENY="${EXTRA_DENY:-}"
EXTRA_CONFIRM="${EXTRA_CONFIRM:-}"
EXTRA_ALLOW="${EXTRA_ALLOW:-}"

DOMAIN="${1:-}"
ACTION="${2:-}"
ENTITY="${3:-}"
BODY="${4:-}"

if [ -z "$DOMAIN" ] || [ -z "$ACTION" ]; then
    echo "deny:bad_input"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Pattern helpers
# ---------------------------------------------------------------------------
match_glob() {
    pat="$1"; val="$2"
    # shellcheck disable=SC2254
    # Intentional: $pat is a user-supplied glob and MUST stay unquoted so
    # case treats it as a pattern (e.g. "light.kids_*"), not a literal.
    case "$val" in
        $pat) return 0 ;;
        *)    return 1 ;;
    esac
}

# Iterate over comma-separated patterns; emit "match" for the first hit.
first_match() {
    list="$1"; val="$2"
    [ -z "$list" ] && return 1
    OLDIFS="$IFS"
    IFS=','
    for pat in $list; do
        IFS="$OLDIFS"
        [ -z "$pat" ] && continue
        if match_glob "$pat" "$val"; then
            echo "$pat"
            return 0
        fi
    done
    IFS="$OLDIFS"
    return 1
}

# ---------------------------------------------------------------------------
# 2. Extras: deny first → allow → confirm
#    (we prefer to DENY-list first so that an entity in both deny and allow
#     is denied — safer default)
# ---------------------------------------------------------------------------
VERDICT=""

if HIT=$(first_match "$EXTRA_DENY" "$ENTITY"); then
    VERDICT="deny:extra_deny:$HIT"
elif HIT=$(first_match "$EXTRA_ALLOW" "$ENTITY"); then
    VERDICT="allow:extra_allow:$HIT"
elif HIT=$(first_match "$EXTRA_CONFIRM" "$ENTITY"); then
    VERDICT="confirm:extra_confirm:$HIT"
fi

# ---------------------------------------------------------------------------
# 3. Hard-coded deny domains (always blocked, regardless of mode/extras)
# ---------------------------------------------------------------------------
case "$VERDICT" in
    deny:*) ;;  # extras already denied
    *)
        case "$DOMAIN" in
            lock|alarm_control_panel|camera|device_tracker)
                VERDICT="deny:hard_block:$DOMAIN"
                ;;
        esac
        ;;
esac

# ---------------------------------------------------------------------------
# 4. Domain defaults (mode-tuned)
# ---------------------------------------------------------------------------
if [ -z "$VERDICT" ]; then
    case "$DOMAIN" in
        light|scene|script|input_boolean|input_number|input_select|media_player)
            VERDICT="allow:default_$DOMAIN"
            ;;
        climate)
            VERDICT="climate_check"
            ;;
        cover|switch)
            if [ "$POLICY_MODE" = "permissive" ]; then
                VERDICT="allow:permissive_$DOMAIN"
            else
                VERDICT="confirm:default_$DOMAIN"
            fi
            ;;
        *)
            if [ "$POLICY_MODE" = "strict" ]; then
                VERDICT="deny:strict_unknown_domain:$DOMAIN"
            else
                VERDICT="confirm:unknown_domain:$DOMAIN"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 5. Climate delta check (only when verdict is climate_check)
# ---------------------------------------------------------------------------
if [ "$VERDICT" = "climate_check" ]; then
    if [ "$ACTION" = "set_temperature" ]; then
        # Test override wins; then jq if available; then sed fallback for plain JSON.
        TARGET="${POLICY_CLIMATE_TARGET:-}"
        if [ -z "$TARGET" ] && [ -n "$BODY" ]; then
            if command -v jq >/dev/null 2>&1; then
                TARGET=$(echo "$BODY" | jq -r '.temperature // empty' 2>/dev/null || true)
            fi
            if [ -z "$TARGET" ]; then
                # crude but reliable: "temperature": 23 or "temperature":23
                TARGET=$(echo "$BODY" | sed -n 's/.*"temperature"[[:space:]]*:[[:space:]]*\([0-9.]\{1,\}\).*/\1/p' | head -1)
            fi
        fi
        CUR="${POLICY_CLIMATE_CURRENT:-}"
        if [ -n "$TARGET" ] && [ -n "$CUR" ]; then
            DELTA=$(awk -v a="$TARGET" -v b="$CUR" 'BEGIN{d=a-b;if(d<0)d=-d;print int(d+0.5)}')
            if [ "$DELTA" -gt "$POLICY_CLIMATE_DELTA" ]; then
                VERDICT="confirm:climate_delta_${DELTA}c"
            else
                VERDICT="allow:climate_within_delta_${DELTA}c"
            fi
        else
            VERDICT="allow:climate_no_baseline"
        fi
    else
        VERDICT="allow:climate_$ACTION"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Bulk action check — escalate allow→confirm when the body targets many
#    entities at once. Caller passes count via POLICY_BULK_COUNT (counted
#    server-side because we don't want to JSON-parse arrays in pure shell).
# ---------------------------------------------------------------------------
if [ -n "${POLICY_BULK_COUNT:-}" ] && [ "$POLICY_BULK_COUNT" -ge "$POLICY_BULK_THRESHOLD" ]; then
    case "$VERDICT" in
        allow:*) VERDICT="confirm:bulk_action_${POLICY_BULK_COUNT}" ;;
    esac
fi

# ---------------------------------------------------------------------------
# 7. Quiet hours — escalate allow→confirm during the configured window
# ---------------------------------------------------------------------------
if [ "$POLICY_QUIET_CONFIRM" = "true" ]; then
    NOW_H="${POLICY_NOW_HOUR:-$(date +%H)}"
    QH_START=$(echo "$QUIET_HOURS" | cut -d- -f1 | cut -d: -f1 | sed 's/^0*//')
    QH_END=$(echo "$QUIET_HOURS" | cut -d- -f2 | cut -d: -f1 | sed 's/^0*//')
    NOW_H=$(echo "$NOW_H" | sed 's/^0*//')
    [ -z "$QH_START" ] && QH_START=0
    [ -z "$QH_END" ] && QH_END=0
    [ -z "$NOW_H" ] && NOW_H=0
    IN_QUIET=0
    if [ "$QH_START" -gt "$QH_END" ]; then
        # window crosses midnight (e.g. 23-06)
        if [ "$NOW_H" -ge "$QH_START" ] || [ "$NOW_H" -lt "$QH_END" ]; then
            IN_QUIET=1
        fi
    else
        if [ "$NOW_H" -ge "$QH_START" ] && [ "$NOW_H" -lt "$QH_END" ]; then
            IN_QUIET=1
        fi
    fi
    if [ "$IN_QUIET" = "1" ]; then
        case "$DOMAIN" in
            light|climate|cover|switch)
                case "$VERDICT" in
                    allow:*) VERDICT="confirm:quiet_hours_${NOW_H}h" ;;
                esac
                ;;
        esac
    fi
fi

echo "$VERDICT"
