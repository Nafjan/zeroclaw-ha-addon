# Native app delivery

The app consumes the official pinned ZeroClaw 0.8.7 ARM64 release archive. The
Docker build verifies its download and executable hashes and includes the
pinned upstream license files. This is not an independent reproduction of the
upstream Rust build. The app image has its own source revision and provenance.

The native qualification script verifies upstream release/source metadata and
runs the isolated ARM64 image fixture. The reusable Tests workflow also runs
configuration, recovery, real HA MCP and old/new binary state checks. ARM64
execution on a hosted x86 runner is emulated, not a hardware qualification.

Before production promotion, keep the protected-branch checks named
`Bats unit tests`, `Shell parsing and ShellCheck`, and `Build and smoke-test arm64 image`. Also require
`Native HA MCP and state compatibility` for the native release. Keep strict
checks, required independent review, admin enforcement, linear history,
conversation resolution and force-push/deletion protection. These settings
are external repository controls; a passing local script does not configure
or attest them. The operator preflight is
`.github/scripts/verify-master-protection.sh OWNER/REPOSITORY master`.

`release.yml` publishes uniquely named candidates from an explicit branch
dispatch. For a canary, dispatch the exact reviewed development branch; do
not merge its future stable descriptor into the production store branch to
enable publication. Do not add the source branch to the HA Store. The canary
uses a separate descriptor-only branch offering only `zeroclaw_canary`.

The workflow rejects tag dispatches and builds the selected event commit. It
first runs all four acceptance jobs, then uses the `release-builder`
environment with its configured required reviewer. That is the owner's release
approval; the independent technical source review is recorded separately in
`zeroclaw/ARCHITECTURE-REVIEWS.md`. A sole owner can retain the existing
environment review policy without adding another GitHub account. The workflow
requires a configured reviewer and fails if it cannot verify that rule; it
never approves its own environment job.
It publishes an app SBOM/build provenance, an artifact attestation and a Cosign
signature, then verifies the signature against this repository/workflow and
selected branch identity. The read-only candidate verifier takes the expected
`--source-ref refs/heads/<reviewed-branch>` from the operator, together with the
expected full source SHA; it never derives verification policy from an image.
Its default remains `refs/heads/master` for callers that explicitly qualify
that branch. Confirm the environment permits the selected branch while
retaining its required reviewer. Include `release.yml` and `test.yml` in the
review of that exact source commit and confirm its four acceptance results
before approving the environment job.

No stable/version alias, Git tag, HA canary install or production change is
performed by that candidate workflow. Production promotion requires a separate
owner-authorized action identifying the exact source and immutable signed image,
with a current Supervisor backup, rollback route and successful canary on the
intended HA host. The old schema-2 promotion/alias automation has been retired;
it must not be used to promote the native image with legacy evidence.

Local qualification does not prove CI ran, registry publication/signing succeeded,
repository protection is configured, or the app works on native ARM hardware.
Record those outcomes only when the corresponding actions actually complete.

Keep the production store descriptor unchanged until a successful native
canary and a separately authorized signed stable image are available. A
`breaking_versions` entry can block automatic crossing of the breaking
version; it does not make an unpublished image available for manual updates.
Only then publish the stable descriptor through the production branch process.
The candidate workflow does not publish that stable image or perform that
promotion. GitHub documents the selected dispatch ref and commit in its
[workflow dispatch semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch);
Home Assistant documents [app identity and update behavior](https://contributors.home-assistant.io/apps/how-apps-work/).
