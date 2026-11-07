# Native app delivery

The app consumes the official pinned ZeroClaw 0.8.7 ARM64 release archive. The
Docker build verifies its download and executable hashes and includes the
pinned upstream license files. This is not an independent reproduction of the
upstream Rust build. The app image has its own source revision and provenance.

The native qualification script verifies upstream release/source metadata and
runs the isolated ARM64 image fixture. The reusable Tests workflow also runs
configuration, recovery, real HA MCP and old/new binary state checks. ARM64
execution on a hosted x86 runner is emulated, not a hardware qualification.

Keep the existing protected-branch checks named `Bats unit tests`, `Shell
parsing and ShellCheck`, and `Build and smoke-test arm64 image`. Also require
`Native HA MCP and state compatibility` for the native release. Keep strict
checks, required independent review, admin enforcement, linear history,
conversation resolution and force-push/deletion protection. These settings
are external repository controls; a passing local script does not configure
or attest them. The operator preflight is
`.github/scripts/verify-master-protection.sh OWNER/REPOSITORY master`.

`release.yml` only publishes uniquely named candidates from an explicit master
branch dispatch. It first runs acceptance, then uses the `release-builder`
environment with its configured required reviewer. That is the owner's release
approval; the independent technical source review is recorded separately in
`zeroclaw/ARCHITECTURE-REVIEWS.md`. A sole owner can retain the existing
environment review policy without adding another GitHub account. The workflow
requires a configured reviewer and fails if it cannot verify that rule; it
never approves its own environment job.
It publishes an app SBOM/build provenance, an artifact attestation and a Cosign
signature, then verifies the signature against this repository/workflow identity.

No stable/version alias, Git tag, HA canary install or production change is
performed by that candidate workflow. Production promotion requires a separate
owner-authorized action identifying the exact source and immutable signed image,
with a current Supervisor backup, rollback route and successful canary on the
intended HA host. The old schema-2 promotion/alias automation has been retired;
it must not be used to promote the native image with legacy evidence.

Local qualification does not prove CI ran, registry publication/signing succeeded,
repository protection is configured, or the app works on native ARM hardware.
Record those outcomes only when the corresponding actions actually complete.
