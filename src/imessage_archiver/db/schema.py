"""Schema constants for the Apple chat.db source database."""

from __future__ import annotations

# ── Source table names ───────────────────────────────────────────────────────
TABLE_MESSAGE = "message"
TABLE_HANDLE = "handle"
TABLE_CHAT = "chat"
TABLE_ATTACHMENT = "attachment"
TABLE_CHAT_MESSAGE_JOIN = "chat_message_join"
TABLE_CHAT_HANDLE_JOIN = "chat_handle_join"
TABLE_MESSAGE_ATTACHMENT_JOIN = "message_attachment_join"
TABLE_DB_PROPERTIES = "_SqliteDatabaseProperties"

# ── Column sets (avoids SELECT *) ────────────────────────────────────────────
CHAT_COLS = """
    guid,
    display_name,
    chat_identifier,
    service_name,
    is_archived,
    room_name,
    group_id
""".strip()

MESSAGE_COLS = """
    m.guid,
    m.text,
    m.attributedBody,
    m.date,
    m.is_from_me,
    m.handle_id,
    m.service,
    m.associated_message_guid,
    m.associated_message_type,
    m.thread_originator_guid,
    m.reply_to_guid,
    m.cache_has_attachments,
    m.date_edited,
    m.date_retracted
""".strip()

ATTACHMENT_COLS = """
    a.guid,
    a.filename,
    a.mime_type,
    a.uti,
    a.total_bytes,
    a.transfer_name,
    a.is_sticker
""".strip()

HANDLE_COLS = "h.id, h.service"

# ── Tapback associated_message_type ranges ───────────────────────────────────
TAPBACK_ADD_MIN = 2000
TAPBACK_ADD_MAX = 2005
TAPBACK_REMOVE_MIN = 3000
TAPBACK_REMOVE_MAX = 3005

TAPBACK_TYPE_NAMES: dict[int, str] = {
    2000: "love",
    2001: "like",
    2002: "dislike",
    2003: "laugh",
    2004: "emphasize",
    2005: "question",
}


def is_tapback(associated_message_type: int) -> bool:
    """Return True if this message row is a tapback (add or remove)."""
    return (
        TAPBACK_ADD_MIN <= associated_message_type <= TAPBACK_ADD_MAX
        or TAPBACK_REMOVE_MIN <= associated_message_type <= TAPBACK_REMOVE_MAX
    )


def tapback_base_type(associated_message_type: int) -> int:
    """Normalise remove (3000-3005) back to add (2000-2005) for name lookup."""
    if TAPBACK_REMOVE_MIN <= associated_message_type <= TAPBACK_REMOVE_MAX:
        return associated_message_type - 1000
    return associated_message_type


def tapback_is_remove(associated_message_type: int) -> bool:
    return TAPBACK_REMOVE_MIN <= associated_message_type <= TAPBACK_REMOVE_MAX
