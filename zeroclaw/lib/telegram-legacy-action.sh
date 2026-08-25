#!/bin/sh
# Recover the exact guarded action form emitted by older/non-tool-capable
# models. This is deliberately narrower than a shell parser: either one
# non-empty line or the exact three-line Markdown fence seen in legacy output,
# one canonical guarded call, an object payload, and services already accepted by the typed capability broker are eligible.
#
# The action still goes through ha-action-guarded. This helper never executes
# model text as shell and never grants an approval or bypasses policy.
set -u

LEGACY_ACTION_GATE="${ZEROCLAW_LEGACY_ACTION_GATE:-/usr/local/bin/ha-action-guarded}"

[ "$#" -eq 1 ] || exit 2
REPLY="$1"
[ "${#REPLY}" -le 8192 ] || exit 2

NON_EMPTY_LINES=$(printf '%s\n' "$REPLY" | awk 'NF { count++ } END { print count + 0 }')
case "$NON_EMPTY_LINES" in
    1)
        LINE=$(printf '%s\n' "$REPLY" | awk 'NF { sub(/\r$/, ""); print; exit }')
        ;;
    3)
        FENCE_START=$(printf '%s\n' "$REPLY" | sed -n '1p' | sed 's/\r$//')
        FENCE_LINE=$(printf '%s\n' "$REPLY" | sed -n '2p' | sed 's/\r$//')
        FENCE_END=$(printf '%s\n' "$REPLY" | sed -n '3p' | sed 's/\r$//')
        printf '%s\n' "$FENCE_START" | grep -Eq '^[[:space:]]*```[[:space:]]*tool_call[[:space:]]*$' || exit 2
        printf '%s\n' "$FENCE_END" | grep -Eq '^[[:space:]]*```[[:space:]]*$' || exit 2
        [ -n "$FENCE_LINE" ] || exit 2
        LINE="$FENCE_LINE"
        ;;
    *)
        exit 2
        ;;
esac

# Do not accept prose, arbitrary fences, function-style calls, or arbitrary
# helper names. The accepted field form is the exact syntax below, with either
# the historical dot name or the canonical hyphenated shell helper name.
PARSED=$(printf '%s\n' "$LINE" | sed -nE \
    "s/^[[:space:]]*(ha[.]action_guarded|ha-action-guarded)[[:space:]]+'([a-z0-9_]+\/[a-z0-9_]+)'[[:space:]]+'(\\{.*\\})'[[:space:]]*$/\\2\t\\3/p")
[ -n "$PARSED" ] || exit 2

SERVICE=${PARSED%%	*}
PAYLOAD=${PARSED#*	}
case "$SERVICE" in
    light/turn_on|light/turn_off|light/toggle|\
    switch/turn_on|switch/turn_off|switch/toggle|\
    input_boolean/turn_on|input_boolean/turn_off|input_boolean/toggle|\
    cover/open_cover|cover/close_cover|cover/stop_cover|\
    climate/set_temperature|climate/set_hvac_mode|\
    scene/turn_on|scene/reload|automation/reload) ;;
    *) exit 2 ;;
esac

CANONICAL_PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -ce 'select(type == "object")' 2>/dev/null) || exit 2

set +e
GATE_OUTPUT=$("$LEGACY_ACTION_GATE" "$SERVICE" "$CANONICAL_PAYLOAD" 2>&1)
GATE_STATUS=$?
set -e

case "$GATE_STATUS" in
    0)
        case "$SERVICE" in
            scene/reload) echo "Home Assistant scenes reloaded." ;;
            automation/reload) echo "Home Assistant automations reloaded." ;;
            *) echo "Action completed: $SERVICE." ;;
        esac
        ;;
    2)
        TICKET=$(printf '%s\n' "$GATE_OUTPUT" | sed -nE 's/.*ticket=([a-f0-9]{8}).*/\1/p' | head -n 1)
        if [ -n "$TICKET" ]; then
            echo "Approval needed (id $TICKET). Reply YES $TICKET to proceed."
        else
            echo "Approval is required before that action can run."
        fi
        ;;
    1)
        case "$GATE_OUTPUT" in
            *"Write actions are disabled by default"*)
                echo "Write actions are disabled; enable them in the ZeroClaw app options first." ;;
            *"DENIED by policy:"*)
                echo "Action denied by the Home Assistant policy." ;;
            *)
                echo "That action was not completed; no success is being claimed." ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac

exit 0
