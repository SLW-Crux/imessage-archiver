"""Phase 7 hardening tests: large DB, cross-version schemas, idempotence at scale."""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

from imessage_archiver.core.archive import ArchiveWriter
from imessage_archiver.core.verify import verify_bundle
from imessage_archiver.db.reader import Reader
from imessage_archiver.db.snapshot import snapshot

FIXTURES = Path(__file__).parent.parent / "fixtures"


def _fixture(name: str) -> Path:
    p = FIXTURES / name
    if not p.exists():
        pytest.skip(f"Fixture {name} not found — run tests/fixtures/generate.py")
    return p


# ----------------------------------------------------------------------
# Cross-version schema coverage
# ----------------------------------------------------------------------


@pytest.mark.parametrize("variant", ["ventura", "sonoma", "sequoia"])
def test_archive_cross_version_schema(tmp_path: Path, variant: str) -> None:
    """Each macOS variant DB must archive and verify cleanly.

    Ventura schema lacks date_edited/date_retracted columns; Sonoma added
    them; Sequoia adds further (unused-by-us) columns. The reader must
    transparently handle all three.
    """
    src = _fixture(f"{variant}.db")
    bundle = tmp_path / "out.imarchive"

    snap_path, sha = snapshot(source=src, work_root=tmp_path / "work")
    with Reader(snap_path) as r:
        with ArchiveWriter(bundle) as w:
            stats = w.run(r, source_sha256=sha, source_db_path=str(src))

    assert stats.messages_seen > 0, f"{variant}: expected messages"
    result = verify_bundle(bundle, log_path=tmp_path / "verify.log")
    assert result.ok, f"{variant}: verify failed: {result.failures}"

    # Make sure the date_edited / date_retracted columns exist in OUR archive
    # even if the source schema didn't have them — they're our own columns.
    con = sqlite3.connect(str(bundle / "archive.sqlite"))
    cols = {r[1] for r in con.execute("PRAGMA table_info(messages)")}
    con.close()
    assert {"date_edited", "date_retracted"}.issubset(cols)


# ----------------------------------------------------------------------
# Large-DB stress test (regenerated on demand, never committed)
# ----------------------------------------------------------------------


@pytest.fixture(scope="module")
def large_db(tmp_path_factory) -> Path:
    """Build a 50K-message synthetic DB once per test run."""
    # The generator writes attachment files to disk; we want them in a
    # temp dir, not the repo's tests/fixtures/Attachments/.
    sys.path.insert(0, str(FIXTURES))
    try:
        import generate as gen  # noqa: WPS433
    finally:
        sys.path.pop(0)

    out_dir = tmp_path_factory.mktemp("large_fixture")
    db_path = out_dir / "large.db"
    # Redirect the module-level fixtures dir so attachments land in our tmp.
    original_root = gen.FIXTURES_DIR
    gen.FIXTURES_DIR = out_dir
    try:
        gen.build_large(db_path)
    finally:
        gen.FIXTURES_DIR = original_root
    return db_path


def test_large_db_archives_under_60s(tmp_path: Path, large_db: Path) -> None:
    """50K messages + ~1K attachments should archive in well under a minute."""
    bundle = tmp_path / "large.imarchive"
    start = time.perf_counter()

    snap_path, sha = snapshot(source=large_db, work_root=tmp_path / "work")
    with Reader(snap_path) as r:
        with ArchiveWriter(bundle) as w:
            stats = w.run(r, source_sha256=sha, source_db_path=str(large_db))

    elapsed = time.perf_counter() - start

    assert stats.messages_seen == 50_000
    assert 0 < stats.attachments_written <= 1_000
    assert elapsed < 60, f"50K-message archive took {elapsed:.1f}s — too slow"

    # Manifest sanity
    manifest = json.loads((bundle / "manifest.json").read_text())
    assert manifest["message_count"] == 50_000
    assert manifest["schema_version"] >= 1


def test_large_db_incremental_is_fast(tmp_path: Path, large_db: Path) -> None:
    """Re-archiving an unchanged large DB must be a no-op (idempotence at scale)."""
    bundle = tmp_path / "large_inc.imarchive"

    # First pass
    snap1, sha1 = snapshot(source=large_db, work_root=tmp_path / "work1")
    with Reader(snap1) as r:
        with ArchiveWriter(bundle) as w:
            stats1 = w.run(r, source_sha256=sha1, source_db_path=str(large_db))

    # Second pass — same source, no new data
    second_start = time.perf_counter()
    snap2, sha2 = snapshot(source=large_db, work_root=tmp_path / "work2")
    with Reader(snap2) as r:
        with ArchiveWriter(bundle) as w:
            stats2 = w.run(r, source_sha256=sha2, source_db_path=str(large_db))
    second_elapsed = time.perf_counter() - second_start

    assert stats1.messages_seen == stats2.messages_seen == 50_000
    # No new attachments should be written on re-run (INSERT OR IGNORE wins)
    assert stats2.attachments_written == 0
    # Second pass walks all rows but writes none — should be much faster
    assert second_elapsed < 30, f"Incremental re-archive took {second_elapsed:.1f}s — slower than expected"

    # Bundle size unchanged
    con = sqlite3.connect(str(bundle / "archive.sqlite"))
    msg_count = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    con.close()
    assert msg_count == 50_000
