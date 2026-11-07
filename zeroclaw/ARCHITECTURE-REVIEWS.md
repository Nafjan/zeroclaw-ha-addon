# Architecture review disposition

Two independent Summon source reviews were completed: Sol and Kimi (requested
K3.1 Pro). Both reviewed the proposed architecture and pinned ZeroClaw 0.8.7
sources, not a final app image. Both independently recommended a native-first
single-runtime design over retaining the custom privileged broker topology.

The owner selected native controls and authorized rethinking the app to make
it simpler and more solid. `ARCHITECTURE.md` is the resulting design.

| Review finding | Disposition |
| --- | --- |
| Native Telegram already provides polling and tool-approval callbacks | Use one native poller; retire the custom watcher and ticket runtime after replacement qualification |
| Native controls trust ZeroClaw and do not isolate a compromised runtime | Accepted by the owner; state the tradeoff, never claim old independent enforcement |
| The tentative `ha` agent alias can hide migrated memory | Preserve native `default`; avoid custom SQL identity reassignment |
| Config, workspace and SQLite paths are not interchangeable | Use one native install prefix `/data/native`; preserve the old workspace as archive |
| Native config saves atomically beside its file | Service-own the contained native install directory; keep Supervisor options and backups outside it |
| Regenerating config unconditionally discards native changes | Regenerate on first use or explicit options changes; preserve it otherwise |
| Native MCP names containing `__` bypass the ordinary tool allowlist | Do not claim categorical denial from `allowed_tools`; use server-side read-only Device control and native supervised approval |
| HA main and individual MCP URLs have different safety semantics | Use main `/api/mcp`; validate the reviewed read-only discovery contract at startup |
| HA read-only annotations are not retained by ZeroClaw's MCP tool definitions | Auto-approve only exact reviewed read names; keep native supervised policy for others |
| Native budget route-down can continue spending | Use native `block` with complete route pricing; no independent reservation claim |
| Native Telegram sender authorization is not a private-chat-only setting | Authorize only the numeric owner; document private bot use and group limitations |
| Old keyed JSON sessions do not establish native channel ownership | Archive them intact; do not guess an identity mapping or build a second session engine |
| A wrapper around the old shell stack is only an intermediate state | Build a thin native entrypoint/config/migration path; delete superseded runtime machinery after qualification |

Review recommendations are not deployment approval or a claim of passing
runtime/image tests. Qualification evidence is recorded separately, including
synthetic HA MCP behavior, old/new state compatibility and arm64 execution.

## Implementation findings and closure

A separate Sol implementation review returned conditional findings. A Kimi
implementation review blocked its earlier snapshot on a genuine SQLite sidecar
issue. The findings were repaired rather than waived:

| Finding | Repair and evidence |
| --- | --- |
| Interrupted target-manifest publication could invalidate the source archive | Keep source checksums immutable and bind the target manifest in the atomic prepared transaction; injected-interruption retry test passes |
| Opening archived SQLite WAL state could modify archived SHM files | Perform SQLite reads on a private work copy, preserve WAL pages and rebuild its temporary SHM; WAL-only row/archive checksum test and actual old/new migration pass |
| Startup checked saved options instead of the preserved effective MCP config | Resolve the native default agent's bundle grants and check the actual endpoint/credential; effective-config unit tests and real nonadmin HA/client fixture pass |
| A root-owned but readable options file stayed readable by the daemon | Set root ownership and 0600 before granting data-root traversal; arm64 image fixture begins with 0644 options and verifies daemon denial |
| Saving unchanged options cannot reset unsupported native header encryption | State that an option value must change before restart; preserve unchanged-config behavior and test the explicit regeneration path |

The old workspace root is also sealed against the new daemon UID; its original
contents remain intact for recovery. Source review, regression tests and actual
runtime qualification are distinct evidence. These reviews do not approve a
release or production installation.

Sol's CLI reported the requested model identity. The Kimi seat requested K3.1
Pro; its CLI did not report a served-model identity, so that identity is not
independently attested. Both review runs left the reviewed source unchanged.

A final pinned-source check confirmed that the numeric Telegram owner can use
plain `/model fast`, `/model reasoning` and native approval callbacks without
agent-wide administrator scope. The app keeps that broader scope off.
`/model auto` resets a conversation override only when the optional native
effort-routing policy is enabled. No live Telegram conversation was used as
qualification evidence.

## Canary preparation review

GLM Flash and DeepSeek Flash also reviewed supplied source and delivery
contracts through Summon. These were text-only reviews; neither executed
repository tests. GLM identified a recoverable hot SQLite rollback journal
that the migration copy did not handle. The repair recovers a private writable
copy, consolidates it through SQLite backup, and excludes database sidecars
from activated memory. A genuine crash-journal regression proves committed
rows survive, incomplete transactions disappear, and source/archive hashes
remain unchanged. Invalid memory-directory types are rejected before snapshot.

DeepSeek identified an ambiguity between unsigned local builds and later
protected releases. The runbook now explicitly distinguishes local run 0
review artifacts from a positive-run signed CI candidate; only the latter
can enter live installation review. The stable source version is a future
target, not a claim of an already published image. No new reset framework
was added: rollback is state recovery, and another migration uses fresh data.

A separate toolful GLM attempt did not finalize and is not counted as a
completed review. The successful text reviewers reported their requested
served-model names. Reviewer findings are evidence, not release approval.

Kimi also reviewed the final release and canary tooling without changing its
snapshot. It found that registry-only provenance publication did not match
the verifier's default GitHub attestation lookup. The verifier now explicitly
loads its attestation bundle from OCI storage, with mocked tests for storage
selection, identities, missing tools and failed verification. The isolated
app identity and version contract had no further blocking findings. This
review requested K3.1 Pro; the CLI did not attest its served-model identity.
Actual registry signature verification still requires a published candidate.

A supported missing-stage retry was also tested with an interruption during
reconstruction. Prepared migrations now rebuild only their exact private,
unactivated stage from the verified archive. Symlinks and special files
remain fail-closed; neither active native state nor source archives are
deleted. Retry and unsafe-stage regressions pass in the Linux migration suite.
