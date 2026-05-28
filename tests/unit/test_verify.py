"""Unit tests for core/verify.py."""

from __future__ import annotations

import sqlite3
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


@pytest.fixture()
def tiny_bundle(tmp_path: Path) -> Path:
    bundle = tmp_path / "archive.imarchive"
    with Reader(_fixture("tiny.db")) as r:
        with ArchiveWriter(bundle) as w:
            w.run(r)
    return bundle


class TestVerifyMissingFiles:
    def test_missing_sqlite_raises(self, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        bundle.mkdir()
        (bundle / "attachments.tar").write_bytes(b"")
        with pytest.raises(FileNotFoundError, match="archive.sqlite"):
            verify_bundle(bundle)

    def test_missing_tar_raises(self, tmp_path: Path) -> None:
        bundle = tmp_path / "archive.imarchive"
        bundle.mkdir()
        (bundle / "archive.sqlite").write_bytes(b"")
        with pytest.raises(FileNotFoundError, match="attachments.tar"):
            verify_bundle(bundle)


class TestVerifyIntegrity:
    def test_good_bundle_passes(self, tiny_bundle: Path, tmp_path: Path) -> None:
        result = verify_bundle(tiny_bundle, log_path=tmp_path / "verify.log")
        assert result.ok
        assert result.checked >= 1
        assert len(result.failures) == 0
        assert result.duration_s >= 0

    def test_log_file_written(self, tiny_bundle: Path, tmp_path: Path) -> None:
        log_path = tmp_path / "verify.log"
        verify_bundle(tiny_bundle, log_path=log_path)
        assert log_path.exists()
        content = log_path.read_text()
        assert "PASS" in content

    def test_corrupted_tar_fails(self, tiny_bundle: Path, tmp_path: Path) -> None:
        """Overwrite tar data bytes to trigger SHA mismatch."""
        tar_path = tiny_bundle / "attachments.tar"
        data = bytearray(tar_path.read_bytes())
        # Flip bytes starting at offset 512 (first file's data)
        for i in range(512, min(len(data), 600)):
            data[i] ^= 0xFF
        tar_path.write_bytes(bytes(data))

        result = verify_bundle(tiny_bundle, log_path=tmp_path / "verify.log")
        assert not result.ok
        assert len(result.failures) >= 1

    def test_empty_bundle_no_attachments(self, tmp_path: Path) -> None:
        """Bundle with no LOCAL_PRESENT attachments: 0 checked, ok=True."""
        bundle = tmp_path / "archive.imarchive"
        bundle.mkdir()
        # Create empty archive with no attachments
        conn = sqlite3.connect(str(bundle / "archive.sqlite"))
        conn.execute("""CREATE TABLE attachments(
            attachment_guid TEXT PRIMARY KEY, message_guid TEXT,
            filename TEXT, mime_type TEXT, uti TEXT, size INTEGER,
            sha256 TEXT, tar_offset INTEGER, tar_length INTEGER, state TEXT)""")
        conn.commit()
        conn.close()
        (bundle / "attachments.tar").write_bytes(b"")

        result = verify_bundle(bundle, log_path=tmp_path / "verify.log")
        assert result.ok
        assert result.checked == 0
