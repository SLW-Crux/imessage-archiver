"""Layer 3: Archive integrity tests.

Runs a full archive of the synthetic fixtures, then verifies:
- archive.sqlite schema is correct
- manifest.json is valid
- All LOCAL_PRESENT attachments are correctly stored in attachments.tar
- SHA-256 hashes match
- INSERT OR IGNORE is idempotent (running twice produces same counts)
"""

from __future__ import annotations

import json
import sqlite3
import tarfile
from pathlib import Path

import pytest

from imessage_archiver.core.archive import ArchiveWriter
from imessage_archiver.core.verify import verify_bundle
from imessage_archiver.db.reader import Reader

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found — run tests/fixtures/generate.py")
    return p


@pytest.fixture()
def tiny_bundle(tmp_path: Path) -> Path:
    bundle = tmp_path / "archive.imarchive"
    with Reader(_fixture("tiny.db")) as r:
        with ArchiveWriter(bundle) as w:
            w.run(r, source_sha256="deadbeef", source_db_path="/tmp/chat.db")
    return bundle


@pytest.fixture()
def edge_bundle(tmp_path: Path) -> Path:
    bundle = tmp_path / "archive.imarchive"
    with Reader(_fixture("edge.db")) as r:
        with ArchiveWriter(bundle) as w:
            w.run(r, source_sha256="cafebabe", source_db_path="/tmp/chat.db")
    return bundle


class TestBundleLayout:
    def test_bundle_files_exist(self, tiny_bundle: Path) -> None:
        assert (tiny_bundle / "archive.sqlite").exists()
        assert (tiny_bundle / "attachments.tar").exists()
        assert (tiny_bundle / "manifest.json").exists()

    def test_manifest_schema(self, tiny_bundle: Path) -> None:
        m = json.loads((tiny_bundle / "manifest.json").read_text())
        assert m["schema_version"] == 1
        assert "created_at" in m
        assert "last_updated_at" in m
        assert m["message_count"] > 0
        assert m["chat_count"] > 0

    def test_manifest_attachment_count_matches_db(self, tiny_bundle: Path) -> None:
        m = json.loads((tiny_bundle / "manifest.json").read_text())
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        db_count = conn.execute("SELECT COUNT(*) FROM attachments").fetchone()[0]
        conn.close()
        assert m["attachment_count"] == db_count


