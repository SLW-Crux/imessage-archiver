"""Unit tests for core/tar_writer.py."""

from __future__ import annotations

import tarfile
from pathlib import Path

from imessage_archiver.core.tar_writer import TarWriter, _tar_entry_name


class TestTarEntryName:
    def test_with_filename(self) -> None:
        name = _tar_entry_name("abc-123", "photo.jpg")
        assert name.endswith("photo.jpg")
        assert "abc-123" in name
        assert len(name) <= 100

    def test_without_filename(self) -> None:
        name = _tar_entry_name("abc-123", None)
        assert name == "abc-123"

    def test_long_filename_truncated(self) -> None:
        long_name = "a" * 200 + ".jpg"
        name = _tar_entry_name("abc-123", long_name)
        assert len(name) <= 100

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
        assert tar_path.exists()
