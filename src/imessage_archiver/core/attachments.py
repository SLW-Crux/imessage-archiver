"""Attachment state classification and SHA-256 hashing."""

from __future__ import annotations

import hashlib
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from imessage_archiver.db.reader import AttachmentRow


class AttachmentState(StrEnum):
    LOCAL_PRESENT = "LOCAL_PRESENT"
    MISSING = "MISSING"
    ZERO_BYTE = "ZERO_BYTE"
    UNREADABLE = "UNREADABLE"


def classify(att: AttachmentRow) -> AttachmentState:
    """Return the attachment state for *att*.

    Checks whether the resolved path exists on disk and is readable.
    """
    path = att.resolved_path
    if path is None:
        return AttachmentState.MISSING

    try:
        stat = path.stat()
    except (OSError, PermissionError):
        if path.exists():
            return AttachmentState.UNREADABLE
        return AttachmentState.MISSING

    if stat.st_size == 0:
        return AttachmentState.ZERO_BYTE

    return AttachmentState.LOCAL_PRESENT


def sha256_file(path: Path) -> str:
    """Return the hex SHA-256 of *path*, streaming in 1 MB chunks."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()
