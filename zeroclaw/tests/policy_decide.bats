#!/usr/bin/env bats
#
# Tests for lib/policy-decide.sh — the pure policy decision function.
#
# These run on plain Linux (no HAOS, no jq required for most tests). Run with:
#   bats zeroclaw/tests/policy_decide.bats
#
# Layout: each test sets only the env vars it cares about. The setup()
# clears every policy var so tests don't leak into each other.

setup() {
    POLICY_SCRIPT="$BATS_TEST_DIRNAME/../lib/policy-decide.sh"
    [ -f "$POLICY_SCRIPT" ] || POLICY_SCRIPT="$BATS_TEST_DIRNAME/../../zeroclaw/lib/policy-decide.sh"
    chmod +x "$POLICY_SCRIPT" 2>/dev/null || true

    unset POLICY_MODE POLICY_QUIET_CONFIRM POLICY_BULK_THRESHOLD
    unset POLICY_CLIMATE_DELTA QUIET_HOURS
    unset EXTRA_DENY EXTRA_CONFIRM EXTRA_ALLOW
    unset POLICY_NOW_HOUR POLICY_CLIMATE_CURRENT POLICY_BULK_COUNT

    # Default: balanced mode, no quiet hours interference (force daytime)
    export POLICY_MODE=balanced
    export POLICY_QUIET_CONFIRM=true
    export POLICY_NOW_HOUR=14
    export QUIET_HOURS="23:00-06:00"
}

decide() {
    sh "$POLICY_SCRIPT" "$@"
}

# ─────────────────────── Domain defaults ───────────────────────

@test "light domain defaults to allow" {
    run decide light turn_on light.kitchen
    [ "$status" -eq 0 ]
    [[ "$output" == allow:default_light* ]]
}

@test "scene domain defaults to allow" {
    run decide scene turn_on scene.movie
    [[ "$output" == allow:default_scene* ]]
}

@test "script domain defaults to allow" {
    run decide script turn_on script.morning
    [[ "$output" == allow:default_script* ]]
}

@test "input_boolean defaults to allow" {
    run decide input_boolean toggle input_boolean.guest_mode
    [[ "$output" == allow:default_input_boolean* ]]
}

@test "switch defaults to confirm in balanced mode" {
    run decide switch turn_off switch.water_heater
    [[ "$output" == confirm:default_switch* ]]
}

@test "switch defaults to allow in permissive mode" {
    POLICY_MODE=permissive
    run decide switch turn_off switch.water_heater
    [[ "$output" == allow:permissive_switch* ]]
}

@test "cover defaults to confirm in balanced mode" {
    run decide cover open cover.garage_door
    [[ "$output" == confirm:default_cover* ]]
}

# ─────────────────────── Hard-coded deny ───────────────────────

@test "lock domain is hard-blocked" {
    run decide lock unlock lock.front_door
    [[ "$output" == deny:hard_block:lock* ]]
}

@test "alarm_control_panel is hard-blocked" {
    run decide alarm_control_panel disarm alarm_control_panel.house
    [[ "$output" == deny:hard_block:alarm_control_panel* ]]
}

@test "camera is hard-blocked" {
    run decide camera turn_off camera.front_porch
    [[ "$output" == deny:hard_block:camera* ]]
}

@test "device_tracker is hard-blocked" {
    run decide device_tracker see device_tracker.alice_phone
    [[ "$output" == deny:hard_block:device_tracker* ]]
}

@test "permissive mode does NOT bypass hard block" {
    POLICY_MODE=permissive
    run decide lock unlock lock.front_door
    [[ "$output" == deny:hard_block:lock* ]]
}

# ─────────────────────── Unknown domains ───────────────────────

@test "unknown domain confirms in balanced mode" {
    run decide remote send_command remote.tv
    [[ "$output" == confirm:unknown_domain:remote* ]]
}

@test "unknown domain denies in strict mode" {
    POLICY_MODE=strict
    run decide remote send_command remote.tv
    [[ "$output" == deny:strict_unknown_domain:remote* ]]
}

# ─────────────────────── Extras list ───────────────────────

@test "extra_deny overrides default allow" {
    export EXTRA_DENY="light.kids_*"
    run decide light turn_on light.kids_room
    [[ "$output" == "deny:extra_deny:light.kids_*" ]]
}

@test "extra_deny pattern non-match falls through to default" {
    export EXTRA_DENY="light.kids_*"
    run decide light turn_on light.kitchen
    [[ "$output" == allow:default_light* ]]
}

@test "extra_allow upgrades a confirm-by-default switch" {
    export EXTRA_ALLOW="switch.fan_*"
    run decide switch turn_on switch.fan_office
    [[ "$output" == "allow:extra_allow:switch.fan_*" ]]
}

@test "extra_confirm downgrades a default-allow light" {
    export EXTRA_CONFIRM="light.living_*"
    run decide light turn_on light.living_room
    [[ "$output" == "confirm:extra_confirm:light.living_*" ]]
}

