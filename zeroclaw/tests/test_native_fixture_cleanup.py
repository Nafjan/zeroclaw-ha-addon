from __future__ import annotations

import io
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

import native_image_smoke as native


def completed(arguments: list[str], returncode: int = 0, stdout: str = "", stderr: str = ""):
    return subprocess.CompletedProcess(arguments, returncode, stdout, stderr)


class NativeFixtureCleanupTests(unittest.TestCase):
    def run_with_fixed_names(self, body):
        with patch.object(native.os, "getpid", return_value=4242), patch.object(
            native.secrets, "token_hex", return_value="deadbeef01"
        ):
            return body()

    @staticmethod
    def expected_volume() -> str:
        return "zeroclaw-native-smoke-4242-deadbeef01-data"

    def test_primary_failure_survives_cleanup_timeout(self):
        calls: list[list[str]] = []
        volume = self.expected_volume()

        def fake_docker(arguments, **_kwargs):
            args = list(arguments)
            calls.append(args)
            if args == ["volume", "create", volume]:
                return completed(args, stdout=volume + "\n")
            if args[:2] == ["run", "--rm"]:
                raise native.SmokeFailure("primary synthetic seed failure")
            if args == ["volume", "rm", volume]:
                raise native.SmokeFailure("cleanup CLI timed out")
            if args == ["volume", "inspect", volume]:
                return completed(args, stdout="{}\n")
            raise AssertionError(f"unexpected Docker command: {args}")

        stderr = io.StringIO()
        with patch.object(native, "docker", side_effect=fake_docker), redirect_stderr(stderr):
            with self.assertRaisesRegex(native.SmokeFailure, "primary synthetic seed failure"):
                self.run_with_fixed_names(
                    lambda: native.run_smoke("candidate:test", "a" * 64, "b" * 40)
                )

        self.assertIn(["volume", "create", volume], calls)
        self.assertIn(["volume", "rm", volume], calls)
        self.assertIn(["volume", "inspect", volume], calls)
        self.assertIn("cleanup also failed after the primary failure", stderr.getvalue())

    def test_volume_create_timeout_attempts_cleanup_of_exact_resource(self):
        calls: list[list[str]] = []
        volume = self.expected_volume()

        def fake_docker(arguments, **_kwargs):
            args = list(arguments)
            calls.append(args)
            if args == ["volume", "create", volume]:
                raise native.SmokeFailure("Docker volume create timed out")
            if args == ["volume", "rm", volume]:
                return completed(args)
            raise AssertionError(f"unexpected Docker command: {args}")

        with patch.object(native, "docker", side_effect=fake_docker):
            with self.assertRaisesRegex(native.SmokeFailure, "volume create timed out"):
                self.run_with_fixed_names(
                    lambda: native.run_smoke("candidate:test", "a" * 64, "b" * 40)
                )

        self.assertEqual(calls, [["volume", "create", volume], ["volume", "rm", volume]])

    def test_timed_out_create_cleanup_confirms_exact_resource_is_absent(self):
        calls: list[list[str]] = []
        volume = self.expected_volume()
        missing = f"Error response from daemon: get {volume}: no such volume"

        def fake_docker(arguments, **_kwargs):
            args = list(arguments)
            calls.append(args)
            if args == ["volume", "create", volume]:
                raise native.SmokeFailure("Docker volume create timed out")
            if args == ["volume", "rm", volume]:
                return completed(args, returncode=1, stderr=missing)
            if args == ["volume", "inspect", volume]:
                return completed(args, returncode=1, stderr=missing)
            raise AssertionError(f"unexpected Docker command: {args}")

        stderr = io.StringIO()
        with patch.object(native, "docker", side_effect=fake_docker), redirect_stderr(stderr):
            with self.assertRaisesRegex(native.SmokeFailure, "volume create timed out"):
                self.run_with_fixed_names(
                    lambda: native.run_smoke("candidate:test", "a" * 64, "b" * 40)
                )

        self.assertEqual(
            calls,
            [
                ["volume", "create", volume],
                ["volume", "rm", volume],
                ["volume", "inspect", volume],
            ],
        )
        self.assertEqual(stderr.getvalue(), "")

    def test_cleanup_failure_after_success_is_reported_without_pass(self):
        calls: list[list[str]] = []
        volume = self.expected_volume()

        def fake_docker(arguments, **_kwargs):
            args = list(arguments)
            calls.append(args)
            if args == ["volume", "rm", volume]:
                return completed(args, returncode=1, stderr="volume is still in use")
            if args == ["volume", "inspect", volume]:
                return completed(args, stdout="{}\n")
            return completed(args)

        stdout = io.StringIO()
        with (
            patch.object(native, "docker", side_effect=fake_docker),
            patch.object(native, "seed_volume"),
            patch.object(native, "start_provider"),
            patch.object(native, "create_app"),
            patch.object(native, "wait_for_health"),
            patch.object(native, "assert_container_state"),
            patch.object(native, "rewrite_fixture_config"),
            patch.object(native, "run_agent_turn"),
            patch.object(native, "inspect_events", return_value=[]),
            patch.object(native, "verify_provider_events"),
            redirect_stdout(stdout),
        ):
            with self.assertRaisesRegex(native.SmokeFailure, "native image fixture cleanup failed"):
                self.run_with_fixed_names(
                    lambda: native.run_smoke("candidate:test", "a" * 64, "b" * 40)
                )

        self.assertIn(["volume", "rm", volume], calls)
        self.assertIn(["volume", "inspect", volume], calls)
        self.assertNotIn("PASS:", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
