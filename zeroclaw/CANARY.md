# Native Home Assistant canary runbook

**Status: preparation only. No live Home Assistant changes have been made.**

This runbook qualifies a separate, manually started candidate app on the same
Home Assistant host. It keeps the installed app, its saved options, and its
data in place. The canary has its own Supervisor app ID and fresh data. It does
not test an in-place upgrade or migrate production state automatically.

The canonical `4.0.0.0` descriptor is the future stable target; it does not
claim that a stable image with that version has been published. Each canary
uses its own prerelease version. A local, unsigned review build with run ID `0`
is **never installable evidence**. Only a later owner-authorized protected CI
build with a positive workflow run ID, verified signature and provenance, and
an exact published image digest may be considered for installation.

The candidate release, its exact image tag, and a descriptor branch must be
available before installation. The repository release workflow and descriptor
must agree on one Supervisor-compatible version and image tag. Do not proceed
if the candidate version, source commit, image tag, and verified image digest
do not identify the same build.

## 1. Prepare and verify the candidate

1. Publish the exact reviewed development branch through an explicit candidate
   workflow dispatch and the required owner environment review. Keep the
   production store branch and its descriptor unchanged during the canary;
   do not merge the future stable descriptor merely to run the workflow, and
   never add the source branch to the HA Store. GitHub runs a dispatch against
   the [selected branch and commit](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).
   The workflow keeps all four acceptance jobs and rejects tag dispatches.
   Confirm the environment permits the selected source branch.

   Verify the candidate's expected full source SHA and branch ref, immutable
   image digest, provenance and signature. Supply the expected ref from the
   review decision, not from image metadata:

   ```text
   python .github/scripts/verify-native-candidate.py \
     --digest sha256:<64-lowercase-hex-characters> \
     --source-sha <full-40-character-source-sha> \
     --source-ref refs/heads/<reviewed-development-branch> \
     --run-id <release-run-id> --attempt <release-run-attempt>
   ```

   Also retain the release SBOM. A candidate tag alone is not proof of its
   contents. Keep the production descriptor at its existing stable version
   until the native canary succeeds and a separately authorized signed stable
   image exists. The current candidate workflow publishes no stable image.
2. Confirm that the Supervisor version string and published image tag are the
   same value:

   ```text
   4.0.0-dev.g<SHA12>.<run-id>.<attempt>
   ```

   `image:` in the app descriptor remains the bare image repository. Supervisor
   derives the tag from `version:`; the OCI app-version label must match it,
   and the digest belongs in separate release evidence. The local renderer
   rejects a tag/version mismatch and marks its recorded digest
   **unverified**.
3. Render a review copy from the committed source. Use a new output directory
   outside the checkout:

   ```text
   python .github/scripts/prepare-native-canary.py \
     --source-commit <full-40-character-source-sha> \
     --run-id <release-run-id> \
     --run-attempt <release-run-attempt> \
     --image-tag <exact-supervisor-version> \
     --image-digest sha256:<64-lowercase-hex-characters> \
     --output-dir <new-directory-outside-the-checkout>
   ```

   The output is a review bundle outside this source repository. It contains
   `zeroclaw_canary/config.yaml` and
   `candidate-evidence.json`. The renderer reads only the committed public
   descriptor. It does not read saved Home Assistant options or app data, contact
   Home Assistant, verify the digest, or approve an installation. For a local
   review build, `--run-id 0 --run-attempt 1` labels the version as local only;
   it does not represent a workflow run or signed release and must never be
   installed. Do not add a second canonical `config.yaml` to this source
   repository.
4. Inspect the rendered descriptor and receipt. Confirm the canary name and
   slug, manual boot, aarch64 support, untagged image repository, and disabled
   Telegram and Home Assistant MCP defaults. The renderer sets the canary-only
   `openrouter_api_key` default to the public nonfunctional sentinel
   `canary-bootstrap-no-provider`; it is not a credential and cannot prove a
   provider connection. This lets the app perform boot and health checks
   without a model turn. The canonical production descriptor remains unchanged.
   Compare the recorded digest with the separately verified release result.
   Keep the receipt out of any public live-operation record unless it has been
   reviewed and redacted.
