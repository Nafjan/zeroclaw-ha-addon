#!/bin/sh
# Exercise the root-only health broker lane with a deterministic local curl
# shim. This verifies authorization and dispatch without contacting Home
# Assistant or depending on a live network service.
set -eu

mkdir -p /data/capability /tmp/health-lane-bin

cat > /tmp/health-lane-bin/curl <<'FAKE_CURL'
#!/bin/sh
# Home Assistant's /template endpoint returns the rendered template body,
# not the JSON envelope used by the REST API. The broker deliberately wraps
# that bounded text response in its own JSON result.
[ -z "${HA_TOKEN:-}" ] || exit 91
printf '%s\n' 'Kitchen: light.kitchen'
FAKE_CURL
chmod 0755 /tmp/health-lane-bin/curl

broker=/opt/zeroclaw/lib/capability-broker-handler.sh

invoke_broker() {
    auth="$1"
    operation="$2"
    printf '{"auth":"%s","operation":"%s"}\n' "$auth" "$operation" |
        env \
            HA_TOKEN=supervisor-secret \
            CAPABILITY_CLIENT_AUTH_TOKEN=cap-client \
            CAPABILITY_HEALTH_CLIENT_AUTH_TOKEN=health-client \
            HA_URL=http://127.0.0.1:42633/core/api \
            PATH="/tmp/health-lane-bin:$PATH" \
            "$broker"
}

health_response=$(invoke_broker health-client health_read_sensors)
printf '%s\n' "$health_response" |
    jq -e '.ok == true and .result == "Kitchen: light.kitchen"' >/dev/null

planner_health_response=$(invoke_broker cap-client health_read_sensors)
printf '%s\n' "$planner_health_response" |
    jq -e '.ok == false and .error_code == "broker_auth_failed"' >/dev/null

health_non_health_response=$(invoke_broker health-client read_lights)
printf '%s\n' "$health_non_health_response" |
    jq -e '.ok == false and .error_code == "broker_auth_failed"' >/dev/null

planner_response=$(invoke_broker cap-client read_lights)
printf '%s\n' "$planner_response" |
    jq -e '.ok == true and .result == "Kitchen: light.kitchen"' >/dev/null

echo 'HEALTH_LANE_OK root_health_allowed=1 planner_health_denied=1 health_non_health_denied=1 planner_read_allowed=1'
