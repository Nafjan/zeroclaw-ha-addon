# Release builder qualification

The checked-in ZeroClaw artifact is authoritative only when the release workflow
rebuilds it to the SHA in `zeroclaw/binary-manifest.json`. The previous checked-in
`a3c5edcb3257ea48bce41629e3b52bcbf5fd59858bac3c7fbfbb0808e18b1341` artifact was
not reproduced by any recorded release workflow. The pinned Cross route now
produces byte-identical `1a3911d3cc776e3f0041b3c6a5b9eb1009d976aa556e73a7afd1c713e5d37c54`
outputs across clean Cargo-job variants, and the trusted Docker Desktop A/A
qualification produced the same SHA in both isolated builders. That re-qualified
SHA is the current manifest artifact; do not substitute a different binary.

## Trusted runner contract

Register a protected Linux x64 self-hosted runner with the custom label
`zeroclaw-release-linux-x64`. It must provide:

- Docker in Linux-container mode;
- `bash`, `git`, `jq`, `sha256sum`, `stat`, `rustup`, `rustc`, and `cargo`;
- the pinned Rust 1.89.0 toolchain and target installation path;
- a reproducible host image or an ephemeral VM that can be recreated after a run;
- no Home Assistant token, provider credential, or other production secret.

Restrict the runner group to this repository and to protected release work. Do
not attach it to pull-request workflows or run arbitrary branches on it. Configure
a `release-builder` environment with required reviewers before using the trusted
mode. The workflow itself additionally requires `refs/heads/master` for that mode.

Protect `master` with strict required checks named `Bats unit tests`, `Shell
parsing and ShellCheck`, and `Build and smoke-test arm64 image`; also enable
admin enforcement, linear history, and conversation resolution, and disable
force-pushes and branch deletion. Before dispatching a promotion, run
`.github/scripts/verify-master-protection.sh` with an authenticated GitHub CLI.
The branch-protection setting is the external hard control; Actions'
`GITHUB_TOKEN` does not have repository Administration permission and is not
used to self-attest that setting.

## Qualification gate

After the runner is online, dispatch the exact release workflow twice, recreating
or rebooting the runner between runs:

```text
gh workflow run release.yml --ref master \
  -f release_tag=v3.1.4.0 \
  -f promote=false \
  -f builder_mode=trusted-aa
```

Every run must show both isolated builders producing
`1a3911d3cc776e3f0041b3c6a5b9eb1009d976aa556e73a7afd1c713e5d37c54`. The
uploaded diagnostics must also show identical full dependency manifests and the
captured `rlib`/`rmeta` artifacts for `channels`, `gateway`, `runtime`, and the
root `zeroclaw` crate. A matching non-authoritative SHA, a mismatch between A and
B, or a missing diagnostic is a failed qualification; do not regenerate the
manifest.

Only after two clean qualifications should the exact signed candidate be used
for production promotion. A temporary authenticated canary may use the hosted
Cross candidate when the `release-builder` environment approval is granted and
the alias workflow verifies the exact candidate run, digest, signature,
attestations, and descriptor. Promotion remains a separate protected dispatch
and must supply the trusted-aa candidate digest plus durable backup, rollback,
and canary evidence.
