"""Unit tests for snapshot.py."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from imessage_archiver.db.snapshot import _sha256, snapshot


class TestSha256:
    def test_known_hash(self, tmp_path: Path) -> None:
        f = tmp_path / "test.bin"
        f.write_bytes(b"hello")
        import hashlib

        expected = hashlib.sha256(b"hello").hexdigest()
        assert _sha256(f) == expected

    def test_empty_file(self, tmp_path: Path) -> None:
        f = tmp_path / "empty.bin"
        f.write_bytes(b"")
        import hashlib

        assert _sha256(f) == hashlib.sha256(b"").hexdigest()


class TestSnapshot:
    def test_snapshot_creates_file(self, tmp_path: Path) -> None:
        # Create a minimal source DB
        src = tmp_path / "chat.db"
        conn = sqlite3.connect(str(src))
        conn.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        conn.execute("INSERT INTO test VALUES (1)")
        conn.commit()
        conn.close()

        snap, sha = snapshot(source=src, work_root=tmp_path / "work")

        assert snap.exists()
        assert len(sha) == 64  # hex SHA-256
        assert sha == _sha256(snap)

    def test_snapshot_is_readable_sqlite(self, tmp_path: Path) -> None:
        src = tmp_path / "chat.db"
        conn = sqlite3.connect(str(src))
        conn.execute("CREATE TABLE msg (id INTEGER, text TEXT)")
        conn.executemany("INSERT INTO msg VALUES (?, ?)", [(i, f"msg{i}") for i in range(10)])
        conn.commit()
        conn.close()

        snap, _ = snapshot(source=src, work_root=tmp_path / "work")

        snap_conn = sqlite3.connect(f"file:{snap}?mode=ro&immutable=1", uri=True)
        rows = snap_conn.execute("SELECT COUNT(*) FROM msg").fetchone()[0]
        snap_conn.close()
        assert rows == 10

    def test_missing_source_raises(self, tmp_path: Path) -> None:
        with pytest.raises((PermissionError, sqlite3.OperationalError)):
            snapshot(source=tmp_path / "nonexistent.db", work_root=tmp_path / "work")

    def test_non_sqlite_raises_database_error(self, tmp_path: Path) -> None:
        """A file that exists but is not a valid SQLite DB raises DatabaseError from VACUUM INTO."""
        bad = tmp_path / "notadb.db"
        bad.write_bytes(b"this is not sqlite data at all")
        with pytest.raises(sqlite3.DatabaseError):
            snapshot(source=bad, work_root=tmp_path / "work")

    def test_snapshot_has_no_wal(self, tmp_path: Path) -> None:
        src = tmp_path / "chat.db"
        conn = sqlite3.connect(str(src))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE t (x INTEGER)")
        conn.execute("INSERT INTO t VALUES (42)")
        conn.commit()
        conn.close()

        snap, _ = snapshot(source=src, work_root=tmp_path / "work")

        assert not (snap.parent / "chat.db-wal").exists()
        assert not (snap.parent / "chat.db-shm").exists()
