from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import tomllib
from unittest import mock

import config
import ha_preflight
from config import ConfigError, render, update


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "config.py"


def base_options() -> dict:
    return {
        "openrouter_api_key": "synthetic-openrouter-key",
        "default_model": "test-primary",
        "complex_model": "test-reasoning",
        "telegram_bot_token": "",
        "ha_mcp_enabled": False,
        "daily_cost_limit_usd": 10.0,
        "monthly_cost_limit_usd": 40.0,
    }


class NativeConfigTests(unittest.TestCase):
    def test_native_default_graph_routes_and_cost_block_are_complete(self):
        config = tomllib.loads(render(base_options()))
        self.assertEqual(config["schema_version"], 3)
        self.assertFalse(config["secrets"]["encrypt"])
        self.assertEqual(config["providers"]["models"]["openrouter"]["default"]["uri"],
                         "https://openrouter.ai/api/v1")
        self.assertEqual(config["providers"]["models"]["openrouter"]["reasoning"]["uri"],
                         "https://openrouter.ai/api/v1")
        routes = {route["hint"]: route for route in config["model_routes"]}
        self.assertEqual(routes["fast"]["model_provider"], "openrouter.default")
        self.assertEqual(routes["fast"]["model"], "test-primary")
        self.assertEqual(routes["reasoning"]["model_provider"], "openrouter.reasoning")
        self.assertEqual(routes["reasoning"]["model"], "test-reasoning")
        self.assertEqual(config["agents"]["default"]["model_provider"], "openrouter.default")
        self.assertEqual(config["agents"]["default"]["memory"]["backend"], "sqlite")
        self.assertEqual(config["channels"]["session_backend"], "sqlite")
        self.assertEqual(config["risk_profiles"]["default"]["allowed_tools"], ["memory_recall"])
        self.assertEqual(config["risk_profiles"]["default"]["delegation_policy"]["mode"], "forbidden")
        self.assertNotIn("effort_routing", config["runtime_profiles"]["default"])
        self.assertNotIn("auto_classify", config["runtime_profiles"]["default"])
        self.assertEqual(config["cost"]["enforcement"]["mode"], "block")
        self.assertEqual(config["cost"]["daily_limit_usd"], 10.0)
        self.assertEqual(config["cost"]["monthly_limit_usd"], 40.0)
        rates = config["cost"]["rates"]["providers"]["models"]["openrouter"]
        self.assertEqual(set(rates), {"test-primary", "test-reasoning"})
        for rate in rates.values():
            self.assertEqual(rate, {"input_per_mtok": 100.0, "output_per_mtok": 100.0})
        self.assertFalse(config["mcp"]["enabled"])
        self.assertEqual(config["tools"]["optional"], [])
        self.assertNotIn("fallback", config["providers"]["models"]["openrouter"]["default"])
        self.assertNotIn("http://127.0.0.1:42620", render(base_options()))

    def test_same_model_is_priced_once_and_fusion_keeps_selected_preset(self):
        options = base_options()
        options.update({"default_model": "openrouter/fusion",
                        "complex_model": "openrouter/fusion",
                        "openrouter_fusion_preset": "general-fast"})
        text = render(options)
        config = tomllib.loads(text)
        providers = config["providers"]["models"]["openrouter"]
        self.assertEqual(providers["reasoning"]["provider_extra"], {
            "plugins": [{"id": "fusion", "preset": "general-fast"}]
        })
        self.assertEqual(len(config["cost"]["rates"]["providers"]["models"]["openrouter"]), 1)

    def test_native_effort_routing_is_explicit_opt_in(self):
        options = base_options()
        options["automatic_model_routing"] = True
        config = tomllib.loads(render(options))
        self.assertEqual(config["runtime_profiles"]["default"]["effort_routing"], {
            "local_hint": "fast",
            "cloud_hint": "reasoning",
            "cloud_escalation": "auto",
        })
        self.assertNotIn("auto_classify", config["runtime_profiles"]["default"])

        options["automatic_model_routing"] = "true"
        with self.assertRaises(ConfigError):
            render(options)

    def test_native_ha_mcp_is_optional_and_scoped_to_known_read_contract(self):
        options = base_options()
        options.update({"ha_mcp_enabled": True,
                        "ha_mcp_url": "https://ha.example.test/api/mcp",
                        "ha_mcp_token": "synthetic-ha-token"})
        config = tomllib.loads(render(options))
        self.assertEqual(config["agents"]["default"]["mcp_bundles"], ["ha"])
        self.assertEqual(config["mcp"]["servers"][0]["name"], "ha")
        self.assertEqual(config["mcp"]["servers"][0]["transport"], "http")
        self.assertEqual(config["mcp"]["servers"][0]["headers"],
                         {"Authorization": "Bearer synthetic-ha-token"})
        self.assertEqual(config["mcp_bundles"]["ha"]["servers"], ["ha"])
        risk = config["risk_profiles"]["default"]
        self.assertEqual(risk["auto_approve"], [
            "memory_recall", "ha__homeassistant__GetLiveContext", "ha__llm__GetDateTime"
        ])
        self.assertEqual(risk["excluded_tools"], ["ha__homeassistant__call_action"])
        self.assertEqual(risk["allowed_tools"], ["memory_recall"])

    def test_telegram_is_enabled_only_for_a_numeric_configured_owner(self):
        options = base_options()
        options.update({"telegram_bot_token": "synthetic-telegram-token",
                        "telegram_owner_id": "123456789"})
        config = tomllib.loads(render(options))
        self.assertEqual(config["agents"]["default"]["channels"], ["telegram.home"])
        telegram = config["channels"]["telegram"]["home"]
        self.assertTrue(telegram["enabled"])
        self.assertTrue(telegram["mention_only"])
        self.assertTrue(telegram["per_user_session"])
        self.assertFalse(telegram["passive_group_context"])
        group = config["peer_groups"]["telegram_owner"]
        self.assertEqual(group["external_peers"], ["123456789"])
        self.assertFalse(group["admin_for_agent_scope"])
        self.assertNotIn("private_only", telegram)

        legacy = base_options()
        legacy.update({"telegram_bot_token": "synthetic-telegram-token",
                       "telegram_allowed_users": "987654321,123456789"})
        legacy_group = tomllib.loads(render(legacy))["peer_groups"]["telegram_owner"]
        self.assertEqual(legacy_group["external_peers"], ["987654321"])

    def test_telegram_owner_is_required_and_rejects_wildcards_or_names(self):
        for owner in ("", "*", "@somebody", "0", "-42", "123 456"):
            options = base_options()
            options.update({"telegram_bot_token": "synthetic-telegram-token",
                            "telegram_owner_id": owner})
            with self.subTest(owner=owner), self.assertRaises(ConfigError):
                render(options)

    def test_ha_url_and_credential_are_strictly_validated(self):
        for url in ("http://user:pass@ha.local/api/mcp", "http://ha.local/api/mcp?x=1",
                    "http://ha.local/api/mcp/", "http://ha.local/api/mcp#fragment",
                    "file:///api/mcp"):
            options = base_options()
            options.update({"ha_mcp_enabled": True, "ha_mcp_url": url,
                            "ha_mcp_token": "synthetic-ha-token"})
            with self.subTest(url=url), self.assertRaises(ConfigError):
                render(options)
        options = base_options()
        options.update({"ha_mcp_enabled": True, "ha_mcp_url": "http://ha.local/api/mcp",
                        "ha_mcp_token": "bad token"})
        with self.assertRaises(ConfigError):
            render(options)

    def test_malformed_and_control_character_values_fail_without_echoing_secrets(self):
        secret = "synthetic-secret\nthat-must-not-appear"
        options = base_options()
        options["openrouter_api_key"] = secret
        with self.assertRaises(ConfigError):
            render(options)
        options = base_options()
        options["default_model"] = "safe\n[malicious]"
        with self.assertRaises(ConfigError):
            render(options)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            opts = root / "options.json"
            out = root / "native" / "config.toml"
            out.parent.mkdir(mode=0o700)
            opts.write_text(json.dumps({**base_options(), "openrouter_api_key": secret}), encoding="utf-8")
            completed = subprocess.run([sys.executable, str(SCRIPT), "--options", str(opts),
                                         "--output", str(out)], capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertNotIn("synthetic-secret", completed.stderr)
            self.assertNotIn("that-must-not-appear", completed.stderr)

    def test_unicode_toml_strings_round_trip_and_invalid_surrogates_are_rejected(self):
        label = "synthetic room 🏠"
        self.assertEqual(tomllib.loads("label = " + config._quote(label))["label"], label)
        with self.assertRaises(ConfigError):
            config._safe_text({"sample": "invalid\ud800"}, "sample")

    def test_huge_json_integer_cost_is_rejected_without_float_overflow(self):
        options = base_options()
        options["daily_cost_limit_usd"] = 10**1000
        with self.assertRaises(ConfigError):
            render(options)

    def test_options_fingerprint_preserves_native_edits_until_options_change(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            native = root / "native"
            native.mkdir(mode=0o700)
            options_path = root / "options.json"
            output_path = native / "config.toml"
            options = base_options()
            options_path.write_text(json.dumps(options), encoding="utf-8")

            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_GENERATED")
            marker = root / ".native-options.sha256"
            self.assertEqual(marker.read_text(), hashlib.sha256(options_path.read_bytes()).hexdigest() + "\n")
            if os.name == "posix":
                self.assertEqual(stat.S_IMODE(output_path.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)

            output_path.write_text(output_path.read_text() + "\n# native pairing/session edit\n", encoding="utf-8")
            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_UNCHANGED")
            self.assertIn("native pairing/session edit", output_path.read_text())

            options["daily_cost_limit_usd"] = 12.0
            options_path.write_text(json.dumps(options), encoding="utf-8")
            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_GENERATED")
            self.assertNotIn("native pairing/session edit", output_path.read_text())
            self.assertEqual(tomllib.loads(output_path.read_text())["cost"]["daily_limit_usd"], 12.0)

    def test_encrypted_native_ha_header_needs_an_app_option_change_to_regenerate(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            native = root / "native"
            native.mkdir(mode=0o700)
            options = base_options()
            options.update({"ha_mcp_enabled": True,
                            "ha_mcp_url": "https://ha.example.test/api/mcp",
                            "ha_mcp_token": "synthetic-ha-token"})
            options_path = root / "options.json"
            options_path.write_text(json.dumps(options), encoding="utf-8")
            output_path = native / "config.toml"

            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_GENERATED")
            original = output_path.read_text(encoding="utf-8")
            # Native encryption covers the complete header value, including
            # its Bearer prefix, rather than only the token substring.
            encrypted_header = "enc2:" + ("ab" * 32)
            self.assertEqual(original.count("Bearer synthetic-ha-token"), 1)
            encrypted = original.replace("Bearer synthetic-ha-token", encrypted_header)
            encrypted = encrypted.replace("encrypt = false", "encrypt = true")
            output_path.write_text(encrypted, encoding="utf-8")
            unchanged_fingerprint = hashlib.sha256(options_path.read_bytes()).hexdigest() + "\n"
            marker_path = root / ".native-options.sha256"
            self.assertEqual(marker_path.read_text(encoding="ascii"), unchanged_fingerprint)

            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_UNCHANGED")
            self.assertIn(encrypted_header, output_path.read_text(encoding="utf-8"))
            self.assertEqual(marker_path.read_text(encoding="ascii"), unchanged_fingerprint)

            with mock.patch.object(ha_preflight, "check_options") as discovery:
                with self.assertRaisesRegex(ha_preflight.PreflightError, "change an app option"):
                    ha_preflight.check_config(tomllib.loads(output_path.read_text(encoding="utf-8")))
                discovery.assert_not_called()

            # A harmless value change intentionally asks config.py to replace
            # the native config with the supported plaintext credential form.
            options["daily_cost_limit_usd"] = 11.0
            options_path.write_text(json.dumps(options), encoding="utf-8")
            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_GENERATED")
            regenerated = tomllib.loads(output_path.read_text(encoding="utf-8"))
            self.assertFalse(regenerated["secrets"]["encrypt"])
            self.assertEqual(regenerated["mcp"]["servers"][0]["headers"], {
                "Authorization": "Bearer synthetic-ha-token",
            })
            self.assertNotIn("enc2:", output_path.read_text(encoding="utf-8"))

            with mock.patch.object(ha_preflight, "check_options") as discovery:
                ha_preflight.check_config(regenerated)
                discovery.assert_called_once_with({
                    "ha_mcp_enabled": True,
                    "ha_mcp_url": "https://ha.example.test/api/mcp",
                    "ha_mcp_token": "synthetic-ha-token",
                })

    def test_same_fingerprint_with_malformed_config_fails_without_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            native = root / "native"
            native.mkdir()
            options_path = root / "options.json"
            options_path.write_text(json.dumps(base_options()), encoding="utf-8")
            output_path = native / "config.toml"
            output_path.write_text("[not valid", encoding="utf-8")
            marker = hashlib.sha256(options_path.read_bytes()).hexdigest()
            (root / ".native-options.sha256").write_text(marker + "\n", encoding="ascii")
            with self.assertRaisesRegex(ConfigError, "malformed"):
                update(options_path, output_path)
            self.assertEqual(output_path.read_text(), "[not valid")

    def test_unmarked_valid_native_config_is_preserved_and_marked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            native = root / "native"
            native.mkdir()
            options_path = root / "options.json"
            options_path.write_text(json.dumps(base_options()), encoding="utf-8")
            output_path = native / "config.toml"
            original = ('schema_version = 3\n\n[agents.default]\nenabled = true\n'
                        '\n[gateway]\nrequire_pairing = true\n')
            output_path.write_text(original, encoding="utf-8")
            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_PRESERVED")
            self.assertEqual(output_path.read_text(), original)
            self.assertTrue((root / ".native-options.sha256").exists())

    def test_valid_toml_without_native_schema_shape_is_not_adopted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            native = root / "native"
            native.mkdir()
            options_path = root / "options.json"
            options_path.write_text(json.dumps(base_options()), encoding="utf-8")
            output_path = native / "config.toml"
            output_path.write_text("schema_version = 2\n\n[agent]\n", encoding="utf-8")
            with self.assertRaisesRegex(ConfigError, "default agent"):
                update(options_path, output_path)
            self.assertFalse((root / ".native-options.sha256").exists())
            self.assertEqual(output_path.read_text(), "schema_version = 2\n\n[agent]\n")

    def test_failed_config_replace_does_not_commit_new_fingerprint(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            native = root / "native"
            native.mkdir()
            options_path = root / "options.json"
            old_options = base_options()
            options_path.write_text(json.dumps(old_options), encoding="utf-8")
            output_path = native / "config.toml"
            self.assertEqual(update(options_path, output_path), "NATIVE_CONFIG_GENERATED")
            marker = root / ".native-options.sha256"
            old_marker = marker.read_bytes()

            changed = dict(old_options, daily_cost_limit_usd=11.0)
            options_path.write_text(json.dumps(changed), encoding="utf-8")
            real_write = config._atomic_private_write

            def fail_output(path: Path, content: bytes) -> None:
                if path == output_path:
                    raise OSError("synthetic interrupted config replace")
                real_write(path, content)

            with mock.patch.object(config, "_atomic_private_write", side_effect=fail_output):
                with self.assertRaises(OSError):
                    update(options_path, output_path)
            self.assertEqual(marker.read_bytes(), old_marker)

    def test_symlinked_options_output_and_marker_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            real_options = root / "real-options.json"
            real_options.write_text(json.dumps(base_options()), encoding="utf-8")
            options_link = root / "options.json"
            native = root / "native"
            native.mkdir()
            output = native / "config.toml"
            try:
                options_link.symlink_to(real_options)
            except (OSError, NotImplementedError):
                self.skipTest("symlink creation is unavailable on this host")
            with self.assertRaises(ConfigError):
                update(options_link, output)

            options_link.unlink()
            options_link.write_text(real_options.read_text(), encoding="utf-8")
            target = root / "target.toml"
            target.write_text("schema_version = 3\n", encoding="utf-8")
            output.symlink_to(target)
            with self.assertRaises(ConfigError):
                update(options_link, output)

            output.unlink()
            output.write_text("schema_version = 3\n", encoding="utf-8")
            marker_target = root / "marker-target"
            marker_target.write_text("0" * 64 + "\n", encoding="ascii")
            marker = root / ".native-options.sha256"
            marker.symlink_to(marker_target)
            with self.assertRaises(ConfigError):
                update(options_link, output)


if __name__ == "__main__":
    unittest.main()
