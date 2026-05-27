"""Unit tests for archive.py branches not covered by integration tests."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from imessage_archiver.core.archive import ArchiveWriter, RunStats, _iso_now, _macos_version
from imessage_archiver.db.reader import Reader

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found")
    return p


class TestArchiveBranches:
    def test_progress_callback_called(self, tmp_path: Path) -> None:
        """Covers the `if progress:` branch (line 166)."""
        bundle = tmp_path / "archive.imarchive"
        calls: list = []

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r, progress=lambda chat, stats: calls.append(chat.chat_guid))

        assert len(calls) >= 1

    def test_corrupt_manifest_json_overwritten(self, tmp_path: Path) -> None:
        """Covers the `except Exception: pass` in _write_manifest (lines 399-400)."""
        bundle = tmp_path / "archive.imarchive"
        bundle.mkdir()

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        # Corrupt the manifest
        (bundle / "manifest.json").write_text("NOT VALID JSON {{{{")

        # Second run should overwrite without raising
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        manifest = json.loads((bundle / "manifest.json").read_text())
        assert manifest["schema_version"] == 1

    def test_macos_version_returns_string(self) -> None:
        result = _macos_version()
        assert isinstance(result, str)

    def test_macos_version_exception_returns_empty(self) -> None:
        """Covers the except branch in _macos_version (lines 469-470)."""
        with patch("platform.mac_ver", side_effect=Exception("boom")):
            assert _macos_version() == ""

    def test_iso_now_format(self) -> None:
        ts = _iso_now()
        assert ts.endswith("Z")
        assert "T" in ts


class TestRebuildReactionsNullTarget:
    def test_tapback_with_null_target_guid_skipped(self, tmp_path: Path) -> None:
        """Tapback row with NULL associated_message_guid — exercises `if not target_guid: continue`."""
        bundle = tmp_path / "archive.imarchive"

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)

        # Inject a tapback with NULL associated_message_guid
        import sqlite3
        conn = sqlite3.connect(str(bundle / "archive.sqlite"))
        conn.execute("PRAGMA foreign_keys=OFF")
        # Get any existing message as a base
        row = conn.execute("SELECT message_guid, chat_guid, timestamp FROM messages LIMIT 1").fetchone()
        conn.execute(
            """INSERT INTO messages(message_guid, chat_guid, timestamp, is_from_me,
               has_attachments, associated_message_guid, associated_message_type)
               VALUES (?, ?, ?, 0, 0, NULL, 2001)""",
            (f"tapback-null-{row[0]}", row[1], row[2] + 1),
        )
        conn.commit()
        conn.close()

        # Re-running the writer should not crash (NULL target is silently skipped)
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)


class TestMergeModule:
    def test_merge_uses_snapshot(self, tmp_path: Path) -> None:
        """merge() calls snapshot() then ArchiveWriter.run() — mock snapshot."""
        from imessage_archiver.core.merge import merge

        snap_path = _fixture("tiny.db")
        bundle = tmp_path / "archive.imarchive"

        with patch("imessage_archiver.core.merge.snapshot", return_value=(snap_path, "abc123")) as mock_snap:
            stats = merge(bundle_path=bundle, source_db=snap_path, work_root=tmp_path)

        mock_snap.assert_called_once()
        assert stats.messages_seen > 0

    def test_merge_default_work_root(self, tmp_path: Path) -> None:
        """merge() without work_root uses default path — covers line 39."""
        from imessage_archiver.core.merge import merge

        snap_path = _fixture("tiny.db")
        bundle = tmp_path / "archive.imarchive"
        default_work = Path.home() / ".imessage-archiver" / "work"

        with patch("imessage_archiver.core.merge.snapshot", return_value=(snap_path, "xyz")) as mock_snap:
            merge(bundle_path=bundle, source_db=snap_path, work_root=None)

        _, kwargs = mock_snap.call_args
        assert kwargs.get("work_root") == default_work or mock_snap.call_args[0][1] == default_work

    def test_merge_default_source_db(self, tmp_path: Path) -> None:
        """merge() without source_db uses _default_chat_db() — covers line 59."""
        from imessage_archiver.core.merge import merge, _default_chat_db

        snap_path = _fixture("tiny.db")
        bundle = tmp_path / "archive.imarchive"

        with patch("imessage_archiver.core.merge.snapshot", return_value=(snap_path, "xyz")):
            merge(bundle_path=bundle, source_db=None, work_root=tmp_path)

        assert _default_chat_db() == Path.home() / "Library" / "Messages" / "chat.db"
