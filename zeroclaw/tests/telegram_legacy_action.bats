#!/usr/bin/env bats

legacy_file="$BATS_TEST_DIRNAME/../lib/telegram-legacy-action.sh"

setup() {
    gate="$BATS_TEST_TMPDIR/gate"
    invocation="$BATS_TEST_TMPDIR/invocation"
    cat > "$gate" <<'SCRIPT'
#!/bin/sh
printf '%s\n%s\n' "$1" "$2" > "$INVOCATION_FILE"
case "${GATE_RESULT:-success}" in
    success) exit 0 ;;
    confirm) echo "CONFIRM_PENDING ticket=deadbeef reason=confirm:test"; exit 2 ;;
    deny) echo "DENIED by policy: deny:test"; exit 1 ;;
    disabled) echo "Write actions are disabled by default; enable only after review."; exit 1 ;;
    *) exit 9 ;;
esac
SCRIPT
    chmod +x "$gate"
}

@test "dispatches an exact one-line scene reload through the gate" {
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "ha.action_guarded 'scene/reload' '{}'"
    [ "$status" -eq 0 ]
    [ "$output" = "Home Assistant scenes reloaded." ]
    [ "$(sed -n '1p' "$invocation")" = "scene/reload" ]
    [ "$(sed -n '2p' "$invocation")" = "{}" ]
}

@test "recovers the exact fenced scene reload shown by legacy Telegram output" {
    fenced=$'```tool_call\n'
    action="ha.action_guarded 'scene/reload' '{}'"
    fenced+="$action"$'\n'
    fenced+='```'
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "$fenced"
    [ "$status" -eq 0 ]
    [ "$output" = "Home Assistant scenes reloaded." ]
    [ "$(sed -n '1p' "$invocation")" = "scene/reload" ]
    [ "$(sed -n '2p' "$invocation")" = "{}" ]
}

@test "accepts only the canonical hyphenated guarded helper inside the fence" {
    fenced=$'```tool_call\n'
    action="ha-action-guarded 'scene/reload' '{}'"
    fenced+="$action"$'\n'
    fenced+='```'
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "$fenced"
    [ "$status" -eq 0 ]
    [ "$output" = "Home Assistant scenes reloaded." ]
    [ "$(sed -n '1p' "$invocation")" = "scene/reload" ]
}

@test "rejects prose around a fenced guarded action" {
    fenced=$'Here is the action:\n```tool_call\n'
    action="ha.action_guarded 'scene/reload' '{}'"
    fenced+="$action"$'\n'
    fenced+='```'
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "$fenced"
    [ "$status" -eq 2 ]
    [ ! -f "$invocation" ]
}

@test "turns a broker confirmation into a Telegram-safe prompt" {
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" GATE_RESULT=confirm \
        "$legacy_file" "ha.action_guarded 'scene/reload' '{}'"
    [ "$status" -eq 0 ]
    [ "$output" = "Approval needed (id deadbeef). Reply YES deadbeef to proceed." ]
}

@test "turns a policy denial into a truthful safe reply" {
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" GATE_RESULT=deny \
        "$legacy_file" "ha.action_guarded 'scene/reload' '{}'"
    [ "$status" -eq 0 ]
    [ "$output" = "Action denied by the Home Assistant policy." ]
}

@test "rejects prose around an action" {
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "I will run ha.action_guarded 'scene/reload' '{}' now."
    [ "$status" -eq 2 ]
    [ ! -f "$invocation" ]
}

@test "rejects an unsupported service before the gate" {
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "ha.action_guarded 'system/restart' '{}'"
    [ "$status" -eq 2 ]
    [ ! -f "$invocation" ]
}

@test "rejects a non-object payload before the gate" {
    run env ZEROCLAW_LEGACY_ACTION_GATE="$gate" INVOCATION_FILE="$invocation" \
        "$legacy_file" "ha.action_guarded 'scene/reload' '[1]'"
    [ "$status" -eq 2 ]
    [ ! -f "$invocation" ]
}
