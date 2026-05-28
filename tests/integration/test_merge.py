"""Layer 4: Incremental merge tests."""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import pytest

from imessage_archiver.core.archive import ArchiveWriter
from imessage_archiver.core.verify import verify_bundle
from imessage_archiver.db.reader import Reader

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found")
    return p


class TestIncrementalMerge:
    def test_merge_medium_then_verify(self, tmp_path: Path) -> None:
        """Full archive of medium.db passes integrity check."""
        bundle = tmp_path / "archive.imarchive"
        with Reader(_fixture("medium.db")) as r:
            with ArchiveWriter(bundle) as w:
                stats = w.run(r)

        result = verify_bundle(bundle)
        assert result.ok, f"Verify failures: {result.failures}"
        assert stats.messages_seen == 5000

    def test_message_counts_consistent(self, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                stats = w.run(r)

        manifest = json.loads((bundle / "manifest.json").read_text())
        conn = sqlite3.connect(str(bundle / "archive.sqlite"))
        db_count = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        conn.close()

        assert manifest["message_count"] == db_count
        assert stats.messages_seen == db_count

    def test_second_run_writes_zero_new_messages(self, tmp_path: Path) -> None:
        """Second archive of same DB: INSERT OR IGNORE means 0 new messages."""
        bundle = tmp_path / "archive.imarchive"

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                stats1 = w.run(r)

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                stats2 = w.run(r)

        assert stats2.messages_written == 0
        assert stats2.attachments_written == 0
        assert stats2.messages_seen == stats1.messages_seen

    def test_manifest_updated_on_second_run(self, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)
        m1 = json.loads((bundle / "manifest.json").read_text())

        time.sleep(1)  # ensure different timestamp

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)
        m2 = json.loads((bundle / "manifest.json").read_text())

        assert m1["created_at"] == m2["created_at"]  # created_at never changes
        assert m1["last_updated_at"] <= m2["last_updated_at"]

    def test_all_fixtures_archive_without_error(self, tmp_path: Path) -> None:
        """Smoke test: each fixture archives cleanly."""
        for name in ["tiny.db", "medium.db", "edge.db", "ventura.db", "sonoma.db", "sequoia.db"]:
            if not (FIXTURES / name).exists():
                continue
            bundle = tmp_path / f"{name}.imarchive"
            with Reader(FIXTURES / name) as r:
                with ArchiveWriter(bundle) as w:
                    stats = w.run(r)
            assert stats.messages_seen >= 1
            assert (bundle / "manifest.json").exists()
