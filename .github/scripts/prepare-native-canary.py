#!/usr/bin/env python3
"""Prepare a review-only isolated Home Assistant app descriptor.

This tool reads one committed public config.yaml with `git show` and writes a
new canary descriptor outside the source checkout. It never connects to Home
Assistant, reads saved Home Assistant app options, installs an app, or verifies
an image digest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any


SOURCE_APP_SLUG = "zeroclaw"
CANARY_APP_SLUG = "zeroclaw_canary"
CANARY_APP_NAME = "ZeroClaw Agent Canary"
BOOTSTRAP_SENTINEL = "canary-bootstrap-no-provider"
IMAGE_REPOSITORY_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*(?:/[a-z0-9][a-z0-9._-]*)+$")
SOURCE_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
IMAGE_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
RUN_ID_RE = re.compile(r"^(?:0|[1-9][0-9]*)$")
POSITIVE_NUMBER_RE = re.compile(r"^[1-9][0-9]*$")


class PreparationError(ValueError):
    """The supplied candidate metadata or source descriptor is not safe."""


def _scalar_value(line: str, prefix: str) -> str:
    if not line.startswith(prefix):
        raise PreparationError("descriptor line did not match its expected key")
    value = line[len(prefix) :].rstrip("\r\n").strip()
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        return value[1:-1]
    if value.startswith("'") and value.endswith("'") and len(value) >= 2:
        return value[1:-1]
    if "#" in value:
        raise PreparationError("descriptor scalar contains an unsupported inline comment")
    return value


def _replace_scalar(
    text: str,
    key: str,
    expected: str,
    replacement: str,
    *,
    indent: int = 0,
    quote: bool = False,
) -> str:
    prefix = (" " * indent) + f"{key}:"
    lines = text.splitlines(keepends=True)
    matches = [index for index, line in enumerate(lines) if line.startswith(prefix)]
    if len(matches) != 1:
        raise PreparationError(f"descriptor must contain exactly one {key} field")

    index = matches[0]
    line = lines[index]
    value = _scalar_value(line, prefix)
    if value != expected:
        raise PreparationError(f"descriptor {key} field did not match the expected source value")

    newline = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
    rendered = f'{replacement}'
    if quote:
        rendered = f'"{rendered}"'
    lines[index] = f"{prefix} {rendered}{newline}"
    return "".join(lines)


def _options_bounds(lines: list[str]) -> tuple[int, int]:
    starts = [index for index, line in enumerate(lines) if line.rstrip("\r\n") == "options:"]
    if len(starts) != 1:
        raise PreparationError("descriptor must contain exactly one top-level options block")
    start = starts[0] + 1
    end = len(lines)
    for index in range(start, len(lines)):
        line = lines[index]
        if line.strip() and not line[0].isspace() and not line.lstrip().startswith("#"):
            end = index
            break
    return start, end


def _read_option(text: str, key: str) -> str:
    lines = text.splitlines(keepends=True)
    start, end = _options_bounds(lines)
    prefix = f"  {key}:"
    matches = [line for line in lines[start:end] if line.startswith(prefix)]
    if len(matches) != 1:
        raise PreparationError(f"descriptor must contain exactly one default option {key}")
    return _scalar_value(matches[0], prefix)


def _replace_option(
    text: str,
    key: str,
    expected: str,
    replacement: str,
    *,
    quote: bool | None = None,
) -> str:
    lines = text.splitlines(keepends=True)
    start, end = _options_bounds(lines)
    prefix = f"  {key}:"
    matches = [index for index in range(start, end) if lines[index].startswith(prefix)]
    if len(matches) != 1:
        raise PreparationError(f"descriptor must contain exactly one default option {key}")

    index = matches[0]
    line = lines[index]
    if _scalar_value(line, prefix) != expected:
        raise PreparationError(f"descriptor default {key} did not match the expected value")
    newline = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
    if quote is None:
        quote = replacement == ""
    rendered = f'"{replacement}"' if quote else replacement
    lines[index] = f"{prefix} {rendered}{newline}"
    return "".join(lines)


def _version(source_commit: str, run_id: str, run_attempt: str) -> str:
    if not SOURCE_COMMIT_RE.fullmatch(source_commit):
        raise PreparationError("source commit must be a full lowercase 40-character Git SHA")
    if not RUN_ID_RE.fullmatch(run_id):
        raise PreparationError("run ID must be a positive workflow ID or 0 for local review")
    if not POSITIVE_NUMBER_RE.fullmatch(run_attempt):
        raise PreparationError("run attempt must be a positive integer")
    if run_id == "0" and run_attempt != "1":
        raise PreparationError("local review uses run ID 0 and attempt 1")
    return f"4.0.0-dev.g{source_commit[:12]}.{run_id}.{run_attempt}"


def render_descriptor(
    source_descriptor: bytes,
    *,
    source_commit: str,
    run_id: str,
    run_attempt: str,
    image_tag: str,
    image_digest: str,
) -> tuple[bytes, dict[str, Any]]:
    """Render the isolated app config and a receipt that explicitly is unverified."""

    version = _version(source_commit, run_id, run_attempt)
    if image_tag != version:
        raise PreparationError("published image tag must exactly match the Supervisor app version")
    if not IMAGE_DIGEST_RE.fullmatch(image_digest):
        raise PreparationError("image digest must have the form sha256:<64 lowercase hex characters>")

    try:
        text = source_descriptor.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PreparationError("committed descriptor is not UTF-8") from exc

    if text.count("\x00"):
        raise PreparationError("committed descriptor contains a NUL byte")

    source_slug = _read_top_level(text, "slug")
    image_repository = _read_top_level(text, "image")
    source_version = _read_top_level(text, "version")
    if source_slug != SOURCE_APP_SLUG:
        raise PreparationError("committed descriptor is not the canonical ZeroClaw app")
    if source_version != "4.0.0.0":
        raise PreparationError("committed descriptor version is not the expected stable source version")
    if not IMAGE_REPOSITORY_RE.fullmatch(image_repository) or ":" in image_repository:
        raise PreparationError("canonical image must be an untagged lowercase repository")
    if not re.search(r"(?m)^arch:\r?\n  - aarch64\r?$", text):
        raise PreparationError("canonical descriptor must declare aarch64 support")

    # Read only tracked defaults from the exact source commit. Never inspect or
    # import a live app's saved options.
    for key in ("openrouter_api_key", "telegram_bot_token", "telegram_owner_id", "ha_mcp_url", "ha_mcp_token"):
        if _read_option(text, key) != "":
            raise PreparationError(f"canonical default {key} must be empty")
    if _read_option(text, "ha_mcp_enabled") != "false":
        raise PreparationError("canonical Home Assistant MCP default must be disabled")

    rendered = text
    rendered = _replace_scalar(rendered, "name", _read_top_level(rendered, "name"), CANARY_APP_NAME)
    rendered = _replace_scalar(rendered, "version", source_version, version, quote=True)
    rendered = _replace_scalar(rendered, "slug", source_slug, CANARY_APP_SLUG)
    rendered = _replace_scalar(rendered, "image", image_repository, image_repository)
    rendered = _replace_scalar(rendered, "boot", _read_top_level(rendered, "boot"), "manual")
    rendered = _replace_scalar(
        rendered,
        "description",
        _read_top_level(rendered, "description"),
        "Isolated native candidate with fresh app data and integrations disabled.",
    )
    rendered = _replace_option(rendered, "openrouter_api_key", "", BOOTSTRAP_SENTINEL, quote=True)
    rendered = _replace_option(rendered, "telegram_bot_token", "", "")
    rendered = _replace_option(rendered, "ha_mcp_enabled", "false", "false")
    rendered = _replace_option(rendered, "ha_mcp_url", "", "")
    rendered = _replace_option(rendered, "ha_mcp_token", "", "")

    descriptor_bytes = rendered.encode("utf-8")
    receipt = {
        "schema_version": 1,
        "artifact_kind": "review_only_isolated_home_assistant_app_descriptor",
        "verification_status": "UNVERIFIED_LOCAL_RENDER_ONLY",
        "source_commit": source_commit,
        "source_descriptor_sha256": hashlib.sha256(source_descriptor).hexdigest(),
        "candidate_version": version,
        "candidate_run_id": int(run_id),
        "candidate_run_attempt": int(run_attempt),
        "candidate_context": "local_review_only" if run_id == "0" else "release_run_claimed_unverified",
        "source_app_slug": SOURCE_APP_SLUG,
        "canary_app_name": CANARY_APP_NAME,
        "canary_app_slug": CANARY_APP_SLUG,
        "image_repository": image_repository,
        "image_tag": image_tag,
        "image_digest_unverified": image_digest,
        "image_reference_unverified": f"{image_repository}:{image_tag}@{image_digest}",
        "descriptor_sha256": hashlib.sha256(descriptor_bytes).hexdigest(),
        "homeassistant_arch": "aarch64",
        "boot_mode": "manual",
        "provider_bootstrap_sentinel": BOOTSTRAP_SENTINEL,
        "provider_credential_status": "no_real_provider_credential",
        "model_turn_qualification": False,
        "telegram_default_enabled": False,
        "ha_mcp_default_enabled": False,
        "state_policy": "fresh app data; no production state or saved options are read or copied",
        "notice": (
            "The supplied digest, source SHA, and run metadata are recorded but not verified by this tool. "
            "This receipt is not a signature, provenance check, backup proof, or approval to install."
        ),
    }
    return descriptor_bytes, receipt


def _read_top_level(text: str, key: str) -> str:
    prefix = f"{key}:"
    lines = [line for line in text.splitlines(keepends=True) if line.startswith(prefix)]
    if len(lines) != 1:
        raise PreparationError(f"descriptor must contain exactly one top-level {key} field")
    return _scalar_value(lines[0], prefix)


def _source_descriptor(repo_root: Path, source_commit: str) -> bytes:
    if not SOURCE_COMMIT_RE.fullmatch(source_commit):
        raise PreparationError("source commit must be a full lowercase 40-character Git SHA")
    try:
        result = subprocess.run(
            ["git", "show", f"{source_commit}:zeroclaw/config.yaml"],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise PreparationError("could not read zeroclaw/config.yaml from the requested source commit") from exc
    return result.stdout


def _output_outside_checkout(repo_root: Path, output_dir: Path) -> tuple[Path, Path]:
    root = repo_root.resolve()
    target = output_dir.resolve()
    try:
        target.relative_to(root)
    except ValueError:
        pass
    else:
        raise PreparationError("output directory must be outside the source checkout")
    if not target.parent.is_dir():
        raise PreparationError("output directory parent must already exist")
    if target.exists() or target.is_symlink():
        raise PreparationError("output directory already exists; refusing to overwrite it")
    return root, target


def prepare_bundle(
    repo_root: Path,
    output_dir: Path,
    *,
    source_commit: str,
    run_id: str,
    run_attempt: str,
    image_tag: str,
    image_digest: str,
) -> None:
    root, target = _output_outside_checkout(repo_root, output_dir)
    source = _source_descriptor(root, source_commit)
    descriptor, receipt = render_descriptor(
        source,
        source_commit=source_commit,
        run_id=run_id,
        run_attempt=run_attempt,
        image_tag=image_tag,
        image_digest=image_digest,
    )

    # Exclusive mkdir prevents an existing directory from being overwritten.
    target.mkdir(mode=0o755)
    try:
        app_directory = target / CANARY_APP_SLUG
        app_directory.mkdir(mode=0o755)
        descriptor_path = app_directory / "config.yaml"
        with descriptor_path.open("xb") as output:
            output.write(descriptor)
        os.chmod(descriptor_path, 0o644)

        receipt_path = target / "candidate-evidence.json"
        payload = (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode("utf-8")
        with receipt_path.open("xb") as output:
            output.write(payload)
        os.chmod(receipt_path, 0o644)
    except BaseException:
        shutil.rmtree(target, ignore_errors=True)
        raise


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True, help="Use 0 only for local review, not a CI run")
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--image-tag", required=True, help="Must match the generated Supervisor version")
    parser.add_argument("--image-digest", required=True, help="Recorded as unverified; must come from a separate check")
    parser.add_argument("--output-dir", required=True, type=Path, help="New directory outside the source checkout")
    args = parser.parse_args(argv)

    try:
        prepare_bundle(
            _repo_root(),
            args.output_dir,
            source_commit=args.source_commit,
            run_id=args.run_id,
            run_attempt=args.run_attempt,
            image_tag=args.image_tag,
            image_digest=args.image_digest,
        )
    except PreparationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except OSError:
        print("ERROR: could not write the review-only descriptor bundle", file=sys.stderr)
        return 1

    print("CANARY_DESCRIPTOR_PREPARED review_only=true digest_verified=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
