#!/usr/bin/env bats

run_file="$BATS_TEST_DIRNAME/../run.sh"

@test "runtime release metadata is explicit and bare" {
    run grep -F 'ADDON_VERSION="${ZEROCLAW_ADDON_VERSION-}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F "missing or invalid baked app version; refusing to start" "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'STATE_SCHEMA="${ZEROCLAW_STATE_SCHEMA-}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F "missing or invalid baked state schema; refusing to start" "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'ENV ZEROCLAW_ADDON_VERSION="${BUILD_VERSION}"' "$BATS_TEST_DIRNAME/../Dockerfile"
    [ "$status" -eq 0 ]
    run grep -F 'ENV ZEROCLAW_STATE_SCHEMA="${ZEROCLAW_STATE_SCHEMA}"' "$BATS_TEST_DIRNAME/../Dockerfile"
    [ "$status" -eq 0 ]
}

@test "Dockerfile has no permissive release metadata defaults" {
    for argument in BUILD_VERSION BUILD_ARCH ZEROCLAW_SHA256 ZEROCLAW_SOURCE_COMMIT ADDON_SOURCE_COMMIT ZEROCLAW_SOURCE_DATE_EPOCH ZEROCLAW_LLVM_RNG_SEED REQUIRE_VERIFIED_ARTIFACT ZEROCLAW_STATE_SCHEMA; do
        run grep -E "^ARG ${argument}=" "$BATS_TEST_DIRNAME/../Dockerfile"
        [ "$status" -ne 0 ]
    done
    run grep -F 'printf '\''%s'\'' "${ZEROCLAW_STATE_SCHEMA}" | grep -Eq '\''^[1-9][0-9]{0,2}$'\''' "$BATS_TEST_DIRNAME/../Dockerfile"
    [ "$status" -eq 0 ]
    run grep -F 'COPY state-schema /usr/share/zeroclaw/state-schema' "$BATS_TEST_DIRNAME/../Dockerfile"
    [ "$status" -eq 0 ]
}
agent_turn_file="$BATS_TEST_DIRNAME/../lib/telegram-agent-turn.sh"

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

@test "runtime enforces the Supervisor version floor before scrubbing the token" {
    run grep -F 'http://supervisor/supervisor/info' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Authorization: Bearer ${SUPERVISOR_TOKEN}' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'below the supported floor 2026.04.0' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'unset SUPERVISOR_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
}

@test "cached Telegram replies are revalidated before replay" {
    run grep -F 'sanitized_cached=' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'blocked internal tool syntax in cached Telegram reply' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'replacing it with a safe status message' "$run_file"
    [ "$status" -eq 0 ]
}

@test "generated Telegram watcher preserves jq actor bindings" {
    run grep -F '.actor_user_id == \$actor and .chat_id == \$chat' "$run_file"
    [ "$status" -eq 0 ]
}

@test "Telegram transport is optional and starts only when configured" {
    run grep -F '[ -n "${OPENROUTER_KEY}" ]' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ -n "${HA_TOKEN}" ]' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'TELEGRAM_ENABLED=false' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'if [ "${TELEGRAM_ENABLED}" = "true" ]; then' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Telegram transport disabled; no bot token or users configured.' "$run_file"
    [ "$status" -eq 0 ]
}

@test "provider credentials are always broker-owned at the Supervisor boundary" {
    run grep -F 'provider_key_mode=direct_temporary is retired; forcing the root-owned broker mode.' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ "${PROVIDER_KEY_MODE}" = "broker" ]' "$run_file"
    [ "$status" -eq 0 ]
}

@test "gateway tool protocol and Telegram reply guard are installed" {
    run grep -F 'install -m 0755 /opt/zeroclaw/lib/telegram-render.sh /usr/local/bin/telegram-render' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'blocked internal tool syntax in Telegram reply' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '## Tool invocation protocol (gateway/channel safety)' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '<tool_call>' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'model returned an invalid tool request' "$run_file"
    [ "$status" -eq 0 ]
}

