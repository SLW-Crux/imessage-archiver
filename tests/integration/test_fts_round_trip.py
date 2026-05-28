"""FTS5 round-trip test (L4 from the test-coverage review).

The existing test_fts_search_works in test_archive_integrity.py only
asserts `len(rows) >= 0` — a no-op. This file proves that FTS5 actually
indexes message text and returns the right messages.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest

from imessage_archiver.core.archive import ArchiveWriter
from imessage_archiver.db.reader import Reader

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found")
    return p


@pytest.fixture
def tiny_bundle(tmp_path: Path) -> Path:
    bundle = tmp_path / "tiny.imarchive"
    with Reader(_fixture("tiny.db")) as r:
        with ArchiveWriter(bundle) as w:
            w.run(r)
    return bundle


def test_fts_returns_message_for_known_token(tiny_bundle: Path) -> None:
    """Tiny fixture contains the literal text "Hey, how are you?".
    Searching for "Hey" must return at least one matching message_guid.
    """
    conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
    rows = conn.execute("SELECT message_guid FROM messages_fts WHERE messages_fts MATCH 'Hey'").fetchall()
    conn.close()
    assert len(rows) >= 1, "FTS5 returned no results for a token known to be in the fixture"


def test_fts_returns_no_results_for_absent_token(tiny_bundle: Path) -> None:
    """A token that does not appear in the fixture must return 0 results."""
    conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
    # Quote to avoid FTS5 interpreting "-" as a column qualifier — same
    # sanitisation as iOS-H11 fix in ArchiveReader.swift.
    rows = conn.execute(
        "SELECT message_guid FROM messages_fts " "WHERE messages_fts MATCH '\"zzzdefinitelynotinfixturexyz\"'"
    ).fetchall()
    conn.close()
    assert len(rows) == 0


def test_fts_results_match_actual_message_rows(tiny_bundle: Path) -> None:
    """Every FTS5 result must correspond to a real messages row — confirms
    the external-content table is properly linked to the messages table."""
    conn = sqlite3.connect(str(tiny_bundle / "archive.sqlite"))
    fts_guids = {
        r[0] for r in conn.execute("SELECT message_guid FROM messages_fts WHERE messages_fts MATCH 'how'")
    }
    real_guids = {r[0] for r in conn.execute("SELECT message_guid FROM messages WHERE text LIKE '%how%'")}
    conn.close()
    # Every FTS-matched guid must exist in the messages table.
    assert fts_guids.issubset(
        real_guids | set()
    ), f"FTS returned guids not in messages: {fts_guids - real_guids}"
