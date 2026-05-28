"""Archive writer — builds and updates the .imarchive bundle.

Non-destructive guarantees enforced here:
- All SQL writes use INSERT OR IGNORE (keyed on Apple GUIDs).
- archive.sqlite is written atomically (.tmp → rename) on first build.
- attachments.tar is append-only.
- manifest.json is written atomically (.tmp → rename) on every run.
"""

from __future__ import annotations

import json
import platform
import sqlite3
import time
import uuid
from collections.abc import Callable
from pathlib import Path

from imessage_archiver import __version__
from imessage_archiver.core.attachments import AttachmentState, classify, sha256_file
from imessage_archiver.core.tar_writer import TarWriter
from imessage_archiver.db.reader import AttachmentRow, ChatRow, MessageRow, Reader
from imessage_archiver.db.schema import TAPBACK_TYPE_NAMES, tapback_base_type

_SCHEMA_VERSION = 1
_DDL = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS chats (
  chat_guid           TEXT PRIMARY KEY,
  display_name        TEXT,
  chat_identifier     TEXT,
  service_name        TEXT,
  is_group            INTEGER,
  participants_json   TEXT,
  first_message_at    INTEGER,
  last_message_at     INTEGER,
  message_count       INTEGER
);

CREATE TABLE IF NOT EXISTS messages (
  message_guid            TEXT PRIMARY KEY,
  chat_guid               TEXT NOT NULL REFERENCES chats(chat_guid),
  sender_handle           TEXT,
  sender_name             TEXT,
  timestamp               INTEGER NOT NULL,
  text                    TEXT,
  is_from_me              INTEGER NOT NULL,
  service                 TEXT,
  reply_to_guid           TEXT,
  associated_message_guid TEXT,
  associated_message_type INTEGER,
  reactions_json          TEXT,
  has_attachments         INTEGER NOT NULL,
  date_edited             INTEGER,
  date_retracted          INTEGER
);

