"""Read-only queries against a snapshotted chat.db.

All connections are opened with ``mode=ro&immutable=1`` — the snapshot was
produced by VACUUM INTO so it has no WAL and will never be written by another
process.

Public API
----------
Reader(path)          — open a snapshot
.list_chats()         — list all chats
.messages_in_chat()   — all messages for a chat_guid
.attachments_for_message() — attachments for a message_guid
.all_messages()       — flat generator over all messages (for archiving)
.close()              — release the connection
"""

from __future__ import annotations

import sqlite3
from collections.abc import Generator
from dataclasses import dataclass
from pathlib import Path

from .attributed_body import extract_text
from .contacts import resolve as resolve_contact
from .epoch import apple_to_unix

# ── Data classes ─────────────────────────────────────────────────────────────


@dataclass
class ChatRow:
    chat_guid: str
    display_name: str | None
    chat_identifier: str | None
    service_name: str | None
    is_group: bool
    participants: list[str]
    first_message_at: int | None  # Unix epoch
    last_message_at: int | None
    message_count: int


@dataclass
class MessageRow:
    message_guid: str
    chat_guid: str
    sender_handle: str | None
    sender_name: str | None
    timestamp: int  # Unix epoch
    text: str | None
    is_from_me: bool
    service: str | None
    reply_to_guid: str | None
    associated_message_guid: str | None
    associated_message_type: int
    reactions_json: str | None  # pre-computed for this message (populated separately)
    has_attachments: bool
    date_edited: int | None  # Unix epoch; None = never edited
    date_retracted: int | None  # Unix epoch; None = not retracted


@dataclass
class AttachmentRow:
    attachment_guid: str
    message_guid: str
    filename: str | None
    mime_type: str | None
    uti: str | None
    size: int
    resolved_path: Path | None  # absolute Path or None if unresolvable


# ── Reader ───────────────────────────────────────────────────────────────────


