"""Detect whether 'Messages in iCloud' is active for the source chat.db
and how many local attachment files have been evicted to the cloud.

The chat.db ``attachment`` table has three columns we use:

- ``ck_record_id`` — non-NULL when the attachment is tracked in Apple's
  iMessage CloudKit container. Almost always non-NULL when Messages in
  iCloud has ever been enabled.
- ``ck_sync_state`` — sync state; > 0 means CloudKit-tracked.
- ``filename`` — the on-disk path. We compare against the filesystem to
  count how many are physically present.

When many ck_record_id rows exist but local files are missing, the user
has Messages in iCloud on AND those attachments are cloud-only — they
exist in Apple's CloudKit servers but were evicted from the local Mac
to save disk space. The archiver can only see local files; cloud-only
attachments will be classified MISSING and lost from the bundle.

Why there's no built-in "fetch from iCloud" helper:

We tried building one (the deleted core/icloud_prefetch.py) that drove
Messages.app via AppleScript / System Events to trigger CloudKit fetches.
On macOS 26 (Tahoe) it didn't work because:

- ``System Events → process "Messages"`` introspection returns
  ``AppleEvent timed out`` (-1712) — Apple has progressively locked
  down third-party UI scripting of first-party apps.
- ``tell application "Messages" to count chats`` hangs indefinitely —
  Messages.app's native AppleScript dictionary has been gutted over
  the last few macOS versions.

Apple's official paths that USED to work also no longer do reliably:

- Toggling off "Messages in iCloud" in Messages → Settings used to
  trigger a "Download Messages from iCloud" dialog. On macOS 26 the
  dialog doesn't appear and no download happens.
- System Settings → iCloud → Manage Storage → Messages: even when
  this exposes a download action, users report it does not download
  the full history reliably.

Apple's privacy data export (privacy.apple.com → "Get a copy of your
data") was also briefly recommended but DOES NOT include iMessage
content. Apple's stated reason is end-to-end encryption; their Legal
Process Guidelines back this up — they return only iMessage lookup
metadata, never message content, even to law enforcement.

So the warning in cli/commands.py honestly tells users the only routes
that have any real chance of recovering more: running the archiver on
the user's primary Messages device (which often has a higher local
cache hit rate), or extracting from an unencrypted Finder iPhone backup
with a tool like imessage-exporter. Both are outside this project's
scope. Detection + manifest fields are what we can reliably ship.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path


@dataclass
class CloudStatus:
    """Cloud-vs-local statistics for the source chat.db."""

    total_attachments: int
    cloud_tracked: int  # ck_record_id IS NOT NULL
    cloud_only_unfetched: int  # ck_record_id non-NULL AND file not on disk
    messages_in_icloud_likely: bool

    def has_problem(self) -> bool:
        """True if Messages in iCloud is on AND many attachments aren't local."""
        return self.messages_in_icloud_likely and self.cloud_only_unfetched > 0


def inspect(db_path: Path) -> CloudStatus:
    """Inspect the source chat.db (read-only) for cloud-only attachments.

    Opens *db_path* with ``mode=ro&immutable=1``. The caller MUST pass a
    snapshot path, not the live ``~/Library/Messages/chat.db``.
    """
    uri = f"file:{db_path}?mode=ro&immutable=1"
    conn = sqlite3.connect(uri, uri=True)
    try:
        row = conn.execute("""SELECT
                   COUNT(*) AS total,
                   SUM(CASE WHEN ck_record_id IS NOT NULL THEN 1 ELSE 0 END) AS cloud_tracked
               FROM attachment""").fetchone()
        total = int(row[0] or 0)
        cloud_tracked = int(row[1] or 0)

        # A bundle is "Messages in iCloud" if a meaningful fraction of
        # attachments have CloudKit record IDs. Threshold = 50% so a tiny
        # number of historical CK rows in an otherwise-local DB don't
        # trigger the warning.
        messages_in_icloud_likely = total > 0 and cloud_tracked > (total // 2)

        # Walk only the cloud-tracked rows. For each, resolve the filename
        # and stat the path; if missing the user has evicted-to-cloud data.
        cloud_only = 0
        if messages_in_icloud_likely:
            rows = conn.execute("SELECT filename FROM attachment WHERE ck_record_id IS NOT NULL")
            for (filename,) in rows:
                if not filename:
                    continue
                resolved = _resolve_attachment_filesystem_path(filename)
                if resolved is None or not resolved.exists():
                    cloud_only += 1

        return CloudStatus(
            total_attachments=total,
            cloud_tracked=cloud_tracked,
            cloud_only_unfetched=cloud_only,
            messages_in_icloud_likely=messages_in_icloud_likely,
        )
    finally:
        conn.close()


def _resolve_attachment_filesystem_path(filename: str) -> Path | None:
    """Expand a chat.db ``filename`` to a Path. Returns None for paths
    that resolve outside ~/Library/Messages/ (mirrors the writer's
    containment policy — Sec-M4 from the code review).
    """
    if filename.startswith("~"):
        candidate = Path(filename).expanduser()
    elif filename.startswith("/"):
        candidate = Path(filename)
    else:
        return None

    try:
        resolved = candidate.resolve(strict=False)
    except OSError:
        return None

    messages_root = (Path.home() / "Library" / "Messages").resolve(strict=False)
    try:
        resolved.relative_to(messages_root)
        return resolved
    except ValueError:
        return None