CREATE TABLE IF NOT EXISTS attachments (
  attachment_guid  TEXT PRIMARY KEY,
  message_guid     TEXT NOT NULL REFERENCES messages(message_guid),
  filename         TEXT,
  mime_type        TEXT,
  uti              TEXT,
  size             INTEGER,
  sha256           TEXT,
  tar_offset       INTEGER,
  tar_length       INTEGER,
  state            TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS archive_runs (
  run_id                   TEXT PRIMARY KEY,
  started_at               INTEGER NOT NULL,
  completed_at             INTEGER,
  source_db_sha256         TEXT,
  source_db_path           TEXT,
  message_count            INTEGER,
  attachment_count         INTEGER,
  missing_attachment_count INTEGER,
  archiver_version         TEXT
);

CREATE TABLE IF NOT EXISTS schema_migrations (
  version    INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  message_guid UNINDEXED,
  text,
  sender_name,
  content='messages',
  content_rowid='rowid'
);

CREATE INDEX IF NOT EXISTS idx_messages_chat      ON messages(chat_guid, timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_guid);
"""


class ArchiveWriter:
    """Builds or incrementally updates an .imarchive bundle.

    Usage::

        with ArchiveWriter(bundle_path) as w:
            w.run(reader, source_sha256=sha)
    """

    def __init__(self, bundle_path: Path) -> None:
        self._bundle = bundle_path
        self._sqlite_path = bundle_path / "archive.sqlite"
        self._tar_path = bundle_path / "attachments.tar"
        self._manifest_path = bundle_path / "manifest.json"
        self._conn: sqlite3.Connection | None = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def run(
        self,
        reader: Reader,
        source_sha256: str = "",
        source_db_path: str = "",
        progress: ProgressCallback | None = None,
    ) -> RunStats:
        """Archive all messages and attachments from *reader* into the bundle."""
        run_id = str(uuid.uuid4())
        started_at = int(time.time())

        self._bundle.mkdir(parents=True, exist_ok=True)
        self._open_db()
        assert self._conn is not None

        run_rowid = self._start_run(run_id, started_at, source_sha256, source_db_path)

        stats = RunStats()
        chats = reader.list_chats()

        with TarWriter(self._tar_path) as tar:
            for chat in chats:
                self._insert_chat(chat)
                messages = reader.messages_in_chat(chat.chat_guid)
                for msg in messages:
                    inserted = self._insert_message(msg)
                    if inserted:
                        stats.messages_written += 1
                    stats.messages_seen += 1

                    atts = reader.attachments_for_message(msg.message_guid)
                    for att in atts:
                        att_stats = self._insert_attachment(att, tar)
                        stats.attachments_seen += 1
                        if att_stats.written:
                            stats.attachments_written += 1
                        if att_stats.state == AttachmentState.MISSING:
                            stats.attachments_missing += 1

                if progress:
                    progress(chat, stats)

            # Denormalise tapbacks into reactions_json
            self._rebuild_reactions()

        self._finish_run(run_rowid, stats, started_at)
        self._write_manifest(source_sha256, stats)
        return stats

    def close(self) -> None:
        if self._conn:
            self._conn.close()
            self._conn = None

    def __enter__(self) -> ArchiveWriter:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _open_db(self) -> None:
        is_new = not self._sqlite_path.exists()
        tmp = self._sqlite_path.with_suffix(".tmp") if is_new else None

        target = tmp if tmp else self._sqlite_path
        conn = sqlite3.connect(str(target))
        conn.executescript(_DDL)
        if is_new:
            conn.execute(
                "INSERT OR IGNORE INTO schema_migrations VALUES (?, ?)",
                (_SCHEMA_VERSION, int(time.time())),
            )
        conn.commit()

        if is_new and tmp:
            conn.close()
            tmp.rename(self._sqlite_path)
            conn = sqlite3.connect(str(self._sqlite_path))
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")

        self._conn = conn

    def _start_run(
        self,
        run_id: str,
        started_at: int,
        source_sha256: str,
        source_db_path: str,
    ) -> int:
        assert self._conn
        cur = self._conn.execute(
            """INSERT INTO archive_runs(run_id, started_at, source_db_sha256, source_db_path,
               archiver_version) VALUES (?, ?, ?, ?, ?)""",
            (run_id, started_at, source_sha256, source_db_path, __version__),
        )
        self._conn.commit()
        return cur.lastrowid  # type: ignore[return-value]

    def _finish_run(self, run_rowid: int, stats: RunStats, started_at: int) -> None:
        assert self._conn
        self._conn.execute(
            """UPDATE archive_runs SET completed_at=?, message_count=?,
               attachment_count=?, missing_attachment_count=? WHERE rowid=?""",
            (
                int(time.time()),
                stats.messages_seen,
                stats.attachments_seen,
                stats.attachments_missing,
                run_rowid,
            ),
        )
        self._conn.commit()

    def _insert_chat(self, chat: ChatRow) -> None:
        assert self._conn
        self._conn.execute(
            """INSERT OR IGNORE INTO chats(
                chat_guid, display_name, chat_identifier, service_name, is_group,
                participants_json, first_message_at, last_message_at, message_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                chat.chat_guid,
                chat.display_name,
                chat.chat_identifier,
                chat.service_name,
                int(chat.is_group),
                json.dumps(chat.participants or []),
                chat.first_message_at,
                chat.last_message_at,
                chat.message_count,
            ),
        )
        self._conn.commit()

    def _insert_message(self, msg: MessageRow) -> bool:
        """Insert message row and FTS entry. Returns True if newly inserted."""
        assert self._conn
        cur = self._conn.execute(
            """INSERT OR IGNORE INTO messages(
                message_guid, chat_guid, sender_handle, sender_name, timestamp,
                text, is_from_me, service, reply_to_guid, associated_message_guid,
                associated_message_type, has_attachments, date_edited, date_retracted
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                msg.message_guid,
                msg.chat_guid,
                msg.sender_handle,
                msg.sender_name,
                msg.timestamp,
                msg.text,
                int(msg.is_from_me),
                msg.service,
                msg.reply_to_guid,
                msg.associated_message_guid,
                msg.associated_message_type,
                int(msg.has_attachments),
                msg.date_edited,
                msg.date_retracted,
            ),
        )
        inserted = cur.rowcount > 0
        if inserted and msg.text:
            # Maintain FTS5 external-content index
            self._conn.execute(
                "INSERT INTO messages_fts(message_guid, text, sender_name) VALUES (?, ?, ?)",
                (msg.message_guid, msg.text, msg.sender_name),
            )
        self._conn.commit()
        return inserted

    def _insert_attachment(
        self,
        att: AttachmentRow,
        tar: TarWriter,
    ) -> _AttStats:
        assert self._conn
        state = classify(att)
        tar_offset: int | None = None
        tar_length: int | None = None
        sha256: str | None = None

        if state == AttachmentState.LOCAL_PRESENT and att.resolved_path:
            # Check if already archived (INSERT OR IGNORE will skip if exists)
            existing = self._conn.execute(
                "SELECT tar_offset FROM attachments WHERE attachment_guid=?",
                (att.attachment_guid,),
            ).fetchone()
            if existing is None:
                tar_offset, tar_length = tar.append(
                    att.attachment_guid,
                    att.resolved_path,
                    att.filename,
                )
                sha256 = sha256_file(att.resolved_path)

        cur = self._conn.execute(
            """INSERT OR IGNORE INTO attachments(
                attachment_guid, message_guid, filename, mime_type, uti,
                size, sha256, tar_offset, tar_length, state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                att.attachment_guid,
                att.message_guid,
                att.filename,
                att.mime_type,
                att.uti,
                att.size,
                sha256,
                tar_offset,
                tar_length,
                state.value,
            ),
        )
        self._conn.commit()
        return _AttStats(written=cur.rowcount > 0, state=state)

    def _rebuild_reactions(self) -> None:
        """Denormalise tapback messages into their target message's reactions_json."""
        assert self._conn
        tapbacks = self._conn.execute(
            """SELECT associated_message_guid, associated_message_type,
                      sender_name, sender_handle, timestamp
               FROM messages
               WHERE associated_message_type > 0
               ORDER BY timestamp""",
        ).fetchall()

        # Build dict: target_guid → list of active reactions
        reactions: dict[str, list[dict[str, object]]] = {}
        for target_guid, msg_type, sender_name, sender_handle, ts in tapbacks:
            if not target_guid:
                continue
            reactions.setdefault(target_guid, [])
            base = tapback_base_type(msg_type)
            from_name = sender_name or sender_handle or "Unknown"
            type_name = TAPBACK_TYPE_NAMES.get(base, "unknown")

            from imessage_archiver.db.schema import tapback_is_remove

            if tapback_is_remove(msg_type):
                # Remove any existing reaction from this sender of this type
                reactions[target_guid] = [
                    r
                    for r in reactions[target_guid]
                    if not (r["from"] == from_name and r["type"] == type_name)
                ]
            else:
                # Upsert: replace existing reaction of same type from same sender
                reactions[target_guid] = [
                    r
                    for r in reactions[target_guid]
                    if not (r["from"] == from_name and r["type"] == type_name)
                ]
                reactions[target_guid].append(
                    {
                        "from": from_name,
                        "type": type_name,
                        "timestamp": ts,
                    }
                )

        for target_guid, reaction_list in reactions.items():
            self._conn.execute(
                "UPDATE messages SET reactions_json=? WHERE message_guid=?",
                (json.dumps(reaction_list) if reaction_list else None, target_guid),
            )
        self._conn.commit()

    def _write_manifest(self, source_sha256: str, stats: RunStats) -> None:
        existing: dict[str, object] = {}
        if self._manifest_path.exists():
            try:
                existing = json.loads(self._manifest_path.read_text())
            except Exception:
                pass

        now = _iso_now()
        tar_size = self._tar_path.stat().st_size if self._tar_path.exists() else 0

        manifest = {
            "schema_version": _SCHEMA_VERSION,
            "archiver_version": __version__,
            "created_at": existing.get("created_at", now),
            "last_updated_at": now,
            "source_db_sha256": source_sha256,
            "source_macos_version": _macos_version(),
            "chat_count": self._count("chats"),
            "message_count": self._count("messages"),
            "attachment_count": self._count("attachments"),
            "missing_attachment_count": self._count_missing(),
            "archive_size_bytes": tar_size,
        }

        tmp = self._manifest_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(manifest, indent=2))
        tmp.replace(self._manifest_path)

    def _count(self, table: str) -> int:
        assert self._conn
        result = self._conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        return int(result)

    def _count_missing(self) -> int:
        assert self._conn
        result = self._conn.execute("SELECT COUNT(*) FROM attachments WHERE state='MISSING'").fetchone()[0]
        return int(result)


# ------------------------------------------------------------------
# Small data holders
# ------------------------------------------------------------------


class RunStats:
    def __init__(self) -> None:
        self.messages_seen = 0
        self.messages_written = 0
        self.attachments_seen = 0
        self.attachments_written = 0
        self.attachments_missing = 0


class _AttStats:
    def __init__(self, written: bool, state: AttachmentState) -> None:
        self.written = written
        self.state = state


# ------------------------------------------------------------------
# Typing helpers
# ------------------------------------------------------------------

ProgressCallback = Callable[[ChatRow, RunStats], None]


def _iso_now() -> str:
    import datetime

    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _macos_version() -> str:
    try:
        return platform.mac_ver()[0]
    except Exception:
        return ""