@test "correction state is broker-owned and not read from planner-writable data" {
    run grep -F 'LAST_OUTCOME_FILE="/data/capability/last-outcome.json"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'if [ ! -L "\$LAST_OUTCOME_FILE" ] && [ -f "\$LAST_OUTCOME_FILE" ]; then' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'set_outcome)' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'exec /usr/local/bin/ha-capability set_outcome' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'rm -f /data/.last_outcome' "$run_file"
    [ "$status" -eq 0 ]
}

@test "learning loop is opt-in and correction receipts are bounded" {
    run grep -F 'ENABLE_LEARNING="${ENABLE_LEARNING:-false}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'enable_learning_loops is invalid; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'LEARNING_ENABLED="${ENABLE_LEARNING}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ "\$LEARNING_ENABLED" = "true" ] || exit 0' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'expires_at:$expires_at' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'OUTCOME_NOW=\$(date -u +%s)' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '.expires_at | type == "number" and floor == . and . >= \$now' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'A correction receipt is valid only' "$BATS_TEST_DIRNAME/../lib/state-cleanup.sh"
    [ "$status" -eq 0 ]
}

@test "legacy textual guarded actions use the typed broker compatibility path" {
    run grep -F 'install -m 0755 /opt/zeroclaw/lib/telegram-legacy-action.sh /usr/local/bin/telegram-legacy-action' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'telegram-legacy-action "\$REPLY"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F "services already accepted by the typed capability broker" "$BATS_TEST_DIRNAME/../lib/telegram-legacy-action.sh"
    [ "$status" -eq 0 ]
    run grep -F 'ha-action-guarded' "$BATS_TEST_DIRNAME/../lib/telegram-legacy-action.sh"
    [ "$status" -eq 0 ]
}

@test "promotion tags the verified candidate commit" {
    promote_file="$BATS_TEST_DIRNAME/../../.github/workflows/promote-existing.yml"
    release_file="$BATS_TEST_DIRNAME/../../.github/workflows/release.yml"
    run grep -F 'CANDIDATE_COMMIT: ${{ needs.verify.outputs.candidate_commit }}' "$promote_file"
    [ "$status" -eq 0 ]
    run grep -F 'candidate_commit="${{ needs.candidate.outputs.candidate_commit }}"' "$release_file"
    [ "$status" -eq 0 ]
    run grep -F 'git tag -a "$RELEASE_TAG" "$CANDIDATE_COMMIT"' "$promote_file"
    [ "$status" -eq 0 ]
    run grep -F 'git tag -a "$release_tag" "$candidate_commit"' "$release_file"
    [ "$status" -eq 0 ]
    run grep -F 'artifact-metadata:' "$release_file"
    [ "$status" -ne 0 ]
}

@test "single-workflow inline promotion is rejected in favor of the two-phase path" {
    release_file="$BATS_TEST_DIRNAME/../../.github/workflows/release.yml"
    run grep -F 'inline promotion is disabled; run release.yml with promote=false, commit post-canary evidence, then use promote-existing.yml' "$release_file"
    [ "$status" -eq 0 ]
    run grep -F 'Deprecated; must remain false. Promote only via promote-existing.yml' "$release_file"
    [ "$status" -eq 0 ]
}

@test "Telegram watcher fails closed on a concurrent polling conflict" {
    run grep -F 'telegram_polling_conflict' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '.error_code == 409' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Telegram polling conflict; refusing to run alongside another poller.' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'exit 42' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'PIPESTATUS[0]' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Telegram polling conflict is latched' "$run_file"
    [ "$status" -eq 0 ]
}

@test "Telegram turns use the full agent tool loop" {
    run grep -F 'run_agent_turn' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '. /opt/zeroclaw/lib/telegram-agent-turn.sh' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'su-exec zeroclaw:zeroclaw timeout 120' "$agent_turn_file"
    [ "$status" -eq 0 ]
    run grep -F -- '--config-dir "$AGENT_CONFIG_DIR" agent' "$agent_turn_file"
    [ "$status" -eq 0 ]
    run grep -F 'REPLY=\$(run_agent_turn' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'unprivileged planner' "$agent_turn_file"
    [ "$status" -eq 0 ]
}

