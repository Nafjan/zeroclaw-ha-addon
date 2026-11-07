#!/usr/bin/env bats

@test "native HA MCP setup rejects broad scopes, redirects and invalid credentials" {
    run python3 "$BATS_TEST_DIRNAME/../native/test_ha_preflight.py"
    [ "$status" -eq 0 ]
}
