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
import sqlite3
import time
from pathlib import Path

_WORK_ROOT = Path.home() / ".imessage-archiver" / "work"
_SOURCE_DB = Path.home() / "Library" / "Messages" / "chat.db"


def snapshot(
    source: Path = _SOURCE_DB,
    work_root: Path = _WORK_ROOT,
) -> tuple[Path, str]:
    """Snapshot *source* into a timestamped working directory.

    Opens *source* read-only, runs ``VACUUM INTO`` to produce a clean
    single-file snapshot, then SHA-256 hashes it.

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
    """
    ts = int(time.time())
    snap_dir = work_root / f"snapshot-{ts}-{time.time_ns() % 1_000_000_000}"
    snap_dir.mkdir(parents=True, exist_ok=True)
    snap_path = snap_dir / "chat.db"

    # Open source read-only — we never write to the original
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
        src.execute(f"VACUUM INTO '{snap_path}'")
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