5. Place the canary descriptor on a dedicated app-repository branch and add
   that branch as a separate Supervisor repository. The branch must offer only
   the canary descriptor; remove the production app descriptor from that
   dedicated branch so it cannot offer a second production app accidentally.
   Do not change the
   canonical app descriptor or stable branch for this canary. Home Assistant
   app IDs include both the repository ID and app slug; a branch has a
   different repository ID, and this canary also has its own slug. See the
   [Supervisor app identity documentation](https://contributors.home-assistant.io/apps/how-apps-work/).

## 2. Capture a usable rollback point

Before installing the canary, create a **fresh manual full Supervisor backup**.
Include Home Assistant settings and all apps, including the currently
installed ZeroClaw app. Wait for completion and confirm the backup record lists
the app and its data without failures. Keep a copy in a location independent of
the Home Assistant host, and retain the matching backup emergency kit
separately. Do not put the backup, its key, options, tokens, or raw IDs in the
repository or a canary receipt.

The canary descriptor requests a cold backup only for the new canary app. That
does not establish how the currently installed app handles backups. Before
relying on the backup as a rollback point or state-copy source, verify the
installed app's backup behavior or use an owner-approved stop, backup, and
restart window for that old app. Preparation work does not stop it. Keep this
consistency check separate from the isolated fresh-data canary, which does not
import production state.

Record the installed app ID, version, image reference/digest if available, and
the option values needed to restore service in private operator notes. Do not
copy production options into the canary. A manual full backup is required even
when app-update backups are enabled: those backups have their own setting and
can be configured to skip. Home Assistant documents [manual backups and their
contents](https://www.home-assistant.io/common-tasks/general/backups/#creating-a-manual-backup),
[app-update backups](https://www.home-assistant.io/common-tasks/general/backups/#app-update-backups),
and [restoring selected apps or a full backup](https://www.home-assistant.io/common-tasks/general/backups/#restoring-a-backup).

No backup has been created by this preparation work.

## 3. Install the isolated canary

Proceed only after the owner approves the live canary window and the backup is
complete.

1. Add or refresh the dedicated descriptor branch in Supervisor's app store.
2. Confirm that the listed app is named **ZeroClaw Agent Canary**, its slug is
   `zeroclaw_canary`, and its full installed app ID differs from the currently
   installed production app ID. Confirm that Supervisor shows manual boot and
   leave **Auto update** off for the canary. Verify both in its Info screen;
   manual boot does not control automatic updates.
   If the ID is the production ID, or if the candidate appears to share the
   production data directory, stop before installation.
3. Keep automatic updates off for the canary during qualification. This is a
   per-app Supervisor setting; do not change the production app's setting.
   Home Assistant exposes this control separately from app boot behavior in
   its [Supervisor app settings API](https://developers.home-assistant.io/docs/api/supervisor/endpoints/).
4. Install only the canary app ID. Do not install another copy of the
   production slug from the canary branch. Leave the canary in manual boot and
   keep its Telegram and MCP options disabled for the first start. The existing
   production app remains the only Telegram poller.
5. Start the canary manually when ready. Confirm the displayed app version
   matches the verified candidate version, Supervisor reports the app running
   and healthy, and the app log has no startup or migration error. The first
   canary data directory must be fresh; the canary migration helper initializes
   it without importing production state. The public provider sentinel permits
   boot and health checks only; do not use it for a model request or count it
   as provider qualification.
6. Confirm that Telegram and Home Assistant MCP remain disabled. No Home
   Assistant global MCP settings should be changed for this phase.

## 4. Accept or stop the fresh-data canary

The fresh-data phase passes only when all of these are true:

- The installed canary app ID is distinct from production and has its own data.
- Its displayed version and image tag match the verified candidate.
- The canary starts and remains healthy with manual boot.
- Startup logs show no migration, database, or configuration failure.
- Telegram and Home Assistant MCP are disabled in the canary options.
- No model turn is attempted; the public bootstrap sentinel is not a provider
  credential and does not prove provider connectivity.
- The production app remains unchanged and available.

This phase checks packaging, Supervisor startup, and fresh-state initialization.
It does not prove restored-memory recall, session continuity, or production
upgrade compatibility.

If a check fails, stop the canary app. The production app and its data remain
the service of record. Remove or retain the stopped canary only according to
the owner's decision; before removal, confirm the canary app ID is selected.
Never select or remove the production app. Do not edit production data or
migration markers.

## 5. Optional private-state qualification

State-copy qualification is a separate, owner-controlled operation. It is not
part of installing or starting the fresh-data canary.

Use a **new, stopped canary data set**. Populate it from a verified backup
before its first migration or start, then run the normal migration once. Give
this qualification its own fresh canary app ID and data directory so the
fresh-data phase remains available for comparison. Do not copy state into an
already initialized canary and expect `prepare` to import it: that command is
idempotent after successful preparation. Do not use `rollback` as a reset;
rollback restores legacy files and intentionally leaves the native app unable
to start. Keep the production app and backup unchanged.

The backup may contain private configuration. Keep it outside source control
and follow a separately reviewed operator procedure for selecting and copying
the intended memory/session state. Do not copy the old workspace prompts or
skills into the active native workspace. Hash-keyed legacy Telegram JSON
conversations remain archived; the canary must not guess their owners.

Accept state-copy qualification only after the native default agent can recall
a known fact from the copied memory and a restart preserves that result. A
healthy process or database row count alone is not a memory-recall check.

## 6. Optional integrations

Keep Telegram and MCP disabled until their use is separately approved. To test
Telegram, the owner configures the canary through its private Supervisor
options and confirms that no other running app polls the same bot. Never put
token values or raw Telegram IDs into a descriptor, receipt, issue, or log
excerpt. If that exclusivity cannot be established without changing the
production app, keep Telegram off in the canary.

If a model turn is later approved, the owner can privately replace the
canary-only bootstrap sentinel with a provider credential in the canary's
Supervisor options. That is a separate integration test; this preparation does
not inspect or reuse credentials.

Enable Home Assistant MCP only after separate approval. Use a dedicated
non-administrator account, Device control only, read-only mode, and only the
entities the owner intends to expose. Keep MCP off if those conditions are not
already in place; this runbook does not change global Home Assistant MCP
settings.

## 7. Rollback boundaries

For this isolated canary, stop the canary app to end the test. The production
app and its data remain in place. If the canary app must be removed, use
Supervisor's app controls and confirm the canary app ID is selected. Never
select or remove the production app.

For a later in-place production migration, use a separate approved cutover
plan. Stop the new runtime, then restore the pre-upgrade Supervisor backup's
old app and data/options (or restore the full backup if system state also needs
to return). Verify that Supervisor reports the recorded old version and that
only the old app is running before resuming service. A native migration
rollback is only a state-recovery operation; it does not downgrade the image.

Restoring a backup overwrites the selected current parts. Home Assistant
documents the current-system restore flow and its scope in the
[backup restore guide](https://www.home-assistant.io/common-tasks/general/backups/#restoring-a-backup).
