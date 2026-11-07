#!/usr/bin/env python3
"""Check the configured native HA MCP read contract without reading home state.

This short-lived startup check does not proxy tools or isolate credentials.
Home Assistant and ZeroClaw remain the runtime enforcement points.
"""
import argparse
import http.client
import json
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request

MAX_RESPONSE = 262144
READ_TOOLS = {"homeassistant__GetLiveContext", "llm__GetDateTime"}


class PreflightError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fp.close()
        raise PreflightError("Home Assistant MCP must use its final URL without redirects")


def check_config(config):
    """Check the servers actually granted to the native default agent.

    Saved app options are not effective configuration after native edits. Resolve
    the native bundle union and exclusions before checking its actual endpoint.
    """
    try:
        mcp = config.get("mcp", {})
        enabled = mcp.get("enabled", False)
        if enabled is False:
            return
        if enabled is not True:
            raise ValueError
        aliases = config["agents"]["default"].get("mcp_bundles", [])
        bundles = config.get("mcp_bundles", {})
        if not isinstance(aliases, list) or not all(isinstance(a, str) for a in aliases):
            raise ValueError
        granted, excluded = set(), set()
        for alias in aliases:
            bundle = bundles.get(alias, {})
            for field, target in (("servers", granted), ("exclude", excluded)):
                values = bundle.get(field, [])
                if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                    raise ValueError
                target.update(values)
        servers = mcp.get("servers", [])
        if not isinstance(servers, list):
            raise ValueError
        selected = {}
        for server in servers:
            name = server.get("name")
            if not isinstance(name, str) or name in selected:
                raise ValueError
            selected[name] = server
        effective = (granted - excluded) & selected.keys()
        if not effective:
            return
        if effective != {"ha"}:
            raise PreflightError("Native default agent must use only the reviewed HA MCP server")
        server = selected["ha"]
        headers = server.get("headers", {})
        authorization = headers.get("Authorization")
        if (server.get("transport") != "http" or set(headers) != {"Authorization"}
                or not isinstance(authorization, str)
                or not authorization.startswith("Bearer ")
                or server.get("command") or server.get("args") or server.get("env")
                or server.get("pinned_resources") or server.get("tls_ca_cert_path")):
            raise PreflightError("Native HA MCP needs the supported HTTP bearer configuration; change an app option and restart to regenerate it")
        check_options({"ha_mcp_enabled": True, "ha_mcp_url": server.get("url"),
                       "ha_mcp_token": authorization.removeprefix("Bearer ")})
    except (KeyError, TypeError, AttributeError, ValueError):
        raise PreflightError("Native MCP configuration is malformed or unsupported") from None


def check_options(options):
    enabled = options.get("ha_mcp_enabled", False)
    if enabled is False:
        return
    if enabled is not True:
        raise PreflightError("Home Assistant MCP enabled must be a boolean")
    url, token = options.get("ha_mcp_url"), options.get("ha_mcp_token")
    if (not isinstance(url, str) or not isinstance(token, str) or not token
            or any(char.isspace() for char in token)):
        raise PreflightError("Home Assistant MCP needs its main URL and a credential")
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment or parsed.path != "/api/mcp"
            or any(ord(char) < 32 or ord(char) == 127 for char in url + token)):
        raise PreflightError("Use the main Home Assistant /api/mcp URL without credentials in the URL")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    headers = {"Authorization": "Bearer " + token,
               "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}

    def post(method, params=None, request_id=None):
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if request_id is not None:
            payload["id"] = request_id
        try:
            request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
            with opener.open(request, timeout=15) as response:
                raw = response.read(MAX_RESPONSE + 1)
                if len(raw) > MAX_RESPONSE:
                    raise PreflightError("Home Assistant MCP discovery response is too large")
                session = response.headers.get("Mcp-Session-Id")
                if session:
                    headers["Mcp-Session-Id"] = session
                if request_id is None:
                    return None
                if response.headers.get_content_type() == "text/event-stream":
                    events = [line[5:].strip() for line in raw.decode().splitlines()
                              if line.startswith("data:")]
                    messages = [json.loads(event) for event in events]
                    matches = [message for message in messages if isinstance(message, dict)
                               and type(message.get("id")) is int and message["id"] == request_id]
                    if len(matches) != 1:
                        raise PreflightError("Home Assistant MCP returned an invalid event response")
                    result = matches[0]
                else:
                    result = json.loads(raw)
        except urllib.error.HTTPError as exc:
            code = exc.code
            exc.close()
            raise PreflightError("Home Assistant MCP request was rejected (HTTP %d)" % code) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError, UnicodeError):
            raise PreflightError("Home Assistant MCP could not be reached or returned an invalid response") from None
        if (not isinstance(result, dict) or result.get("jsonrpc") != "2.0"
                or type(result.get("id")) is not int or result["id"] != request_id
                or not isinstance(result.get("result"), dict) or "error" in result):
            raise PreflightError("Home Assistant MCP rejected discovery or returned an invalid response")
        return result["result"]

    initialized = post("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "zeroclaw-ha-app-preflight", "version": "1"}}, 1)
    version = initialized.get("protocolVersion")
    if version not in ("2024-11-05", "2025-03-26", "2025-06-18"):
        raise PreflightError("Home Assistant MCP uses an unsupported protocol version")
    headers["MCP-Protocol-Version"] = version
    post("notifications/initialized")
    listed = post("tools/list", {}, 2)
    tools = listed.get("tools")
    if not isinstance(tools, list) or not tools or listed.get("nextCursor"):
        raise PreflightError("Home Assistant MCP did not expose the expected Device control read tools")
    names = set()
    for tool in tools:
        if (not isinstance(tool, dict) or not isinstance(tool.get("name"), str)
                or tool.get("name") not in READ_TOOLS
                or tool.get("name") in names or not isinstance(tool.get("annotations"), dict)
                or tool["annotations"].get("readOnlyHint") is not True):
            raise PreflightError("Configure Home Assistant MCP for Device control only with Read-only enabled")
        names.add(tool["name"])
    if "homeassistant__GetLiveContext" not in names:
        raise PreflightError("Home Assistant MCP Device control context is unavailable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--options", help="check an options fixture")
    inputs.add_argument("--config", help="check the effective native TOML configuration")
    args = parser.parse_args()
    try:
        if args.config:
            with open(args.config, "rb") as source:
                check_config(tomllib.load(source))
        else:
            with open(args.options, encoding="utf-8") as source:
                options = json.load(source)
            if not isinstance(options, dict):
                raise PreflightError("App options must be an object")
            check_options(options)
    except (PreflightError, OSError, ValueError) as exc:
        # JSON parser messages contain no source values; never print response,
        # request headers, options or token-bearing exception representations.
        message = str(exc) if isinstance(exc, PreflightError) else "Startup configuration could not be read"
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
