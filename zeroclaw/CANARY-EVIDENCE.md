# HA canary evidence

Production promotion requires a redacted JSON evidence file committed to an
immutable commit in this repository. Do not include tokens, passwords, raw
Telegram IDs, entity names that disclose sensitive information, or backup
contents. Record hashes and boolean results only.

The evidence must contain:

```json
{
  "schema_version": 1,
  "candidate_digest": "sha256:<exact candidate digest>",
  "canary_tag": "<exact temporary GHCR canary tag>",
  "tested_at": "2026-08-21T12:00:00Z",
  "ha_version": "2026.8.2",
  "backup": {
    "app_slug": "zeroclaw",
    "created": true,
    "artifact_sha256": "<backup artifact SHA256>",
    "restore_verified": true
  },
  "rollback": {"snapshot_id": "<migration snapshot id>", "verified": true},
  "read_only": {
    "loopback_pairing": true,
    "ha_status": true,
    "invalid_entity_fail_closed": true,
    "broker_unavailable_fail_closed": true,
    "planner_no_supervisor_token": true,
    "planner_no_telegram_token": true
  },
  "approval": {
    "non_owner_rejected": true,
    "changed_ticket_rejected": true,
    "replay_rejected": true,
    "sealed_ticket": true,
    "truthful_audit": true,
    "failed_claim_retained": true
  },
  "write_canary": {
    "low_risk_write": true,
    "confirm_class_approved": true,
    "outcome_audited": true,
    "writes_disabled_after": true
  }
}
```

After committing the redacted file, use a raw URL pinned to that commit and
the file SHA256 as `canary_evidence` and `canary_evidence_sha256` when running
the protected promotion workflow. The workflow verifies the URL, downloads
the file, checks its hash, binds it to the exact candidate digest and canary
tag, and requires every listed gate to be true.
