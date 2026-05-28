"""Incremental merge — archive new messages from a fresh chat.db snapshot.

On first run, ArchiveWriter.run() archives everything.
On subsequent runs, this module identifies only new messages/attachments
since the last archive run and writes them incrementally.

Because all writes use INSERT OR IGNORE, running a full archive again
is always safe — it just won't overwrite existing rows.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from imessage_archiver.core.archive import ArchiveWriter, RunStats
from imessage_archiver.db.reader import ChatRow, Reader
from imessage_archiver.db.snapshot import snapshot

ProgressCallback = Callable[[ChatRow, RunStats], None]


def merge(
    bundle_path: Path,
    source_db: Path | None = None,
    work_root: Path | None = None,
    progress: ProgressCallback | None = None,
) -> RunStats:
    """Snapshot *source_db* and merge new messages into *bundle_path*.

    This is a thin wrapper around :class:`ArchiveWriter` that:
    1. Takes a fresh VACUUM INTO snapshot of *source_db*.
    2. Runs :meth:`ArchiveWriter.run` (INSERT OR IGNORE skips known rows).
    3. Returns stats about what was written.

    Because ArchiveWriter uses INSERT OR IGNORE, this function is idempotent —
    running it twice produces the same result.
    """
    if work_root is None:
        work_root = Path.home() / ".imessage-archiver" / "work"

    snap_path, sha256 = snapshot(
        source=source_db or _default_chat_db(),
        work_root=work_root,
    )

    with Reader(snap_path) as reader:
        with ArchiveWriter(bundle_path) as writer:
            stats = writer.run(
                reader,
                source_sha256=sha256,
                source_db_path=str(source_db or _default_chat_db()),
                progress=progress,
            )

    return stats


def _default_chat_db() -> Path:
    return Path.home() / "Library" / "Messages" / "chat.db"
