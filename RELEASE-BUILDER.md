# Release builder qualification

The checked-in ZeroClaw artifact is authoritative only when the release workflow
rebuilds it to the SHA in `zeroclaw/binary-manifest.json`. The standard hosted
runner is retained for acceptance and diagnostics, but it is not an authoritative
compiler: isolated hosted A/A builds have repeatedly produced the byte-identical
`2654bb878d0cf7d7644a193f5c3be00a51c39e1af78871ded6f3b1887c755827` family while
the manifest remains `a3c5edcb3257ea48bce41629e3b52bcbf5fd59858bac3c7fbfbb0808e18b1341`.

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

## Qualification gate

After the runner is online, dispatch the exact release workflow twice, recreating
or rebooting the runner between runs:

```text
gh workflow run release.yml --ref master \
  -f release_tag=v3.1.3.5 \
  -f promote=false \
  -f builder_mode=trusted-aa
```

Every run must show both isolated builders producing the authoritative SHA. The
uploaded diagnostics must also show identical full dependency manifests and the
captured `rlib`/`rmeta` artifacts for `channels`, `gateway`, `runtime`, and the
root `zeroclaw` crate. A matching non-authoritative SHA, a mismatch between A and
B, or a missing diagnostic is a failed qualification; do not regenerate the
manifest.

Only after two clean qualifications should the exact signed candidate be used for
the authenticated Home Assistant canary. Promotion remains a separate protected
dispatch and must supply the candidate digest plus durable backup, rollback, and
canary evidence.
