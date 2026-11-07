import importlib.util
import io
from contextlib import redirect_stderr
from unittest import mock
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-native-candidate.py"
SPEC = importlib.util.spec_from_file_location("verify_native_candidate", SCRIPT)
assert SPEC and SPEC.loader
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class CandidateIdentityTests(unittest.TestCase):
    def test_identity_uses_supervisor_compatible_prerelease(self):
        tag, version = verifier.candidate_identity("a" * 40, "12345", "2")
        self.assertEqual(version, "4.0.0-dev.g" + "a" * 12 + ".12345.2")
        self.assertEqual(tag, version)

    def test_all_zero_sha_remains_a_non_numeric_semver_identifier(self):
        _, version = verifier.candidate_identity("0" * 40, "1", "1")
        self.assertEqual(version, "4.0.0-dev.g000000000000.1.1")

    def test_rejects_short_or_malformed_identity_fields(self):
        for sha, run_id, attempt in (("a" * 12, "1", "1"), ("A" * 40, "1", "1"), ("a" * 40, "0", "1"), ("a" * 40, "1", "01")):
            with self.subTest(sha=sha, run_id=run_id, attempt=attempt):
                with self.assertRaises(verifier.VerificationError):
                    verifier.candidate_identity(sha, run_id, attempt)


class ImageMetadataTests(unittest.TestCase):
    def test_runtime_label_pins_are_loaded_from_the_manifest(self):
        manifest = SCRIPT.parents[2] / "zeroclaw" / "runtime-manifest.json"
        labels = verifier._load_runtime_pins(manifest)
        self.assertEqual(labels["io.zeroclaw.runtime.version"], "0.8.7")
        self.assertEqual(
            labels["io.zeroclaw.runtime.source.revision"],
            "99bd353c756f4e64f381cfe9c3002ebff32f3055",
        )
        self.assertEqual(
            labels["io.zeroclaw.runtime.binary-sha256"],
            "f33279b7b42b54e56ea9dd1cc722e6d09e3c05533b6f70147d1f6d4dc204972f",
        )

    def test_accepts_expected_arm64_app_and_runtime_pins(self):
        sha = "a" * 40
        runtime = {
            "io.zeroclaw.runtime.version": "0.8.7",
            "io.zeroclaw.runtime.source.revision": "9" * 40,
            "io.zeroclaw.runtime.target": "aarch64-unknown-linux-musl",
            "io.zeroclaw.runtime.release-archive-sha256": "b" * 64,
            "io.zeroclaw.runtime.binary-sha256": "c" * 64,
        }
        labels = {
            "org.opencontainers.image.version": "4.0.0-dev.g" + "a" * 12 + ".12345.1",
            "org.opencontainers.image.revision": sha,
            "io.hass.version": "4.0.0-dev.g" + "a" * 12 + ".12345.1",
            "io.hass.type": "app",
            "io.hass.arch": "aarch64",
            "io.zeroclaw.app.source.revision": sha,
            **runtime,
        }
        verifier.verify_image_config(
            {"os": "linux", "architecture": "arm64", "config": {"Labels": labels}},
            source_sha=sha,
            app_version="4.0.0-dev.g" + "a" * 12 + ".12345.1",
            runtime_labels=runtime,
        )

    def test_rejects_app_version_or_architecture_mismatch(self):
        sha = "a" * 40
        with self.assertRaises(verifier.VerificationError):
            verifier.verify_image_config(
                {"os": "linux", "architecture": "amd64", "config": {"Labels": {}}},
                source_sha=sha,
                app_version="4.0.0-dev.g" + "a" * 12 + ".1.1",
                runtime_labels={},
            )


