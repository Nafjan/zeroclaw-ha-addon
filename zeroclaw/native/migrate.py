#!/usr/bin/env python3
"""One-off, reversible migration of legacy ZeroClaw state to native 0.8 layout.

Run as root before generating /data/native/config.toml. The previous runtime
must be stopped. This snapshots only legacy memory and session state; it does
not activate the old workspace identity or import keyed Telegram JSON files.
The native daemon remains responsible for its own SQLite schema upgrades.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import shutil
import sqlite3
import stat
import sys
import tempfile
from typing import Any, Iterator


FORMAT = 1
LAYOUT = 3
MARKER = ".runtime-layout"
MIGRATION_PREFIX = "runtime-layout-v2-to-v3-"
STAGE_PREFIX = ".native-v3-stage-"
CHUNK = 1024 * 1024
SQLITE_DATABASES = ("brain.db",)
SESSION_DATABASE = "sessions.db"
RPC_SOCKET_RELATIVE = "data/daemon.sock"


class MigrationError(RuntimeError):
    """Unsafe or incomplete persistent-state migration."""


def _lstat(path: Path) -> os.stat_result | None:
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def _real_dir(path: Path, label: str) -> None:
    info = _lstat(path)
    if info is None or not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"{label} is not a real directory: {path}")


def _regular(path: Path, label: str) -> os.stat_result:
    info = _lstat(path)
    if info is None or not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"{label} is not a regular file: {path}")
    return info


def _private_dir(path: Path) -> None:
    info = _lstat(path)
    if info is None:
        path.mkdir(mode=0o700)
    elif not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"private migration directory is unsafe: {path}")
    os.chmod(path, 0o700)


def _fsync_dir(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}-{secrets.token_hex(4)}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        _fsync_dir(path.parent)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def _write_json(path: Path, value: Any) -> None:
    _atomic_bytes(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode())


def _read_json(path: Path, label: str) -> dict[str, Any]:
    _regular(path, label)
    if stat.S_IMODE(path.lstat().st_mode) & 0o077:
        raise MigrationError(f"{label} is not private: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise MigrationError(f"{label} is malformed: {path}") from exc
    if not isinstance(value, dict):
        raise MigrationError(f"{label} is malformed: {path}")
    return value


def _safe_relative(raw: Any) -> str:
    if not isinstance(raw, str) or not raw or "\\" in raw:
        raise MigrationError("migration manifest has an invalid relative path")
    relative = PurePosixPath(raw)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        raise MigrationError("migration manifest contains an unsafe relative path")
    return relative.as_posix()


@contextmanager
def _migration_lock(root: Path) -> Iterator[None]:
    lock_path = root / ".runtime-migration.lock"
    descriptor = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise MigrationError("runtime migration lock is not a private regular file")
        os.fchmod(descriptor, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise MigrationError("another runtime state migration is in progress") from exc
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _entries(path: Path) -> Iterator[tuple[Path, os.stat_result]]:
    info = _lstat(path)
    if info is None:
        return
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"state tree is not a real directory: {path}")
    for current, dirnames, filenames in os.walk(path, topdown=True, followlinks=False):
        current_path = Path(current)
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            child = current_path / name
            child_info = _lstat(child)
            if child_info is None or not stat.S_ISDIR(child_info.st_mode) or stat.S_ISLNK(child_info.st_mode):
                raise MigrationError(f"state tree contains a symlink or special directory: {child}")
            yield child, child_info
        for name in filenames:
            child = current_path / name
            child_info = _lstat(child)
            if child_info is None or not stat.S_ISREG(child_info.st_mode) or stat.S_ISLNK(child_info.st_mode):
                raise MigrationError(f"state tree contains a symlink or special file: {child}")
            yield child, child_info


def _tree_size(path: Path) -> int:
    info = _lstat(path)
    if info is None:
        return 0
    if stat.S_ISREG(info.st_mode):
        return info.st_size
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"legacy state contains a symlink or special file: {path}")
    return sum(item.st_size for _, item in _entries(path) if stat.S_ISREG(item.st_mode))


def _source_roots(root: Path) -> list[tuple[str, Path]]:
    workspace = root / "workspace"
    info = _lstat(workspace)
    if info is None:
        return []
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"legacy workspace is unsafe: {workspace}")
    candidates: list[tuple[str, Path]] = []
    memory = workspace / "memory"
    memory_info = _lstat(memory)
    if memory_info is not None:
        if not stat.S_ISDIR(memory_info.st_mode) or stat.S_ISLNK(memory_info.st_mode):
            raise MigrationError(f"legacy memory path is unsafe: {memory}")
        candidates.append(("workspace/memory", memory))
    for child in sorted(workspace.iterdir(), key=lambda item: item.name):
        if child.name.startswith("sessions"):
            child_info = _lstat(child)
            if child_info is None or stat.S_ISLNK(child_info.st_mode):
                raise MigrationError(f"legacy session path is unsafe: {child}")
            if not (stat.S_ISDIR(child_info.st_mode) or stat.S_ISREG(child_info.st_mode)):
                raise MigrationError(f"legacy session path is a special file: {child}")
            candidates.append((child.relative_to(root).as_posix(), child))
    for _, path in candidates:
        if stat.S_ISDIR(path.lstat().st_mode):
            list(_entries(path))
    return candidates


def _hash_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        while block := source.read(CHUNK):
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def _copy_file(source: Path, destination: Path) -> None:
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_fd = -1
    try:
        source_info = os.fstat(source_fd)
        if not stat.S_ISREG(source_info.st_mode):
            raise MigrationError(f"state source changed to a special file: {source}")
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        with os.fdopen(source_fd, "rb", closefd=False) as source_file:
            with os.fdopen(destination_fd, "wb", closefd=False) as output:
                while block := source_file.read(CHUNK):
                    output.write(block)
                output.flush()
                os.fsync(output.fileno())
        os.fchmod(destination_fd, 0o600)
    except BaseException:
        try:
            destination.unlink()
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)


def _copy_entry(source: Path, destination: Path) -> None:
    info = _lstat(source)
    if info is None:
        return
    if stat.S_ISDIR(info.st_mode):
        destination.mkdir(mode=0o700, parents=True, exist_ok=False)
        for child in sorted(source.iterdir(), key=lambda item: item.name):
            _copy_entry(child, destination / child.name)
        os.chmod(destination, 0o700)
        _fsync_dir(destination)
        return
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"cannot copy unsafe state entry: {source}")
    _copy_file(source, destination)


def _snapshot_files(snapshot: Path) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    # The source inventory is immutable once the snapshot is published.  The
    # native target manifest is published later while preparing the install;
    # its digest is bound by transaction.json after it is durable.
    excluded = {"checksums.json", "transaction.json", "target-manifest.json"}
    for path, info in _entries(snapshot):
        if not stat.S_ISREG(info.st_mode):
            continue
        relative = path.relative_to(snapshot).as_posix()
        if relative in excluded:
            continue
        digest, size = _hash_file(path)
        result.append({"path": relative, "sha256": digest, "size": size})
    result.sort(key=lambda record: record["path"])
    return result


def _write_checksums(snapshot: Path) -> None:
    _write_json(snapshot / "checksums.json", {"format": FORMAT, "files": _snapshot_files(snapshot)})


def _verify_snapshot(snapshot: Path) -> dict[str, Any]:
    info = _lstat(snapshot)
    if info is None or not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"migration snapshot is unsafe: {snapshot}")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise MigrationError(f"migration snapshot is not private: {snapshot}")
    manifest = _read_json(snapshot / "manifest.json", "migration snapshot manifest")
    checksums = _read_json(snapshot / "checksums.json", "migration snapshot checksums")
    if manifest.get("format") != FORMAT or manifest.get("snapshot_id") != snapshot.name:
        raise MigrationError("migration snapshot manifest is unsupported")
    if checksums.get("format") != FORMAT or not isinstance(checksums.get("files"), list):
        raise MigrationError("migration snapshot checksums are malformed")

    expected: dict[str, tuple[str, int]] = {}
    for record in checksums["files"]:
        if not isinstance(record, dict):
            raise MigrationError("migration snapshot checksum record is malformed")
        relative = _safe_relative(record.get("path"))
        digest, size = record.get("sha256"), record.get("size")
        if (
            relative in expected
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(char not in "0123456789abcdef" for char in digest)
            or not isinstance(size, int)
            or size < 0
        ):
            raise MigrationError("migration snapshot checksum record is malformed")
        expected[relative] = (digest, size)

    actual: dict[str, tuple[str, int]] = {}
    for path, info in _entries(snapshot):
        if not stat.S_ISREG(info.st_mode):
            continue
        relative = path.relative_to(snapshot).as_posix()
        if relative in ("checksums.json", "transaction.json", "target-manifest.json"):
            continue
        actual[relative] = _hash_file(path)
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        unrecorded = sorted(set(actual) - set(expected))
        changed = sorted(
            path for path in set(actual) & set(expected) if actual[path] != expected[path]
        )
        details = []
        if missing:
            details.append(f"missing={missing[:8]}")
        if unrecorded:
            details.append(f"unrecorded={unrecorded[:8]}")
        if changed:
            details.append(f"changed={changed[:8]}")
        raise MigrationError(
            "migration snapshot checksum inventory mismatch (" + "; ".join(details) + ")"
        )
    return manifest


def _transaction_path(snapshot: Path) -> Path:
    return snapshot / "transaction.json"


def _read_transaction(snapshot: Path) -> dict[str, Any]:
    transaction = _read_json(_transaction_path(snapshot), "migration transaction")
    if transaction.get("format") != FORMAT or transaction.get("snapshot_id") != snapshot.name:
        raise MigrationError("migration transaction is malformed")
    if transaction.get("phase") not in ("snapshot-ready", "prepared", "committed", "rolled-back"):
        raise MigrationError("migration transaction phase is unsupported")
    return transaction


def _write_transaction(snapshot: Path, transaction: dict[str, Any]) -> None:
    transaction["format"] = FORMAT
    _write_json(_transaction_path(snapshot), transaction)


def _create_snapshot(root: Path, sources: list[tuple[str, Path]]) -> Path:
    total_source_bytes = sum(_tree_size(source) for _, source in sources)
    required = total_source_bytes * 2
    if shutil.disk_usage(root).free < required:
        raise MigrationError(
            f"insufficient free space for a reversible migration (need about {required} bytes)"
        )

    migrations = root / "migrations"
    _private_dir(migrations)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    snapshot_id = f"{MIGRATION_PREFIX}{stamp}-{os.getpid()}-{secrets.token_hex(4)}"
    snapshot = migrations / snapshot_id
    snapshot.mkdir(mode=0o700)
    try:
        source_records: list[dict[str, Any]] = []
        for relative, source in sources:
            _copy_entry(source, snapshot / relative)
            source_records.append(
                {
                    "path": relative,
                    "present": True,
                    "kind": "dir" if stat.S_ISDIR(source.lstat().st_mode) else "file",
                }
            )
        manifest = {
            "format": FORMAT,
            "snapshot_id": snapshot_id,
            "source_layout": 2,
            "target_layout": LAYOUT,
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "source_paths": source_records,
            "session_import": "SQLite sessions.db only; keyed JSON conversations remain archived",
            "workspace_policy": "legacy workspace remains inactive",
        }
        _write_json(snapshot / "manifest.json", manifest)
        _write_checksums(snapshot)
        _write_transaction(snapshot, {"snapshot_id": snapshot_id, "phase": "snapshot-ready"})
        _fsync_dir(migrations)
        _verify_snapshot(snapshot)
    except BaseException:
        if _lstat(_transaction_path(snapshot)) is None:
            shutil.rmtree(snapshot, ignore_errors=True)
        raise
    return snapshot


def _check_sqlite(connection: sqlite3.Connection, label: str) -> None:
    try:
        row = connection.execute("PRAGMA quick_check").fetchone()
    except sqlite3.DatabaseError as exc:
        raise MigrationError(f"{label} failed SQLite integrity validation") from exc
    if row is None or row[0] != "ok":
        raise MigrationError(f"{label} failed SQLite integrity validation")


def _sqlite_backup(source: Path, destination: Path, label: str) -> None:
    _regular(source, label)
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = source.with_name(source.name + suffix)
        info = _lstat(sidecar)
        if info is not None and (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
            raise MigrationError(f"{label} has an unsafe SQLite sidecar: {sidecar}")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        # SQLite must open a hot rollback journal read/write to recover it.
        # Do that only against this private copy, so recovery cannot mutate
        # the checksummed snapshot. A WAL copy is also kept beside the DB so
        # committed WAL pages remain visible to SQLite during the backup.
        with tempfile.TemporaryDirectory(prefix=".sqlite-backup-", dir=destination.parent) as temporary:
            working_source = Path(temporary) / source.name
            _copy_file(source, working_source)
            for suffix in ("-wal", "-journal"):
                sidecar = source.with_name(source.name + suffix)
                if _lstat(sidecar) is not None:
                    _copy_file(sidecar, working_source.with_name(working_source.name + suffix))
            source_uri = working_source.resolve().as_uri() + "?mode=rw"
            source_db: sqlite3.Connection | None = None
            target: sqlite3.Connection | None = None
            try:
                source_db = sqlite3.connect(source_uri, uri=True)
                _check_sqlite(source_db, label)
                target = sqlite3.connect(destination)
                source_db.backup(target)
                _check_sqlite(target, f"native copy of {label}")
                target.commit()
            finally:
                if source_db is not None:
                    source_db.close()
                if target is not None:
                    target.close()
    except (OSError, sqlite3.DatabaseError) as exc:
        try:
            destination.unlink()
        except FileNotFoundError:
            pass
        raise MigrationError(f"could not create native SQLite backup of {label}") from exc
    os.chmod(destination, 0o600)
    with destination.open("rb") as output:
        os.fsync(output.fileno())


def _copy_native_memory(snapshot: Path, memory: Path) -> None:
    source = snapshot / "workspace" / "memory"
    if _lstat(source) is None:
        return
    _real_dir(memory, "native memory directory")
    # Carry non-database memory artifacts and archives, but let SQLite's
    # backup API consolidate each database and any committed WAL pages.
    sidecars = {
        f"{name}-{suffix}"
        for name in SQLITE_DATABASES
        for suffix in ("wal", "shm", "journal")
    }
    for child in sorted(source.iterdir(), key=lambda item: item.name):
        name = child.name
        if name in SQLITE_DATABASES or name in sidecars:
            continue
        _copy_entry(child, memory / name)
    for name in SQLITE_DATABASES:
        database = source / name
        if _lstat(database) is not None:
            _sqlite_backup(database, memory / name, f"legacy memory database {name}")


def _copy_native_sessions(snapshot: Path, sessions: Path) -> None:
    source = snapshot / "workspace" / "sessions" / SESSION_DATABASE
    if _lstat(source) is None:
        return
    _sqlite_backup(source, sessions / SESSION_DATABASE, "legacy session database")


def _stage_native(snapshot: Path, stage: Path) -> None:
    stage.mkdir(mode=0o700)
    data = stage / "data"
    agents = stage / "agents"
    workspace = agents / "default" / "workspace"
    (data / "memory").mkdir(mode=0o700, parents=True)
    (data / "sessions").mkdir(mode=0o700, parents=True)
    workspace.mkdir(mode=0o700, parents=True)
    _copy_native_memory(snapshot, data / "memory")
    _copy_native_sessions(snapshot, data / "sessions")
    for path, _ in _entries(stage):
        if stat.S_ISDIR(path.lstat().st_mode):
            os.chmod(path, 0o700)
    _fsync_dir(data / "memory")
    _fsync_dir(data / "sessions")
    _fsync_dir(data)
    _fsync_dir(workspace)
    _fsync_dir(workspace.parent)
    _fsync_dir(agents)
    _fsync_dir(stage)


def _tree_manifest(root: Path, *, allow_rpc_socket: bool = False) -> list[dict[str, Any]]:
    _real_dir(root, "native state tree")
    entries: list[dict[str, Any]] = []
    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            path = current_path / name
            info = _lstat(path)
            if info is None or not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise MigrationError(f"native tree contains a symlink or unsafe directory: {path}")
            entries.append({"path": path.relative_to(root).as_posix(), "kind": "dir"})
        for name in filenames:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            info = _lstat(path)
            if info is None:
                raise MigrationError(f"native tree changed during validation: {path}")
            if stat.S_ISSOCK(info.st_mode) and allow_rpc_socket and relative == RPC_SOCKET_RELATIVE:
                continue
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise MigrationError(f"native tree contains a symlink or special file: {path}")
            digest, size = _hash_file(path)
            entries.append({"path": relative, "kind": "file", "sha256": digest, "size": size})
    entries.sort(key=lambda entry: entry["path"])
    return entries


def _target_manifest_path(snapshot: Path) -> Path:
    return snapshot / "target-manifest.json"


def _target_digest(snapshot: Path) -> str:
    target_manifest = _target_manifest_path(snapshot)
    _regular(target_manifest, "native target manifest")
    return _hash_file(target_manifest)[0]


def _target_matches(native: Path, snapshot: Path, transaction: dict[str, Any]) -> bool:
    try:
        target_manifest = _read_json(_target_manifest_path(snapshot), "native target manifest")
        expected = target_manifest.get("entries")
        digest = _target_digest(snapshot)
        if target_manifest.get("format") != FORMAT or not isinstance(expected, list):
            return False
        return digest == transaction.get("target_sha256") and _tree_manifest(native) == expected
    except (MigrationError, OSError):
        return False


def _stage_name(snapshot: Path, transaction: dict[str, Any]) -> Path:
    name = transaction.get("stage_name")
    expected_name = f"{STAGE_PREFIX}{snapshot.name.removeprefix(MIGRATION_PREFIX)}"
    if not isinstance(name, str) or name != expected_name:
        raise MigrationError("migration stage reference is unsafe")
    return snapshot.parent.parent / name


def _safe_remove_stage(stage: Path) -> None:
    info = _lstat(stage)
    if info is None:
        return
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise MigrationError(f"native stage is not a real directory: {stage}")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise MigrationError(f"native stage is not private: {stage}")
    _tree_manifest(stage)
    shutil.rmtree(stage)


def _prepare_snapshot(root: Path, snapshot: Path) -> None:
    manifest = _verify_snapshot(snapshot)
    if manifest.get("target_layout") != LAYOUT:
        raise MigrationError("migration snapshot targets an unsupported native layout")
    transaction = _read_transaction(snapshot)
    native = root / "native"

    if transaction["phase"] == "snapshot-ready":
        if _lstat(native) is not None:
            raise MigrationError("native install path exists before migration was prepared")
        stage = root / f"{STAGE_PREFIX}{snapshot.name.removeprefix(MIGRATION_PREFIX)}"
        _safe_remove_stage(stage)
        _stage_native(snapshot, stage)
        target = {"format": FORMAT, "entries": _tree_manifest(stage)}
        _write_json(_target_manifest_path(snapshot), target)
        transaction.update(
            {
                "phase": "prepared",
                "stage_name": stage.name,
                "target_sha256": _target_digest(snapshot),
            }
        )
        _write_transaction(snapshot, transaction)
        manifest = _verify_snapshot(snapshot)

    if transaction["phase"] != "prepared":
        raise MigrationError("migration snapshot is not pending")
    stage = _stage_name(snapshot, transaction)
    target_manifest = _read_json(_target_manifest_path(snapshot), "native target manifest")
    expected = target_manifest.get("entries")
    if not isinstance(expected, list) or _target_digest(snapshot) != transaction.get("target_sha256"):
        raise MigrationError("native target manifest checksum mismatch")

    if _lstat(native) is not None:
        if not _target_matches(native, snapshot, transaction):
            raise MigrationError("native install path conflicts with the prepared migration")
    else:
        if _lstat(stage) is None:
            _stage_native(snapshot, stage)
        elif _tree_manifest(stage) != expected:
            # In the prepared phase the expected tree and its digest are
            # already bound by the private snapshot transaction. A retry may
            # have been interrupted while recreating a missing stage. Remove
            # only the exact, private helper-owned stage after validating it
            # contains no symlinks or special files, then rebuild from the
            # verified archive.
            _safe_remove_stage(stage)
            _stage_native(snapshot, stage)
        if _tree_manifest(stage) != expected:
            raise MigrationError("staged native install differs from its manifest")
        os.replace(stage, native)
        _fsync_dir(root)

    _validate_native(native)
    _write_marker(root, LAYOUT, snapshot.name)
    transaction["phase"] = "committed"
    _write_transaction(snapshot, transaction)


def _validate_native(native: Path) -> None:
    _real_dir(native, "native install root")
    _real_dir(native / "data", "native data directory")
    _real_dir(native / "agents", "native agents directory")
    _real_dir(native / "agents" / "default", "native default agent directory")
    _real_dir(native / "agents" / "default" / "workspace", "native default workspace")
    for current, dirnames, filenames in os.walk(native, topdown=True, followlinks=False):
        current_path = Path(current)
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            path = current_path / name
            info = _lstat(path)
            if info is None or not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise MigrationError(f"native tree contains a symlink or unsafe directory: {path}")
        for name in filenames:
            path = current_path / name
            relative = path.relative_to(native).as_posix()
            info = _lstat(path)
            if info is None:
                raise MigrationError(f"native tree changed during validation: {path}")
            if stat.S_ISSOCK(info.st_mode) and relative == RPC_SOCKET_RELATIVE:
                continue
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise MigrationError(f"native tree contains a symlink or special file: {path}")


def _write_marker(root: Path, layout: int, snapshot_id: str) -> None:
    marker = root / MARKER
    info = _lstat(marker)
    if info is not None and (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
        raise MigrationError("runtime layout marker is unsafe")
    _write_json(marker, {"format": FORMAT, "layout": layout, "snapshot_id": snapshot_id})
    os.chmod(marker, 0o600)


def _read_marker(root: Path) -> dict[str, Any] | None:
    marker = root / MARKER
    info = _lstat(marker)
    if info is None:
        return None
    value = _read_json(marker, "runtime layout marker")
    if value.get("format") != FORMAT or value.get("layout") not in (2, LAYOUT):
        raise MigrationError("runtime layout marker is unsupported")
    snapshot_id = value.get("snapshot_id")
    if not isinstance(snapshot_id, str) or Path(snapshot_id).name != snapshot_id:
        raise MigrationError("runtime layout snapshot reference is invalid")
    return value


def _find_snapshot(root: Path, snapshot_id: str) -> Path:
    if not snapshot_id.startswith(MIGRATION_PREFIX):
        raise MigrationError("runtime layout snapshot reference is invalid")
    snapshot = root / "migrations" / snapshot_id
    _verify_snapshot(snapshot)
    return snapshot


def _pending_snapshot(root: Path) -> Path | None:
    migrations = root / "migrations"
    if _lstat(migrations) is None:
        return None
    _real_dir(migrations, "migration snapshots directory")
    pending: list[Path] = []
    for child in sorted(migrations.iterdir(), key=lambda item: item.name):
        if not child.name.startswith(MIGRATION_PREFIX):
            continue
        child_info = _lstat(child)
        if child_info is None or not stat.S_ISDIR(child_info.st_mode) or stat.S_ISLNK(child_info.st_mode):
            raise MigrationError(f"migration snapshot path is unsafe: {child}")
        if _lstat(_transaction_path(child)) is None:
            continue
        transaction = _read_transaction(child)
        if transaction["phase"] in ("snapshot-ready", "prepared"):
            pending.append(child)
    if len(pending) > 1:
        raise MigrationError("multiple incomplete native migrations need recovery")
    return pending[0] if pending else None


def prepare(data_dir: Path) -> str:
    root = data_dir
    _real_dir(root, "persistent data directory")
    with _migration_lock(root):
        marker = _read_marker(root)
        if marker is not None:
            if marker["layout"] == 2:
                raise MigrationError("runtime state was rolled back to layout 2")
            native = root / "native"
            _validate_native(native)
            return "STATE_LAYOUT_READY layout=3 idempotent=true"

        pending = _pending_snapshot(root)
        native = root / "native"
        if pending is None:
            if _lstat(native) is not None:
                raise MigrationError("native install path exists without a runtime layout marker")
            sources = _source_roots(root)
            pending = _create_snapshot(root, sources)
        _prepare_snapshot(root, pending)
        return f"STATE_LAYOUT_READY layout=3 snapshot={pending.name} idempotent=false"


def _restore_preflight(source: Path, target: Path) -> None:
    source_info = _lstat(source)
    if source_info is None:
        return
    target_info = _lstat(target)
    if stat.S_ISDIR(source_info.st_mode):
        if target_info is not None and (not stat.S_ISDIR(target_info.st_mode) or stat.S_ISLNK(target_info.st_mode)):
            raise MigrationError(f"rollback target conflicts with archived directory: {target}")
        for child in source.iterdir():
            _restore_preflight(child, target / child.name)
        return
    if not stat.S_ISREG(source_info.st_mode) or stat.S_ISLNK(source_info.st_mode):
        raise MigrationError(f"rollback archive contains an unsafe entry: {source}")
    if target_info is not None:
        if not stat.S_ISREG(target_info.st_mode) or stat.S_ISLNK(target_info.st_mode):
            raise MigrationError(f"rollback target conflicts with archived file: {target}")
        if _hash_file(source) != _hash_file(target):
            raise MigrationError(f"rollback refuses to overwrite changed legacy state: {target}")


def _restore_missing(source: Path, target: Path) -> None:
    source_info = _lstat(source)
    if source_info is None:
        return
    target_info = _lstat(target)
    if stat.S_ISDIR(source_info.st_mode):
        if target_info is None:
            target.mkdir(mode=0o700, parents=True)
        for child in sorted(source.iterdir(), key=lambda item: item.name):
            _restore_missing(child, target / child.name)
    elif target_info is None:
        _copy_entry(source, target)


def rollback(data_dir: Path) -> str:
    root = data_dir
    _real_dir(root, "persistent data directory")
    with _migration_lock(root):
        marker = _read_marker(root)
        if marker is None or marker["layout"] != LAYOUT:
            raise MigrationError("runtime layout is not at v3; nothing to roll back")
        snapshot = _find_snapshot(root, marker["snapshot_id"])
        transaction = _read_transaction(snapshot)
        if transaction["phase"] not in ("prepared", "committed"):
            raise MigrationError("native migration snapshot is not committed or recoverable")

        source_paths = _read_json(snapshot / "manifest.json", "migration snapshot manifest").get("source_paths")
        if not isinstance(source_paths, list):
            raise MigrationError("migration snapshot source list is malformed")
        restores: list[tuple[Path, Path]] = []
        for record in source_paths:
            if not isinstance(record, dict) or record.get("present") is not True:
                raise MigrationError("migration snapshot source record is malformed")
            relative = _safe_relative(record.get("path"))
            if relative != "workspace/memory" and not relative.startswith("workspace/sessions"):
                raise MigrationError("migration snapshot contains an unexpected source path")
            source = snapshot / relative
            target = root / relative
            _restore_preflight(source, target)
            restores.append((source, target))
        for source, target in restores:
            _restore_missing(source, target)
        _write_marker(root, 2, snapshot.name)
        return f"STATE_LAYOUT_ROLLED_BACK layout=2 snapshot={snapshot.name} native_retained=true"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Prepare or roll back native ZeroClaw persistent state")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "rollback"):
        command = commands.add_parser(name)
        command.add_argument("data_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        result = prepare(args.data_dir) if args.command == "prepare" else rollback(args.data_dir)
        print(result)
        return 0
    except (MigrationError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
