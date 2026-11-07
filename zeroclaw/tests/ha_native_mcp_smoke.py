#!/usr/bin/env python3
"""Exercise the pinned Home Assistant native MCP endpoint in an isolated container.

This smoke creates a throwaway Home Assistant owner and synthetic entity states.
It uses no host Home Assistant instance, provider credentials, published ports,
or host network access. The only writable host mount is a fresh temporary
configuration directory, removed when the test exits.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path


IMAGE = (
    "ghcr.io/home-assistant/home-assistant@"
    "sha256:078222f9ea47cf47b172a301c2c45a1d2344b9d666827729b71fc3f7d7a57592"
)
EXPECTED_IMAGE_DIGEST = "sha256:078222f9ea47cf47b172a301c2c45a1d2344b9d666827729b71fc3f7d7a57592"
EXPECTED_ZEROCLAW_ARCHIVE_SHA256 = "3cc7f1c859a67524d5496260d29806190bc7127d2877a479a5496ce34b9b401a"

# Kept as an in-container script so the container needs no exposed host port.
HA_CLIENT = r'''# -*- coding: utf-8 -*-
import asyncio
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import time
import tomllib
import uuid

import aiohttp
from aiohttp import web

BASE = "http://127.0.0.1:8123"
TIMEOUT = aiohttp.ClientTimeout(total=20)
CLIENT_ID = BASE + "/"
PREFLIGHT_SOURCE_B64 = "PREFLIGHT_SOURCE_B64_PLACEHOLDER"
PREFLIGHT_ONLY = PREFLIGHT_ONLY_PLACEHOLDER
NATIVE_CONFIG_SOURCE_B64 = "NATIVE_CONFIG_SOURCE_B64_PLACEHOLDER"
NATIVE_INTEROP = NATIVE_INTEROP_PLACEHOLDER
NATIVE_BINARY = "/config/zeroclaw-native-interop"


def make_openrouter_fixture_certificates():
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    except ImportError as err:
        raise RuntimeError("Home Assistant image lacks cryptography for the local TLS fixture") from err

    from datetime import datetime, timedelta, timezone

    now = datetime.now(timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ZeroClaw isolated MCP test CA")])
    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    server_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    server_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "openrouter.ai")])
    server_cert = (
        x509.CertificateBuilder()
        .subject_name(server_name)
        .issuer_name(ca_name)
        .public_key(server_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("openrouter.ai")]), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    ca_path = Path("/config/fixture-openrouter-ca.pem")
    chain_path = Path("/config/fixture-openrouter-chain.pem")
    key_path = Path("/config/fixture-openrouter-key.pem")
    ca_path.write_bytes(ca_cert.public_bytes(serialization.Encoding.PEM))
    chain_path.write_bytes(
        server_cert.public_bytes(serialization.Encoding.PEM)
        + ca_cert.public_bytes(serialization.Encoding.PEM)
    )
    key_path.write_bytes(server_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ))
    os.chmod(ca_path, 0o600)
    os.chmod(chain_path, 0o600)
    os.chmod(key_path, 0o600)
    return ca_path, chain_path, key_path


async def main():
    async with aiohttp.ClientSession(timeout=TIMEOUT) as session:
        deadline = time.monotonic() + STARTUP_TIMEOUT
        ready = False
        while time.monotonic() < deadline:
            try:
                async with session.get(BASE + "/api/") as response:
                    if response.status in (200, 401):
                        ready = True
                        break
            except (aiohttp.ClientError, asyncio.TimeoutError):
                pass
            await asyncio.sleep(2)
        if not ready:
            raise RuntimeError("Home Assistant HTTP API did not become ready")

        async def request(method, path, *, body=None, token=None, form=None,
                          expected=(200,)):
            headers = {}
            if token:
                headers["Authorization"] = "Bearer " + token
            url = BASE + path
            async with session.request(
                method, url, json=body, data=form, headers=headers
            ) as response:
                raw = await response.read()
                if response.status not in expected:
                    # Never print response bodies or credentials.
                    raise RuntimeError(
                        f"{method} {path} returned HTTP {response.status}"
                    )
                if not raw:
                    return response.status, None
                try:
                    return response.status, json.loads(raw)
                except json.JSONDecodeError:
                    return response.status, raw.decode("utf-8", "replace")

        username = "mcp-smoke-" + uuid.uuid4().hex[:12]
        password = secrets.token_urlsafe(32)
        _, created = await request(
            "POST", "/api/onboarding/users",
            body={"name": "Synthetic MCP Smoke Owner", "username": username,
                  "password": password, "client_id": CLIENT_ID, "language": "en"},
        )
        auth_code = created["auth_code"]
        _, token_result = await request(
            "POST", "/auth/token",
            form={"client_id": CLIENT_ID, "grant_type": "authorization_code",
                  "code": auth_code},
        )
        token = token_result["access_token"]
        _, authenticated_api = await request("GET", "/api/", token=token)
        if not isinstance(authenticated_api, dict):
            raise RuntimeError("onboarding token did not authenticate to the Home Assistant API")
        async with session.ws_connect(BASE + "/api/websocket") as owner_ws:
            await owner_ws.receive_json()
            await owner_ws.send_json({"type": "auth", "access_token": token})
            owner_auth = await owner_ws.receive_json()
            if owner_auth.get("type") != "auth_ok":
                raise RuntimeError("onboarding token failed Home Assistant WebSocket authentication")
            await owner_ws.send_json({"id": 1, "type": "auth/current_user"})
            owner_identity = await owner_ws.receive_json()
            if (owner_identity.get("success") is not True
                    or owner_identity.get("result", {}).get("is_owner") is not True):
                raise RuntimeError("onboarding token did not identify as the Home Assistant owner")

        # The native integration exposes its normal config flow and options flow.
        _, flow = await request(
            "POST", "/api/config/config_entries/flow",
            body={"handler": "mcp_server", "show_advanced_options": False},
            token=token,
        )
        _, entry = await request(
            "POST", "/api/config/config_entries/flow/" + flow["flow_id"],
            body={}, token=token,
        )
        entry_id = entry["result"]["entry_id"]

        async def set_options(apis, *, require_admin=True):
            _, options_flow = await request(
                "POST", "/api/config/config_entries/options/flow",
                body={"handler": entry_id}, token=token,
            )
            await request(
                "POST", "/api/config/config_entries/options/flow/"
                + options_flow["flow_id"],
                body={"all_llm_apis": False, "llm_hass_api": apis,
                      "require_admin": require_admin, "read_only": True},
                token=token,
            )

        async def websocket_command(access_token, message):
            async with session.ws_connect(BASE + "/api/websocket") as websocket:
                greeting = await websocket.receive_json()
                if greeting.get("type") != "auth_required":
                    raise RuntimeError("Home Assistant WebSocket did not request authentication")
                await websocket.send_json({"type": "auth", "access_token": access_token})
                authenticated = await websocket.receive_json()
                if authenticated.get("type") != "auth_ok":
                    raise RuntimeError("Home Assistant WebSocket authentication failed")
                await websocket.send_json(message)
                result = await websocket.receive_json()
                if result.get("success") is not True:
                    error = result.get("error", {}).get("code", "unknown")
                    raise RuntimeError("Home Assistant WebSocket command failed: " + str(error))
                return result.get("result")

        async def create_nonadmin_user(owner_token):
            name = "mcp-reader-" + uuid.uuid4().hex[:10]
            password = secrets.token_urlsafe(32)
            created_user = await websocket_command(owner_token, {
                "id": 1, "type": "config/auth/create", "name": "Synthetic MCP Reader"
            })
            user = created_user["user"]
            if (user.get("is_owner") is not False
                    or "system-administrators" in user.get("group_ids", [])):
                raise AssertionError("synthetic read account is not a non-admin user")
            await websocket_command(owner_token, {
                "id": 2, "type": "config/auth_provider/homeassistant/create",
                "user_id": user["id"], "username": name, "password": password,
            })
            _, providers = await request("GET", "/auth/providers")
            provider_list = providers.get("providers") if isinstance(providers, dict) else providers
            if not isinstance(provider_list, list):
                shape = sorted(providers.keys()) if isinstance(providers, dict) else type(providers).__name__
                raise RuntimeError("Home Assistant auth provider response has an unsupported shape: "
                                   + str(shape))
            provider = next((item for item in provider_list
                             if (item.get("type") if isinstance(item, dict) else item)
                             == "homeassistant"), None)
            if provider is None:
                raise RuntimeError("Home Assistant local authentication provider is unavailable")
            provider_type = provider.get("type") if isinstance(provider, dict) else provider
            provider_id = provider.get("id") if isinstance(provider, dict) else None
            _, login = await request(
                "POST", "/auth/login_flow",
                body={"client_id": CLIENT_ID,
                      "handler": [provider_type, provider_id],
                      "redirect_uri": CLIENT_ID},
            )
            login_status, completed = await request(
                "POST", "/auth/login_flow/" + login["flow_id"],
                body={"client_id": CLIENT_ID, "username": name, "password": password},
                expected=(200, 400),
            )
            if login_status != 200:
                diagnostic = {"response_type": type(completed).__name__}
                if isinstance(completed, dict):
                    diagnostic["keys"] = sorted(completed.keys())
                    for key in ("type", "step_id", "message"):
                        value = completed.get(key)
                        if isinstance(value, str) and len(value) <= 80:
                            diagnostic[key] = value
                    errors = completed.get("errors")
                    if isinstance(errors, dict):
                        diagnostic["errors"] = {
                            str(key): (value if isinstance(value, str) and len(value) <= 40
                                       else type(value).__name__)
                            for key, value in errors.items()
                        }
                raise RuntimeError("synthetic non-admin login form was rejected (HTTP %d; %s)"
                                   % (login_status, json.dumps(diagnostic, sort_keys=True)))
            if completed.get("type") != "create_entry":
                raise RuntimeError("synthetic non-admin login flow did not complete")
            _, token_data = await request(
                "POST", "/auth/token",
                form={"client_id": CLIENT_ID, "grant_type": "authorization_code",
                      "code": completed["result"]},
            )
            access_token = token_data["access_token"]
            identity = await websocket_command(access_token, {"id": 3, "type": "auth/current_user"})
            if identity.get("is_owner") is not False:
                raise AssertionError("issued MCP credential is not a non-owner account")
            return access_token

        async def run_native_interop(access_token, exposed_marker, private_marker):
            namespace = {"__name__": "native_config_fixture"}
            source = base64.b64decode(NATIVE_CONFIG_SOURCE_B64)
            exec(compile(source, "<native-config>", "exec"), namespace)
            options = {
                "openrouter_api_key": "synthetic-openrouter-key",
                "default_model": "test-primary",
                "complex_model": "openrouter/fusion",
                "openrouter_fusion_preset": "general-budget",
                "telegram_bot_token": "",
                "ha_mcp_enabled": True,
                "ha_mcp_url": BASE + "/api/mcp",
                "ha_mcp_token": access_token,
                "daily_cost_limit_usd": 10.0,
                "monthly_cost_limit_usd": 40.0,
            }
            config_text = namespace["render"](options)
            official_uri = "https://openrouter.ai/api/v1"
            if config_text.count(official_uri) != 2:
                raise AssertionError("native config did not contain its two typed OpenRouter URIs")
            config_text += (
                "\n[proxy]\n"
                "enabled = true\n"
                'https_proxy = "http://127.0.0.1:42619"\n'
                'scope = "services"\n'
                'services = ["model_provider.openrouter"]\n'
            )
            native_dir = Path("/tmp/zeroclaw-native")
            native_dir.mkdir(mode=0o700, exist_ok=True)
            config_path = native_dir / "config.toml"
            config_path.write_text(config_text, encoding="utf-8")
            os.chmod(config_path, 0o600)
            preflight_namespace = {"__name__": "native_ha_preflight_fixture"}
            preflight_source = base64.b64decode(PREFLIGHT_SOURCE_B64)
            exec(compile(preflight_source, "<native-ha-preflight>", "exec"), preflight_namespace)
            preflight_namespace["check_config"](tomllib.loads(config_text))
            fixture_ca, fixture_chain, fixture_key = make_openrouter_fixture_certificates()
            if not Path(NATIVE_BINARY).is_file():
                raise RuntimeError("pinned ZeroClaw binary is missing from the fixture container")
            os.chmod(NATIVE_BINARY, 0o755)
            version = await asyncio.to_thread(
                subprocess.run, [NATIVE_BINARY, "--version"], capture_output=True,
                text=True, timeout=15, check=False,
            )
            if version.returncode or "0.8.7" not in version.stdout:
                raise RuntimeError("fixture binary is not the expected ZeroClaw 0.8.7 release")

            expected_tools = {
                "memory_recall",
                "ha__homeassistant__GetLiveContext",
                "ha__llm__GetDateTime",
            }
            provider_requests = []
            provider_errors = []
            expected_models = [
                "test-primary", "test-primary", "test-primary",
                "openrouter/fusion", "openrouter/fusion",
            ]

            async def send_sse(request, payload):
                response = web.StreamResponse(
                    status=200,
                    headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"},
                )
                await response.prepare(request)
                await response.write(("data: " + json.dumps(payload) + "\n\n").encode())
                await response.write(b"data: [DONE]\n\n")
                await response.write_eof()
                return response

            async def fake_openrouter(request):
                if request.headers.get("Authorization") != "Bearer synthetic-openrouter-key":
                    provider_errors.append("fake provider received an unexpected credential")
                    return web.Response(status=401)
                body = await request.json()
                names = [tool.get("function", {}).get("name") for tool in body.get("tools", [])]
                provider_requests.append({"body": body, "tool_names": names,
                                          "host": request.host})
                request_number = len(provider_requests)
                expected_model = expected_models[request_number - 1] if request_number <= len(expected_models) else None
                if body.get("model") != expected_model:
                    provider_errors.append("ZeroClaw selected an unexpected model")
                expected_plugins = ([{"id": "fusion", "preset": "general-budget"}]
                                   if request_number in (4, 5) else None)
                if body.get("plugins") != expected_plugins:
                    provider_errors.append("OpenRouter fusion plugin payload did not match the selected route")
                if set(names) != expected_tools or len(names) != len(expected_tools):
                    provider_errors.append("ZeroClaw exposed an unexpected tool set: " + repr(sorted(names)))
                if request_number == 1:
                    if body.get("stream") is True:
                        return await send_sse(request, {
                            "id": "fixture-tool-call",
                            "choices": [{"index": 0,
                                         "delta": {"role": "assistant", "tool_calls": [{
                                             "index": 0, "id": "call-native-ha-1", "type": "function",
                                             "function": {"name": "ha__homeassistant__GetLiveContext",
                                                          "arguments": "{}"},
                                         }]},
                                         "finish_reason": "tool_calls"}],
                        })
                    return web.json_response({
                        "id": "fixture-tool-call",
                        "choices": [{"index": 0, "finish_reason": "tool_calls",
                                     "message": {"role": "assistant", "content": None,
                                                 "tool_calls": [{"id": "call-native-ha-1",
                                                                 "type": "function",
                                                                 "function": {
                                                                     "name": "ha__homeassistant__GetLiveContext",
                                                                     "arguments": "{}"}}]}}],
                    })
                if request_number == 2:
                    tool_messages = [message for message in body.get("messages", [])
                                     if message.get("role") == "tool"]
                    result_text = "\n".join(str(message.get("content", ""))
                                             for message in tool_messages)
                    if not tool_messages:
                        provider_errors.append("ZeroClaw did not return an HA MCP tool result to the model")
                    if exposed_marker not in result_text:
                        provider_errors.append("exposed entity marker was absent from the HA tool result")
                    if private_marker in result_text:
                        provider_errors.append("unexposed entity marker leaked into the HA tool result")
                if body.get("stream") is True:
                    return await send_sse(request, {
                        "id": "fixture-final",
                        "choices": [{"index": 0,
                                     "delta": {"role": "assistant", "content": (
                                         "NATIVE_HA_INTEROP_DONE" if request_number == 2
                                         else "NATIVE_MODEL_ROUTING_DONE")},
                                     "finish_reason": "stop"}],
                    })
                return web.json_response({
                    "id": "fixture-final",
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant", "content": (
                                     "NATIVE_HA_INTEROP_DONE" if request_number == 2
                                     else "NATIVE_MODEL_ROUTING_DONE")}}],
                })

            app = web.Application()
            app.router.add_post("/api/v1/chat/completions", fake_openrouter)
            runner = web.AppRunner(app)
            await runner.setup()
            tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls_context.load_cert_chain(str(fixture_chain), str(fixture_key))
            site = web.TCPSite(runner, "127.0.0.1", 443, ssl_context=tls_context)
            await site.start()
            proxy_requests = []

            async def tunnel_copy(source, destination):
                try:
                    while block := await source.read(65536):
                        destination.write(block)
                        await destination.drain()
                except (ConnectionError, asyncio.CancelledError):
                    pass
                finally:
                    try:
                        destination.close()
                    except (AttributeError, RuntimeError):
                        pass

            async def local_https_proxy(reader, writer):
                try:
                    request_line = await asyncio.wait_for(reader.readline(), timeout=5)
                    headers = []
                    while line := await reader.readline():
                        if line in (b"\r\n", b"\n"):
                            break
                        headers.append(line)
                    proxy_requests.append(request_line.decode("ascii", "replace").strip())
                    if request_line != b"CONNECT openrouter.ai:443 HTTP/1.1\r\n":
                        writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                        await writer.drain()
                        return
                    origin_reader, origin_writer = await asyncio.open_connection("127.0.0.1", 443)
                    writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    await writer.drain()
                    await asyncio.gather(
                        tunnel_copy(reader, origin_writer),
                        tunnel_copy(origin_reader, writer),
                    )
                except (asyncio.TimeoutError, ConnectionError, OSError):
                    return
                finally:
                    writer.close()
                    try:
                        await writer.wait_closed()
                    except (ConnectionError, OSError):
                        pass

            proxy_server = await asyncio.start_server(
                local_https_proxy, "127.0.0.1", 42619
            )
            env = {"HOME": str(native_dir), "PATH": "/usr/local/bin:/usr/bin:/bin",
                   "ZEROCLAW_CONFIG_DIR": str(native_dir), "TZ": "UTC",
                   "SSL_CERT_FILE": str(fixture_ca)}

            async def run_agent(config_dir, message, extra_args=()):
                completed = await asyncio.to_thread(
                    subprocess.run,
                    [NATIVE_BINARY, "--config-dir", str(config_dir), "agent", "--agent", "default",
                     "--message", message, *extra_args],
                    capture_output=True, text=True, timeout=120, check=False, env=env,
                )
                if completed.returncode:
                    detail = (completed.stderr.strip().splitlines()[-1:]
                              or completed.stdout.strip().splitlines()[-1:])
                    safe_detail = detail[0] if detail else "no process output"
                    safe_detail = safe_detail.replace(access_token, "[redacted]")
                    safe_detail = safe_detail.replace("synthetic-openrouter-key", "[redacted]")
                    raise RuntimeError("ZeroClaw agent failed (exit %d): %s" %
                                       (completed.returncode, safe_detail[:240]))
                return completed

            try:
                completed = await run_agent(
                    native_dir,
                    "Read the synthetic Home Assistant context and report the exposed marker.",
                )
                if "NATIVE_HA_INTEROP_DONE" not in completed.stdout:
                    raise AssertionError("ZeroClaw did not deliver the fake model's HA response")

                route_dir = Path("/tmp/zeroclaw-native-routing")
                route_dir.mkdir(mode=0o700, exist_ok=True)
                routing_options = {**options, "automatic_model_routing": True}
                routing_config = namespace["render"](routing_options) + (
                    "\n[proxy]\n"
                    "enabled = true\n"
                    'https_proxy = "http://127.0.0.1:42619"\n'
                    'scope = "services"\n'
                    'services = ["model_provider.openrouter"]\n'
                )
                route_config_path = route_dir / "config.toml"
                route_config_path.write_text(routing_config, encoding="utf-8")
                os.chmod(route_config_path, 0o600)
                simple_result = await run_agent(route_dir, "What is 2 + 2?")
                complex_message = (
                    "Please analyze this long synthetic planning request. Compare three native routing designs, "
                    "explain their trade-offs, evaluate migration risks, and walk through a step-by-step assessment. "
                    "Include assumptions, alternatives, and a concise recommendation. "
                    "This extra context ensures the request is longer than two hundred UTF-8 bytes."
                )
                complex_result = await run_agent(route_dir, complex_message)
                explicit_result = await run_agent(
                    route_dir, "What is 2 + 2?",
                    ("--model-provider", "openrouter.reasoning", "--model", "openrouter/fusion"),
                )
            finally:
                await runner.cleanup()
                proxy_server.close()
                await proxy_server.wait_closed()
            if len(provider_requests) != 5:
                raise AssertionError("ZeroClaw did not complete the HA and routing provider requests")
            if provider_errors:
                raise AssertionError("; ".join(provider_errors))
            if any(record["host"] != "openrouter.ai" for record in provider_requests):
                raise AssertionError("OpenRouter client used an unexpected TLS-host name")
            if not proxy_requests or any(line != "CONNECT openrouter.ai:443 HTTP/1.1"
                                          for line in proxy_requests):
                raise AssertionError("OpenRouter client did not use the isolated loopback HTTPS proxy")
            if ("NATIVE_MODEL_ROUTING_DONE" not in simple_result.stdout
                    or "NATIVE_MODEL_ROUTING_DONE" not in complex_result.stdout
                    or "NATIVE_MODEL_ROUTING_DONE" not in explicit_result.stdout):
                raise AssertionError("ZeroClaw did not deliver one or more routing fixture responses")
            return {"native_binary_version": version.stdout.strip(),
                    "native_model_requests": len(provider_requests),
                    "native_tools_registered": sorted(provider_requests[0]["tool_names"]),
                    "native_ha_mcp_exposed_marker_forwarded": True,
                    "native_ha_mcp_unexposed_marker_omitted": True,
                    "native_provider_family": "openrouter",
                    "native_loopback_https_connects": len(proxy_requests),
                    "native_tls_fixture_ca_only": True,
                    "automatic_routing_simple_model": provider_requests[2]["body"]["model"],
                    "automatic_routing_complex_model": provider_requests[3]["body"]["model"],
                    "automatic_routing_fusion_plugins": provider_requests[3]["body"].get("plugins"),
                    "explicit_provider_model_override": provider_requests[4]["body"]["model"],
                    "explicit_provider_model_fusion_plugins": provider_requests[4]["body"].get("plugins")}

        native_nonadmin_token = await create_nonadmin_user(token) if NATIVE_INTEROP else None

        async def rpc(method, call_id, params=None, version=None):
            headers = {"Accept": "application/json",
                       "Content-Type": "application/json",
                       "Authorization": "Bearer " + token}
            if version:
                headers["MCP-Protocol-Version"] = version
            payload = {"jsonrpc": "2.0", "id": call_id, "method": method}
            if params is not None:
                payload["params"] = params
            async with session.post(BASE + "/api/mcp", json=payload,
                                    headers=headers) as response:
                raw = await response.read()
                if response.status != 200:
                    raise RuntimeError(
                        f"MCP {method} returned HTTP {response.status}"
                    )
                try:
                    result = json.loads(raw)
                except json.JSONDecodeError as err:
                    raise RuntimeError(
                        f"MCP {method} returned a non-JSON response"
                    ) from err
                if "error" in result:
                    raise RuntimeError(f"MCP {method} returned a JSON-RPC error")
                return result["result"]

        # Unauthenticated access to the configured main MCP URL must be denied.
        unauthenticated_status, _ = await request(
            "POST", "/api/mcp",
            body={"jsonrpc": "2.0", "id": "unauth", "method": "initialize",
                  "params": {"protocolVersion": "2025-03-26",
                             "capabilities": {},
                             "clientInfo": {"name": "native-mcp-smoke", "version": "1"}}},
            expected=(401, 403),
        )

        async def list_tools():
            initialized = await rpc(
                "initialize", "init",
                {"protocolVersion": "2025-03-26", "capabilities": {},
                 "clientInfo": {"name": "native-mcp-smoke", "version": "1"}},
            )
            version = initialized["protocolVersion"]
            result = await rpc("tools/list", "tools", {}, version)
            return version, result["tools"]

        # Exercise the Home Assistant API read-only filter against its actual
        # mutating call_action tool, without issuing any action.
        await set_options(["homeassistant"])
        version, ha_tools = await list_tools()
        ha_names = {tool["name"] for tool in ha_tools}
        if "homeassistant__call_action" in ha_names:
            raise AssertionError("read-only main URL exposed homeassistant__call_action")
        if not {"homeassistant__render_template", "homeassistant__search_actions"} <= ha_names:
            raise AssertionError("expected read-only Home Assistant tools were absent")
        denied_call = await rpc(
            "tools/call", "denied-call",
            {"name": "homeassistant__call_action",
             "arguments": {"action": "mcp_smoke.invalid_action"}}, version,
        )
        denial_text = "\n".join(
            item.get("text", "") for item in denied_call.get("content", [])
            if item.get("type") == "text"
        )
        if (denied_call.get("isError") is not True
                or 'Tool "homeassistant__call_action" not found' not in denial_text):
            raise AssertionError("filtered action call was not rejected by the tool filter")

        # The Assist API contains exposed-entity-aware live context and built-in
        # mutating intent tools; read_only must leave only read-only tools.
        await set_options(["assist"], require_admin=not NATIVE_INTEROP)
        _, assist_tools = await list_tools()
        assist_names = {tool["name"] for tool in assist_tools}
        if "homeassistant__GetLiveContext" not in assist_names:
            raise AssertionError("Assist API omitted homeassistant__GetLiveContext")
        if any(name.startswith("intent__") for name in assist_names):
            raise AssertionError("read-only Assist API exposed a mutating intent tool")
        assist_annotations = {}
        for tool in assist_tools:
            annotations = tool.get("annotations")
            if not isinstance(annotations, dict) or annotations.get("readOnlyHint") is not True:
                raise AssertionError("read-only Assist API omitted a readOnlyHint annotation")
            assist_annotations[tool["name"]] = annotations["readOnlyHint"]

        # Run the production startup helper inside this isolated container so
        # it reaches the real HA HTTP MCP endpoint without a published port,
        # host-network access, source mount, or Home Assistant state read.
        helper_namespace = {"__name__": "ha_preflight_fixture"}
        helper_source = base64.b64decode(PREFLIGHT_SOURCE_B64)
        exec(compile(helper_source, "<native-ha-preflight>", "exec"), helper_namespace)
        selected_ha_token = native_nonadmin_token or token
        if not NATIVE_INTEROP:
            helper_namespace["check_options"]({
                "ha_mcp_enabled": True,
                "ha_mcp_url": BASE + "/api/mcp",
                "ha_mcp_token": selected_ha_token,
            })
        if PREFLIGHT_ONLY:
            print(json.dumps({
                "status": "PASS",
                "endpoint": "/api/mcp",
                "require_admin": not NATIVE_INTEROP,
                "nonadmin_user": NATIVE_INTEROP,
                "assist_read_only_tools": sorted(assist_names),
                "assist_read_only_annotations": assist_annotations,
                "startup_check_options_passed": True,
                "context_read_performed": False,
                "protocol_version": version,
            }, sort_keys=True))
            return

        exposed_marker = "NATIVE_HA_EXPOSED_7F2A91"
        private_marker = "NATIVE_HA_UNEXPOSED_0C8314"
        for entity_id, state, attributes in (
            ("sensor.synthetic_exposed_temperature", "21.5",
             {"friendly_name": "Synthetic exposed temperature " + exposed_marker,
              "device_class": "temperature", "unit_of_measurement": "°C"}),
            ("sensor.synthetic_private", "private-value",
             {"friendly_name": "Synthetic unexposed sensor " + private_marker}),
        ):
            await request(
                "POST", "/api/states/" + entity_id,
                body={"state": state, "attributes": attributes}, token=token,
                expected=(200, 201),
            )

        if NATIVE_INTEROP:
            result = await run_native_interop(native_nonadmin_token, exposed_marker, private_marker)
            print(json.dumps({
                "status": "PASS",
                "endpoint": "/api/mcp",
                "require_admin": False,
                "nonadmin_user": True,
                "assist_read_only_tools": sorted(assist_names),
                "assist_read_only_annotations": assist_annotations,
                "startup_effective_config_check_passed": True,
                "context_read_performed": True,
                "protocol_version": version,
                **result,
            }, sort_keys=True))
            return

        result = await rpc(
            "tools/call", "context",
            {"name": "homeassistant__GetLiveContext", "arguments": {}}, version,
        )
        if result.get("isError"):
            raise AssertionError("GetLiveContext returned an MCP error")
        context_text = "\n".join(
            item.get("text", "") for item in result.get("content", [])
            if item.get("type") == "text"
        )
        if ("Synthetic exposed temperature" not in context_text
                and "sensor.synthetic_exposed_temperature" not in context_text):
            raise AssertionError("exposed synthetic temperature missing from live context")
        if ("Synthetic unexposed sensor" in context_text
                or "sensor.synthetic_private" in context_text or "private-value" in context_text):
            raise AssertionError("unexposed synthetic sensor leaked into live context")

        print(json.dumps({
            "status": "PASS",
            "endpoint": "/api/mcp",
            "unauthenticated_status": unauthenticated_status,
            "require_admin": True,
            "homeassistant_read_only_tools": sorted(ha_names),
            "assist_read_only_tools": sorted(assist_names),
            "assist_read_only_annotations": assist_annotations,
            "startup_check_options_passed": True,
            "filtered_action_call_rejected": True,
            "live_context_exposed_entity": True,
            "live_context_unexposed_entity_omitted": True,
            "protocol_version": version,
        }, sort_keys=True))


asyncio.run(main())
'''


def run(command: list[str], *, timeout: int = 120, input_text: str | None = None,
        error_lines: int = 1) -> str:
    completed = subprocess.run(
        command,
        input=input_text.encode("utf-8") if input_text is not None else None,
        capture_output=True,
        text=False,
        timeout=timeout,
        check=False,
    )
    stdout = completed.stdout.decode("utf-8", "replace")
    stderr = completed.stderr.decode("utf-8", "replace")
    if completed.returncode:
        detail = (stderr.strip().splitlines()[-error_lines:]
                  or stdout.strip().splitlines()[-error_lines:])
        raise RuntimeError(
            f"command failed ({completed.returncode}): {command[0]}"
            + ("; " + " | ".join(line[:240] for line in detail) if detail else "")
        )
    return stdout.strip()


def ensure_image(pull: bool) -> None:
    try:
        image = json.loads(run(["docker", "image", "inspect", IMAGE]))[0]
    except (RuntimeError, json.JSONDecodeError):
        if not pull:
            raise RuntimeError("pinned Home Assistant image is not present; rerun with --pull")
        print("Pulling the pinned official Home Assistant image...", flush=True)
        run(["docker", "pull", "--platform", "linux/amd64", IMAGE], timeout=900)
        image = json.loads(run(["docker", "image", "inspect", IMAGE]))[0]
    if image["Os"] != "linux" or image["Architecture"] != "amd64":
        raise RuntimeError("pinned Home Assistant image is not linux/amd64")
    repo_digests = image.get("RepoDigests") or []
    if not any(EXPECTED_IMAGE_DIGEST in item for item in repo_digests):
        raise RuntimeError("Docker image digest did not match the pinned release digest")


def extract_pinned_zeroclaw(archive_path: Path, destination: Path) -> None:
    try:
        info = archive_path.lstat()
    except OSError:
        raise RuntimeError("official ZeroClaw release archive is unavailable") from None
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise RuntimeError("official ZeroClaw release archive is not a regular file")
    digest = hashlib.sha256()
    with archive_path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    if digest.hexdigest() != EXPECTED_ZEROCLAW_ARCHIVE_SHA256:
        raise RuntimeError("official ZeroClaw release archive digest did not match the pin")
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            matches = [member for member in archive.getmembers()
                       if member.name == "zeroclaw" and member.isfile()]
            if len(matches) != 1:
                raise RuntimeError("pinned release archive has no unique regular zeroclaw binary")
            source = archive.extractfile(matches[0])
            if source is None:
                raise RuntimeError("pinned release archive binary could not be read")
            with source, destination.open("xb") as output:
                while block := source.read(1024 * 1024):
                    output.write(block)
        os.chmod(destination, 0o700)
    except (OSError, tarfile.TarError):
        raise RuntimeError("pinned ZeroClaw release archive could not be extracted") from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pull", action="store_true", help="pull the pinned image when missing")
    parser.add_argument("--startup-timeout", type=int, default=240, metavar="SECONDS")
    parser.add_argument("--preflight-only", action="store_true",
                        help="exercise startup discovery without reading entity context")
    parser.add_argument("--native-interop", action="store_true",
                        help="run pinned ZeroClaw against native HA MCP and a loopback fake provider")
    parser.add_argument("--zeroclaw-archive", type=Path,
                        help="official 0.8.7 linux/amd64 release archive (required with --native-interop)")
    args = parser.parse_args()
    if args.native_interop and (args.preflight_only or args.zeroclaw_archive is None):
        parser.error("--native-interop requires --zeroclaw-archive and cannot use --preflight-only")
    if args.zeroclaw_archive is not None and not args.native_interop:
        parser.error("--zeroclaw-archive is only used with --native-interop")

    try:
        run(["docker", "info", "--format", "{{.OSType}}/{{.Architecture}}"], timeout=30)
        ensure_image(args.pull)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as err:
        print(f"BLOCKED: Docker/image preflight failed: {err}", file=sys.stderr)
        return 2

    container = "ha-native-mcp-smoke-" + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix="ha-native-mcp-smoke-") as temp_dir:
        config_dir = Path(temp_dir)
        (config_dir / "configuration.yaml").write_text(
            "homeassistant:\n  name: Native MCP smoke\n  unit_system: metric\n"
            "  time_zone: UTC\nhttp:\n  server_host: 127.0.0.1\n",
            encoding="utf-8",
        )
        native_binary = config_dir / "zeroclaw-native-interop"
        if args.native_interop:
            try:
                extract_pinned_zeroclaw(args.zeroclaw_archive, native_binary)
            except (OSError, RuntimeError) as err:
                print(f"BLOCKED: native interop binary preflight failed: {err}", file=sys.stderr)
                return 2
        docker_run = [
            "docker", "run", "--detach", "--name", container,
            "--network", "none", "--platform", "linux/amd64",
            "--volume", f"{config_dir}:/config", "--env", "TZ=UTC", IMAGE,
        ]
        try:
            run(docker_run, timeout=60)
            print("Started the pinned Home Assistant image with --network none and a fresh temporary /config.", flush=True)
            preflight_source = Path(__file__).resolve().parents[1] / "native" / "ha_preflight.py"
            helper = base64.b64encode(preflight_source.read_bytes()).decode("ascii")
            client = HA_CLIENT.replace("STARTUP_TIMEOUT", str(args.startup_timeout))
            client = client.replace("PREFLIGHT_SOURCE_B64_PLACEHOLDER", helper)
            client = client.replace("PREFLIGHT_ONLY_PLACEHOLDER", "True" if args.preflight_only else "False")
            if args.native_interop:
                config_source = Path(__file__).resolve().parents[1] / "native" / "config.py"
                config_source_b64 = base64.b64encode(config_source.read_bytes()).decode("ascii")
            else:
                config_source_b64 = ""
            client = client.replace("NATIVE_CONFIG_SOURCE_B64_PLACEHOLDER", config_source_b64)
            client = client.replace("NATIVE_INTEROP_PLACEHOLDER", "True" if args.native_interop else "False")
            output = run(
                ["docker", "exec", "-i", container, "python3", "-"],
                timeout=args.startup_timeout + 240,
                input_text=client,
                error_lines=8,
            )
            print(output)
            return 0
        except (OSError, RuntimeError, subprocess.TimeoutExpired, KeyError, AssertionError) as err:
            print(f"FAIL: isolated HA MCP smoke did not pass: {err}", file=sys.stderr)
            return 1
        finally:
            subprocess.run(
                ["docker", "rm", "--force", container],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )


if __name__ == "__main__":
    raise SystemExit(main())
