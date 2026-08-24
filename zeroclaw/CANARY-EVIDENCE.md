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
    "planner_no_telegram_token": true,
    "telegram_transport_isolated": true,
    "telegram_no_internal_syntax_leak": true
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

After the live canary, commit the redacted file to the repository. The
evidence commit may be newer than the candidate commit; the JSON itself binds
the evidence to the candidate workflow run and add-on commit. Use a raw URL
pinned to the evidence commit and the file SHA256 as `canary_evidence` and
`canary_evidence_sha256` when dispatching `.github/workflows/promote-existing.yml`.
That workflow verifies the signed candidate tag, exact canary alias digest,
attestations, evidence hash, candidate run/commit binding, and every listed
gate before creating Supervisor release tags.

Create the temporary alias with `.github/workflows/publish-canary-alias.yml`,
providing the candidate digest, candidate tag, candidate commit, and the
matching `<version>-canary.<candidate-run-id>` tag. The alias workflow verifies
the candidate signature and provenance/SBOM attestations before writing the
alias.

## Telegram canary procedure

Never run the production and canary watchers with the same Telegram bot token
at the same time. Use a separate canary bot, or stop production for the short
canary window and restore it afterward. Record only the boolean isolation gate
above; do not record the token or raw Telegram IDs.

For the read-only UX gate, the operator sends `Reload the Home Assistant
scenes.` from the authorized Telegram account and verifies that the reply is a
short truthful result (or a truthful safe failure) with no `ha.action_guarded`,
`<tool_call>`, fenced tool block, or other internal syntax. Do not inject an
update through the Bot API and do not have the bot impersonate the operator.
