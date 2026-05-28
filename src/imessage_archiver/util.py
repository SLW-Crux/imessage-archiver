"""Cross-cutting helpers shared by core/, cli/, gui/."""

from __future__ import annotations

import datetime
import os
from pathlib import Path


def iso_now() -> str:
    """ISO-8601 UTC timestamp with a trailing Z (e.g. 2026-05-28T14:00:00Z)."""
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_write_bytes(target: Path, data: bytes) -> None:
    """Write *data* to *target* atomically.

    The pattern: write to ``<target>.tmp``, ``fsync(2)`` the file, ``close``,
    ``rename(2)`` over the target, then fsync the parent directory so the
    rename is durable across power-loss.

    This is the durability contract CLAUDE.md requires for manifest.json,
    archive.sqlite (first-create), and the lock file.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, target)
    _fsync_parent_dir(target)


def atomic_write_text(target: Path, text: str) -> None:
    """UTF-8 atomic write — see :func:`atomic_write_bytes`."""
    atomic_write_bytes(target, text.encode("utf-8"))


def _fsync_parent_dir(path: Path) -> None:
    """fsync the directory containing *path* so a prior rename is durable.

    POSIX only — on a typical macOS/Linux dev machine this is a no-op for
    most filesystems but is required to survive power-loss with the rename
    committed. On Windows this would error; we are macOS-only so it's fine.
    """
    try:
        fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        # Some filesystems (smbfs, network mounts) don't support fsync on
        # directories. Best-effort — the file rename itself is atomic on POSIX.
        pass


def fsync_file(path_or_fd: Path | int) -> None:
    """fsync(2) a file by path or open fd."""
    if isinstance(path_or_fd, Path):
        fd = os.open(str(path_or_fd), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    else:
        os.fsync(path_or_fd)