class SignatureVerificationTests(unittest.TestCase):
    def setUp(self):
        self.image_digest = f"{verifier.IMAGE}@sha256:{'b' * 64}"
        self.source_sha = "a" * 40

    def _assert_exact_signature_commands(self, source_ref=None):
        expected_source_ref = source_ref or verifier.DEFAULT_SOURCE_REF
        with mock.patch.object(verifier, "_run_readonly") as run_readonly, mock.patch.object(
            verifier.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"
        ):
            if source_ref is None:
                verifier.verify_signatures(self.image_digest, self.source_sha)
            else:
                verifier.verify_signatures(self.image_digest, self.source_sha, source_ref)

            self.assertEqual(run_readonly.call_count, 2)
            gh_command, gh_purpose = run_readonly.call_args_list[0].args
            self.assertEqual(gh_purpose, "GitHub Actions provenance and source identity")
            self.assertEqual(
                gh_command,
                [
                    "gh",
                    "attestation",
                    "verify",
                    f"oci://{self.image_digest}",
                    "--repo",
                    verifier.REPOSITORY,
                    "--bundle-from-oci",
                    "--signer-workflow",
                    verifier.WORKFLOW,
                    "--source-digest",
                    self.source_sha,
                    "--source-ref",
                    expected_source_ref,
                    "--deny-self-hosted-runners",
                ],
            )

            cosign_command, cosign_purpose = run_readonly.call_args_list[1].args
            self.assertEqual(cosign_purpose, "keyless Cosign signature identity")
            self.assertEqual(
                cosign_command,
                [
                    "cosign",
                    "verify",
                    "--certificate-identity=https://github.com/"
                    f"{verifier.REPOSITORY}/.github/workflows/release.yml@{expected_source_ref}",
                    f"--certificate-oidc-issuer={verifier.OIDC_ISSUER}",
                    self.image_digest,
                ],
            )

    def test_defaults_to_master_identity(self):
        self.assertEqual(verifier.DEFAULT_SOURCE_REF, "refs/heads/master")
        self.assertEqual(
            verifier.parse_args(
                [
                    "--digest",
                    "sha256:" + "b" * 64,
                    "--source-sha",
                    self.source_sha,
                    "--run-id",
                    "123",
                    "--attempt",
                    "1",
                ]
            ).source_ref,
            verifier.DEFAULT_SOURCE_REF,
        )
        self._assert_exact_signature_commands()

    def test_uses_explicit_reviewed_branch_for_provenance_and_cosign(self):
        self._assert_exact_signature_commands("refs/heads/review/native-canary")

    @mock.patch.object(verifier, "_run_readonly")
    @mock.patch.object(verifier.shutil, "which")
    def test_rejects_each_missing_verification_tool(self, which, run_readonly):
        for missing_tool in ("gh", "cosign"):
            with self.subTest(tool=missing_tool):
                which.side_effect = lambda name, missing=missing_tool: (
                    None if name == missing else f"/usr/bin/{name}"
                )
                with self.assertRaises(verifier.VerificationError):
                    verifier.verify_signatures(self.image_digest, self.source_sha)
        run_readonly.assert_not_called()

    @mock.patch.object(verifier.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(verifier.subprocess, "run")
    def test_nonzero_exit_from_either_verifier_fails_closed(self, run, _which):
        for gh_exit, cosign_exit, expected_calls in ((1, 0, 1), (0, 1, 2)):
            with self.subTest(gh_exit=gh_exit, cosign_exit=cosign_exit):
                run.reset_mock()
                run.side_effect = [
                    mock.Mock(returncode=gh_exit),
                    mock.Mock(returncode=cosign_exit),
                ]
                with self.assertRaises(verifier.VerificationError):
                    verifier.verify_signatures(self.image_digest, self.source_sha)
                self.assertEqual(run.call_count, expected_calls)

    @mock.patch.object(verifier, "verify_signatures")
    @mock.patch.object(verifier, "_verify_oci_metadata")
    def test_invalid_source_refs_fail_before_registry_or_signature_access(
        self, verify_metadata, verify_signatures
    ):
        invalid_refs = (
            "refs/tags/v4.0.0.0",
            "refs/heads/",
            "refs/heads/../escape",
            "refs/heads/review//candidate",
            "refs/heads/hidden/.branch",
            "refs/heads/review/candidate.lock",
            "refs/heads/review/candidate?bad",
        )
        for source_ref in invalid_refs:
            with self.subTest(source_ref=source_ref):
                with redirect_stderr(io.StringIO()):
                    result = verifier.main(
                        [
                            "--digest",
                            "sha256:" + "b" * 64,
                            "--source-sha",
                            self.source_sha,
                            "--run-id",
                            "123",
                            "--attempt",
                            "1",
                            "--source-ref",
                            source_ref,
                        ]
                    )
                self.assertEqual(result, 1)
                verify_metadata.assert_not_called()
                verify_signatures.assert_not_called()


if __name__ == "__main__":
    unittest.main()
