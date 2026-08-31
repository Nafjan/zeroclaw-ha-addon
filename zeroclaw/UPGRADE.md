# ZeroClaw defensive release runbook

This release changes the trust boundary. ZeroClaw is an unprivileged planner;
the root-owned capability brokers hold the Supervisor and Telegram credentials.
Write actions remain disabled by default.

The checked-in binary is the re-qualified authoritative artifact: its
manifest records the pinned Cross image digest and clean Cross/trusted-builder
replays produced the same ZeroClaw 0.7.5 SHA (`1a3911d3…`). The signed CI workflow must reproduce this
result before publication; do not deploy an untagged working tree or bypass the
candidate/canary gates.

## Before installing

1. Treat the currently configured Home Assistant token, Telegram bot token, and
   provider key as exposed until rotated. Create a new HA long-lived token and
   Telegram bot token, revoke the old credentials, and update the add-on only
   after the new values are available.
2. Export a copy of the current add-on options and create a Supervisor partial
   backup containing this app. If an older build used `/addon_configs/`, archive
   that legacy directory separately before upgrading. Do not delete `brain.db`
   or sessions as a shortcut for an upgrade. Existing pre-upgrade pending tickets are retained
   as source records but are not auto-promoted into the new root-owned sealed
   ticket store; re-request any action that still needs approval.
3. Record the running app version, image digest, ZeroClaw version, and the
   current values of `enable_write_actions`, `enable_creation_skill`,
   `daily_report_enabled`, and `observer_enabled`.
4. Confirm that `telegram_allowed_users` begins with the intended approval
   owner. The first ID is the only actor allowed to approve or reject a ticket.

## First boot

Keep these values until the canary is complete:

```yaml
enable_write_actions: false
enable_creation_skill: false
daily_report_enabled: false
observer_enabled: false
provider_key_mode: broker
```

The entrypoint creates a versioned snapshot under `/data/migrations/` before
advancing its marker. A failed snapshot refuses startup. The migration helper
does not wipe the brain database, sessions, or workspace. New approval tickets
are copied into `/data/approval-receipts/tickets/`, made root-owned, and
checksummed before Telegram delivery; old planner-writable pending files are
never treated as already-approved tickets. Each snapshot includes a checksum
manifest and is root-owned after startup. The planner workspace receives owner
write bits at boot even when shipped seed files are read-only. Telegram
allowlist, cursor, and cost-watchdog state is recreated under root-only
/run/zeroclaw; the legacy planner-writable .tg_* files are discarded. Broker
logs are sanitized for symlinks before listeners start and remain root-owned.
The persistent `/data` mount is root-owned with a sticky group boundary: the
planner can create only its own runtime entries and cannot unlink or replace
root-owned audit, approval, migration, or configuration state.
Each boot also rotates ephemeral, root-created client credentials for the
loopback provider, HA, and Telegram brokers; `/run/zeroclaw` is not included in
backups and the planner receives no Supervisor, Telegram-bot, or provider
secret.
The CI backup gate archives the persistent `/data` volume, restores it
byte-for-byte, preserves secret-file mode, and excludes ephemeral `/run` state.
The app deliberately does not map `addon_config`: its state and Supervisor
options are already under `/data`, so the planner has no unnecessary host
configuration tree to read or modify.
The provider broker owns profile-bound model routes and per-profile budgets in
root-owned state. OpenRouter remains the default profile. NVIDIA and BytePlus
ModelArk are optional, disabled-by-default edges that require both a separate
credential and an explicit `provider_*_fallback_enabled` switch. A 401/402
credential or credit failure, timeout, 429, or 5xx blocks that profile for the
request and moves to the next eligible profile; the same credential is not
retried after a provider-wide failure. A 404 may try another model on the same
profile. The old `/data/provider/quota.json` counters are migrated into the
durable reservation ledger, reservations settle to actual reported completion
usage when valid, and crash/expiry/invalid usage is charged at the reserved
maximum. Planner configuration cannot raise any of these limits at request
time.

