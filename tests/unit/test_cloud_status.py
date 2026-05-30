"""Tests for db/cloud_status.py — Messages-in-iCloud detection."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from imessage_archiver.db.cloud_status import (
    CloudStatus,
    _resolve_attachment_filesystem_path,
    inspect,
)


def _make_chat_db(
    tmp_path: Path,
    *,
    attachment_rows: list[tuple[str | None, str | None]],
) -> Path:
    """Build a minimal chat.db with `attachment` rows.

    Each row is (filename, ck_record_id). Path is None for "no filename".
    ck_record_id is None for "not CloudKit-tracked".
    """
    db = tmp_path / "chat.db"
    conn = sqlite3.connect(str(db))
    conn.execute("""CREATE TABLE attachment(
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            filename TEXT,
            ck_record_id TEXT
        )""")
    for filename, ck in attachment_rows:
        conn.execute(
            "INSERT INTO attachment(filename, ck_record_id) VALUES (?, ?)",
            (filename, ck),
        )
    conn.commit()
    conn.close()
    return db


# ----------------------------------------------------------------------
# Detection logic
# ----------------------------------------------------------------------


def test_no_attachments_returns_no_problem(tmp_path: Path) -> None:
    db = _make_chat_db(tmp_path, attachment_rows=[])
    cs = inspect(db)
    assert cs.total_attachments == 0
    assert not cs.messages_in_icloud_likely
    assert not cs.has_problem()


def test_all_local_no_ck_records_no_warning(tmp_path: Path) -> None:
    """Pre-Messages-in-iCloud chat.db has no ck_record_id values."""
    db = _make_chat_db(
        tmp_path,
        attachment_rows=[("~/Library/Messages/Attachments/x.png", None)] * 10,
    )
    cs = inspect(db)
    assert cs.total_attachments == 10
    assert cs.cloud_tracked == 0
    assert not cs.messages_in_icloud_likely
    assert not cs.has_problem()


def test_majority_cloud_tracked_triggers_messages_in_icloud(tmp_path: Path) -> None:
    """If > 50% of attachments have ck_record_id, treat as Messages in iCloud."""
    # 8 of 10 attachments have ck_record_id and are missing on disk → flagged.
    rows = [("~/Library/Messages/Attachments/missing.png", "ckrec-x")] * 8 + [
        ("~/Library/Messages/Attachments/local.png", None)
    ] * 2
    db = _make_chat_db(tmp_path, attachment_rows=rows)
    cs = inspect(db)
    assert cs.messages_in_icloud_likely
    # All 8 cloud-tracked rows reference filesystem paths that don't exist
    # in this test env, so they all count as cloud_only_unfetched.
    assert cs.cloud_only_unfetched == 8
    assert cs.has_problem()


def test_minority_cloud_tracked_does_not_trigger(tmp_path: Path) -> None:
    """A handful of historical ck_record_id rows in an otherwise-local DB
    should not falsely trip the warning."""
    rows = [("~/Library/Messages/Attachments/x.png", None)] * 9 + [
        ("~/Library/Messages/Attachments/x.png", "ckrec-x")
    ]
    db = _make_chat_db(tmp_path, attachment_rows=rows)
    cs = inspect(db)
    assert not cs.messages_in_icloud_likely
    # cloud_only_unfetched is skipped when messages_in_icloud_likely is False
    # (no point scanning if we're not warning).
    assert cs.cloud_only_unfetched == 0


def test_null_filename_skipped(tmp_path: Path) -> None:
    """Rows with NULL filename are skipped during the on-disk check."""
    rows = [(None, "ckrec-x")] * 8 + [("~/Library/Messages/Attachments/x.png", None)] * 2
    db = _make_chat_db(tmp_path, attachment_rows=rows)
    cs = inspect(db)
    assert cs.messages_in_icloud_likely
    # NULL filenames don't count toward cloud_only_unfetched.
    assert cs.cloud_only_unfetched == 0


# ----------------------------------------------------------------------
# Path resolution / containment
# ----------------------------------------------------------------------


def test_tilde_path_is_resolved() -> None:
    """A ~/Library/Messages/Attachments path is accepted and home-expanded."""
    p = _resolve_attachment_filesystem_path("~/Library/Messages/Attachments/x.png")
    assert p is not None
    assert str(p).startswith(str(Path.home() / "Library" / "Messages"))


def test_absolute_path_outside_messages_rejected() -> None:
    """Sec-M4 containment: absolute paths outside ~/Library/Messages/ → None."""
    p = _resolve_attachment_filesystem_path("/etc/passwd")
    assert p is None


def test_relative_path_rejected() -> None:
    """A bare relative filename has no safe interpretation; reject."""
    p = _resolve_attachment_filesystem_path("relative/path.png")
    assert p is None


# ----------------------------------------------------------------------
# Sanity: CloudStatus dataclass behaviour
# ----------------------------------------------------------------------


def test_has_problem_requires_both_conditions() -> None:
    """has_problem() only True when iCloud-likely AND cloud_only_unfetched > 0."""
    cs1 = CloudStatus(10, 10, 5, messages_in_icloud_likely=True)
    cs2 = CloudStatus(10, 10, 5, messages_in_icloud_likely=False)
    cs3 = CloudStatus(10, 10, 0, messages_in_icloud_likely=True)
    assert cs1.has_problem()
    assert not cs2.has_problem()  # not iCloud
    assert not cs3.has_problem()  # iCloud but nothing actually missing
