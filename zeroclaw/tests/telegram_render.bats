#!/usr/bin/env bats

render_file="$BATS_TEST_DIRNAME/../lib/telegram-render.sh"

@test "Telegram renderer blocks fenced tool calls" {
    set +e
    output=$(printf '%s\n' '```tool_call' "ha.action_guarded 'scene/reload' '{}'" '```' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks XML tool calls" {
    set +e
    output=$(printf '%s\n' '<tool_call>' '{"name":"shell","arguments":{"command":"ha-action-guarded '\''scene/reload'\'' '\''{}'\''"}}' '</tool_call>' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer preserves ordinary replies" {
    run sh -c "printf '%s\n' 'Scenes reloaded.' | '$render_file'"
    [ "$status" -eq 0 ]
    [ "$output" = "Scenes reloaded." ]
}

@test "Telegram renderer blocks bare internal commands" {
    set +e
    output=$(printf '%s\n' "ha.action_guarded 'scene/reload' '{}'" | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks an internal command after prose" {
    set +e
    output=$(printf '%s\n' "I will run ha.action_guarded 'scene/reload' '{}' now." | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}