@test "extra_deny wins over extra_allow when both match" {
    export EXTRA_DENY="switch.water_heater"
    export EXTRA_ALLOW="switch.water_heater"
    run decide switch turn_on switch.water_heater
    [[ "$output" == "deny:extra_deny:switch.water_heater" ]]
}

@test "extra_deny does NOT bypass hard block (deny still wins; reason differs)" {
    export EXTRA_DENY="lock.*"
    run decide lock unlock lock.front_door
    # Either reason is acceptable — the point is that it's denied.
    [[ "$output" == deny:* ]]
}

# ─────────────────────── Climate delta ───────────────────────

@test "climate set_temperature small delta allows" {
    export POLICY_CLIMATE_DELTA=3
    export POLICY_CLIMATE_CURRENT=24
    body='{"entity_id":"climate.bedroom","temperature":23}'
    run decide climate set_temperature climate.bedroom "$body"
    [[ "$output" == allow:climate_within_delta* ]]
}

@test "climate set_temperature big delta confirms" {
    export POLICY_CLIMATE_DELTA=3
    export POLICY_CLIMATE_CURRENT=24
    body='{"entity_id":"climate.bedroom","temperature":18}'
    run decide climate set_temperature climate.bedroom "$body"
    [[ "$output" == confirm:climate_delta_* ]]
}

@test "climate set_temperature without baseline allows" {
    # No POLICY_CLIMATE_CURRENT set
    BODY='{"entity_id":"climate.bedroom","temperature":18}'
    run decide climate set_temperature climate.bedroom "$BODY"
    [[ "$output" == allow:climate_no_baseline* ]]
}

@test "climate non-temperature action allows" {
    run decide climate set_hvac_mode climate.bedroom '{"hvac_mode":"cool"}'
    [[ "$output" == allow:climate_set_hvac_mode* ]]
}

# ─────────────────────── Bulk action ───────────────────────

@test "bulk action escalates allow to confirm" {
    POLICY_BULK_COUNT=8
    POLICY_BULK_THRESHOLD=3
    export POLICY_BULK_COUNT POLICY_BULK_THRESHOLD
    run decide light turn_off light.all_lights
    [[ "$output" == confirm:bulk_action_8* ]]
}

@test "bulk count below threshold leaves allow alone" {
    POLICY_BULK_COUNT=2
    POLICY_BULK_THRESHOLD=3
    export POLICY_BULK_COUNT POLICY_BULK_THRESHOLD
    run decide light turn_off light.kitchen
    [[ "$output" == allow:default_light* ]]
}

@test "bulk action does NOT downgrade deny" {
    POLICY_BULK_COUNT=10
    POLICY_BULK_THRESHOLD=3
    export POLICY_BULK_COUNT POLICY_BULK_THRESHOLD
    run decide lock unlock lock.front_door
    [[ "$output" == deny:* ]]
}

# ─────────────────────── Quiet hours ───────────────────────

@test "quiet hours escalates light allow to confirm" {
    POLICY_NOW_HOUR=2  # 2 AM, inside 23:00-06:00
    run decide light turn_on light.kitchen
    [[ "$output" == confirm:quiet_hours_2h* ]]
}

@test "quiet hours does not affect daytime hours" {
    POLICY_NOW_HOUR=14
    run decide light turn_on light.kitchen
    [[ "$output" == allow:default_light* ]]
}

@test "quiet hours toggle off keeps allow at night" {
    POLICY_QUIET_CONFIRM=false
    POLICY_NOW_HOUR=2
    run decide light turn_on light.kitchen
    [[ "$output" == allow:default_light* ]]
}

@test "quiet hours edge: hour equal to start-of-window means inside" {
    POLICY_NOW_HOUR=23
    run decide light turn_on light.kitchen
    [[ "$output" == confirm:quiet_hours_23h* ]]
}

@test "quiet hours edge: hour equal to end-of-window means outside" {
    POLICY_NOW_HOUR=6
    run decide light turn_on light.kitchen
    [[ "$output" == allow:default_light* ]]
}

@test "quiet hours non-midnight-spanning window (08-18)" {
    QUIET_HOURS="08:00-18:00"
    POLICY_NOW_HOUR=12
    run decide light turn_on light.kitchen
    [[ "$output" == confirm:quiet_hours_12h* ]]
}

@test "quiet hours does not apply to scene domain" {
    POLICY_NOW_HOUR=2
    run decide scene turn_on scene.movie
    [[ "$output" == allow:default_scene* ]]
}

# ─────────────────────── Bad input ───────────────────────

@test "missing domain returns deny:bad_input" {
    run decide "" "" ""
    [[ "$output" == deny:bad_input* ]]
}

@test "missing action returns deny:bad_input" {
    run decide light "" light.kitchen
    [[ "$output" == deny:bad_input* ]]
}
