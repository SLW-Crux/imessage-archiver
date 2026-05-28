"""Append-mode POSIX ustar tar writer.

Each call to :func:`append` writes one file entry and returns
``(offset, length)`` where *offset* is the byte position of the first
file-data byte (header_start + 512) and *length* is the raw file size
(not padded).  The iOS reader does ``seek(offset); read(length)``.
"""

from __future__ import annotations

import os
import tarfile
from pathlib import Path

_HEADER_SIZE = 512
_BLOCK_SIZE = 512


def _tar_entry_name(attachment_guid: str, filename: str | None) -> str:
    """Build a safe tar entry name ≤ 100 chars (ustar path limit)."""
    if filename:
        basename = Path(filename).name
        # Strip leading dots to avoid hidden-file confusion
        safe = basename.lstrip(".")[:80] or "file"
        return f"{attachment_guid[:36]}-{safe}"
    return attachment_guid[:36]


class TarWriter:
    """Append-mode tar writer for attachments.tar.

    Opens the tar in append mode if it already exists; creates it if not.
    Call :meth:`close` (or use as a context manager) to finalize.
    """

    def __init__(self, path: Path) -> None:
        self._path = path
        if path.exists():
            # Open existing tar in append mode (r|* would strip end-of-archive blocks)
            self._tar = tarfile.open(str(path), "a:")
        else:
            self._tar = tarfile.open(str(path), "w:")
        # Cache file descriptor for offset tracking
        self._fd = self._tar.fileobj

    # ------------------------------------------------------------------
    def append(
        self,
        attachment_guid: str,
        source_path: Path,
        filename: str | None = None,
    ) -> tuple[int, int]:
        """Append *source_path* to the tar.

        Returns ``(tar_offset, tar_length)`` where ``tar_offset`` is the
        byte position of the first file-data byte.
        """
        entry_name = _tar_entry_name(attachment_guid, filename)
        file_size = source_path.stat().st_size

        # Seek to end of existing content (before the end-of-archive blocks)
        # tarfile "a:" mode positions the file pointer before EOA blocks
        header_start = self._fd.tell()

        info = tarfile.TarInfo(name=entry_name)
        info.size = file_size
        info.mtime = int(source_path.stat().st_mtime)
        info.mode = 0o644
        info.type = tarfile.REGTYPE

        with source_path.open("rb") as fh:
            self._tar.addfile(info, fh)
        # Flush Python buffers AND fsync the OS page cache before returning.
        # Without fsync, a SIGKILL between this append and the SQLite commit
        # that records (tar_offset, tar_length) would leave the SQLite row
        # pointing at bytes that are still in the page cache and never on disk.
        fileobj = self._tar.fileobj
        if fileobj is not None and hasattr(fileobj, "flush"):
            fileobj.flush()
            fileno = getattr(fileobj, "fileno", None)
            if callable(fileno):
                try:
                    os.fsync(fileno())
                except OSError:
                    # Some filesystems / fileobj wrappers don't support fsync.
                    # Durability is best-effort on those paths.
                    pass

        tar_offset = header_start + _HEADER_SIZE
        return tar_offset, file_size

    # ------------------------------------------------------------------
    def close(self) -> None:
        self._tar.close()

    def __enter__(self) -> TarWriter:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