@test "Telegram protocol fallback is deterministic and does not retry a tool request" {
    run grep -F 'RECOVERY_MODEL="${COMPLEX_MODEL}"' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'retry_model="${3:-}"' "$agent_turn_file"
    [ "$status" -eq 0 ]
    run grep -F -- '--model "$retry_model"' "$agent_turn_file"
    [ "$status" -eq 0 ]
    run grep -F 'run_agent_turn "\$chat_id" "\$RECOVERY_PROMPT" "\$RECOVERY_MODEL"' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F "I couldn't safely complete that request because the model returned an invalid tool request." "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'I did not retry it.' "$run_file"
    [ "$status" -eq 0 ]
}

@test "HA skill documents shell commands instead of fake callable tables" {
    run grep -F '[[tools]]' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'The entries below are command aliases, not callable tool names' "$run_file"
    [ "$status" -eq 0 ]
}

@test "planner uses the actual shell tool for structured gateway calls" {
    run grep -F '{"name":"shell","arguments":{"command":"ha-action-guarded' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'structured shell tool exactly' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Never write a tool call as Markdown, a bare shell command, or prose.' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'approved:true' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '"name":"ha.action_guarded"' "$run_file"
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
    run grep -F 'provider_max_input_tokens is outside the safe range' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chmod 0710 /run/zeroclaw' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'PROVIDER_CLIENT_AUTH_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'CAPABILITY_CLIENT_AUTH_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'TELEGRAM_CLIENT_AUTH_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'TELEGRAM_OFFSET_FILE="/data/capability/telegram-offset"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'REPLY_CACHE_DIR="/data/capability/telegram-replies"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'install -m 0755 /opt/zeroclaw/lib/telegram-broker-handler.sh' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'api.telegram.org/bot${TELEGRAM_TOKEN}' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'telegram_curl()' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'curl --connect-timeout 5 --max-time 35 --config "\$config_file"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Authorization: Bearer ${HA_TOKEN}' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -ne 0 ]
    run grep -F 'Authorization: Bearer ${OPENROUTER_KEY}' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -ne 0 ]
    run grep -F 'provider broker client authentication failed' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'write capabilities are internal-only' "$BATS_TEST_DIRNAME/../lib/ha-capability.sh"
    [ "$status" -eq 0 ]
    run grep -F 'TICKET_DIR="${ZEROCLAW_APPROVAL_TICKET_DIR:-/data/approval-receipts/tickets}"' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
    run grep -F 'The planner-supplied prose is intentionally ignored' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'Parameters: %s' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'validate_ticket_payload' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "provider fallback is root-owned, profile-bound, and safely enabled by default" {
    run grep -F 'default_model: "~deepseek/deepseek-v4-flash-latest"' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'complex_model: openrouter/fusion' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'openrouter_auto_model: openrouter/auto' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'openrouter_fusion_preset: general-budget' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'openrouter_auto_cost_tier: medium' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'openrouter_free_model: nvidia/nemotron-3.5-lightning:free' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'openrouter_free_router_model: openrouter/free' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'provider_free_fallback_enabled: true' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'provider_max_input_tokens: 32768' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'provider_nvidia_fallback_enabled: false' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'provider_ark_fallback_enabled: false' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'export PROVIDER_PROFILE_SPEC=' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'export PROVIDER_ROUTE_SPEC=' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '~google/gemini-flash-latest' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'export PROVIDER_FUSION_PRESET=' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'openrouter/auto' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ "${SMOKE_PROVIDER_BROKER:-false}" = "true" ]' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'provider_retries = 0' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '((.stream // false) == false)' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'FAILURE_CLASS="credit_exhausted"' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'migrated_reserved_max' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'must use an explicit :free model slug' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ "$legacy_requests" -le "$MAX_REQUESTS_PER_HOUR" ]' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F '((.tools // []) | length) == 0' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'input token estimate exceeds the broker limit' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'conservative half-byte estimate' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'input_chars=$(wc -c < "$body_file"' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F '(.n == null or' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "provider ledger flushes reservations before upstream contact" {
    run grep -F 'sync -f "$ledger_tmp"' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'sync -f "$(dirname -- "$LEDGER_FILE")"' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "free fallback routes cover both primary and complex no-tools turns" {
    run grep -F '${DEFAULT_MODEL}|openrouter|${OPENROUTER_FREE_MODEL}|free' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '${COMPLEX_MODEL}|openrouter|${OPENROUTER_FREE_MODEL}|free' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '${COMPLEX_MODEL}|openrouter|${OPENROUTER_FREE_ROUTER_MODEL}|free' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Tool-capable turns never get downgraded to a free model.' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
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
    run grep -F 'SCHEMA_FILE="${CONFIG_DIR}/.state-schema"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F "schema-tombstone-%s\\n" "$run_file"
    [ "$status" -eq 0 ]
}

@test "the root entrypoint drops credential copies before launching the planner" {
    run grep -F 'unset OPENROUTER_KEY LEGACY_HA_TOKEN HA_TOKEN TELEGRAM_TOKEN SUPERVISOR_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
}

@test "credential presence checks do not use dynamic shell evaluation" {
    run grep -F 'eval val=\$$var' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F '[ -n "${OPENROUTER_KEY}" ]' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ -n "${HA_TOKEN}" ]' "$run_file"
    [ "$status" -eq 0 ]
}

@test "only the HA capability broker retains the Supervisor token" {
    run grep -F 'unset SUPERVISOR_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'unset SUPERVISOR_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'export HA_TOKEN HA_URL' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'unset HA_TOKEN LEGACY_HA_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
}

@test "Telegram commits its cursor only after processing the batch" {
    run grep -F 'Process the complete batch before committing its cursor' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'handle_message "\$M_CHAT" "\$M_FROM" "\$MSG_TEXT" "\$UPDATE_ID"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'done <"\$BATCH_FILE"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'if [ "\$BATCH_OK" != "true" ]; then' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'handle_message "\$M_CHAT" "\$M_FROM" "\$MSG_TEXT" &' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'commit_offset "\$((NEW_OFFSET + 1))"' "$run_file"
    [ "$status" -eq 0 ]
}

@test "Telegram cursor and delivery state are durable and API-validated" {
    run grep -F 'TELEGRAM_OFFSET_FILE="/data/capability/telegram-offset"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F "printf '%s\\n' '-1' > \"\${TELEGRAM_OFFSET_FILE}\"" "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'bootstrap_offset' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'telegram_response_ok "\$response"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'send_msg()' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'telegram_call_ok sendMessage' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'cache_reply "\$update_id" "\$REPLY"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'send_and_cache "\$update_id" "\$chat_id"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'telegram_curl sendMessage' "$run_file"
    [ "$status" -ne 0 ]
}

@test "Telegram bootstrap and cache never trust planner-controlled symlinks" {
    run grep -F '[ ! -L "\$OFFSET_F" ] && [ -f "\$OFFSET_F" ] || exit 1' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ ! -L "\$REPLY_CACHE_DIR" ] || exit 1' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F '[ ! -L "\$cached_file" ] && [ -f "\$cached_file" ]' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'telegram-replies' "$run_file"
    [ "$status" -eq 0 ]
}

