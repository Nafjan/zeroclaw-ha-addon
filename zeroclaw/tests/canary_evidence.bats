#!/usr/bin/env bats

VERIFIER="$BATS_TEST_DIRNAME/../../.github/scripts/verify-canary-evidence.sh"
PROVIDER_VERIFIER="$BATS_TEST_DIRNAME/../../.github/scripts/verify-provider-contract-report.sh"
DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
TAG='3.1.4.0-canary.test'
RUN_ID='123456789'
COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
DESCRIPTOR_SHA256='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

setup() {
    TMP_DIR=$(mktemp -d)
    EVIDENCE="$TMP_DIR/evidence.json"
    PROVIDER_REPORT="$TMP_DIR/provider-contract-report.json"
    suite_sha=$(sha256sum "$BATS_TEST_DIRNAME/provider_profile_fallback_smoke.sh" | awk '{print $1}')
    jq -n \
        --arg commit "$COMMIT" \
        --arg suite_sha "$suite_sha" \
        '{
          schema_version: 1,
          status: "passed",
          candidate_commit: $commit,
          tested_at: "2026-08-21T12:00:00Z",
          suite: {name:"provider_profile_fallback_smoke.sh",sha256:$suite_sha},
          routes: {
            primary:{profile:"openrouter",model:"~deepseek/deepseek-v4-flash-latest",tier:"paid"},
            complex:{profile:"openrouter",model:"openrouter/fusion",tier:"paid",preset:"general-budget"},
            complex_auto:{profile:"openrouter",model:"openrouter/auto",tier:"paid",cost_tier:"medium"},
            complex_pro:{profile:"openrouter",model:"deepseek/deepseek-v4-pro",tier:"paid"},
            free_model:{profile:"openrouter",model:"nvidia/nemotron-3.5-lightning:free",tier:"free"},
            free_router:{profile:"openrouter",model:"openrouter/free",tier:"free"}
          },
          classification:{credit_exhausted_402:true,network_timeout:true,transient_5xx:true,credential_401_blocks_same_profile_fallback:true},
          safety:{free_route_no_tools_only:true,tool_capable_never_free:true},
          accounting:{reservation_recorded:true,success_settlement_recorded:true,failure_settlement_recorded:true,budget_denied_before_upstream:true,ledger_schema:1,ledger_sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
          limits:{max_input_tokens:65536,max_output_tokens:2048,profile_daily_token_budget:200000,global_daily_token_budget:200000,global_requests_per_hour:120,client_requests_per_hour:120,daily_cost_limit_micros:10000000,monthly_cost_limit_micros:40000000,max_cost_micros_per_1k_tokens:100000}
        }' > "$PROVIDER_REPORT"
    provider_report_sha=$(sha256sum "$PROVIDER_REPORT" | awk '{print $1}')
    jq -n \
        --arg digest "$DIGEST" \
        --arg tag "$TAG" \
        --arg run_id "$RUN_ID" \
        --arg commit "$COMMIT" \
        --arg provider_report_sha "$provider_report_sha" \
        '{
          schema_version: 2,
          candidate_digest: $digest,
          canary_tag: $tag,
          candidate_run_id: ($run_id | tonumber),
          candidate_commit: $commit,
          tested_at: "2026-08-21T12:00:00Z",
          ha_version: "2026.8.2",
          supervisor_version: "2026.8.2",
          supervisor_preflight: {api_endpoint:"/supervisor/info",version:"2026.8.2",minimum_version:"2026.04.0",verified_before_install:true},
          descriptor: {side_loaded:true,app_slug:"zeroclaw_canary",artifact_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",minimum_supervisor_version:"2026.04.0"},
          backup: {app_slug:"zeroclaw",created:true,artifact_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",restore_verified:true},
          rollback: {snapshot_id:"old-to-new-20260821",verified:true},
          read_only: {loopback_pairing:true,ha_status:true,invalid_entity_fail_closed:true,broker_unavailable_fail_closed:true,planner_no_supervisor_token:true,planner_no_telegram_token:true,telegram_transport_isolated:true,telegram_no_internal_syntax_leak:true},
          approval: {non_owner_rejected:true,changed_ticket_rejected:true,replay_rejected:true,sealed_ticket:true,truthful_audit:true,failed_claim_retained:true},
          write_canary: {low_risk_write:true,confirm_class_approved:true,outcome_audited:true,writes_disabled_after:true},
          provider_contract: {report_schema_version:1,report_sha256:$provider_report_sha},
          operator_attestation: {operator_ref:"test-operator",attested_at:"2026-08-21T12:00:00Z",method:"canary-runbook-v2",automated_reports_verified:true,gate_groups_attested:["descriptor","backup","rollback","supervisor","read_only","approval","write_canary","provider_contract"]}
        }' > "$EVIDENCE"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "canary evidence verifier accepts complete evidence" {
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha" "$DESCRIPTOR_SHA256" "$provider_report_sha"
    [ "$status" -eq 0 ]
}

@test "canary evidence verifier rejects a missing acceptance gate" {
    jq '.write_canary.writes_disabled_after = false' "$EVIDENCE" > "$EVIDENCE.tmp"
    mv "$EVIDENCE.tmp" "$EVIDENCE"
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha" "$DESCRIPTOR_SHA256" "$provider_report_sha"
    [ "$status" -ne 0 ]
}

@test "canary evidence verifier rejects missing Telegram isolation proof" {
    jq 'del(.read_only.telegram_transport_isolated)' "$EVIDENCE" > "$EVIDENCE.tmp"
    mv "$EVIDENCE.tmp" "$EVIDENCE"
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha" "$DESCRIPTOR_SHA256" "$provider_report_sha"
    [ "$status" -ne 0 ]
}

@test "canary evidence verifier rejects a digest mismatch" {
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha" "$DESCRIPTOR_SHA256" "$provider_report_sha"
    [ "$status" -ne 0 ]
}

@test "canary evidence run and commit bindings are documented" {
    run grep -F '"candidate_run_id":' "$BATS_TEST_DIRNAME/../CANARY-EVIDENCE.md"
    [ "$status" -eq 0 ]
    run grep -F '"candidate_commit":' "$BATS_TEST_DIRNAME/../CANARY-EVIDENCE.md"
    [ "$status" -eq 0 ]
}

@test "canary evidence requires a current Supervisor and side-load descriptor" {
    jq '.supervisor_version = "2026.03.9"' "$EVIDENCE" > "$EVIDENCE.tmp"
    mv "$EVIDENCE.tmp" "$EVIDENCE"
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha" "$DESCRIPTOR_SHA256" "$provider_report_sha"
    [ "$status" -ne 0 ]
}

@test "provider contract report verifies against the exact smoke suite" {
    run bash "$PROVIDER_VERIFIER" "$PROVIDER_REPORT" "$provider_report_sha" "$COMMIT"
    [ "$status" -eq 0 ]
}

@test "canary evidence requires provider contract report binding" {
    jq '.provider_contract.report_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$EVIDENCE" > "$EVIDENCE.tmp"
    mv "$EVIDENCE.tmp" "$EVIDENCE"
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha" "$DESCRIPTOR_SHA256" "$provider_report_sha"
    [ "$status" -ne 0 ]
}
