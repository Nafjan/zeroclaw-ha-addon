#!/usr/bin/env bats

VERIFIER="$BATS_TEST_DIRNAME/../../.github/scripts/verify-canary-evidence.sh"
DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
TAG='3.1.4.0-canary.test'
RUN_ID='123456789'
COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

setup() {
    TMP_DIR=$(mktemp -d)
    EVIDENCE="$TMP_DIR/evidence.json"
    jq -n \
        --arg digest "$DIGEST" \
        --arg tag "$TAG" \
        --arg run_id "$RUN_ID" \
        --arg commit "$COMMIT" \
        '{
          schema_version: 1,
          candidate_digest: $digest,
          canary_tag: $tag,
          candidate_run_id: ($run_id | tonumber),
          candidate_commit: $commit,
          tested_at: "2026-08-21T12:00:00Z",
          ha_version: "2026.8.2",
          backup: {app_slug:"zeroclaw",created:true,artifact_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",restore_verified:true},
          rollback: {snapshot_id:"old-to-new-20260821",verified:true},
          read_only: {loopback_pairing:true,ha_status:true,invalid_entity_fail_closed:true,broker_unavailable_fail_closed:true,planner_no_supervisor_token:true,planner_no_telegram_token:true,telegram_transport_isolated:true,telegram_no_internal_syntax_leak:true},
          approval: {non_owner_rejected:true,changed_ticket_rejected:true,replay_rejected:true,sealed_ticket:true,truthful_audit:true,failed_claim_retained:true},
          write_canary: {low_risk_write:true,confirm_class_approved:true,outcome_audited:true,writes_disabled_after:true}
        }' > "$EVIDENCE"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "canary evidence verifier accepts complete evidence" {
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha"
    [ "$status" -eq 0 ]
}

@test "canary evidence verifier rejects a missing acceptance gate" {
    jq '.write_canary.writes_disabled_after = false' "$EVIDENCE" > "$EVIDENCE.tmp"
    mv "$EVIDENCE.tmp" "$EVIDENCE"
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha"
    [ "$status" -ne 0 ]
}

@test "canary evidence verifier rejects missing Telegram isolation proof" {
    jq 'del(.read_only.telegram_transport_isolated)' "$EVIDENCE" > "$EVIDENCE.tmp"
    mv "$EVIDENCE.tmp" "$EVIDENCE"
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" "$DIGEST" "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha"
    [ "$status" -ne 0 ]
}

@test "canary evidence verifier rejects a digest mismatch" {
    evidence_sha=$(sha256sum "$EVIDENCE" | awk '{print $1}')
    run bash "$VERIFIER" "$EVIDENCE" 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' "$TAG" "$RUN_ID" "$COMMIT" "$evidence_sha"
    [ "$status" -ne 0 ]
}

@test "canary evidence run and commit bindings are documented" {
    run grep -F '"candidate_run_id":' "$BATS_TEST_DIRNAME/../CANARY-EVIDENCE.md"
    [ "$status" -eq 0 ]
    run grep -F '"candidate_commit":' "$BATS_TEST_DIRNAME/../CANARY-EVIDENCE.md"
    [ "$status" -eq 0 ]
}
