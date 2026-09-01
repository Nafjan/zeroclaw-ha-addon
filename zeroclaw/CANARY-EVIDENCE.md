# HA canary evidence

Production promotion requires a redacted JSON evidence file committed to an
immutable commit in this repository. Do not include tokens, passwords, raw
Telegram IDs, entity names that disclose sensitive information, or backup
contents. Record hashes and boolean results only. The provider contract report
is a separate machine-generated, redacted JSON file committed beside the
evidence; it must not contain request headers, provider responses, or secrets.

The evidence must contain:

```json
{
  "schema_version": 2,
  "candidate_digest": "sha256:<exact candidate digest>",
  "canary_tag": "<exact temporary GHCR canary tag>",
  "candidate_run_id": 123456789,
  "candidate_commit": "<40-character add-on commit used by the candidate build>",
  "tested_at": "2026-08-21T12:00:00Z",
  "ha_version": "2026.8.2",
  "supervisor_version": "2026.8.2",
  "supervisor_preflight": {
    "api_endpoint": "/supervisor/info",
    "version": "2026.8.2",
    "minimum_version": "2026.04.0",
    "verified_before_install": true
  },
  "descriptor": {
    "side_loaded": true,
    "app_slug": "zeroclaw_canary",
    "artifact_sha256": "<SHA256 of the exact side-load config.yaml>",
    "minimum_supervisor_version": "2026.04.0"
  },
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
  },
  "provider_contract": {
    "report_schema_version": 1,
    "report_sha256": "<SHA256 of provider-contract-report.json>"
  },
  "operator_attestation": {
    "operator_ref": "<opaque non-secret operator reference>",
    "attested_at": "2026-08-21T12:00:00Z",
    "method": "canary-runbook-v2",
    "automated_reports_verified": true,
    "gate_groups_attested": [
      "descriptor",
      "backup",
      "rollback",
      "supervisor",
      "read_only",
      "approval",
      "write_canary",
      "provider_contract"
    ]
  }
}
```

The machine-generated `provider-contract-report.json` must be produced by the
exact `zeroclaw/tests/provider_profile_fallback_smoke.sh` from the evidence
commit, with `CANARY_CANDIDATE_COMMIT` set to the candidate image's full
40-character add-on commit. The script must finish successfully and records
the exact OpenRouter primary, Fusion budget, Auto, DeepSeek Pro, free-model,
and free-router bindings. It also exercises and records 402 credit exhaustion,
network timeout, transient 5xx, same-profile 401 rejection, no-tools-only
free routing, durable reservation/settlement, and pre-upstream budget denial.
The promotion verifier recomputes the smoke-suite hash and validates every
field in the report before accepting the evidence.

After the live canary, commit the redacted file and the exact side-load
descriptor (under a non-`config.yaml` filename, so the repository retains one
canonical app descriptor), plus `provider-contract-report.json`, to the
repository. The evidence commit may be newer than the candidate commit; the
JSON itself binds the evidence to the candidate workflow run and add-on
commit. Use one `canary_evidence_bundle` JSON input containing raw URLs pinned
to the evidence commit and the six URL/SHA256 fields, for example:

```json
{
  "evidence": "https://raw.githubusercontent.com/Nafjan/zeroclaw-ha-addon/<evidence-commit>/zeroclaw/canary-evidence.json",
  "evidence_sha256": "<64 hex characters>",
  "descriptor": "https://raw.githubusercontent.com/Nafjan/zeroclaw-ha-addon/<evidence-commit>/zeroclaw/canary-config.yaml",
  "descriptor_sha256": "<64 hex characters>",
  "provider_report": "https://raw.githubusercontent.com/Nafjan/zeroclaw-ha-addon/<evidence-commit>/zeroclaw/provider-contract-report.json",
  "provider_report_sha256": "<64 hex characters>"
}
```

when dispatching `.github/workflows/promote-existing.yml`. The promotion workflow verifies the
descriptor content, its SHA256, the isolated `zeroclaw_canary` slug, and the
resolved `tag@digest` identity recorded alongside the Supervisor-compatible
bare image repository before it accepts the evidence. Supervisor app
configuration does not accept a tag or digest in `image:`; it derives the
image tag from `version:`. The descriptor therefore carries the exact
canary tag in `version:`, the bare repository in `image:`, and the exact
resolved `repository:tag@digest` in its comments and identity file.
That workflow verifies the signed candidate tag, exact canary alias digest,
attestations, evidence hash, candidate run/commit binding, the provider report
contract, explicit operator attestation, and every listed gate before creating
Supervisor release tags.

Create the temporary alias with `.github/workflows/publish-canary-alias.yml`,
providing the candidate digest, candidate tag, candidate commit, and the
matching `<version>-canary.<candidate-run-id>` tag. The alias workflow verifies
that the candidate is the successful `workflow_dispatch` run on `master` using
the `zeroclaw-release-linux-x64` trusted builder, then verifies the candidate
signature and provenance/SBOM attestations before writing the alias. It uploads
the mandatory side-load descriptor artifact. Copy its
`config.yaml` into a local app directory such as
`/addons/local/zeroclaw_canary/` before installing the canary; use a separate
Telegram bot from production.

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
