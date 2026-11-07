#!/usr/bin/env python3
"""Exercise the native ZeroClaw ARM64 image in an isolated Docker network.

The image is never attached to a host network. Its only provider is a tiny
synthetic OpenAI-compatible server sharing a Docker ``none`` network namespace
with the app. The script creates and removes only its uniquely named container
and volume resources.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import time
from typing import Any


SYNTHETIC_KEY = "synthetic-test-key"
SUPERVISOR_SENTINEL = "native-image-smoke-supervisor-sentinel"
PRIMARY_MODEL = "test-primary"
REASONING_MODEL = "test-reasoning"
RELEASE_ARCHIVE_SHA256 = "eab013d82ed333689698a328b104ecaf5f5a76b046af30ab25482f0181518f3d"
APP_SOURCE_URL = "https://github.com/Nafjan/zeroclaw-ha-addon"
ASSISTANT_REPLY = "native image synthetic response"
STABLE_APP_VERSION = "4.0.0.0"
APP_VERSION_PATTERN = re.compile(
    r"^(?:4\.0\.0\.0|4\.0\.0-dev\.g[0-9a-f]{12}\.(?:0|[1-9][0-9]*)\.[1-9][0-9]*)$"
)


class SmokeFailure(RuntimeError):
    """An image qualification assertion failed."""


def validate_app_version(app_version: str) -> None:
    """Accept the stable app version or a run-specific Supervisor prerelease."""
    if not isinstance(app_version, str) or not APP_VERSION_PATTERN.fullmatch(app_version):
        raise SmokeFailure(
            "app version must be 4.0.0.0 or 4.0.0-dev.g<SHA12>.<run-id>.<attempt>"
        )


PROVIDER_SOURCE = r'''import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading

events_path = Path("/tmp/native-image-events.jsonl")
events_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *args):
        return
    def send_json(self, status, value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def record(self, method, body=None):
        tools = body.get("tools", []) if isinstance(body, dict) else []
        names = []
        if isinstance(tools, list):
            for tool in tools:
                if isinstance(tool, dict):
                    name = tool.get("name")
                    fn = tool.get("function")
                    if name is None and isinstance(fn, dict):
                        name = fn.get("name")
                    if isinstance(name, str):
                        names.append(name)
        event = {
            "method": method,
            "path": self.path,
            "authorized": self.headers.get("Authorization") == "Bearer synthetic-test-key",
            "model": body.get("model") if isinstance(body, dict) else None,
            "tools": names,
        }
        with events_lock, events_path.open("a", encoding="utf-8") as output:
            output.write(json.dumps(event, separators=(",", ":")) + "\n")
            output.flush()
    def do_GET(self):
        self.record("GET")
        if self.path not in ("/v1/models", "/models"):
            self.send_json(404, {"error": {"message": "synthetic endpoint not found"}})
            return
        self.send_json(200, {"object": "list", "data": [
            {"id": "test-primary", "object": "model", "owned_by": "synthetic"},
            {"id": "test-reasoning", "object": "model", "owned_by": "synthetic"},
        ]})
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if length < 0 or length > 1048576:
            self.send_json(413, {"error": {"message": "synthetic body rejected"}})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            body = None
        self.record("POST", body)
        if self.path != "/v1/chat/completions" or not isinstance(body, dict):
            self.send_json(404, {"error": {"message": "synthetic endpoint not found"}})
            return
        self.send_json(200, {
            "id": "chatcmpl-native-smoke", "object": "chat.completion", "created": 1794000000,
            "model": body.get("model", "test-primary"),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "native image synthetic response"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 3, "completion_tokens": 6, "total_tokens": 9},
        })

ThreadingHTTPServer(("127.0.0.1", 42620), Handler).serve_forever()
'''


def scrub(value: str, volume: str, name_prefix: str) -> str:
    value = re.sub(r"(?im)(X-Pairing-Code:\s*)\S+", r"\1[redacted-pairing-code]", value)
    value = re.sub(r"(?m)^(\s*│\s*).+?(\s*│\s*)$", r"\1[redacted-pairing-code]\2", value)
    return value.replace(SYNTHETIC_KEY, "[synthetic-key]").replace(
        SUPERVISOR_SENTINEL, "[supervisor-sentinel]"
    ).replace(volume, "[smoke-volume]").replace(name_prefix, "[smoke-resource]")


def docker(
    arguments: list[str], *,
    timeout: float = 60,
    volume: str = "",
    name_prefix: str = "",
    allow_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    command = ["docker", *arguments]
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        operation = " ".join(arguments[:3])
        raise SmokeFailure(
            f"Docker command timed out after {timeout:g}s: {scrub(operation, volume, name_prefix)}"
        ) from None
    if result.returncode and not allow_failure:
        message = scrub((result.stderr or result.stdout)[-6000:], volume, name_prefix)
        raise SmokeFailure(f"Docker command failed ({arguments[0]}, exit {result.returncode}): {message}")
    return result


def docker_json(arguments: list[str], *, volume: str, name_prefix: str) -> Any:
    result = docker(arguments, volume=volume, name_prefix=name_prefix)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        raise SmokeFailure(f"Docker returned invalid JSON for {arguments[0]}") from None


def _docker_resource_missing(output: str, name: str) -> bool:
    lowered = output.casefold()
    return name.casefold() in lowered and any(
        marker in lowered
        for marker in ("no such object", "no such container", "no such volume")
    )


def _cleanup_native_resource(
    remove_arguments: list[str],
    inspect_arguments: list[str],
    name: str,
    volume: str,
    name_prefix: str,
) -> str | None:
    try:
        removed = docker(
            remove_arguments, timeout=20, volume=volume, name_prefix=name_prefix,
            allow_failure=True,
        )
    except Exception as exc:
        removal_failure = (
            f"cleanup command for {scrub(name, volume, name_prefix)} failed: "
            f"{scrub(str(exc), volume, name_prefix)}"
        )
    else:
        if removed.returncode == 0:
            return None
        detail = scrub((removed.stderr or removed.stdout)[-1000:], volume, name_prefix)
        removal_failure = (
            f"cleanup command for {scrub(name, volume, name_prefix)} returned "
            f"exit {removed.returncode}: {detail}"
        )

    try:
        inspected = docker(
            inspect_arguments, timeout=20, volume=volume, name_prefix=name_prefix,
            allow_failure=True,
        )
    except Exception as exc:
        return (
            f"{removal_failure}; could not verify fixture resource absence: "
            f"{scrub(str(exc), volume, name_prefix)}"
        )
    if inspected.returncode != 0:
        output = inspected.stderr or inspected.stdout
        if _docker_resource_missing(output, name):
            return None
        detail = scrub(output[-1000:], volume, name_prefix)
        return f"{removal_failure}; fixture resource absence was not confirmed: {detail}"
    return f"{removal_failure}; fixture resource remains after cleanup"


def wait_for_health(app: str, provider: str, volume: str, name_prefix: str) -> None:
    deadline = time.monotonic() + 75
    last_error = "not attempted"
    while time.monotonic() < deadline:
        result = docker([
            "exec", provider, "python3", "-c",
            "import json,urllib.request; r=urllib.request.urlopen('http://127.0.0.1:42617/health', timeout=2); "
            "d=json.load(r); assert d.get('status')=='ok' and d.get('require_pairing') is True",
        ], timeout=15, volume=volume, name_prefix=name_prefix, allow_failure=True)
        if result.returncode == 0:
            return
        last_error = scrub((result.stderr or result.stdout)[-300:], volume, name_prefix)
        state = docker(["inspect", "--format", "{{.State.Running}}", app],
                       timeout=10, volume=volume, name_prefix=name_prefix, allow_failure=True)
        if state.returncode or state.stdout.strip() != "true":
            logs = docker(["logs", "--tail", "40", app], timeout=5,
                          volume=volume, name_prefix=name_prefix, allow_failure=True)
            detail = scrub((logs.stderr + logs.stdout)[-6000:], volume, name_prefix)
            raise SmokeFailure(f"native app exited before loopback health was ready: {detail}")
        time.sleep(1)
    raise SmokeFailure(f"native daemon loopback health did not become ready: {last_error}")


def seed_volume(image: str, volume: str, name_prefix: str) -> None:
    options = {
        "openrouter_api_key": SYNTHETIC_KEY,
        "default_model": PRIMARY_MODEL,
        "complex_model": REASONING_MODEL,
        "telegram_bot_token": "",
        "ha_mcp_enabled": False,
        "daily_cost_limit_usd": 10.0,
        "monthly_cost_limit_usd": 40.0,
        "max_tool_iterations": 8,
        "max_history_messages": 30,
        "max_context_tokens": 16000,
        "provider_max_tokens": 2048,
    }
    options_json = json.dumps(options, separators=(",", ":"))
    seed_code = (
        "import json,os,pathlib,sys; root=pathlib.Path('/data'); "
        "root.mkdir(exist_ok=True); p=root/'options.json'; "
        "p.write_text(sys.argv[1], encoding='utf-8'); os.chmod(p,0o644); "
        "legacy=root/'workspace'/'memory'; legacy.mkdir(parents=True,exist_ok=True); "
        "os.chown(root/'workspace',1000,1000); "
        "(legacy/'qualification-note.txt').write_text('synthetic migration fixture\\n',encoding='utf-8'); "
        "os.chmod(legacy/'qualification-note.txt',0o600)"
    )
    docker([
        "run", "--rm", "--platform", "linux/arm64", "--network", "none",
        "--mount", f"type=volume,source={volume},target=/data",
        "--entrypoint", "python3", image, "-c", seed_code, options_json,
    ], timeout=90, volume=volume, name_prefix=name_prefix)


def start_provider(image: str, provider: str, volume: str, name_prefix: str) -> None:
    docker([
        "create", "--platform", "linux/arm64", "--name", provider, "--network", "none",
        "--entrypoint", "python3", image, "-u", "-c", PROVIDER_SOURCE,
    ], timeout=60, volume=volume, name_prefix=name_prefix)
    docker(["start", provider], timeout=20, volume=volume, name_prefix=name_prefix)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = docker([
            "exec", provider, "python3", "-c",
            "import socket; s=socket.create_connection(('127.0.0.1',42620),timeout=1); s.close()",
        ], timeout=15, volume=volume, name_prefix=name_prefix, allow_failure=True)
        if result.returncode == 0:
            return
        time.sleep(0.5)
    raise SmokeFailure("synthetic provider did not listen on its private loopback")


def create_app(image: str, app: str, provider: str, volume: str,
               binary_sha256: str, name_prefix: str) -> None:
    docker([
        "create", "--platform", "linux/arm64", "--name", app,
        "--network", f"container:{provider}", "--read-only",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=32m",
        "--mount", f"type=volume,source={volume},target=/data",
        "--env", f"SUPERVISOR_TOKEN={SUPERVISOR_SENTINEL}",
        "--env", f"QUALIFICATION_BINARY_SHA256={binary_sha256}",
        image,
    ], timeout=60, volume=volume, name_prefix=name_prefix)


def run_cli_probe(image: str, provider: str, volume: str, name_prefix: str,
                  command: list[str], *, timeout: float = 60,
                  allow_failure: bool = False) -> subprocess.CompletedProcess[str]:
    return docker([
        "run", "--rm", "--platform", "linux/arm64",
        "--network", f"container:{provider}", "--read-only",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=32m",
        "--mount", f"type=volume,source={volume},target=/data",
        "--entrypoint", "su-exec", image,
        "zeroclaw:zeroclaw", "env", "-i",
        "HOME=/data/native", "PATH=/usr/local/bin:/usr/bin:/bin",
        "/usr/local/bin/zeroclaw", "--config-dir", "/data/native", *command,
    ], timeout=timeout, volume=volume, name_prefix=name_prefix, allow_failure=allow_failure)


def rewrite_fixture_config(image: str, volume: str, name_prefix: str) -> None:
    code = r'''from pathlib import Path
import os
import stat
import tomllib

path = Path('/data/native/config.toml')
info = path.lstat()
if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
    raise SystemExit('generated config is not a regular file')
text = path.read_text(encoding='utf-8')
if text.count('https://openrouter.ai/api/v1') != 2:
    raise SystemExit('generated config did not contain exactly two official provider URLs')
text = text.replace('https://openrouter.ai/api/v1', 'http://127.0.0.1:42620/v1')
for old, new, expected_count in (
    ('[providers.models.openrouter.', '[providers.models.custom.', 2),
    ('[cost.rates.providers.models.openrouter.', '[cost.rates.providers.models.custom.', 2),
    ('"openrouter.default"', '"custom.default"', 2),
    ('"openrouter.reasoning"', '"custom.reasoning"', 1),
):
    if text.count(old) != expected_count:
        raise SystemExit('generated config did not contain the expected native OpenRouter route references')
    text = text.replace(old, new)
config = tomllib.loads(text)
models = config.get('providers', {}).get('models', {})
if 'openrouter' in models or set(models) != {'custom'}:
    raise SystemExit('fixture config did not use only the supported compatible-provider family')
profiles = models.get('custom', {})
if set(profiles) != {'default', 'reasoning'}:
    raise SystemExit('generated config did not contain the two expected direct provider profiles')
if profiles['default'].get('model') != 'test-primary' or profiles['reasoning'].get('model') != 'test-reasoning':
    raise SystemExit('generated config model profiles did not match the synthetic options')
if any(profile.get('uri') != 'http://127.0.0.1:42620/v1' for profile in profiles.values()):
    raise SystemExit('compatible-provider fixture did not point both profiles to its private loopback')
if config.get('gateway', {}).get('host') != '127.0.0.1' or config.get('gateway', {}).get('port') != 42617:
    raise SystemExit('generated gateway is not restricted to its expected loopback endpoint')
path.write_text(text, encoding='utf-8')
os.chmod(path, 0o600)
'''
    docker([
        "run", "--rm", "--platform", "linux/arm64", "--network", "none",
        "--read-only", "--tmpfs", "/tmp:rw,nosuid,nodev,size=16m",
        "--mount", f"type=volume,source={volume},target=/data",
        "--entrypoint", "su-exec", image,
        "zeroclaw:zeroclaw", "python3", "-c", code,
    ], timeout=30, volume=volume, name_prefix=name_prefix)


def inspect_events(provider: str, volume: str, name_prefix: str) -> list[dict[str, Any]]:
    code = "from pathlib import Path; p=Path('/tmp/native-image-events.jsonl'); print(p.read_text() if p.exists() else '')"
    result = docker(["exec", provider, "python3", "-c", code], timeout=10,
                    volume=volume, name_prefix=name_prefix)
    events: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            detail = scrub(line[:500], volume, name_prefix)
            raise SmokeFailure(f"synthetic provider event log was malformed: {detail!r}") from None
        if isinstance(item, dict):
            events.append(item)
    return events


def validate_image_labels(labels: dict[str, str], binary_sha256: str,
                          app_source_revision: str, app_version: str) -> None:
    validate_app_version(app_version)
    if labels.get("io.zeroclaw.runtime.binary-sha256") != binary_sha256:
        raise SmokeFailure("candidate image binary hash label did not match the verified archive executable")
    if labels.get("io.zeroclaw.runtime.release-archive-sha256") != RELEASE_ARCHIVE_SHA256:
        raise SmokeFailure("candidate image archive hash label did not match the verified upstream archive")
    if labels.get("io.zeroclaw.runtime.source.revision") != "99bd353c756f4e64f381cfe9c3002ebff32f3055":
        raise SmokeFailure("candidate image runtime provenance did not match the verified upstream source pin")
    if (labels.get("org.opencontainers.image.source") != APP_SOURCE_URL
            or labels.get("org.opencontainers.image.revision") != app_source_revision
            or labels.get("io.zeroclaw.app.source.revision") != app_source_revision):
        raise SmokeFailure("candidate image app provenance did not identify its own source revision")
    if (labels.get("org.opencontainers.image.version") != app_version
            or labels.get("io.hass.version") != app_version
            or labels.get("io.hass.type") != "app"
            or labels.get("io.hass.arch") != "aarch64"):
        raise SmokeFailure("candidate image Home Assistant version/type/architecture labels did not match the requested app candidate")


def assert_container_state(app: str, volume: str, name_prefix: str,
                           binary_sha256: str, app_source_revision: str,
                           app_version: str) -> None:
    inspect = docker_json(["inspect", app], volume=volume, name_prefix=name_prefix)[0]
    if inspect.get("HostConfig", {}).get("ReadonlyRootfs") is not True:
        raise SmokeFailure("native candidate was not run with a read-only root filesystem")
    mode = inspect.get("HostConfig", {}).get("NetworkMode")
    if not isinstance(mode, str) or not mode.startswith("container:"):
        raise SmokeFailure("native app did not share the isolated provider network namespace")
    labels = inspect.get("Config", {}).get("Labels") or {}
    validate_image_labels(labels, binary_sha256, app_source_revision, app_version)

    code = r'''import json,os,re,stat
def facts(path):
    s=os.lstat(path)
    return (s.st_uid,s.st_gid,stat.S_IMODE(s.st_mode),stat.S_ISREG(s.st_mode),stat.S_ISDIR(s.st_mode))
paths={
  '/data':(0,1000,0o750,False,True),
  '/data/options.json':(0,0,0o600,True,False),
  '/data/workspace':(0,0,0o700,False,True),
  '/data/.runtime-layout':(0,0,0o600,True,False),
  '/data/.native-options.sha256':(0,0,0o600,True,False),
  '/data/migrations':(0,0,0o700,False,True),
  '/data/native':(1000,1000,0o700,False,True),
  '/data/native/config.toml':(1000,1000,0o600,True,False),
  '/data/native/data':(1000,1000,0o700,False,True),
  '/data/native/data/memory/qualification-note.txt':(1000,1000,0o600,True,False),
  '/data/native/agents/default/workspace':(1000,1000,0o700,False,True),
}
bad={p:(facts(p),want) for p,want in paths.items() if facts(p)!=want}
if bad: raise SystemExit('persistent path permissions or ownership are unexpected: '+repr(bad))
status=open('/proc/1/status',encoding='ascii').read()
uids=re.search(r'^Uid:\s+(\d+)',status,re.M)
gids=re.search(r'^Gid:\s+(\d+)',status,re.M)
if not uids or not gids or (int(uids.group(1)),int(gids.group(1)))!=(1000,1000):
 raise SystemExit('daemon PID 1 is not running as UID/GID 1000')
for name in ('LICENSE-MIT','LICENSE-APACHE','NOTICE'):
 p='/usr/share/licenses/zeroclaw-runtime/'+name
 s=os.lstat(p)
 if not stat.S_ISREG(s.st_mode) or s.st_size == 0 or stat.S_IMODE(s.st_mode) != 0o444:
  raise SystemExit('pinned upstream runtime license file is missing or unsafe')
'''
    result = docker(["exec", app, "python3", "-c", code], timeout=15,
                    volume=volume, name_prefix=name_prefix)
    del result
    environment_check = (
        "items=open('/proc/1/environ','rb').read().split(b'\\0'); "
        "assert not any(b'SUPERVISOR_TOKEN=' in item or "
        "b'native-image-smoke-supervisor-sentinel' in item for item in items), "
        "'daemon inherited the synthetic Supervisor-token sentinel'"
    )
    docker([
        "exec", app, "su-exec", "zeroclaw:zeroclaw", "env", "-i",
        "HOME=/data/native", "PATH=/usr/local/bin:/usr/bin:/bin",
        "python3", "-c", environment_check,
    ], timeout=15, volume=volume, name_prefix=name_prefix)
    options_privacy_check = (
        "try: open('/data/options.json','rb').read(1)\n"
        "except PermissionError: pass\n"
        "else: raise SystemExit('daemon UID can read Supervisor options')"
    )
    docker([
        "exec", app, "su-exec", "zeroclaw:zeroclaw", "env", "-i",
        "HOME=/data/native", "PATH=/usr/local/bin:/usr/bin:/bin",
        "python3", "-c", options_privacy_check,
    ], timeout=15, volume=volume, name_prefix=name_prefix)
    legacy_workspace_check = (
        "try: open('/data/workspace/memory/qualification-note.txt','rb').read(1)\n"
        "except PermissionError: pass\n"
        "else: raise SystemExit('daemon UID can read the sealed legacy workspace')"
    )
    docker([
        "exec", app, "su-exec", "zeroclaw:zeroclaw", "env", "-i",
        "HOME=/data/native", "PATH=/usr/local/bin:/usr/bin:/bin",
        "python3", "-c", legacy_workspace_check,
    ], timeout=15, volume=volume, name_prefix=name_prefix)
    binary = docker(["exec", app, "sha256sum", "/usr/local/bin/zeroclaw"],
                    timeout=10, volume=volume, name_prefix=name_prefix)
    if binary.stdout.split()[0] != binary_sha256:
        raise SmokeFailure("executable in the native image did not match the verified candidate hash")
    arch = docker(["exec", app, "uname", "-m"], timeout=10,
                  volume=volume, name_prefix=name_prefix)
    if arch.stdout.strip() != "aarch64":
        raise SmokeFailure(f"candidate image was not executing as aarch64: {arch.stdout.strip()}")


def run_agent_turn(image: str, provider: str, volume: str, name_prefix: str,
                   model_hint: str | None = None) -> None:
    message = "Reply with the requested synthetic test response. Do not call tools."
    command = ["agent", "--agent", "default", "--message", message]
    if model_hint:
        command.extend(["--model", model_hint])
    result = run_cli_probe(image, provider, volume, name_prefix, command, timeout=90)
    output = result.stdout + "\n" + result.stderr
    safe_output = scrub(output, volume, name_prefix)
    if result.returncode != 0 or ASSISTANT_REPLY not in output:
        raise SmokeFailure(f"native CLI request failed or returned no synthetic answer: {safe_output[-6000:]}")
    if SYNTHETIC_KEY in output or SUPERVISOR_SENTINEL in output:
        raise SmokeFailure("native CLI output exposed a synthetic credential")


def verify_provider_events(events: list[dict[str, Any]]) -> None:
    chats = [event for event in events if event.get("method") == "POST"]
    if len(chats) != 2 or any(event.get("path") != "/v1/chat/completions" for event in chats):
        raise SmokeFailure(f"expected two compatible-provider chat calls to private loopback, observed {len(chats)}")
    if [event.get("model") for event in chats] != [PRIMARY_MODEL, REASONING_MODEL]:
        raise SmokeFailure("primary and explicit reasoning routes selected unexpected provider models")
    if any(event.get("authorized") is not True for event in chats):
        raise SmokeFailure("provider requests did not use the synthetic Bearer credential")
    if any(event.get("tools") != ["memory_recall"] for event in chats):
        observed = [event.get("tools") for event in chats]
        raise SmokeFailure(f"native provider tools escaped the memory_recall-only policy: {observed}")
    if any(event.get("method") not in ("GET", "POST") for event in events):
        raise SmokeFailure("native runtime used an unexpected HTTP method against the provider fixture")
    if any(event.get("method") == "GET" and event.get("path") not in ("/v1/models", "/models") for event in events):
        raise SmokeFailure("native runtime requested an unexpected provider discovery endpoint")


def run_smoke(image: str, binary_sha256: str, app_source_revision: str,
              app_version: str = STABLE_APP_VERSION) -> None:
    validate_app_version(app_version)
    if len(binary_sha256) != 64 or any(char not in "0123456789abcdef" for char in binary_sha256):
        raise SmokeFailure("candidate binary SHA-256 input is malformed")
    suffix = f"{os.getpid()}-{secrets.token_hex(5)}"
    name_prefix = f"zeroclaw-native-smoke-{suffix}"
    volume = f"{name_prefix}-data"
    provider = f"{name_prefix}-provider"
    app = f"{name_prefix}-app"
    created_volume = False
    created_provider = False
    created_app = False
    primary_error: BaseException | None = None
    try:
        # Docker may create the volume even if its CLI client times out.
        created_volume = True
        docker(["volume", "create", volume], timeout=20, volume=volume, name_prefix=name_prefix)
        seed_volume(image, volume, name_prefix)
        created_provider = True
        start_provider(image, provider, volume, name_prefix)
        created_app = True
        create_app(image, app, provider, volume, binary_sha256, name_prefix)
        docker(["start", app], timeout=20, volume=volume, name_prefix=name_prefix)
        wait_for_health(app, provider, volume, name_prefix)
        assert_container_state(app, volume, name_prefix, binary_sha256, app_source_revision,
                               app_version)

        # Prove the real options generator wrote the native config, then make
        # only its two official provider URLs loopback for this no-network run.
        # The pinned daemon owns the SQLite/config state lock. Run the explicit
        # CLI routing probes only while it is gracefully stopped, through a
        # temporary container sharing the same volume and private loopback.
        docker(["stop", "--time", "10", app], timeout=20,
              volume=volume, name_prefix=name_prefix)
        # Shutdown writes its live config state. Rewrite only after it stops,
        # using a separate network-none helper with the same daemon UID.
        rewrite_fixture_config(image, volume, name_prefix)
        run_agent_turn(image, provider, volume, name_prefix)
        run_agent_turn(image, provider, volume, name_prefix, "hint:reasoning")
        verify_provider_events(inspect_events(provider, volume, name_prefix))

        docker(["start", app], timeout=20, volume=volume, name_prefix=name_prefix)
        wait_for_health(app, provider, volume, name_prefix)
        assert_container_state(app, volume, name_prefix, binary_sha256, app_source_revision,
                               app_version)

        marker = "native-image-smoke-state-survived-restart"
        marker_code = "from pathlib import Path; Path('/data/native/data/qualification-restart.marker').write_text('" + marker + "',encoding='ascii')"
        docker(["exec", app, "su-exec", "zeroclaw:zeroclaw", "python3", "-c", marker_code],
              timeout=10, volume=volume, name_prefix=name_prefix)
        docker(["stop", "--time", "10", app], timeout=20, volume=volume, name_prefix=name_prefix)
        docker(["start", app], timeout=20, volume=volume, name_prefix=name_prefix)
        wait_for_health(app, provider, volume, name_prefix)
        marker_check = "from pathlib import Path; p=Path('/data/native/data/qualification-restart.marker'); assert p.read_text(encoding='ascii')=='" + marker + "'"
        docker(["exec", app, "python3", "-c", marker_check], timeout=10,
              volume=volume, name_prefix=name_prefix)

        # SIGKILL deliberately leaves the upstream daemon socket behind. The
        # migration/ownership checks must allow only this known socket path.
        docker(["kill", "--signal", "KILL", app], timeout=15, volume=volume, name_prefix=name_prefix)
        socket_check = "import os,stat; p='/data/native/data/daemon.sock'; s=os.lstat(p); assert stat.S_ISSOCK(s.st_mode), 'expected the upstream daemon RPC socket after SIGKILL'"
        docker([
            "run", "--rm", "--platform", "linux/arm64", "--network", "none",
            "--mount", f"type=volume,source={volume},target=/data",
            "--entrypoint", "python3", image, "-c", socket_check,
        ], timeout=30, volume=volume, name_prefix=name_prefix)
        docker(["start", app], timeout=20, volume=volume, name_prefix=name_prefix)
        wait_for_health(app, provider, volume, name_prefix)
        assert_container_state(app, volume, name_prefix, binary_sha256, app_source_revision,
                               app_version)
        docker(["exec", app, "python3", "-c", marker_check], timeout=10,
              volume=volume, name_prefix=name_prefix)
    except BaseException as exc:
        primary_error = exc
        raise
    finally:
        cleanup_failures = []
        if created_app:
            failure = _cleanup_native_resource(
                ["rm", "--force", app], ["inspect", app], app, volume, name_prefix,
            )
            if failure:
                cleanup_failures.append(failure)
        if created_provider:
            failure = _cleanup_native_resource(
                ["rm", "--force", provider], ["inspect", provider], provider, volume, name_prefix,
            )
            if failure:
                cleanup_failures.append(failure)
        if created_volume:
            failure = _cleanup_native_resource(
                ["volume", "rm", volume], ["volume", "inspect", volume], volume,
                volume, name_prefix,
            )
            if failure:
                cleanup_failures.append(failure)
        if cleanup_failures:
            detail = "; ".join(cleanup_failures)
            if primary_error is None:
                raise SmokeFailure(f"native image fixture cleanup failed: {detail}") from None
            print(
                f"WARNING: native image fixture cleanup also failed after the primary failure: {detail}",
                file=sys.stderr,
            )
    print("PASS: ARM64 native image booted network-isolated, protected options and legacy state, routed authenticated primary/reasoning calls through the supported compatible-provider family to synthetic loopback, and recovered after graceful and SIGKILL restarts.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="locally built inactive candidate image tag")
    parser.add_argument("--binary-sha256", required=True, help="verified extracted executable digest")
    parser.add_argument("--app-source-revision", required=True,
                        help="local application source revision label")
    parser.add_argument("--app-version", default=STABLE_APP_VERSION,
                        help="expected app version label (stable default: 4.0.0.0)")
    args = parser.parse_args()
    try:
        run_smoke(args.image, args.binary_sha256, args.app_source_revision, args.app_version)
    except SmokeFailure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"FAIL: native image qualification infrastructure error: {type(exc).__name__}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
