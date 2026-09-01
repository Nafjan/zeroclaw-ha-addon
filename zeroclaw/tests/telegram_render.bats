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

@test "Telegram renderer blocks function-style internal commands" {
    set +e
    output=$(printf '%s\n' "ha.action_guarded('scene/reload','{}')" | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks internal commands embedded in JSON" {
    set +e
    output=$(printf '%s\n' '{"name":"shell","arguments":{"command":"ha-action-guarded scene/reload {}"}}' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks a helper token without arguments" {
    set +e
    output=$(printf '%s\n' 'ha.action_guarded' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks hyphenated zc helpers" {
    set +e
    output=$(printf '%s\n' 'zc-undo 1' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks generic JSON tool envelopes" {
    set +e
    output=$(printf '%s\n' '{"tool":"shell","arguments":{"command":"echo unsafe"}}' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks generic function envelopes" {
    set +e
    output=$(printf '%s\n' '{"function":"call_service","arguments":{"domain":"light"}}' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "Telegram renderer blocks credential-like output" {
    set +e
    output=$(printf '%s\n' 'Authorization: Bearer abcdefghijklmnop1234567890' | "$render_file")
    status=$?
    set -e

    [ "$status" -eq 2 ]
    [ -z "$output" ]
}
