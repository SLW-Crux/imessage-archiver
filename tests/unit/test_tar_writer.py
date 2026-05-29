"""Unit tests for core/tar_writer.py."""

from __future__ import annotations

import hashlib
import tarfile
from pathlib import Path

from imessage_archiver.core.tar_writer import TarWriter, _tar_entry_name


class TestTarEntryName:
    def test_with_filename(self) -> None:
        name = _tar_entry_name("abc-123", "photo.jpg")
        assert name.endswith("photo.jpg")
        assert "abc-123" in name

    def test_without_filename(self) -> None:
        name = _tar_entry_name("abc-123", None)
        assert name == "abc-123"

    def test_filename_clamped_to_80_chars(self) -> None:
        long_name = "a" * 200 + ".jpg"
        # Use a guid without a hyphen so the suffix split is unambiguous.
        name = _tar_entry_name("ABCGUID", long_name)
        # Filename portion (after the "guid-" prefix) is clamped to 80 chars.
        # The total may exceed 100 with a long guid — tarfile handles
        # that transparently via PAX extended headers; the tar_writer
        # offset calculation is PAX-safe (see TestTarWriter below).
        suffix = name.removeprefix("ABCGUID-")
        assert len(suffix) <= 80

    def test_leading_dot_stripped(self) -> None:
        name = _tar_entry_name("abc-123", ".hidden")
        assert not name.split("-", 1)[-1].startswith(".")


class TestTarWriter:
    def test_creates_new_tar(self, tmp_path: Path) -> None:
        tar_path = tmp_path / "test.tar"
        src = tmp_path / "file.txt"
        src.write_bytes(b"hello world")

        with TarWriter(tar_path) as tw:
            offset, length = tw.append("GUID-001", src, "file.txt")

        assert tar_path.exists()
        assert offset == 512  # first file: header at 0, data at 512
        assert length == len(b"hello world")

    def test_offset_points_to_data(self, tmp_path: Path) -> None:
        tar_path = tmp_path / "test.tar"
        data = b"the payload bytes"
        src = tmp_path / "payload.bin"
        src.write_bytes(data)

        with TarWriter(tar_path) as tw:
            offset, length = tw.append("GUID-001", src, "payload.bin")

        with tar_path.open("rb") as fh:
            fh.seek(offset)
            actual = fh.read(length)
        assert actual == data

    def test_append_mode(self, tmp_path: Path) -> None:
        tar_path = tmp_path / "test.tar"
        src1 = tmp_path / "a.txt"
        src2 = tmp_path / "b.txt"
        src1.write_bytes(b"AAAA")
        src2.write_bytes(b"BBBB")

        with TarWriter(tar_path) as tw:
            off1, len1 = tw.append("GUID-001", src1, "a.txt")

        with TarWriter(tar_path) as tw:
            off2, len2 = tw.append("GUID-002", src2, "b.txt")

        # Second file starts after first entry (at least 512+512 bytes in)
        assert off2 > off1

        with tar_path.open("rb") as fh:
            fh.seek(off1)
            assert fh.read(len1) == b"AAAA"
            fh.seek(off2)
            assert fh.read(len2) == b"BBBB"

    def test_readable_as_tarfile(self, tmp_path: Path) -> None:
        tar_path = tmp_path / "test.tar"
        src = tmp_path / "hello.txt"
        src.write_bytes(b"hello")

        with TarWriter(tar_path) as tw:
            tw.append("GUID-001", src, "hello.txt")

        with tarfile.open(str(tar_path)) as tf:
            names = tf.getnames()
        assert any("GUID-001" in n for n in names)

    def test_zero_byte_file(self, tmp_path: Path) -> None:
        tar_path = tmp_path / "test.tar"
        src = tmp_path / "empty.bin"
        src.write_bytes(b"")

        with TarWriter(tar_path) as tw:
            offset, length = tw.append("GUID-001", src, "empty.bin")

        assert length == 0

    def test_context_manager(self, tmp_path: Path) -> None:
        tar_path = tmp_path / "test.tar"
        src = tmp_path / "f.bin"
        src.write_bytes(b"ctx")
        with TarWriter(tar_path) as tw:
            tw.append("GUID-001", src)
        # Should not raise after close

    def test_offset_correct_for_long_name_pax_header(self, tmp_path: Path) -> None:
        """Regression: when the tar entry name exceeds 100 chars (POSIX
        ustar limit), Python's tarfile prepends PAX extended headers
        (extra 512-byte blocks). The returned tar_offset must still
        point at the real file data — verified by reading those exact
        bytes and confirming the SHA-256 matches.

        Without the PAX-safe offset calculation, this test fails with
        a SHA mismatch (the very bug that real iMessage `at_0_*` GUIDs
        with long filenames hit in production).
        """
        tar_path = tmp_path / "long.tar"
        src = tmp_path / "data.bin"
        payload = b"PAYLOAD" * 8000  # 56 KB so it crosses block boundaries
        src.write_bytes(payload)
        expected_sha = hashlib.sha256(payload).hexdigest()

        # Real iMessage GUID with at_0_ prefix (longer than 36 chars).
        long_guid = "at_0_49B49FFB-9663-4453-A5B5-4D11CE2E6E28"
        # Real-world long filename (truncated at 80 chars internally).
        long_filename = "E-ticket for Williams Zara Lily Ms departing on 12DEC2018 for SIN-SYD.pdf"

        with TarWriter(tar_path) as tw:
            tar_offset, tar_length = tw.append(long_guid, src, long_filename)

        # Read exactly tar_length bytes starting at tar_offset and verify
        # the SHA matches the original payload.
        with tar_path.open("rb") as f:
            f.seek(tar_offset)
            data = f.read(tar_length)
        assert len(data) == tar_length
        actual_sha = hashlib.sha256(data).hexdigest()
        assert actual_sha == expected_sha, (
            f"SHA mismatch — tar_offset is wrong. "
            f"Stored offset={tar_offset}, length={tar_length}, "
            f"expected sha={expected_sha[:16]}, got {actual_sha[:16]}"
        )

    def test_offset_correct_for_short_name_no_pax(self, tmp_path: Path) -> None:
        """Positive control: same SHA check but with a short entry name
        that fits in 100 chars (no PAX headers). Must also pass."""
        tar_path = tmp_path / "short.tar"
        src = tmp_path / "data.bin"
        payload = b"hello world\n" * 1000
        src.write_bytes(payload)
        expected_sha = hashlib.sha256(payload).hexdigest()

        with TarWriter(tar_path) as tw:
            tar_offset, tar_length = tw.append("SHORT-GUID-123", src, "f.bin")

        with tar_path.open("rb") as f:
            f.seek(tar_offset)
            data = f.read(tar_length)
        assert hashlib.sha256(data).hexdigest() == expected_sha
        assert tar_path.exists()