The supplied free-tier routes (`nvidia/nemotron-3.5-lightning:free` followed by
`openrouter/free`) are enabled by default. The broker permits them only for a
request with no tools, no required tool choice, and no prior tool-call
continuation; tool-capable turns fail closed instead of silently downgrading.
Set `provider_free_fallback_enabled: false` to disable them. This broker
release is buffered and non-streaming: `stream=true` is rejected until a
separately qualified streaming/cancellation design lands.

Verify the following from the add-on log and Home Assistant UI:

- the gateway is loopback-only and pairing is required;
- the app reaches HA through `http://supervisor/core/api`;
- a status query works without exposing a token to the planner;
- a deliberately invalid entity and an unavailable broker fail closed;
- the planner process is non-root and cannot read `/data/options.json` or the
  root-only Telegram credential file;
- a synthetic approval from a non-owner, a changed ticket, and a replayed
  marker are rejected.
- a ticket cannot be written or changed by the planner after it has entered the
  sealed store; the Telegram text is derived from the canonical ticket rather
  than planner-supplied prose.
- audit rows are readable by the planner for reports, but the audit directory
  and approval locks are root-owned; broker outcome rows cannot be forged by
  the planner. An approved ticket is claimed once before execution; a failed
  execution remains claimed rather than becoming replayable.

## Canary enablement

After the read-only checks pass, enable writes for one canary window only. Use
one low-risk light action, inspect the audit rows for both `intent` and outcome,
then test a confirm-class switch, cover, scene, or climate action. The latter
must remain pending until the configured Telegram owner confirms it. Confirm
that the ticket is sealed and that a second approval cannot replay it.

Do not enable NVIDIA or Ark fallback in the same canary as writes. First run
the provider profile contract smoke with the exact configured model IDs and
observe one forced OpenRouter 402/timeout path, then enable the relevant
profile switch and repeat the canary. Keep free-tier fallback disabled unless
you have intentionally configured a current model slug and accepted the
no-tools-only behavior.

Do not enable creation, scheduling, observer reports, or broad HTTP access in
the same change. Creation is explicitly blocked in this release because the
host Home Assistant `/config` tree is no longer mapped into the app; a future
broker-backed config writer must land before scene/automation persistence is
re-enabled. `provider_key_mode=direct_temporary` is an explicit temporary
exception. The included broker mode is the required end state; use
`direct_temporary` only for a controlled migration comparison and do not
enable production writes while it is selected.

## Rollback

If any canary gate fails, disable writes, stop the app, preserve the migration
snapshot and audit files, and return to the previously known-good app image.
Restore state only from the matching migration manifest after validating the
backup. With the app stopped, the installed helper moves the current state to
a recoverable rollback snapshot before restoring the selected backup:

```sh
state-restore /data /data/migrations/<legacy-or-schema>-to-schema-<new-schema>-<timestamp>-<pid>
```

Never use a recursive delete of the data directory as rollback.

The local two-pass source rebuild/hash gate (including the pinned source epoch
and LLVM seed), shell checks, and
Bats suite have passed. The release is not ready for unattended rollout until
the signed CI arm64 image build, real-binary provider round-trip, startup,
broker write, backup/restore, and real HA canary all pass. The signed release
workflow calls the full acceptance workflow as a prerequisite, publishes only
a signed candidate digest, and requires a protected `canary` environment plus
a commit-pinned, SHA256-checked redacted JSON evidence file bound to the exact
canary tag and digest before the protected `production` environment can create
Supervisor version tags. The evidence must prove the backup/restore, rollback,
read-only, approval, audit, and write-canary gates; see `CANARY-EVIDENCE.md`.
Configure both environments with required reviewers who verify the
authenticated canary and backup evidence. The promotion job creates the Git
tag only after the arm64 OCI image has BuildKit provenance/SBOM attestations
and a keyless Cosign signature. Verify the exact digest and signature before
allowing Supervisor to deploy it.

Use the workflows in two phases so the evidence can be created after the
candidate has actually run: dispatch `release.yml` with `promote: false`, then
publish the exact signed candidate through `publish-canary-alias.yml`, install
only that immutable canary tag, and perform the live canary. Commit the
redacted evidence JSON, then dispatch `promote-existing.yml` with the original
candidate digest, candidate tag/run/commit, canary tag, evidence URL, and
evidence SHA256. This final workflow verifies the existing artifact and
attestations without rebuilding it, then promotes only that digest.
