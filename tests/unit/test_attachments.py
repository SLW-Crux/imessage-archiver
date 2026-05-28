"""Unit tests for core/attachments.py."""

from __future__ import annotations

import hashlib
from pathlib import Path
from unittest.mock import MagicMock

from imessage_archiver.core.attachments import AttachmentState, classify, sha256_file


def _att(resolved_path: Path | None) -> MagicMock:
    m = MagicMock()
    m.resolved_path = resolved_path
    return m


class TestClassify:
    def test_none_path_is_missing(self) -> None:
        assert classify(_att(None)) == AttachmentState.MISSING

    def test_nonexistent_path_is_missing(self, tmp_path: Path) -> None:
        assert classify(_att(tmp_path / "nope.png")) == AttachmentState.MISSING

    def test_zero_byte_file(self, tmp_path: Path) -> None:
        f = tmp_path / "empty.png"
        f.write_bytes(b"")
        assert classify(_att(f)) == AttachmentState.ZERO_BYTE

    def test_present_file(self, tmp_path: Path) -> None:
        f = tmp_path / "photo.png"
        f.write_bytes(b"\x89PNG")
        assert classify(_att(f)) == AttachmentState.LOCAL_PRESENT

    def test_unreadable_file(self, tmp_path: Path) -> None:
        f = tmp_path / "locked.png"
        f.write_bytes(b"data")
        f.chmod(0o000)
        try:
            result = classify(_att(f))
            # On macOS running as root this may return LOCAL_PRESENT
            assert result in (AttachmentState.UNREADABLE, AttachmentState.LOCAL_PRESENT)
        finally:
            f.chmod(0o644)


class TestSha256File:
    def test_known_hash(self, tmp_path: Path) -> None:
        f = tmp_path / "data.bin"
        f.write_bytes(b"hello")
        assert sha256_file(f) == hashlib.sha256(b"hello").hexdigest()

    def test_empty_file(self, tmp_path: Path) -> None:
        f = tmp_path / "empty.bin"
        f.write_bytes(b"")
        assert sha256_file(f) == hashlib.sha256(b"").hexdigest()

    def test_large_file_streams(self, tmp_path: Path) -> None:
        data = b"x" * (3 * 1024 * 1024)
        f = tmp_path / "big.bin"
        f.write_bytes(data)
        assert sha256_file(f) == hashlib.sha256(data).hexdigest()