@test "Telegram reply cache has bounded root-only cleanup" {
    cleanup_file="$BATS_TEST_DIRNAME/../lib/state-cleanup.sh"
    run grep -F 'REPLY_CACHE_DIR="${DATA_DIR}/capability/telegram-replies"' "$cleanup_file"
    [ "$status" -eq 0 ]
    run grep -F 'REPLY_CACHE_GRACE_SECONDS=604800' "$cleanup_file"
    [ "$status" -eq 0 ]
    run grep -F '[ -L "$reply" ] && continue' "$cleanup_file"
    [ "$status" -eq 0 ]
    run grep -F 'rm -f "$reply"' "$cleanup_file"
    [ "$status" -eq 0 ]
}

@test "typed brokers scrub unrelated credential classes" {
    run grep -F 'unset SUPERVISOR_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'unset SUPERVISOR_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'unset SUPERVISOR_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN \' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'OPENROUTER_KEY NVIDIA_KEY ARK_KEY LEGACY_HA_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
}

@test "unrelated root helper loops scrub inherited credentials" {
    run grep -F 'scrub_unrelated_child_credentials()' "$run_file"
    [ "$status" -eq 0 ]

    for marker in \
        'state-cleanup.sh /data' \
        'bashio::log.info "Cron seeder waiting for gateway..."' \
        '/usr/local/bin/tg-callback-watcher 2>&1 | while read -r line; do' \
        'TODAY=$(curl -s "${GW}/api/cost"'; do
        run grep -F -B 3 "$marker" "$run_file"
        [ "$status" -eq 0 ]
        [[ "$output" == *"scrub_unrelated_child_credentials"* ]]
    done

    run grep -F 'unset SUPERVISOR_TOKEN HA_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_TOKEN' "$run_file"
    [ "$status" -eq 0 ]
}

