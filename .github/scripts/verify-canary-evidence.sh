#!/usr/bin/env bash
set -euo pipefail

EVIDENCE_FILE="${1:?evidence file is required}"
EXPECTED_DIGEST="${2:?candidate digest is required}"
EXPECTED_TAG="${3:?canary tag is required}"
EXPECTED_RUN_ID="${4:?candidate workflow run id is required}"
EXPECTED_COMMIT="${5:?candidate commit is required}"
EXPECTED_SHA256="${6:?evidence SHA256 is required}"
EXPECTED_DESCRIPTOR_SHA256="${7:?canary descriptor SHA256 is required}"

[ -s "$EVIDENCE_FILE" ] || {
    echo "canary evidence file is missing or empty" >&2
    exit 1
}

printf '%s  %s\n' "$EXPECTED_SHA256" "$EVIDENCE_FILE" | sha256sum --check --status - || {
    echo "canary evidence SHA256 mismatch" >&2
    exit 1
}

printf '%s' "$EXPECTED_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "evidence SHA256 has an invalid format" >&2
    exit 1
}

printf '%s' "$EXPECTED_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$' || {
    echo "candidate digest has an invalid format" >&2
    exit 1
}

printf '%s' "$EXPECTED_RUN_ID" | grep -Eq '^[0-9]+$' || {
    echo "candidate workflow run id has an invalid format" >&2
    exit 1
}

printf '%s' "$EXPECTED_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "candidate commit has an invalid format" >&2
    exit 1
}

printf '%s' "$EXPECTED_DESCRIPTOR_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
    echo "canary descriptor SHA256 has an invalid format" >&2
    exit 1
}

jq -e --arg digest "$EXPECTED_DIGEST" --arg tag "$EXPECTED_TAG" \
  --arg run_id "$EXPECTED_RUN_ID" --arg commit "$EXPECTED_COMMIT" \
  --arg descriptor_sha256 "$EXPECTED_DESCRIPTOR_SHA256" '
  def hash256: if type == "string" then test("^[0-9a-f]{64}$") else false end;
  def nonempty_text: if type == "string" then (length > 0 and length <= 256) else false end;
  def supervisor_version_ok:
    try (capture("^(?<major>[0-9]{4})\\.(?<minor>[0-9]{1,2})([.][0-9]+)?$") |
      (.major | tonumber) as $major |
      (.minor | tonumber) as $minor |
      ($major > 2026 or ($major == 2026 and $minor >= 4)))
    catch false;
  (.schema_version == 1)
  and (.candidate_digest == $digest)
  and (.canary_tag == $tag)
  and ((.candidate_run_id | tostring) == $run_id)
  and (.candidate_commit == $commit)
  and (.tested_at | if type == "string" then test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") else false end)
  and (.ha_version | nonempty_text)
  and (.supervisor_version | supervisor_version_ok)
  and (.descriptor.side_loaded == true)
  and (.descriptor.app_slug == "zeroclaw_canary")
  and (.descriptor.artifact_sha256 == $descriptor_sha256)
  and (.descriptor.minimum_supervisor_version == "2026.04.0")
  and (.backup.app_slug == "zeroclaw")
  and (.backup.created == true)
  and (.backup.artifact_sha256 | hash256)
  and (.backup.restore_verified == true)
  and (.rollback.snapshot_id | nonempty_text)
  and (.rollback.verified == true)
  and all([
      .read_only.loopback_pairing,
      .read_only.ha_status,
      .read_only.invalid_entity_fail_closed,
      .read_only.broker_unavailable_fail_closed,
      .read_only.planner_no_supervisor_token,
      .read_only.planner_no_telegram_token,
      .read_only.telegram_transport_isolated,
      .read_only.telegram_no_internal_syntax_leak
    ][]; . == true)
  and all([
      .approval.non_owner_rejected,
      .approval.changed_ticket_rejected,
      .approval.replay_rejected,
      .approval.sealed_ticket,
      .approval.truthful_audit,
      .approval.failed_claim_retained
    ][]; . == true)
  and all([
      .write_canary.low_risk_write,
      .write_canary.confirm_class_approved,
      .write_canary.outcome_audited,
      .write_canary.writes_disabled_after
    ][]; . == true)
' "$EVIDENCE_FILE" >/dev/null || {
    echo "canary evidence does not satisfy the required schema or gates" >&2
    exit 1
}

printf 'canary evidence verified: %s\n' "$EVIDENCE_FILE"
