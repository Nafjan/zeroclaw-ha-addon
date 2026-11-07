import json
import threading
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ha_preflight import PreflightError, check_config, check_options


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.server.calls.append(self.path)
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.server.status != 200:
            self.send_response(self.server.status)
            if self.server.status == 302:
                self.send_header("Location", self.server.redirect)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.headers.get("Authorization") != "Bearer synthetic-test-key":
            self.send_error(401)
            return
        method = payload["method"]
        if method != "initialize" and self.headers.get("Mcp-Session-Id") != "synthetic-session":
            self.send_error(400)
            return
        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        result = ({"protocolVersion": "2025-03-26", "capabilities": {}}
                  if method == "initialize" else {"tools": self.server.tools})
        body = json.dumps({"jsonrpc": "2.0", "id": payload["id"], "result": result})
        if self.server.sse:
            body = "event: message\ndata: " + body + "\n\n"
        raw = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if self.server.sse else "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Mcp-Session-Id", "synthetic-session")
        self.end_headers()
        self.wfile.write(raw)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.calls = []
        self.server.status = 200
        self.server.sse = False
        self.server.redirect = "http://127.0.0.1:1/credential-must-not-follow"
        self.server.tools = [{"name": "homeassistant__GetLiveContext",
                              "annotations": {"readOnlyHint": True}}]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.options = {"ha_mcp_enabled": True,
                        "ha_mcp_url": "http://127.0.0.1:%d/api/mcp" % self.server.server_port,
                        "ha_mcp_token": "synthetic-test-key"}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_disabled_has_no_network_calls(self):
        check_options({})
        check_options({"ha_mcp_enabled": False})
        self.assertEqual(self.server.calls, [])

    def test_real_discovery_flow_preserves_session_without_reading_home_state(self):
        check_options(self.options)
        self.assertEqual(self.server.calls, ["/api/mcp"] * 3)

    def native_config(self):
        return {"agents": {"default": {"mcp_bundles": ["home"]}},
                "mcp_bundles": {"home": {"servers": ["ha"]}},
                "mcp": {"enabled": True, "servers": [
                    {"name": "ha", "transport": "http", "url": self.options["ha_mcp_url"],
                     "headers": {"Authorization": "Bearer " + self.options["ha_mcp_token"]}}]}}

    def test_preserved_native_config_is_checked_without_options(self):
        # The native config may enable MCP even when saved options disabled it.
        check_config(self.native_config())
        self.assertEqual(self.server.calls, ["/api/mcp"] * 3)

    def test_effective_url_and_credential_are_used_after_native_edits(self):
        config = self.native_config()
        server = config["mcp"]["servers"][0]
        server["url"] = "https://replacement.invalid/api/mcp"
        server["headers"]["Authorization"] = "Bearer replacement-credential"
        with patch("ha_preflight.check_options") as probe:
            check_config(config)
        probe.assert_called_once_with({"ha_mcp_enabled": True,
                                       "ha_mcp_url": server["url"],
                                       "ha_mcp_token": "replacement-credential"})
        self.assertEqual(self.server.calls, [])

    def test_native_bundle_exclusion_wins_and_unused_servers_are_not_probed(self):
        config = self.native_config()
        config["mcp_bundles"]["home"]["exclude"] = ["ha"]
        check_config(config)
        self.assertEqual(self.server.calls, [])

    def test_native_unknown_grants_and_unsupported_credentials_fail_closed(self):
        for change in ("extra-server", "encrypted-header", "pinned-resource", "stdio"):
            config = self.native_config()
            server = config["mcp"]["servers"][0]
            if change == "extra-server":
                config["mcp_bundles"]["home"]["servers"].append("other")
                config["mcp"]["servers"].append({"name": "other", "transport": "stdio"})
            elif change == "encrypted-header":
                server["headers"]["Authorization"] = "enc2:synthetic-encrypted-value"
            elif change == "pinned-resource":
                server["pinned_resources"] = ["synthetic://unexpected"]
            else:
                server["transport"] = "stdio"
            with self.subTest(change=change), self.assertRaises(PreflightError):
                check_config(config)
        self.assertEqual(self.server.calls, [])

    def test_sse_discovery_is_supported(self):
        self.server.sse = True
        check_options(self.options)

    def test_main_url_and_credential_are_required_before_network(self):
        for change in ({"ha_mcp_token": ""}, {"ha_mcp_url": self.options["ha_mcp_url"] + "/assist"},
                       {"ha_mcp_enabled": "true"}, {"ha_mcp_token": "bad\nheader"},
                       {"ha_mcp_url": "http://user:password@localhost/api/mcp"}):
            with self.subTest(change=change), self.assertRaises(PreflightError):
                check_options(dict(self.options, **change))
        self.assertEqual(self.server.calls, [])

    def test_broad_mutating_or_unknown_tools_are_rejected(self):
        for tool in ({"name": "homeassistant__call_action", "annotations": {"readOnlyHint": False}},
                     {"name": "homeassistant__render_template", "annotations": {"readOnlyHint": True}},
                     {"name": "homeassistant__GetLiveContext"},
                     {"name": ["invalid"], "annotations": {"readOnlyHint": True}}):
            with self.subTest(tool=tool):
                self.server.tools = [tool]
                with self.assertRaises(PreflightError):
                    check_options(self.options)

    def test_auth_rejection_is_sanitized(self):
        self.server.status = 401
        with self.assertRaises(PreflightError) as error:
            check_options(self.options)
        self.assertIn("401", str(error.exception))
        self.assertNotIn(self.options["ha_mcp_token"], str(error.exception))

    def test_redirects_are_not_followed(self):
        self.server.status = 302
        with self.assertRaises(PreflightError):
            check_options(self.options)
        self.assertEqual(len(self.server.calls), 1)


if __name__ == "__main__":
    unittest.main()
