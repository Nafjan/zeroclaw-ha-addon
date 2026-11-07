"""Portable runtime qualification for the reversible ZeroClaw state migration.

Host invocation:
  python tests/state_migration_smoke.py --old-binary PATH_TO_0.7.5_ARM_BINARY --new-archive PATH_TO_PINNED_0.8.7_ARCHIVE

The test uses a temporary named volume. It pulls the Python utility image by
immutable digest if needed, builds a scratch ARM64 image from the pinned legacy
binary, and runs every container with networking disabled. The official 0.8.7
binary, migration helper, and fake provider run in the Python container. No
host HA state or credentials are read.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from typing import Any


REPO = Path(__file__).resolve().parents[1]
PYTHON_IMAGE = "python@sha256:4840d514c583a4d3d8cad3940e68dee6f0f6f3635c12fcd0a3d74c21a5b93a54"
OLD_BINARY_SHA256 = "1a3911d3cc776e3f0041b3c6a5b9eb1009d976aa556e73a7afd1c713e5d37c54"
NEW_ARCHIVE_SHA256 = "3cc7f1c859a67524d5496260d29806190bc7127d2877a479a5496ce34b9b401a"
SYNTHETIC_FACT = "The legacy migration marker is cobalt lantern 7319."
SYNTHETIC_SESSION = "synthetic legacy session row survives native upgrade"
CONTAINER_UID = 1000


class SmokeFailure(RuntimeError):
    pass


class FakeProvider(http.server.BaseHTTPRequestHandler):
    requests: list[dict[str, Any]] = []

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        self.requests.append(body)
        if body.get("stream"):
            chunks = [
                {
                    "id": "chatcmpl-smoke",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "synthetic",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"role": "assistant", "content": "Synthetic continuity check complete."},
                            "finish_reason": None,
                        }
                    ],
                },
                {
                    "id": "chatcmpl-smoke",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "synthetic",
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                },
            ]
            content = b"".join(
                b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks
            ) + b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(content)
            return

        response = {
            "id": "chatcmpl-smoke",
            "object": "chat.completion",
            "created": 1,
            "model": "synthetic",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": "Synthetic continuity check complete."},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
        }
        content = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


def run(command: list[str], *, timeout: int = 60, expected: set[int] = {0}) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    if completed.returncode not in expected:
        raise SmokeFailure(
            f"command failed with exit {completed.returncode}: {command[0]}\n"
            f"{completed.stdout[-6000:]}"
        )
    return completed


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def docker_mount(path: Path, target: str, readonly: bool = False) -> str:
    suffix = ":ro" if readonly else ""
    return f"{path}:{target}{suffix}"


def run_in_container(args: argparse.Namespace) -> int:
    archive = Path(args.new_archive)
    if sha256(archive) != NEW_ARCHIVE_SHA256:
        raise SmokeFailure("official 0.8.7 archive SHA-256 does not match the pinned release")
    with tarfile.open(archive, "r:gz") as package:
        matches = [
            member
            for member in package.getmembers()
            if member.name == "zeroclaw"
            and member.isfile()
        ]
        if len(matches) != 1:
            raise SmokeFailure("pinned 0.8.7 x86_64 archive does not contain one root zeroclaw binary")
        binary_path = Path("/tmp/zeroclaw-smoke") / "zeroclaw"
        binary_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        binary_path.parent.chmod(0o755)
        source = package.extractfile(matches[0])
        if source is None:
            raise SmokeFailure("pinned ZeroClaw binary could not be read from its archive")
        with source, binary_path.open("wb") as destination:
            shutil.copyfileobj(source, destination)
    binary_path.chmod(0o755)
    version = run([str(binary_path), "--version"]).stdout.strip()
    if version != "zeroclaw 0.8.7 (99bd353)":
        raise SmokeFailure(f"unexpected new ZeroClaw binary: {version}")

    old_memory = Path("/data/workspace/memory/brain.db")
    old_sessions = Path("/data/workspace/sessions/sessions.db")
    if not old_memory.is_file() or not old_sessions.is_file():
        raise SmokeFailure("the real 0.7.5 binary did not create both legacy SQLite databases")
    seed_legacy_memory(old_memory)
    seed_legacy_session(old_sessions)
    old_memory_hash = file_hash(old_memory)
    old_sessions_hash = file_hash(old_sessions)
    (old_sessions.parent / "telegram_opaque_digest.json").write_text(
        '{"messages":["preserve but do not guess a native chat owner"]}\n',
        encoding="utf-8",
    )
    (old_memory.parent.parent / "SOUL.md").write_text(
        "legacy generated helper identity is archived, not active\n",
        encoding="utf-8",
    )

    helper = load_migration_helper(Path(args.helper))
    print(helper.prepare(Path("/data")))
    marker = json.loads(Path("/data/.runtime-layout").read_text(encoding="utf-8"))
    snapshot = Path("/data/migrations") / marker["snapshot_id"]
    if not (snapshot / "workspace/sessions/telegram_opaque_digest.json").is_file():
        raise SmokeFailure("opaque Telegram history was not retained in the root-only snapshot")

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeProvider)
    FakeProvider.requests.clear()
    provider_thread = threading.Thread(target=provider.serve_forever, daemon=True)
    provider_thread.start()
    try:
        with socket.socket() as port_probe:
            port_probe.bind(("127.0.0.1", 0))
            gateway_port = int(port_probe.getsockname()[1])
        native = Path("/data/native")
        (native / "config.toml").write_text(
            f'''schema_version = 3
[providers.models.openai.smoke]
model = "gpt-4o-mini"
api_key = "synthetic-test-key"
uri = "http://127.0.0.1:{provider.server_address[1]}/v1"
wire_api = "chat_completions"
timeout_secs = 8
[agents.default]
enabled = true
model_provider = "openai.smoke"
risk_profile = "default"
runtime_profile = "default"
skill_bundles = []
knowledge_bundles = []
mcp_bundles = []
[agents.default.workspace]
path = "/data/native/agents/default/workspace"
[risk_profiles.default]
deny_all_tools = true
[runtime_profiles.default]
[channels]
session_persistence = true
session_backend = "sqlite"
[gateway]
host = "127.0.0.1"
port = {gateway_port}
session_persistence = true
''',
            encoding="utf-8",
        )
        (native / "config.toml").chmod(0o600)
        chown_native(native)

        agent = run_as_native(
            [
                str(binary_path),
                "--config-dir",
                str(native),
                "agent",
                "--agent",
                "default",
                "--message",
                "Use the legacy memory to recall the migration marker cobalt lantern 7319.",
            ],
            timeout=45,
        )
        print("0.8.7 default-agent turn:", agent.stdout.strip()[-1000:])
        captured = json.dumps(FakeProvider.requests, sort_keys=True)
        if SYNTHETIC_FACT not in captured:
            raise SmokeFailure(
                "0.8.7 agents.default did not recall the migrated memory into its provider request"
            )

        gateway_once(binary_path, native, gateway_port, 1)
        gateway_once(binary_path, native, gateway_port, 2)
        if file_hash(old_memory) != old_memory_hash or file_hash(old_sessions) != old_sessions_hash:
            raise SmokeFailure("0.8.7 migration or startup modified the archived 0.7.5 SQLite databases")

        print(helper.rollback(Path("/data")))
        if not (native / "data/memory/brain.db").is_file():
            raise SmokeFailure("rollback removed native memory state")
        if file_hash(native / "data/memory/brain.db") == old_memory_hash:
            # SQLite backup copies pages into a new file; it should remain
            # independently usable after the legacy source is restored.
            raise SmokeFailure("native backup unexpectedly aliases the old database file")
        if (Path("/data/.state-schema").read_text(encoding="ascii") != "1\n"):
            raise SmokeFailure("runtime migration changed the independent app inventory schema")
        print("PASS: agents.default recalled a 0.7.5 memory; 0.8.7 upgraded and restarted the real session DB; rollback retained both layouts.")
    finally:
        provider.shutdown()
        provider.server_close()
        provider_thread.join(timeout=2)
    return 0


def seed_legacy_memory(path: Path) -> None:
    import sqlite3

    connection = sqlite3.connect(path)
    try:
        columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(memories)")}
        required = {"id", "key", "content", "category", "created_at", "updated_at"}
        if not required.issubset(columns):
            raise SmokeFailure("0.7.5 brain.db does not have its expected legacy schema")
        now = datetime.now(timezone.utc).isoformat()
        values = {
            "id": "synthetic-migration-memory",
            "key": "synthetic-migration-memory",
            "content": SYNTHETIC_FACT,
            "category": "core",
            "created_at": now,
            "updated_at": now,
            "session_id": None,
            "namespace": "default",
            "importance": 0.95,
            "superseded_by": None,
        }
        names = [name for name in values if name in columns]
        quoted = ", ".join('"' + name + '"' for name in names)
        placeholders = ", ".join("?" for _ in names)
        connection.execute(
            f"INSERT INTO memories ({quoted}) VALUES ({placeholders})",
            [values[name] for name in names],
        )
        connection.commit()
    finally:
        connection.close()


def seed_legacy_session(path: Path) -> None:
    import sqlite3

    connection = sqlite3.connect(path)
    try:
        columns = [(str(row[1]), int(row[3]), int(row[5])) for row in connection.execute("PRAGMA table_info(sessions)")]
        if not columns:
            raise SmokeFailure("0.7.5 did not create its SQLite sessions table")
        now = datetime.now(timezone.utc).isoformat()
        values = {
            "session_key": "telegram.synthetic-owner",
            "role": "user",
            "content": SYNTHETIC_SESSION,
            "created_at": now,
        }
        names = [name for name, _, _ in columns if name in values]
        for name, not_null, primary_key in columns:
            if name not in values and not_null and not primary_key:
                raise SmokeFailure(f"unknown required old session column: {name}")
        quoted = ", ".join('"' + name + '"' for name in names)
        placeholders = ", ".join("?" for _ in names)
        connection.execute(
            f"INSERT INTO sessions ({quoted}) VALUES ({placeholders})",
            [values[name] for name in names],
        )
        connection.commit()
        stored = connection.execute(
            "SELECT COUNT(*) FROM sessions WHERE content = ?",
            (SYNTHETIC_SESSION,),
        ).fetchone()[0]
        if stored != 1:
            raise SmokeFailure("synthetic legacy session row was not inserted")
    finally:
        connection.close()


def gateway_once(binary: Path, native: Path, port: int, attempt: int) -> None:
    import sqlite3

    db = native / "data/sessions/sessions.db"
    log_path = Path(f"/tmp/zeroclaw-gateway-{attempt}.log")
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            [str(binary), "--config-dir", str(native), "gateway", "start"],
            stdout=log,
            stderr=subprocess.STDOUT,
            preexec_fn=drop_to_native_user,
        )
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise SmokeFailure(f"0.8.7 gateway exited before schema readiness: {log_path.read_text()[-2500:]}")
            if session_ready(db):
                break
            time.sleep(0.15)
        else:
            process.send_signal(signal.SIGINT)
            process.wait(timeout=10)
            raise SmokeFailure(f"0.8.7 gateway did not upgrade session metadata: {log_path.read_text()[-2500:]}")
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            raise SmokeFailure("0.8.7 gateway did not stop after SIGINT")
    if process.returncode not in (0, -signal.SIGINT, 128 + signal.SIGINT):
        raise SmokeFailure(f"0.8.7 gateway stop returned {process.returncode}: {log_path.read_text()[-2000:]}")
    if not session_ready(db):
        raise SmokeFailure("session compatibility row did not survive a daemon restart")


def session_ready(path: Path) -> bool:
    import sqlite3

    try:
        with sqlite3.connect(path, timeout=1) as connection:
            columns = {row[1] for row in connection.execute("PRAGMA table_info(session_metadata)")}
            count = connection.execute(
                "SELECT COUNT(*) FROM sessions WHERE content = ?",
                (SYNTHETIC_SESSION,),
            ).fetchone()[0]
            return "agent_alias" in columns and count == 1
    except sqlite3.DatabaseError:
        return False


def chown_native(native: Path) -> None:
    for current, dirnames, filenames in os.walk(native, followlinks=False):
        current_path = Path(current)
        for name in dirnames + filenames:
            path = current_path / name
            info = path.lstat()
            if not (info.st_mode & 0o170000) == 0o100000 or path.is_symlink():
                if (info.st_mode & 0o170000) != 0o040000:
                    raise SmokeFailure(f"native target contains an unsafe entry: {path}")
            os.chown(path, CONTAINER_UID, CONTAINER_UID, follow_symlinks=False)
        os.chown(current_path, CONTAINER_UID, CONTAINER_UID, follow_symlinks=False)


def drop_to_native_user() -> None:
    os.setgroups([])
    os.setgid(CONTAINER_UID)
    os.setuid(CONTAINER_UID)


def run_as_native(command: list[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
        preexec_fn=drop_to_native_user,
    )


def file_hash(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def load_migration_helper(path: Path):
    import importlib.util

    spec = importlib.util.spec_from_file_location("native_runtime_migrate", path)
    if spec is None or spec.loader is None:
        raise SmokeFailure("could not load the migration helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-binary", type=Path)
    parser.add_argument("--new-archive", type=Path)
    parser.add_argument("--in-container", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--helper", default="/opt/zeroclaw/native/migrate.py")
    args = parser.parse_args()
    try:
        if args.in_container:
            return run_in_container(args)
        return run_on_host(args)
    except SmokeFailure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


def run_on_host(args: argparse.Namespace) -> int:
    if args.old_binary is None or args.new_archive is None:
        raise SmokeFailure("pass --old-binary and --new-archive")
    old_binary = args.old_binary.resolve()
    new_archive = args.new_archive.resolve()
    if sha256(old_binary) != OLD_BINARY_SHA256:
        raise SmokeFailure("the selected 0.7.5 ARM binary does not match its recorded fixture hash")
    if sha256(new_archive) != NEW_ARCHIVE_SHA256:
        raise SmokeFailure("the selected 0.8.7 archive does not match the pinned release hash")
    if shutil.which("docker") is None:
        raise SmokeFailure("Docker CLI is required")
    run(["docker", "pull", "--platform", "linux/amd64", PYTHON_IMAGE], timeout=180)

    volume = f"zc-state-v3-smoke-{secrets.token_hex(8)}"
    old_image = f"zc-state-v3-old-runtime:{secrets.token_hex(8)}"
    run(["docker", "volume", "create", volume], timeout=15)
    gateway_name = f"{volume}-old-gateway"
    try:
        build_old_runtime_image(old_binary, old_image)
        docker_volume_run(
            volume,
            PYTHON_IMAGE,
            ["python3", "-c", LEGACY_VOLUME_INITIALIZER],
        )
        old_stats = docker_old_binary(old_image, volume, "memory", "stats")
        print("0.7.5 initial memory stats:", old_stats.stdout.strip()[-500:])
        start_legacy_gateway(old_image, volume, gateway_name)

        smoke = docker_python_smoke(volume, new_archive)
        print(smoke.stdout.strip())
        old_after = docker_old_binary(old_image, volume, "memory", "stats")
        print("0.7.5 rollback reopen:", old_after.stdout.strip()[-500:])
        print("PASS: real old/new runtime migration, default-agent recall, session restart, and rollback.")
    finally:
        run(["docker", "rm", "-f", gateway_name], timeout=15, expected={0, 1})
        run(["docker", "volume", "rm", volume], timeout=15, expected={0, 1})
        run(["docker", "image", "rm", old_image], timeout=15, expected={0, 1})
    return 0


LEGACY_VOLUME_INITIALIZER = '''import os, pathlib
root = pathlib.Path("/data")
root.mkdir(exist_ok=True)
(root / ".state-schema").write_text("1\\n", encoding="ascii")
(root / "config.toml").write_text("""schema_version = 2
[providers]
fallback = "custom:http://127.0.0.1:42620/v1"
[providers.models."custom:http://127.0.0.1:42620/v1"]
base_url = "http://127.0.0.1:42620/v1"
api_path = "/chat/completions"
model = "synthetic"
wire_api = "chat_completions"
max_tokens = 64
[agent]
workspace_only = true
[memory]
backend = "sqlite"
auto_save = true
[channels]
session_persistence = true
session_backend = "sqlite"
[gateway]
session_persistence = true
""", encoding="utf-8")
os.chown(root, 1000, 1000)
os.chmod(root, 0o700)
os.chown(root / ".state-schema", 1000, 1000)
os.chown(root / "config.toml", 1000, 1000)
os.chmod(root / "config.toml", 0o600)
'''


def docker_volume_run(volume: str, image: str, command: list[str]) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "docker", "run", "--rm", "--pull=never", "--platform", "linux/amd64", "--network", "none",
            "--mount", f"type=volume,source={volume},target=/data",
            image, *command,
        ],
        timeout=45,
    )


def build_old_runtime_image(binary: Path, tag: str) -> None:
    # The pinned 0.7.5 binary is a static musl executable. A scratch image
    # avoids depending on a host shell or pulling another architecture image.
    with tempfile.TemporaryDirectory(prefix="zeroclaw-old-runtime-") as temporary:
        context = Path(temporary)
        shutil.copyfile(binary, context / "zeroclaw")
        (context / "Dockerfile").write_text(
            "FROM scratch\n"
            "COPY --chmod=0555 zeroclaw /zeroclaw\n"
            "ENV HOME=/data\n"
            'ENTRYPOINT ["/zeroclaw"]\n',
            encoding="ascii",
        )
        run(
            [
                "docker", "build", "--platform", "linux/arm64", "--network", "none",
                "--pull=false", "--tag", tag, str(context),
            ],
            timeout=90,
        )


def docker_old_binary(image: str, volume: str, *command: str) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "docker", "run", "--rm", "--pull=never", "--platform", "linux/arm64", "--network", "none",
            "--user", "1000:1000", "--mount", f"type=volume,source={volume},target=/data",
            image, "--config-dir", "/data", *command,
        ],
        timeout=45,
    )


def start_legacy_gateway(image: str, volume: str, name: str) -> None:
    started = run(
        [
            "docker", "run", "-d", "--pull=never", "--platform", "linux/arm64", "--network", "none",
            "--name", name, "--user", "1000:1000",
            "--mount", f"type=volume,source={volume},target=/data",
            image, "--config-dir", "/data", "gateway", "start",
        ],
        timeout=40,
    )
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            probe = run(
                [
                    "docker", "run", "--rm", "--pull=never", "--platform", "linux/amd64",
                    "--network", "none", "--mount", f"type=volume,source={volume},target=/data",
                    PYTHON_IMAGE, "python3", "-c",
                    "import pathlib,sys; sys.exit(0 if pathlib.Path('/data/workspace/sessions/sessions.db').is_file() else 1)",
                ],
                timeout=15,
                expected={0, 1},
            )
            if probe.returncode == 0:
                run(["docker", "stop", "--time", "8", name], timeout=15)
                return
            status = run(["docker", "inspect", "--format", "{{.State.Status}}", name]).stdout.strip()
            if status != "running":
                logs = run(["docker", "logs", name]).stdout
                raise SmokeFailure(f"0.7.5 gateway stopped before creating sessions.db:\n{logs[-3000:]}")
            time.sleep(0.25)
        logs = run(["docker", "logs", name]).stdout
        raise SmokeFailure(f"0.7.5 gateway did not create sessions.db:\n{logs[-3000:]}")
    finally:
        run(["docker", "rm", "-f", name], timeout=15, expected={0, 1})


def docker_python_smoke(volume: str, archive: Path) -> subprocess.CompletedProcess[str]:
    script = Path(__file__).resolve()
    helper = REPO / "native" / "migrate.py"
    return run(
        [
            "docker", "run", "--rm", "--pull=never", "--platform", "linux/amd64", "--network", "none",
            "--mount", f"type=volume,source={volume},target=/data",
            "-v", docker_mount(script, "/opt/zeroclaw/tests/state_migration_smoke.py", True),
            "-v", docker_mount(helper, "/opt/zeroclaw/native/migrate.py", True),
            "-v", docker_mount(archive, "/assets/zeroclaw-0.8.7.tar.gz", True),
            PYTHON_IMAGE, "python3", "/opt/zeroclaw/tests/state_migration_smoke.py",
            "--in-container", "--new-archive", "/assets/zeroclaw-0.8.7.tar.gz",
            "--helper", "/opt/zeroclaw/native/migrate.py",
        ],
        timeout=180,
    )


if __name__ == "__main__":
    raise SystemExit(main())
