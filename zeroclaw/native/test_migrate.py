"""Synthetic unit tests for native persistent-state migration."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from native import migrate


def _database(path: Path, table: str, row: tuple[object, ...]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    try:
        if table == "memory_rows":
            connection.execute(
                "CREATE TABLE memory_rows (id INTEGER PRIMARY KEY, agent_alias TEXT, content TEXT)"
            )
            connection.execute(
                "INSERT INTO memory_rows(agent_alias, content) VALUES (?, ?)",
                row,
            )
        else:
            connection.execute(
                "CREATE TABLE sessions (id TEXT PRIMARY KEY, channel TEXT, sender_id TEXT, payload TEXT)"
            )
            connection.execute(
                "INSERT INTO sessions(id, channel, sender_id, payload) VALUES (?, ?, ?, ?)",
                row,
            )
        connection.commit()
    finally:
        connection.close()


class RuntimeMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="zeroclaw-migrate-")
        self.root = Path(self.temp.name)
        self.workspace = self.root / "workspace"
        self.memory = self.workspace / "memory"
        self.sessions = self.workspace / "sessions"
        self.memory.mkdir(parents=True)
        self.sessions.mkdir(parents=True)
        (self.root / ".state-schema").write_text("1\n", encoding="ascii")
        (self.workspace / "SOUL.md").write_text("legacy helper identity must stay inactive\n")
        (self.workspace / "skills").mkdir()
        (self.workspace / "skills" / "legacy-tool.md").write_text("do not activate\n")
        _database(self.memory / "brain.db", "memory_rows", ("default", "synthetic remembered fact"))
        _database(
            self.sessions / "sessions.db",
            "sessions",
            ("synthetic-session-1", "telegram", "synthetic-sender", "conversation row"),
        )
        (self.sessions / "telegram_opaque_digest.json").write_text(
            '{"messages":["must remain archived"]}\n',
            encoding="utf-8",
        )
        (self.memory / "archive").mkdir()
        (self.memory / "archive" / "note.txt").write_text("preserved artifact\n")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _leave_prepared_snapshot(self) -> tuple[Path, Path]:
        write_transaction = migrate._write_transaction

        def interrupt_after_prepared(snapshot: Path, transaction: dict[str, object]) -> None:
            write_transaction(snapshot, transaction)
            if transaction.get("phase") == "prepared":
                raise RuntimeError("synthetic interruption after prepared transaction publication")

        with mock.patch.object(migrate, "_write_transaction", side_effect=interrupt_after_prepared):
            with self.assertRaisesRegex(RuntimeError, "after prepared transaction publication"):
                migrate.prepare(self.root)

        snapshots = list((self.root / "migrations").iterdir())
        self.assertEqual(len(snapshots), 1)
        snapshot = snapshots[0]
        transaction = migrate._read_transaction(snapshot)
        self.assertEqual(transaction["phase"], "prepared")
        return snapshot, migrate._stage_name(snapshot, transaction)

    def test_prepare_copies_native_databases_and_keeps_legacy_workspace_inactive(self) -> None:
        result = migrate.prepare(self.root)

        self.assertIn("layout=3", result)
        native = self.root / "native"
        self.assertTrue((native / "config.toml").exists() is False)
        self.assertTrue((native / "agents/default/workspace").is_dir())
        with sqlite3.connect(native / "data/memory/brain.db") as connection:
            self.assertEqual(
                connection.execute("SELECT agent_alias, content FROM memory_rows").fetchone(),
                ("default", "synthetic remembered fact"),
            )
        with sqlite3.connect(native / "data/sessions/sessions.db") as connection:
            self.assertEqual(
                connection.execute("SELECT id, payload FROM sessions").fetchone(),
                ("synthetic-session-1", "conversation row"),
            )
        self.assertFalse((native / "data/sessions/telegram_opaque_digest.json").exists())
        self.assertFalse((native / "agents/default/workspace/SOUL.md").exists())
        self.assertFalse((native / "agents/default/workspace/skills").exists())
        self.assertTrue((self.workspace / "SOUL.md").exists())
        self.assertEqual((self.root / ".state-schema").read_text(), "1\n")
        marker = json.loads((self.root / ".runtime-layout").read_text())
        self.assertEqual(marker["layout"], 3)
        self.assertTrue((self.root / "migrations" / marker["snapshot_id"] / "checksums.json").is_file())

    def test_prepare_is_idempotent_without_retained_migration_snapshot(self) -> None:
        migrate.prepare(self.root)
        marker = json.loads((self.root / ".runtime-layout").read_text())
        shutil.rmtree(self.root / "migrations" / marker["snapshot_id"])

        result = migrate.prepare(self.root)

        self.assertIn("idempotent=true", result)
        self.assertEqual(json.loads((self.root / ".runtime-layout").read_text())["layout"], 3)

    def test_prepare_resumes_after_target_manifest_publication_interruption(self) -> None:
        write_transaction = migrate._write_transaction

        def interrupt_after_target_manifest(snapshot: Path, transaction: dict[str, object]) -> None:
            if transaction.get("phase") == "prepared":
                raise RuntimeError("synthetic interruption after target manifest publication")
            write_transaction(snapshot, transaction)

        with mock.patch.object(migrate, "_write_transaction", side_effect=interrupt_after_target_manifest):
            with self.assertRaisesRegex(RuntimeError, "after target manifest publication"):
                migrate.prepare(self.root)

        self.assertFalse((self.root / ".runtime-layout").exists())
        snapshots = list((self.root / "migrations").iterdir())
        self.assertEqual(len(snapshots), 1)
        snapshot = snapshots[0]
        self.assertTrue((snapshot / "target-manifest.json").is_file())
        migrate._verify_snapshot(snapshot)
        self.assertEqual(migrate._read_transaction(snapshot)["phase"], "snapshot-ready")

        result = migrate.prepare(self.root)

        self.assertIn("layout=3", result)
        marker = json.loads((self.root / ".runtime-layout").read_text())
        self.assertEqual(marker["layout"], 3)
        self.assertEqual(migrate._read_transaction(snapshot)["phase"], "committed")

    def test_prepare_recovers_after_interruption_while_rebuilding_prepared_stage(self) -> None:
        snapshot, stage = self._leave_prepared_snapshot()
        shutil.rmtree(stage)

        def interrupt_during_restage(_snapshot: Path, partial_stage: Path) -> None:
            partial_stage.mkdir(mode=0o700)
            (partial_stage / "partial").write_text("synthetic interrupted stage\n", encoding="utf-8")
            raise RuntimeError("synthetic interruption during prepared-stage rebuild")

        with mock.patch.object(migrate, "_stage_native", side_effect=interrupt_during_restage):
            with self.assertRaisesRegex(RuntimeError, "during prepared-stage rebuild"):
                migrate.prepare(self.root)

        self.assertTrue(stage.is_dir())
        self.assertFalse((self.root / "native").exists())
        self.assertFalse((self.root / ".runtime-layout").exists())
        migrate._verify_snapshot(snapshot)

        result = migrate.prepare(self.root)

        self.assertIn("layout=3", result)
        self.assertFalse(stage.exists())
        self.assertEqual(migrate._read_transaction(snapshot)["phase"], "committed")
        migrate._verify_snapshot(snapshot)
        with sqlite3.connect(self.root / "native/data/memory/brain.db") as native:
            self.assertEqual(
                native.execute("SELECT content FROM memory_rows").fetchone(),
                ("synthetic remembered fact",),
            )

    def test_prepare_does_not_remove_unsafe_prepared_stage(self) -> None:
        snapshot, stage = self._leave_prepared_snapshot()
        shutil.rmtree(stage)
        stage.mkdir(mode=0o700)
        outside = self.root / "outside-stage-target"
        outside.write_text("must remain untouched\n", encoding="utf-8")
        (stage / "escape").symlink_to(outside)

        with self.assertRaisesRegex(migrate.MigrationError, "symlink or special file"):
            migrate.prepare(self.root)

        self.assertTrue((stage / "escape").is_symlink())
        self.assertEqual(outside.read_text(encoding="utf-8"), "must remain untouched\n")
        self.assertFalse((self.root / "native").exists())
        self.assertFalse((self.root / ".runtime-layout").exists())
        self.assertEqual(migrate._read_transaction(snapshot)["phase"], "prepared")
        migrate._verify_snapshot(snapshot)

    def test_prepare_preserves_and_reads_legacy_wal_sidecars(self) -> None:
        database = self.memory / "brain.db"
        writer = sqlite3.connect(database)
        try:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute(
                "INSERT INTO memory_rows(agent_alias, content) VALUES (?, ?)",
                ("default", "committed only in the legacy WAL"),
            )
            writer.commit()
            self.assertTrue(Path(str(database) + "-wal").is_file())
            self.assertTrue(Path(str(database) + "-shm").is_file())

            migrate.prepare(self.root)

            marker = json.loads((self.root / ".runtime-layout").read_text())
            snapshot = self.root / "migrations" / marker["snapshot_id"]
            self.assertTrue((snapshot / "workspace/memory/brain.db-wal").is_file())
            self.assertTrue((snapshot / "workspace/memory/brain.db-shm").is_file())
            migrate._verify_snapshot(snapshot)
            with sqlite3.connect(self.root / "native/data/memory/brain.db") as native:
                self.assertEqual(
                    native.execute(
                        "SELECT content FROM memory_rows WHERE content = ?",
                        ("committed only in the legacy WAL",),
                    ).fetchone(),
                    ("committed only in the legacy WAL",),
                )
        finally:
            writer.close()

    def test_prepare_recovers_hot_delete_journal_without_mutating_archive(self) -> None:
        database = self.memory / "brain.db"
        database.unlink()
        writer = sqlite3.connect(database)
        try:
            writer.execute("PRAGMA page_size=1024")
            writer.execute(
                "CREATE TABLE memory_rows (id INTEGER PRIMARY KEY, agent_alias TEXT, content TEXT)"
            )
            writer.executemany(
                "INSERT INTO memory_rows(agent_alias, content) VALUES (?, ?)",
                [("default", f"committed-{index}-" + "c" * 1800) for index in range(1, 301)],
            )
            writer.commit()
        finally:
            writer.close()

        source_hash_before_crash = migrate._hash_file(database)
        child = """\
