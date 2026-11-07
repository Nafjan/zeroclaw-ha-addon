# Native 4.0 local qualification

Qualification dates: 2026-11-07–08. Runtime: official ZeroClaw 0.8.7 at upstream
commit `99bd353c756f4e64f381cfe9c3002ebff32f3055`. Home Assistant: 2026.11.0.
Both were checked against their latest stable release listings on 2026-11-08.

## Passing checks

| Scope | Evidence |
| --- | --- |
| Configuration and lifecycle | 17 unit tests cover native profiles, owner identity, MCP scope, estimates/block mode, optional automatic routing, quoting, file safety and options-driven regeneration |
| MCP startup discovery | 11 tests cover authenticated JSON/SSE discovery, effective native configuration, bundle exclusion, redirect/auth errors and broad/mutating tool rejection |
| Migration recovery | 16 tests cover checksums, WAL-only rows, genuine hot rollback-journal recovery, immutable archives, interrupted preparation and restaging, idempotence, invalid memory paths and rollback |
| Real old/new state | Actual 0.7.5 ARM and 0.8.7 binaries create/upgrade state; `agents.default` recalls a migrated fact; session restart and old-runtime reopen after rollback pass |
| Real HA/client interop | Actual HA 2026.11.0 and native ZeroClaw authenticate as a non-owner, non-admin HA user; only the two reviewed HA read tools plus memory recall are registered; exposed state reaches the model and unexposed state is absent |
| Real OpenRouter provider path | Native OpenRouter HTTPS runs through an isolated loopback CONNECT/TLS fixture; primary, automatic simple/complex selection and explicit reasoning override pass; Fusion sends the budget plugin preset |
| Canonical ARM64 image | The pinned canonical Dockerfile builds; aarch64 execution under QEMU passes startup, migration, health, private options/native state, unprivileged identity and environment removal, legacy-workspace denial, compatible-provider primary/reasoning calls, restart persistence and stale-socket recovery after SIGKILL |

The three Bats wrappers run the 44 Python unit tests above; they are not an
additional 44 tests. Shell parsing, ShellCheck, Python syntax, workflow/descriptor
YAML parsing and source whitespace checks also passed locally. Ten canary
descriptor tests and eleven candidate-verifier tests also pass. Nine fixture-cleanup regressions
cover uncertain resource creation, exact-name removal, preservation of the
primary failure, and refusal to report success after failed cleanup. The migration
repair was rechecked in a network-disabled Linux container with files copied
into its temporary filesystem.

The ARM64 image fixture uses a temporary supported compatible-provider profile
for its synthetic endpoint. The separate x86 interop fixture exercises the
actual OpenRouter provider family. Neither fixture uses production credentials,
an external model service, or a real home. Their containers have no external
network, and their temporary data/resources are removed.

## Review and delivery limits

[ARCHITECTURE-REVIEWS.md](ARCHITECTURE-REVIEWS.md) records independent Summon
architecture/implementation findings and their repairs. Review findings were
resolved with regression and real-runtime evidence, not converted into release
approval.

This qualifies the local implementation and emulated ARM64 candidate. It does
not establish native ARM hardware operation, a live Supervisor canary, remote
GitHub Actions success, repository protection settings, registry publication,
image signing, or production installation. Those actions have not been performed.
The official upstream executable was verified, not independently rebuilt.

The release workflow prepares uniquely tagged signed candidates after protected
review. It publishes no stable/version alias and performs no HA installation.
See [the delivery contract](../RELEASE-BUILDER.md) and [UPGRADE.md](UPGRADE.md).

The final repaired migration passed the 16 Linux regressions and the real
old/new functional fixture. On the local Windows/Docker host, stock fixture
runners hit Docker CLI subprocess deadlines during build/inspection. Private
qualification runners disabled only those CLI deadlines and added progress
logging; runtime assertions, health/readiness deadlines, hashes and network
isolation stayed unchanged. Both functional fixtures passed and removed their
own resources. This is distinct from a stock-runner or remote CI pass.
