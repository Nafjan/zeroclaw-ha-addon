from __future__ import annotations

import argparse
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import state_migration_smoke as state


class StateFixtureCleanupTests(unittest.TestCase):
    def run_with_volume_failure(self, *, cleanup_failure=False):
        volume = "zc-state-v3-smoke-" + "a" * 16
        primary = subprocess.TimeoutExpired(["docker", "volume", "create", volume], 15)
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            if command[:3] == ["docker", "volume", "create"]:
                raise primary
            if command[:3] == ["docker", "volume", "rm"] and cleanup_failure:
                raise subprocess.TimeoutExpired(command, 15)
            return subprocess.CompletedProcess(command, 0, "{}", "")

        stderr = io.StringIO()
        stdout = io.StringIO()
        with (
            patch.object(state, "sha256", side_effect=[state.OLD_BINARY_SHA256, state.NEW_ARCHIVE_SHA256]),
            patch.object(state.shutil, "which", return_value="docker"),
            patch.object(state.secrets, "token_hex", side_effect=["a" * 16, "b" * 16]),
            patch.object(state, "run", side_effect=fake_run),
            redirect_stderr(stderr), redirect_stdout(stdout),
        ):
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                state.run_on_host(argparse.Namespace(old_binary=Path("old"), new_archive=Path("new")))
        self.assertIs(caught.exception, primary)
        self.assertIn(["docker", "volume", "rm", volume], calls)
        self.assertFalse(any(c[:3] in (["docker", "image", "rm"], ["docker", "rm", "-f"]) for c in calls))
        self.assertNotIn("PASS:", stdout.getvalue())
        return stderr.getvalue()

    def test_uncertain_volume_creation_cleans_only_attempted_resource(self):
        self.assertEqual(self.run_with_volume_failure(), "")

    def test_cleanup_failure_preserves_original_exception(self):
        self.assertIn("could not confirm removal", self.run_with_volume_failure(cleanup_failure=True))

    def test_cleanup_failure_without_primary_is_reported(self):
        with patch.object(state, "run", return_value=subprocess.CompletedProcess([], 0, "{}", "")) as run:
            run.side_effect = [subprocess.TimeoutExpired([], 15), subprocess.CompletedProcess([], 0, "{}", "")]
            with self.assertRaisesRegex(state.SmokeFailure, "could not confirm removal"):
                state.cleanup_host_resources([("volume", "fixture-volume")], primary_failure=False)

    def test_timeout_can_confirm_exact_volume_absence(self):
        name = "fixture-volume"
        with patch.object(state, "run") as run:
            run.side_effect = [
                subprocess.TimeoutExpired([], 15),
                subprocess.CompletedProcess([], 1, f"Error response from daemon: get {name}: no such volume", ""),
            ]
            state.cleanup_host_resources([("volume", name)], primary_failure=False)
            self.assertEqual(run.call_args_list[1].args[0], ["docker", "volume", "inspect", name])

    def test_daemon_connection_failure_is_not_resource_absence(self):
        with patch.object(state, "run") as run:
            run.side_effect = [
                subprocess.TimeoutExpired([], 15),
                subprocess.CompletedProcess([], 1, "Cannot connect to daemon: no such file or directory", ""),
            ]
            with self.assertRaises(state.SmokeFailure):
                state.cleanup_host_resources([("volume", "fixture-volume")], primary_failure=False)


if __name__ == "__main__":
    unittest.main()