import os
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA journal_mode=DELETE")
connection.execute("PRAGMA cache_size=1")
connection.execute("PRAGMA cache_spill=ON")
connection.execute("BEGIN EXCLUSIVE")
for row_id in range(1, 301):
    connection.execute(
        "UPDATE memory_rows SET content=? WHERE id=?",
        ("UNCOMMITTED-" + str(row_id) + "-" + "u" * 1800, row_id),
    )
os._exit(0)
"""
        subprocess.run([sys.executable, "-c", child, str(database)], check=True)
        journal = Path(str(database) + "-journal")
        self.assertTrue(journal.is_file())
        self.assertGreater(journal.stat().st_size, 512)
        self.assertNotEqual(migrate._hash_file(database), source_hash_before_crash)
        source_hash = migrate._hash_file(database)
        journal_hash = migrate._hash_file(journal)

        # Prove this is a hot rollback journal using only a disposable clone.
        control = self.root / "control.db"
        control.write_bytes(database.read_bytes())
        Path(str(control) + "-journal").write_bytes(journal.read_bytes())
        with sqlite3.connect(control) as recovered:
            self.assertEqual(
                recovered.execute(
                    "SELECT COUNT(*) FROM memory_rows WHERE content LIKE 'UNCOMMITTED-%'"
                ).fetchone(),
                (0,),
            )
            self.assertEqual(recovered.execute("PRAGMA quick_check").fetchone(), ("ok",))
        self.assertFalse(Path(str(control) + "-journal").exists())
        self.assertEqual(migrate._hash_file(database), source_hash)
        self.assertEqual(migrate._hash_file(journal), journal_hash)

        migrate.prepare(self.root)

        marker = json.loads((self.root / ".runtime-layout").read_text())
        snapshot = self.root / "migrations" / marker["snapshot_id"]
        archived_database = snapshot / "workspace/memory/brain.db"
        archived_journal = Path(str(archived_database) + "-journal")
        self.assertTrue(archived_journal.is_file())
        self.assertEqual(migrate._hash_file(database), source_hash)
        self.assertEqual(migrate._hash_file(journal), journal_hash)
        migrate._verify_snapshot(snapshot)

        native_database = self.root / "native/data/memory/brain.db"
        self.assertFalse(Path(str(native_database) + "-journal").exists())
        with sqlite3.connect(native_database) as native:
            self.assertEqual(
                native.execute(
                    "SELECT COUNT(*) FROM memory_rows WHERE content LIKE 'UNCOMMITTED-%'"
                ).fetchone(),
                (0,),
            )
            self.assertEqual(
                native.execute(
                    "SELECT COUNT(*) FROM memory_rows WHERE content LIKE 'committed-%'"
                ).fetchone(),
                (300,),
            )
            self.assertEqual(native.execute("PRAGMA quick_check").fetchone(), ("ok",))

    def test_sqlite_backup_rejects_unsafe_delete_journal_sidecar(self) -> None:
        journal = Path(str(self.memory / "brain.db") + "-journal")
        outside = self.root / "outside-journal"
        outside.write_bytes(b"not a database journal")
        journal.symlink_to(outside)

        with self.assertRaisesRegex(migrate.MigrationError, "unsafe SQLite sidecar"):
            migrate._sqlite_backup(self.memory / "brain.db", self.root / "copy.db", "test memory")

        self.assertFalse((self.root / "copy.db").exists())

    def test_rollback_restores_missing_legacy_memory_and_sessions_without_rewinding_native(self) -> None:
        migrate.prepare(self.root)
        archived_brain_hash = migrate._hash_file(
            self.root / "migrations" / json.loads((self.root / ".runtime-layout").read_text())["snapshot_id"]
            / "workspace/memory/brain.db"
        )
        native_hash = migrate._hash_file(self.root / "native/data/memory/brain.db")
        (self.memory / "brain.db").unlink()
        (self.sessions / "sessions.db").unlink()
        (self.sessions / "telegram_opaque_digest.json").unlink()

        result = migrate.rollback(self.root)

        self.assertIn("native_retained=true", result)
        self.assertEqual(migrate._hash_file(self.memory / "brain.db"), archived_brain_hash)
        self.assertEqual(migrate._hash_file(self.root / "native/data/memory/brain.db"), native_hash)
        self.assertTrue((self.sessions / "sessions.db").is_file())
        self.assertTrue((self.sessions / "telegram_opaque_digest.json").is_file())
        self.assertTrue((self.root / "native/data/memory/brain.db").is_file())
        self.assertEqual(json.loads((self.root / ".runtime-layout").read_text())["layout"], 2)
        self.assertEqual((self.root / ".state-schema").read_text(), "1\n")

    def test_rollback_refuses_to_overwrite_changed_legacy_archive(self) -> None:
        migrate.prepare(self.root)
        (self.memory / "archive/note.txt").write_text("new legacy data\n")

        with self.assertRaisesRegex(migrate.MigrationError, "refuses to overwrite"):
            migrate.rollback(self.root)

        self.assertEqual(json.loads((self.root / ".runtime-layout").read_text())["layout"], 3)
        self.assertTrue((self.root / "native/data/memory/brain.db").is_file())

    def test_snapshot_checksum_detects_tampering_before_rollback(self) -> None:
        migrate.prepare(self.root)
        marker = json.loads((self.root / ".runtime-layout").read_text())
        snapshot = self.root / "migrations" / marker["snapshot_id"]
        (snapshot / "workspace/memory/archive/note.txt").write_text("tampered\n")

        with self.assertRaisesRegex(migrate.MigrationError, "checksum inventory"):
            migrate.rollback(self.root)

    def test_prepare_rejects_an_existing_unmarked_native_path(self) -> None:
        (self.root / "native").mkdir()

        with self.assertRaisesRegex(migrate.MigrationError, "without a runtime layout marker"):
            migrate.prepare(self.root)

        self.assertEqual((self.root / ".state-schema").read_text(), "1\n")

    def test_prepare_rejects_relevant_source_symlinks_before_copy(self) -> None:
        outside = self.root / "outside.txt"
        outside.write_text("not state\n")
        (self.memory / "escape").symlink_to(outside)

        with self.assertRaisesRegex(migrate.MigrationError, "symlink or special"):
            migrate.prepare(self.root)

        self.assertFalse((self.root / "native").exists())

    def test_prepare_rejects_non_directory_workspace_before_snapshot(self) -> None:
        shutil.rmtree(self.workspace)
        self.workspace.write_text("not a directory\n", encoding="utf-8")

        with self.assertRaisesRegex(migrate.MigrationError, "legacy workspace is unsafe"):
            migrate.prepare(self.root)

        self.assertFalse((self.root / "migrations").exists())
        self.assertFalse((self.root / "native").exists())

    def test_prepare_rejects_non_directory_memory_before_snapshot(self) -> None:
        shutil.rmtree(self.memory)
        self.memory.write_text("not a directory\n", encoding="utf-8")

        with self.assertRaisesRegex(migrate.MigrationError, "legacy memory path is unsafe"):
            migrate.prepare(self.root)

        self.assertFalse((self.root / "migrations").exists())
        self.assertFalse((self.root / "native").exists())

    def test_prepare_uses_a_private_exclusive_lock(self) -> None:
        with migrate._migration_lock(self.root):
            with self.assertRaisesRegex(migrate.MigrationError, "migration is in progress"):
                migrate.prepare(self.root)


if __name__ == "__main__":
    unittest.main()
