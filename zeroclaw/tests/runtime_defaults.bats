#!/usr/bin/env bats

run_file="$BATS_TEST_DIRNAME/../run.sh"

@test "runtime uses the Supervisor core API and safe gateway defaults" {
    run grep -F 'HA_URL="http://supervisor/core/api"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'host = "127.0.0.1"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'require_pairing = true' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'telegram = false' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'cli = true' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[channels_config]' "$run_file"
    [ "$status" -ne 0 ]
}

@test "planner defaults do not expose raw shell or wildcard HTTP" {
    run grep -F 'level = "supervised"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'workspace_only = true' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'require_approval_for_medium_risk = true' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'block_high_risk_commands = true' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'allowed_domains = []' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'allow_private_hosts = false' "$run_file"
    [ "$status" -eq 0 ]
    run grep -E '^allowed_commands = .*"curl"' "$run_file"
    [ "$status" -ne 0 ]
}

@test "write actions are opt-in and destructive version deletion is absent" {
    run grep -F "enable_write_actions: false" "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'rm -rf "${CONFIG_DIR}/workspace/sessions"* "${CONFIG_DIR}/brain.db"' "$run_file"
    [ "$status" -ne 0 ]
}

@test "HA and Telegram credentials stay behind root-owned broker boundaries" {
    run grep -F 'provider_key_mode: broker' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'install -m 0755 /opt/zeroclaw/lib/capability-broker-handler.sh' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'env -u HA_TOKEN -u SUPERVISOR_TOKEN -u TELEGRAM_BOT_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0700 /data/approved /data/approval-receipts' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0700 /data/approval-receipts/.locks' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chown -R root:root /data/approval-receipts' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0700 /data/approval-receipts/tickets' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chown root:zeroclaw /data/audit' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0750 /data/logs' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0700 /data/provider' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0700 /data/capability' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'CAPABILITY_MAX_ACTIONS_PER_HOUR' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'provider_max_requests_per_hour is outside the safe range' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0700 /run/zeroclaw' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'OFFSET_F="/run/zeroclaw/telegram-offset"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'install -m 0755 /opt/zeroclaw/lib/telegram-broker-handler.sh' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'api.telegram.org/bot${TELEGRAM_TOKEN}' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'telegram_curl()' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'curl --config "\$config_file"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Authorization: Bearer ${HA_TOKEN}' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -ne 0 ]
    run grep -F 'Authorization: Bearer ${OPENROUTER_KEY}' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -ne 0 ]
    run grep -F 'write capabilities are internal-only' "$BATS_TEST_DIRNAME/../lib/ha-capability.sh"
    [ "$status" -eq 0 ]
    run grep -F 'TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
    run grep -F 'The planner-supplied prose is intentionally ignored' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "the sticky persistent root protects root-owned state" {
    run grep -F 'chown root:zeroclaw /data' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 1770 /data' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'ROOT_APPROVAL_STORE_REPLACED' "$BATS_TEST_DIRNAME/startup_smoke.sh"
    [ "$status" -eq 0 ]
    run grep -F 'persistent root entry is a symlink' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'VF="${CONFIG_DIR}/.state-version"' "$run_file"
    [ "$status" -eq 0 ]
}

@test "the root entrypoint drops credential copies before launching the planner" {
    run grep -F 'unset OPENROUTER_KEY LEGACY_HA_TOKEN HA_TOKEN TELEGRAM_TOKEN SUPERVISOR_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
}

@test "the planner receives no unnecessary host add-on configuration mapping" {
    run grep -E '^map:' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -ne 0 ]
}

@test "the app does not request broad Supervisor API rights" {
    run grep -E '^(hassio_api|hassio_role):' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -ne 0 ]
}

@test "direct provider compatibility mode cannot enable writes" {
    run grep -F 'provider_key_mode=direct_temporary cannot be combined with write actions' "$run_file"
    [ "$status" -eq 0 ]
}

@test "policy options default safely and reject malformed gates" {
    run grep -F 'POLICY_MODE="${POLICY_MODE:-balanced}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'policy_quiet_hours_require_confirm is invalid; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'policy_climate_delta_confirm_c is outside the safe range; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
}

@test "approval transition requires actor binding and a broker receipt" {
    run grep -F 'actor is not authorized for ticket' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
    run grep -F 'was not sealed by the Telegram broker' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
    run grep -F 'changed after notification' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
    run grep -F 'verify_claim' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
}

@test "confirmed execution is claimed and finalized inside the root broker" {
    run grep -F 'approval-transition.sh claim "$ticket"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'ZEROCLAW_APPROVAL_CLAIMED=1' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'approval-transition.sh complete "$approval_ticket"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'approval outcome audit could not be persisted; claim retained' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "approval sealing clamps planner-controlled expiry" {
    run grep -F 'max_expires=$((now + 1800))' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'expires_at="$max_expires"' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "sealed approval cleanup is root-owned and expiry-aware" {
    run grep -F '/opt/zeroclaw/lib/state-cleanup.sh /data' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'never removes an unexpired ticket' "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh"
    [ "$status" -eq 0 ]
    run grep -F 'CLAIM_GRACE_SECONDS=3600' "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh"
    [ "$status" -eq 0 ]
}

@test "the broker enforces the write feature flag independently of the client" {
    run grep -F 'export ENABLE_WRITE_ACTIONS' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ "${ENABLE_WRITE_ACTIONS:-false}" = "true" ] || json_error "write capability is disabled"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "post-action audit failure is not reported as a successful action" {
    run grep -F 'service executed but broker outcome audit could not be persisted' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'the claim remains for recovery' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'the denial audit row could not be persisted' "$run_file"
    [ "$status" -eq 0 ]
}

@test "planner audit boundary cannot mint execution outcomes" {
    run grep -F 'intent|deny|confirm|confirm_failed' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'Execution, failure, and undo outcomes are written by root-owned' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'provider_max_requests_per_hour' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
}

@test "Telegram approval execution failures are reported as failures" {
    run grep -F 'Approved, but execution failed; the claim remains for recovery' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Execution failed; claim retained.' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Telegram sendMessage rejected approval' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
}