@test "the planner receives no unnecessary host add-on configuration mapping" {
    run grep -E '^map:' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -ne 0 ]
}

@test "the typed broker requests the default Supervisor API role" {
    run grep -F 'hassio_api: true' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'hassio_role: default' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -F 'homeassistant_api: true' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
    run grep -E '^hassio_role: (admin|manager|homeassistant)$' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -ne 0 ]
}

@test "legacy direct provider mode is forced into the root broker" {
    run grep -F 'provider_key_mode=direct_temporary is retired; forcing the root-owned broker mode.' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'provider_key_mode: list(direct_temporary|broker)' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
}

@test "policy options default safely and reject malformed gates" {
    run grep -F 'POLICY_MODE="${POLICY_MODE:-balanced}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'policy_quiet_hours_require_confirm is invalid; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'policy_climate_delta_confirm_c is outside the safe range; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'POLICY_REQUIRE_APPROVAL=true' "$run_file"
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

@test "rejection is audited before the sealed ticket is removed" {
    run grep -F 'rejection audit could not be persisted; rejection retained' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
    run grep -F 'zc-audit-write reject' "$BATS_TEST_DIRNAME/../lib/approval-transition.sh"
    [ "$status" -eq 0 ]
}

@test "confirmed execution is claimed and finalized inside the root broker" {
    run grep -F 'verify_approval_context "$approval_ticket" "$service" "$payload"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'reserve_action_quota' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'claim_approval_context "$approval_ticket"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'ZEROCLAW_APPROVAL_CLAIMED=1' "$run_file"
    [ "$status" -ne 0 ]
    run grep -F 'approval-transition.sh complete "$approval_ticket"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'approval outcome audit could not be persisted; claim retained' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'write_approval_outcome "$approval_ticket" "$service" "$payload" "$result"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'approval_outcome_receipt_unavailable' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'executed_approval_outcome_unknown' "$BATS_TEST_DIRNAME/../lib/ha-capability.sh"
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

@test "the broker requires a root-sealed Telegram ticket for every write" {
    run grep -F 'approved Telegram ticket is required' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'POLICY_REQUIRE_APPROVAL' "$run_file"
    [ "$status" -eq 0 ]
}

@test "post-action audit failure is not reported as a successful action" {
    run grep -F 'service executed but broker outcome audit could not be persisted' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'executed_audit_unknown' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'exit 3' "$BATS_TEST_DIRNAME/../lib/ha-capability.sh"
    [ "$status" -eq 0 ]
    run grep -F 'the claim remains for recovery' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'the denial audit row could not be persisted' "$run_file"
    [ "$status" -eq 0 ]
}

@test "planner audit boundary cannot mint execution outcomes" {
    run grep -F 'intent|deny|confirm|confirm_failed' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'source:"untrusted_planner"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'planner_event "planner/telemetry"' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'AUDIT_DIR=/data/audit/planner' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'provider_max_requests_per_hour' "$BATS_TEST_DIRNAME/../config.yaml"
    [ "$status" -eq 0 ]
}

@test "broker framing is bounded before JSON or HTTP parsing" {
    run grep -F 'bounded_read_line 32769' "$BATS_TEST_DIRNAME/../lib/capability-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'bounded_read_line "$((line_limit + 1))"' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F '"$header_count" -le 64' "$BATS_TEST_DIRNAME/../lib/provider-broker-handler.sh"
    [ "$status" -eq 0 ]
    run grep -F 'bounded_read_line 131073' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "Telegram approval execution outcomes stay truthful when confirmation is incomplete" {
    run grep -F 'the execution outcome could not be confirmed; the claim remains for recovery' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'execution outcome could not be confirmed; claim retained for recovery' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Outcome unconfirmed; claim retained.' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'Telegram sendMessage rejected approval' "$BATS_TEST_DIRNAME/../lib/telegram-broker-handler.sh"
    [ "$status" -eq 0 ]
}

@test "policy strings are kept out of generated shell and reloaded from root state" {
    run grep -F 'policy runtime file is not a regular file' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'chown root:zeroclaw "${POLICY_RUNTIME_TMP}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'POLICY_RUNTIME_FILE="${CONFIG_DIR}/policy-runtime.json"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'export POLICY_MODE="${POLICY_MODE}"' "$run_file"
    [ "$status" -ne 0 ]
}

@test "operator clock options are validated before helper generation" {
    run grep -F 'quiet_hours must use H:MM-H:MM; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'daily_report_time "${DAILY_REPORT_TIME}"' "$run_file"
    [ "$status" -eq 0 ]
    run grep -F 'is outside the valid 24-hour range; refusing to start' "$run_file"
    [ "$status" -eq 0 ]
}

@test "canary alias requires the signed candidate and its attestations" {
    alias_file="$BATS_TEST_DIRNAME/../../.github/workflows/publish-canary-alias.yml"
    run grep -F 'candidate_tag:' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'candidate_commit:' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'cosign verify --certificate-oidc-issuer=https://token.actions.githubusercontent.com' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'predicate-type https://slsa.dev/provenance/v1' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'predicate-type https://spdx.dev/Document/v2.3' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F '(.head_branch == "master")' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'zeroclaw-release-linux-x64' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'Render and verify the mandatory side-load descriptor' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$alias_file"
    [ "$status" -eq 0 ]
    run grep -F 'app_slug == "zeroclaw_canary"' "$alias_file"
    [ "$status" -eq 0 ]
}

@test "existing-candidate promotion requires the trusted reproducible builder run" {
    promote_file="$BATS_TEST_DIRNAME/../../.github/workflows/promote-existing.yml"
    run grep -F 'candidate_run_json="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${CANDIDATE_RUN_ID}")"' "$promote_file"
    [ "$status" -eq 0 ]
    run grep -F '(.head_sha == $commit)' "$promote_file"
    [ "$status" -eq 0 ]
    run grep -F 'Rebuild, attest, and sign candidate digest' "$promote_file"
    [ "$status" -eq 0 ]
    run grep -F 'zeroclaw-release-linux-x64' "$promote_file"
    [ "$status" -eq 0 ]
    protection_file="$BATS_TEST_DIRNAME/../../.github/scripts/verify-master-protection.sh"
    run grep -F 'verify-master-protection.sh' "$BATS_TEST_DIRNAME/../../RELEASE-BUILDER.md"
    [ "$status" -eq 0 ]
    run grep -F '.required_status_checks.strict == true' "$protection_file"
    [ "$status" -eq 0 ]
    run grep -F 'Bats unit tests' "$protection_file"
    [ "$status" -eq 0 ]
}
