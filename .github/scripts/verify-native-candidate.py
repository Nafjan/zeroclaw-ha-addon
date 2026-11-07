#!/usr/bin/env python3
"""Verify the immutable, signed ARM64 native candidate before a HA canary."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


IMAGE = "ghcr.io/nafjan/zeroclaw-ha-addon"
REPOSITORY = "Nafjan/zeroclaw-ha-addon"
WORKFLOW = "Nafjan/zeroclaw-ha-addon/.github/workflows/release.yml"
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
DEFAULT_SOURCE_REF = "refs/heads/master"
_SAFE_BRANCH_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MEDIA_TYPES = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


class VerificationError(Exception):
    """The candidate failed a required identity or artifact check."""


def candidate_identity(source_sha: str, run_id: str, attempt: str) -> tuple[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise VerificationError("source SHA must be a full lowercase 40-character commit")
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", attempt):
        raise VerificationError("run ID and attempt must be positive decimal integers")
    version = f"4.0.0-dev.g{source_sha[:12]}.{run_id}.{attempt}"
    return version, version


def validate_source_ref(source_ref: str) -> str:
    """Accept only a conservative Git branch ref for provenance verification."""
    prefix = "refs/heads/"
    if not source_ref.startswith(prefix):
        raise VerificationError("source ref must use refs/heads/<branch>")
    branch = source_ref[len(prefix) :]
    components = branch.split("/")
    if (
        not branch
        or any(
            not _SAFE_BRANCH_COMPONENT.fullmatch(component)
            or ".." in component
            or component.endswith(".")
            or component.lower().endswith(".lock")
            for component in components
        )
    ):
        raise VerificationError("source ref contains an invalid branch name")
    return source_ref


def digest_of(payload: bytes) -> str:
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def _request(url: str, *, token: str | None = None, accept: str | None = None) -> tuple[bytes, Any]:
    headers: dict[str, str] = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if accept:
        headers["Accept"] = accept
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read(16 * 1024 * 1024 + 1), response.headers
    except (urllib.error.URLError, TimeoutError) as error:
        raise VerificationError("could not read public candidate registry metadata") from error


def _anonymous_registry_token(repository: str) -> str:
    query = urllib.parse.urlencode(
        {"service": "ghcr.io", "scope": f"repository:{repository}:pull"}
    )
    payload, _ = _request(f"https://ghcr.io/token?{query}")
    try:
        token = json.loads(payload)["token"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise VerificationError("public registry did not provide a pull-only metadata token") from error
    if not isinstance(token, str) or not token:
        raise VerificationError("public registry returned an invalid metadata token")
    return token


def _registry_resource(token: str, repository: str, resource: str, accept: str | None = None) -> tuple[bytes, Any]:
    url = f"https://ghcr.io/v2/{repository}/{resource}"
    payload, headers = _request(url, token=token, accept=accept)
    if len(payload) > 16 * 1024 * 1024:
        raise VerificationError("registry metadata object exceeded the 16 MiB safety limit")
    return payload, headers


def _manifest_digest(payload: bytes, headers: Any) -> str:
    computed = digest_of(payload)
    header_digest = headers.get("Docker-Content-Digest")
    if header_digest and header_digest != computed:
        raise VerificationError("registry manifest digest header did not match its content")
    return computed


def _read_manifest(token: str, repository: str, reference: str) -> tuple[dict[str, Any], str]:
    payload, headers = _registry_resource(
        token, repository, f"manifests/{reference}", MEDIA_TYPES
    )
    digest = _manifest_digest(payload, headers)
    try:
        manifest = json.loads(payload)
    except json.JSONDecodeError as error:
        raise VerificationError("registry returned malformed image manifest metadata") from error
    if not isinstance(manifest, dict):
        raise VerificationError("registry image manifest must be a JSON object")
    return manifest, digest


def _arm64_manifest(
    token: str, repository: str, top: dict[str, Any], top_digest: str
) -> tuple[dict[str, Any], str]:
    descriptors = top.get("manifests")
    if descriptors is None:
        return top, top_digest
    arm64 = [
        descriptor
        for descriptor in descriptors
        if descriptor.get("platform", {}).get("os") == "linux"
        and descriptor.get("platform", {}).get("architecture") == "arm64"
    ]
    if len(arm64) != 1:
        raise VerificationError("candidate index must contain exactly one linux/arm64 image")
    child_digest = arm64[0].get("digest", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", child_digest):
        raise VerificationError("ARM64 image manifest digest is malformed")
    child, actual_digest = _read_manifest(token, repository, child_digest)
    if actual_digest != child_digest:
        raise VerificationError("ARM64 child manifest did not match its index digest")
    return child, child_digest


def _load_runtime_pins(path: Path) -> dict[str, str]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        candidate = document["candidate"]
        return {
            "io.zeroclaw.runtime.version": candidate["version"],
            "io.zeroclaw.runtime.source.revision": candidate["source_commit"],
            "io.zeroclaw.runtime.target": candidate["target"],
            "io.zeroclaw.runtime.release-archive-sha256": candidate["release_asset_sha256"],
            "io.zeroclaw.runtime.binary-sha256": candidate["runtime_binary_sha256"],
        }
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise VerificationError("runtime-manifest.json is missing valid immutable runtime pins") from error


def verify_image_config(
    config: dict[str, Any], *, source_sha: str, app_version: str, runtime_labels: dict[str, str]
) -> None:
    if config.get("os") != "linux" or config.get("architecture") != "arm64":
        raise VerificationError("candidate config is not linux/arm64")
    labels = config.get("config", {}).get("Labels") or {}
    expected = {
        "org.opencontainers.image.version": app_version,
        "org.opencontainers.image.revision": source_sha,
        "io.hass.version": app_version,
        "io.hass.type": "app",
        "io.hass.arch": "aarch64",
        "io.zeroclaw.app.source.revision": source_sha,
        **runtime_labels,
    }
    mismatches = [key for key, value in expected.items() if labels.get(key) != value]
    if mismatches:
        raise VerificationError("candidate OCI labels did not match the expected source/runtime pins: " + ", ".join(mismatches))


def _verify_oci_metadata(
    *, tag: str, expected_digest: str, source_sha: str, app_version: str, runtime_labels: dict[str, str]
) -> None:
    repository = IMAGE.removeprefix("ghcr.io/")
    token = _anonymous_registry_token(repository)
    tagged, tag_digest = _read_manifest(token, repository, tag)
    if tag_digest != expected_digest:
        raise VerificationError("candidate tag no longer resolves to the supplied immutable digest")
    if not isinstance(tagged.get("schemaVersion"), int) or tagged["schemaVersion"] != 2:
        raise VerificationError("candidate tag did not resolve to an OCI/Docker schema 2 image")
    image_manifest, arm64_digest = _arm64_manifest(token, repository, tagged, tag_digest)
    if arm64_digest == tag_digest and "manifests" in tagged:
        raise VerificationError("candidate index did not resolve to a distinct ARM64 image manifest")
    config_descriptor = image_manifest.get("config", {})
    config_digest = config_descriptor.get("digest", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", config_digest):
        raise VerificationError("ARM64 image config digest is malformed")
    config_payload, _ = _registry_resource(token, repository, f"blobs/{config_digest}")
    if digest_of(config_payload) != config_digest:
        raise VerificationError("ARM64 image config blob did not match its descriptor digest")
    try:
        config = json.loads(config_payload)
    except json.JSONDecodeError as error:
        raise VerificationError("ARM64 image config blob was malformed") from error
    verify_image_config(
        config,
        source_sha=source_sha,
        app_version=app_version,
        runtime_labels=runtime_labels,
    )


def _run_readonly(command: list[str], purpose: str) -> None:
    try:
        result = subprocess.run(command, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        raise VerificationError(f"required verification tool could not start: {purpose}") from error
    if result.returncode != 0:
        raise VerificationError(f"cryptographic verification failed: {purpose} (exit {result.returncode})")


def verify_signatures(
    image_digest: str, source_sha: str, source_ref: str = DEFAULT_SOURCE_REF
) -> None:
    source_ref = validate_source_ref(source_ref)
    if not shutil.which("gh"):
        raise VerificationError("GitHub CLI (`gh`) is required to verify the provenance attestation")
    if not shutil.which("cosign"):
        raise VerificationError("Cosign is required to verify the candidate signature")
    oci_ref = f"oci://{image_digest}"
    _run_readonly(
        [
            "gh",
            "attestation",
            "verify",
            oci_ref,
            "--repo",
            REPOSITORY,
            "--bundle-from-oci",
            "--signer-workflow",
            WORKFLOW,
            "--source-digest",
            source_sha,
            "--source-ref",
            source_ref,
            "--deny-self-hosted-runners",
        ],
        "GitHub Actions provenance and source identity",
    )
    identity = f"https://github.com/{REPOSITORY}/.github/workflows/release.yml@{source_ref}"
    _run_readonly(
        [
            "cosign",
            "verify",
            f"--certificate-identity={identity}",
            f"--certificate-oidc-issuer={OIDC_ISSUER}",
            image_digest,
        ],
        "keyless Cosign signature identity",
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify a signed ARM64 native candidate by immutable digest before a HA canary."
    )
    parser.add_argument("--digest", required=True, help="image digest, sha256:<64 lowercase hex>")
    parser.add_argument("--source-sha", required=True, help="full 40-character source commit SHA")
    parser.add_argument("--run-id", required=True, help="GitHub Actions run ID")
    parser.add_argument("--attempt", required=True, help="GitHub Actions run attempt")
    parser.add_argument(
        "--source-ref",
        default=DEFAULT_SOURCE_REF,
        help="expected reviewed Git branch ref (default: refs/heads/master)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.digest):
            raise VerificationError("candidate digest must be sha256 followed by 64 lowercase hex characters")
        source_ref = validate_source_ref(args.source_ref)
        tag, app_version = candidate_identity(args.source_sha, args.run_id, args.attempt)
        runtime_labels = _load_runtime_pins(
            Path(__file__).resolve().parents[2] / "zeroclaw" / "runtime-manifest.json"
        )
        image_digest = f"{IMAGE}@{args.digest}"
        _verify_oci_metadata(
            tag=tag,
            expected_digest=args.digest,
            source_sha=args.source_sha,
            app_version=app_version,
            runtime_labels=runtime_labels,
        )
        verify_signatures(image_digest, args.source_sha, source_ref)
    except VerificationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print(f"PASS: {image_digest}")
    print(f"Source: {args.source_sha}")
    print(f"Source ref: {source_ref}")
    print(f"Candidate tag: {tag}")
    print(f"Home Assistant version: {app_version}")
    print("Verified: public OCI config metadata, ARM64 runtime pins, GitHub provenance, and Cosign identity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