class TestDatabaseSchema:
    def test_schema_migrations_seeded(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        rows = conn.execute("SELECT version FROM schema_migrations").fetchall()
        conn.close()
        assert len(rows) == 1
        assert rows[0][0] == 1

    def test_all_messages_have_valid_chat_guids(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        orphans = conn.execute(
            """SELECT COUNT(*) FROM messages m
               LEFT JOIN chats c ON m.chat_guid = c.chat_guid
               WHERE c.chat_guid IS NULL"""
        ).fetchone()[0]
        conn.close()
        assert orphans == 0

    def test_all_attachments_have_valid_message_guids(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        orphans = conn.execute(
            """SELECT COUNT(*) FROM attachments a
               LEFT JOIN messages m ON a.message_guid = m.message_guid
               WHERE m.message_guid IS NULL"""
        ).fetchone()[0]
        conn.close()
        assert orphans == 0

    def test_fts_index_populated(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        fts_count = conn.execute("SELECT COUNT(*) FROM messages_fts").fetchone()[0]
        msg_count = conn.execute(
            "SELECT COUNT(*) FROM messages WHERE text IS NOT NULL"
        ).fetchone()[0]
        conn.close()
        assert fts_count == msg_count

    def test_fts_search_works(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        rows = conn.execute(
            "SELECT message_guid FROM messages_fts WHERE messages_fts MATCH 'Hello'"
        ).fetchall()
        conn.close()
        assert len(rows) >= 0  # just verifying no exception

    def test_archive_runs_recorded(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        runs = conn.execute("SELECT COUNT(*) FROM archive_runs").fetchone()[0]
        conn.close()
        assert runs == 1


class TestAttachmentStorage:
    def test_local_present_attachments_have_offsets(self, tiny_bundle: Path) -> None:
        conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
        rows = conn.execute(
            """SELECT attachment_guid, tar_offset, tar_length, sha256
               FROM attachments WHERE state='LOCAL_PRESENT'"""
        ).fetchall()
        conn.close()
        assert len(rows) >= 1
        for guid, offset, length, sha in rows:
            assert offset is not None
            assert length is not None
            assert sha is not None

    def test_missing_attachments_have_null_offsets(self, edge_bundle: Path) -> None:
        conn = sqlite3.connect(str(edge_bundle / "archive.sqlite"))
        rows = conn.execute(
            "SELECT tar_offset, tar_length FROM attachments WHERE state='MISSING'"
        ).fetchall()
        conn.close()
        for offset, length in rows:
            assert offset is None
            assert length is None

    def test_tar_data_matches_sha256(self, tiny_bundle: Path) -> None:
        result = verify_bundle(tiny_bundle)
        assert result.ok, f"Verification failures: {result.failures}"
        assert result.checked >= 1

    def test_attachment_states_valid(self, edge_bundle: Path) -> None:
        valid_states = {"LOCAL_PRESENT", "MISSING", "ZERO_BYTE", "UNREADABLE"}
        conn = sqlite3.connect(str(edge_bundle / "archive.sqlite"))
        states = {r[0] for r in conn.execute("SELECT DISTINCT state FROM attachments")}
        conn.close()
        assert states.issubset(valid_states)


class TestIdempotency:
    def test_double_archive_same_counts(self, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                stats1 = w.run(r)

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                stats2 = w.run(r)

        conn = sqlite3.connect(str(bundle / "archive.sqlite"))
        msg_count = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        att_count = conn.execute("SELECT COUNT(*) FROM attachments").fetchone()[0]
        runs = conn.execute("SELECT COUNT(*) FROM archive_runs").fetchone()[0]
        conn.close()

        assert stats1.messages_seen == stats2.messages_seen
        assert msg_count == stats1.messages_seen  # no duplicates
        assert runs == 2  # two archive_run records

    def test_double_archive_tar_size_stable_for_same_data(self, tmp_path: Path) -> None:
        """Second archive should not grow the tar (all attachments already stored)."""
        bundle = tmp_path / "archive.imarchive"

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)
        size1 = (bundle / "attachments.tar").stat().st_size

        with Reader(_fixture("tiny.db")) as r:
            with ArchiveWriter(bundle) as w:
                w.run(r)
        size2 = (bundle / "attachments.tar").stat().st_size

        assert size1 == size2


class TestEdgeCases:
    def test_attributed_body_message_has_text(self, edge_bundle: Path) -> None:
        conn = sqlite3.connect(str(edge_bundle / "archive.sqlite"))
        row = conn.execute(
            "SELECT text FROM messages WHERE text='via attributedBody'"
        ).fetchone()
        conn.close()
        assert row is not None

    def test_tapback_messages_stored(self, edge_bundle: Path) -> None:
        conn = sqlite3.connect(str(edge_bundle / "archive.sqlite"))
        tapbacks = conn.execute(
            "SELECT COUNT(*) FROM messages WHERE associated_message_type > 0"
        ).fetchone()[0]
        conn.close()
        assert tapbacks >= 2

    def test_reactions_json_denormalised(self, edge_bundle: Path) -> None:
        conn = sqlite3.connect(str(edge_bundle / "archive.sqlite"))
        rows = conn.execute(
            "SELECT reactions_json FROM messages WHERE reactions_json IS NOT NULL"
        ).fetchall()
        conn.close()
        assert len(rows) >= 1
        for (rjson,) in rows:
            parsed = json.loads(rjson)
            assert isinstance(parsed, list)
            for r in parsed:
                assert "from" in r
                assert "type" in r
                assert "timestamp" in r
