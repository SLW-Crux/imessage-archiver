"""Snapshot the live chat.db to a working directory using VACUUM INTO.

Using VACUUM INTO is the only safe snapshot strategy when chat.db runs in
WAL mode (which it always does on modern macOS). Copying the three files
(chat.db, chat.db-wal, chat.db-shm) with shutil.copy2 is unsafe because
Messages.app may write between copies, producing an inconsistent snapshot.
VACUUM INTO reads all committed WAL data through SQLite's own merge logic
and writes a single, clean, WAL-free file atomically.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import tempfile
from pathlib import Path

_WORK_ROOT = Path.home() / ".imessage-archiver" / "work"
_SOURCE_DB = Path.home() / "Library" / "Messages" / "chat.db"


def snapshot(
    source: Path = _SOURCE_DB,
    work_root: Path = _WORK_ROOT,
) -> tuple[Path, str]:
    """Snapshot *source* into a fresh working directory.

    Opens *source* read-only, runs ``VACUUM INTO`` to produce a clean
    single-file snapshot, then SHA-256 hashes it.

    The working directory is created via ``mkdtemp`` (mode 0o700, race-free
    against symlink attacks). The snapshot path is validated to contain
    neither single-quotes nor NUL bytes before being interpolated into
    the ``VACUUM INTO`` SQL (SQLite has no parameter binding for VACUUM).

    Returns
    -------
    snapshot_path : Path
        Absolute path to the snapshot file.
    sha256 : str
        Hex SHA-256 of the snapshot.

    Raises
    ------
    PermissionError
        If Full Disk Access has not been granted and *source* cannot be opened.
    sqlite3.DatabaseError
        If *source* is not a valid SQLite database.
    ValueError
        If the resolved snapshot path contains characters that would break
        out of the SQL literal (single-quote, NUL).
    """
    # Ensure the work root exists with restrictive perms before any tempdir
    # creation. mkdtemp inherits 0o700 by default (good), but the parent
    # may be world-readable on first run.
    work_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(work_root, 0o700)
    except OSError:
        pass

    # mkdtemp is race-free: no symlink can be pre-created at the resulting
    # path because the kernel generates the suffix atomically.
    snap_dir = Path(tempfile.mkdtemp(prefix="snapshot-", dir=str(work_root)))
    snap_path = snap_dir / "chat.db"

    # Defense-in-depth: refuse any path the SQL would interpret unexpectedly.
    snap_str = str(snap_path)
    if "'" in snap_str or "\x00" in snap_str:
        raise ValueError(f"Snapshot path contains characters unsafe for VACUUM INTO: {snap_str!r}")
    # Also assert the snapshot dir is not a symlink (defense vs. TOCTOU on
    # the work_root itself).
    if snap_dir.is_symlink():
        raise ValueError(f"Refusing to write through a symlink: {snap_dir}")

    # Open source read-only — we never write to the original.
    try:
        src = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    except sqlite3.OperationalError as exc:
        if "unable to open" in str(exc).lower():
            raise PermissionError(
                f"Cannot open {source}. Grant Full Disk Access to Terminal "
                "in System Settings → Privacy & Security."
            ) from exc
        raise

    try:
        src.execute(f"VACUUM INTO '{snap_str}'")
    finally:
        src.close()

    sha = _sha256(snap_path)
    return snap_path, sha


def _sha256(path: Path) -> str:
    """Stream-hash *path* in 1 MB chunks and return the hex digest."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()