class Reader:
    """Read-only interface to a snapshotted chat.db."""

    def __init__(self, path: Path) -> None:
        self._path = path
        uri = f"file:{path}?mode=ro&immutable=1"
        self._conn = sqlite3.connect(uri, uri=True)
        self._conn.row_factory = sqlite3.Row

    # ── Public API ────────────────────────────────────────────────────────

    def list_chats(self) -> list[ChatRow]:
        """Return all chats sorted by last message timestamp descending."""
        chats = self._fetch_chats()
        # Annotate with participant handles and message counts
        handle_map = self._chat_handles()
        counts = self._message_counts_per_chat()
        first_last = self._first_last_per_chat()

        result: list[ChatRow] = []
        for c in chats:
            chat_id = c["ROWID"]
            guid = c["guid"]
            participants = handle_map.get(chat_id, [])
            is_group = bool(c["room_name"]) or len(participants) > 1
            fl = first_last.get(guid, (None, None))
            result.append(
                ChatRow(
                    chat_guid=guid,
                    display_name=c["display_name"],
                    chat_identifier=c["chat_identifier"],
                    service_name=c["service_name"],
                    is_group=is_group,
                    participants=participants,
                    first_message_at=fl[0],
                    last_message_at=fl[1],
                    message_count=counts.get(guid, 0),
                )
            )
        result.sort(key=lambda r: r.last_message_at or 0, reverse=True)
        return result

    def messages_in_chat(self, chat_guid: str) -> list[MessageRow]:
        """Return all messages for *chat_guid*, ordered by timestamp."""
        chat_id = self._chat_rowid(chat_guid)
        if chat_id is None:
            return []
        rows = self._conn.execute(
            """
            SELECT
                m.guid,
                m.text,
                m.attributedBody,
                m.date,
                m.is_from_me,
                m.handle_id,
                m.service,
                m.associated_message_guid,
                m.associated_message_type,
                m.reply_to_guid,
                m.thread_originator_guid,
                m.cache_has_attachments,
                m.date_edited,
                m.date_retracted,
                h.id AS handle_id_str
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ?
            ORDER BY m.date ASC
            """,
            (chat_id,),
        ).fetchall()
        return [self._row_to_message(r, chat_guid) for r in rows]

    def attachments_for_message(self, message_guid: str) -> list[AttachmentRow]:
        """Return all attachments for *message_guid*."""
        rows = self._conn.execute(
            """
            SELECT
                a.guid,
                a.filename,
                a.mime_type,
                a.uti,
                a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            WHERE m.guid = ?
            """,
            (message_guid,),
        ).fetchall()
        return [self._row_to_attachment(r, message_guid) for r in rows]

    def all_messages(self) -> Generator[tuple[str, MessageRow], None, None]:
        """Yield (chat_guid, MessageRow) for every message in the database."""
        rows = self._conn.execute("""
            SELECT
                m.guid,
                m.text,
                m.attributedBody,
                m.date,
                m.is_from_me,
                m.handle_id,
                m.service,
                m.associated_message_guid,
                m.associated_message_type,
                m.reply_to_guid,
                m.thread_originator_guid,
                m.cache_has_attachments,
                m.date_edited,
                m.date_retracted,
                h.id AS handle_id_str,
                c.guid AS chat_guid
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            ORDER BY m.date ASC
            """)
        for row in rows:
            chat_guid = row["chat_guid"]
            yield chat_guid, self._row_to_message(row, chat_guid)

    def all_attachments(self) -> Generator[AttachmentRow, None, None]:
        """Yield every attachment row in the database."""
        rows = self._conn.execute("""
            SELECT
                a.guid,
                a.filename,
                a.mime_type,
                a.uti,
                a.total_bytes,
                m.guid AS message_guid
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            """)
        for row in rows:
            yield self._row_to_attachment(row, row["message_guid"])

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> Reader:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # ── Internal helpers ──────────────────────────────────────────────────

    def _fetch_chats(self) -> list[sqlite3.Row]:
        return self._conn.execute(
            "SELECT ROWID, guid, display_name, chat_identifier, service_name, room_name "
            "FROM chat WHERE guid IS NOT NULL"
        ).fetchall()

    def _chat_handles(self) -> dict[int, list[str]]:
        """Map chat ROWID → list of handle.id strings."""
        rows = self._conn.execute("""
            SELECT chj.chat_id, h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """).fetchall()
        result: dict[int, list[str]] = {}
        for r in rows:
            result.setdefault(r[0], []).append(r[1])
        return result

    def _message_counts_per_chat(self) -> dict[str, int]:
        rows = self._conn.execute("""
            SELECT c.guid, COUNT(*) AS cnt
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.guid
            """).fetchall()
        return {r[0]: r[1] for r in rows}

    def _first_last_per_chat(self) -> dict[str, tuple[int | None, int | None]]:
        rows = self._conn.execute("""
            SELECT c.guid, MIN(m.date), MAX(m.date)
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.guid
            """).fetchall()
        result: dict[str, tuple[int | None, int | None]] = {}
        for guid, first, last in rows:
            first_unix = apple_to_unix(first) if first else None
            last_unix = apple_to_unix(last) if last else None
            result[guid] = (first_unix, last_unix)
        return result

    def _chat_rowid(self, chat_guid: str) -> int | None:
        row = self._conn.execute("SELECT ROWID FROM chat WHERE guid = ?", (chat_guid,)).fetchone()
        return row[0] if row else None

    def _resolve_text(self, text: str | None, attributed_body: bytes | None) -> str | None:
        if text:
            return text
        if attributed_body:
            return extract_text(attributed_body)
        return None

    def _resolve_sender(self, is_from_me: int, handle_id_str: str | None) -> tuple[str | None, str | None]:
        """Return (sender_handle, sender_name)."""
        if is_from_me:
            return None, "Me"
        if not handle_id_str:
            return None, None
        name = resolve_contact(handle_id_str)
        return handle_id_str, name

    def _row_to_message(self, row: sqlite3.Row, chat_guid: str) -> MessageRow:
        is_from_me = int(row["is_from_me"])
        handle_id_str = row["handle_id_str"] if "handle_id_str" in row.keys() else None
        sender_handle, sender_name = self._resolve_sender(is_from_me, handle_id_str)
        text = self._resolve_text(
            row["text"],
            row["attributedBody"] if "attributedBody" in row.keys() else None,
        )
        raw_date = row["date"] or 0
        timestamp = apple_to_unix(raw_date) if raw_date else 0

        raw_edited = row["date_edited"] if "date_edited" in row.keys() else 0
        raw_retracted = row["date_retracted"] if "date_retracted" in row.keys() else 0
        date_edited = apple_to_unix(raw_edited) if raw_edited else None
        date_retracted = apple_to_unix(raw_retracted) if raw_retracted else None

        return MessageRow(
            message_guid=row["guid"],
            chat_guid=chat_guid,
            sender_handle=sender_handle,
            sender_name=sender_name,
            timestamp=timestamp,
            text=text,
            is_from_me=bool(is_from_me),
            service=row["service"],
            reply_to_guid=row["reply_to_guid"],
            associated_message_guid=row["associated_message_guid"],
            associated_message_type=int(row["associated_message_type"] or 0),
            reactions_json=None,  # populated by archive writer
            has_attachments=bool(int(row["cache_has_attachments"] or 0)),
            date_edited=date_edited,
            date_retracted=date_retracted,
        )

    @staticmethod
    def _row_to_attachment(row: sqlite3.Row, message_guid: str) -> AttachmentRow:
        filename = row["filename"]
        resolved: Path | None = None
        if filename:
            try:
                resolved = _resolve_attachment_path(filename)
            except Exception:
                pass
        return AttachmentRow(
            attachment_guid=row["guid"],
            message_guid=message_guid,
            filename=filename,
            mime_type=row["mime_type"],
            uti=row["uti"],
            size=int(row["total_bytes"] or 0),
            resolved_path=resolved,
        )


def _resolve_attachment_path(filename: str) -> Path:
    """Resolve an attachment filename to an absolute Path."""
    if filename.startswith("~"):
        return Path(filename).expanduser()
    if filename.startswith("/"):
        return Path(filename)
    return Path.home() / "Library" / "Messages" / filename
