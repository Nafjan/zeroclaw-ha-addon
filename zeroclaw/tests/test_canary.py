from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / ".github" / "scripts" / "prepare-native-canary.py"
SPEC = importlib.util.spec_from_file_location("prepare_native_canary", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
CANARY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CANARY
SPEC.loader.exec_module(CANARY)


SOURCE_DESCRIPTOR = (ROOT / "zeroclaw" / "config.yaml").read_bytes()
SOURCE_COMMIT = "0" * 40
RUN_ID = "0"
RUN_ATTEMPT = "1"
VERSION = f"4.0.0-dev.g{SOURCE_COMMIT[:12]}.{RUN_ID}.{RUN_ATTEMPT}"
IMAGE_DIGEST = "sha256:" + "a" * 64


class CanaryDescriptorTests(unittest.TestCase):
    def render(self, **overrides):
        values = {
            "source_commit": SOURCE_COMMIT,
            "run_id": RUN_ID,
            "run_attempt": RUN_ATTEMPT,
            "image_tag": VERSION,
            "image_digest": IMAGE_DIGEST,
        }
        values.update(overrides)
        return CANARY.render_descriptor(SOURCE_DESCRIPTOR, **values)

    def test_render_uses_isolated_identity_and_safe_defaults(self):
        descriptor, receipt = self.render()
        text = descriptor.decode("utf-8")

        self.assertIn("name: ZeroClaw Agent Canary", text)
        self.assertIn(f'version: "{VERSION}"', text)
        self.assertIn("slug: zeroclaw_canary", text)
        self.assertIn("boot: manual", text)
        self.assertIn('  openrouter_api_key: "canary-bootstrap-no-provider"', text)
        self.assertIn('  telegram_bot_token: ""', text)
        self.assertIn("  ha_mcp_enabled: false", text)
        self.assertIn('  ha_mcp_url: ""', text)
        self.assertIn('  ha_mcp_token: ""', text)
        self.assertIn("image: ghcr.io/nafjan/zeroclaw-ha-addon", text)
        self.assertNotIn(f"image: ghcr.io/nafjan/zeroclaw-ha-addon:{VERSION}", text)

        self.assertEqual(receipt["canary_app_slug"], "zeroclaw_canary")
        self.assertEqual(receipt["candidate_version"], VERSION)
        self.assertEqual(receipt["image_digest_unverified"], IMAGE_DIGEST)
        self.assertEqual(receipt["verification_status"], "UNVERIFIED_LOCAL_RENDER_ONLY")
        self.assertEqual(receipt["provider_bootstrap_sentinel"], "canary-bootstrap-no-provider")
        self.assertEqual(receipt["provider_credential_status"], "no_real_provider_credential")
        self.assertFalse(receipt["model_turn_qualification"])
        self.assertFalse(receipt["telegram_default_enabled"])
        self.assertFalse(receipt["ha_mcp_default_enabled"])

    def test_all_zero_sha_is_rendered_as_semver_safe_prerelease(self):
        descriptor, receipt = self.render()
        version = receipt["candidate_version"]
        self.assertRegex(version, r"^4\.0\.0-dev\.g[0-9a-f]{12}\.0\.1$")
        self.assertIn(version.encode(), descriptor)

    def test_image_tag_must_match_supervisor_version(self):
        with self.assertRaisesRegex(CANARY.PreparationError, "image tag"):
            self.render(image_tag="candidate-not-the-supervisor-version")

    def test_digest_must_be_sha256(self):
        with self.assertRaisesRegex(CANARY.PreparationError, "image digest"):
            self.render(image_digest="sha256:abc")

    def test_canonical_descriptor_slug_must_be_expected(self):
        bad = SOURCE_DESCRIPTOR.replace(b"slug: zeroclaw", b"slug: unexpected", 1)
        self.assertNotEqual(bad, SOURCE_DESCRIPTOR)
        with self.assertRaisesRegex(CANARY.PreparationError, "canonical ZeroClaw"):
            CANARY.render_descriptor(
                bad,
                source_commit=SOURCE_COMMIT,
                run_id=RUN_ID,
                run_attempt=RUN_ATTEMPT,
                image_tag=VERSION,
                image_digest=IMAGE_DIGEST,
            )

    def test_nonempty_sensitive_source_default_is_rejected(self):
        bad = SOURCE_DESCRIPTOR.replace(
            b'  telegram_bot_token: ""',
            b'  telegram_bot_token: "placeholder"',
            1,
        )
        with self.assertRaisesRegex(CANARY.PreparationError, "telegram_bot_token"):
            CANARY.render_descriptor(
                bad,
                source_commit=SOURCE_COMMIT,
                run_id=RUN_ID,
                run_attempt=RUN_ATTEMPT,
                image_tag=VERSION,
                image_digest=IMAGE_DIGEST,
            )

    def test_rejects_invalid_commit_and_invalid_run_metadata(self):
        with self.assertRaisesRegex(CANARY.PreparationError, "full lowercase"):
            self.render(source_commit="not-a-commit")
        with self.assertRaisesRegex(CANARY.PreparationError, "run attempt"):
            self.render(run_attempt="0")
        with self.assertRaisesRegex(CANARY.PreparationError, "run ID"):
            self.render(run_id="01")

    def test_output_must_be_outside_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            repo = parent / "repo"
            repo.mkdir()
            output = repo / "candidate-output"
            with patch.object(CANARY, "_source_descriptor", side_effect=AssertionError("should not read source")):
                with self.assertRaisesRegex(CANARY.PreparationError, "outside the source checkout"):
                    CANARY.prepare_bundle(
                        repo,
                        output,
                        source_commit=SOURCE_COMMIT,
                        run_id=RUN_ID,
                        run_attempt=RUN_ATTEMPT,
                        image_tag=VERSION,
                        image_digest=IMAGE_DIGEST,
                    )

    def test_bundle_is_written_outside_checkout_and_receipt_disclaims_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            repo = parent / "repo"
            repo.mkdir()
            output = parent / "candidate-review"
            result = subprocess.CompletedProcess(
                args=["git", "show"],
                returncode=0,
                stdout=SOURCE_DESCRIPTOR,
                stderr=b"",
            )
            with patch.object(CANARY.subprocess, "run", return_value=result) as git_show:
                CANARY.prepare_bundle(
                    repo,
                    output,
                    source_commit=SOURCE_COMMIT,
                    run_id=RUN_ID,
                    run_attempt=RUN_ATTEMPT,
                    image_tag=VERSION,
                    image_digest=IMAGE_DIGEST,
                )

            self.assertEqual(git_show.call_args.args[0], ["git", "show", f"{SOURCE_COMMIT}:zeroclaw/config.yaml"])
            self.assertTrue((output / "zeroclaw_canary" / "config.yaml").is_file())
            receipt_path = output / "candidate-evidence.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["verification_status"], "UNVERIFIED_LOCAL_RENDER_ONLY")
            self.assertEqual(
                receipt["descriptor_sha256"],
                hashlib.sha256((output / "zeroclaw_canary" / "config.yaml").read_bytes()).hexdigest(),
            )
            self.assertNotIn(str(output), receipt_path.read_text(encoding="utf-8"))
            self.assertNotIn("placeholder", receipt_path.read_text(encoding="utf-8"))

    def test_existing_output_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            repo = parent / "repo"
            repo.mkdir()
            output = parent / "candidate-review"
            output.mkdir()
            sentinel = output / "keep.txt"
            sentinel.write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(CANARY.PreparationError, "already exists"):
                CANARY.prepare_bundle(
                    repo,
                    output,
                    source_commit=SOURCE_COMMIT,
                    run_id=RUN_ID,
                    run_attempt=RUN_ATTEMPT,
                    image_tag=VERSION,
                    image_digest=IMAGE_DIGEST,
                )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
