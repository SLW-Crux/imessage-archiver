"""
Synthetic chat.db fixture generator.

Creates realistic SQLite databases that match the Apple chat.db schema
without using any real Messages data.

Run directly: python tests/fixtures/generate.py
"""

from __future__ import annotations

import plistlib
import random
import sqlite3
import time
from pathlib import Path

FIXTURES_DIR = Path(__file__).parent
ATTACHMENTS_DIR = FIXTURES_DIR / "Attachments"
ATTACHMENTS_DIR.mkdir(exist_ok=True)

# Apple epoch: seconds since 2001-01-01 00:00:00 UTC
APPLE_EPOCH_OFFSET = 978307200
# Use nanoseconds for Sonoma+ style timestamps
NS_OFFSET = APPLE_EPOCH_OFFSET * 1_000_000_000

HANDLES = [
    ("+14155550101", "iMessage"),
    ("+14155550102", "iMessage"),
    ("+14155550103", "SMS"),
    ("alice@example.com", "iMessage"),
    ("bob@example.com", "iMessage"),
    ("+447700900001", "iMessage"),
    ("+447700900002", "SMS"),
]

CONTACT_NAMES = {
    "+14155550101": "Alice Smith",
    "+14155550102": "Bob Jones",
    "+14155550103": "Carol White",
    "alice@example.com": "Alice Smith",
    "bob@example.com": "Bob Jones",
    "+447700900001": "Dave Brown",
    "+447700900002": "Eve Green",
}

SAMPLE_TEXTS = [
    "Hey, how are you?",
    "Good thanks! You?",
    "Doing great 😊",
    "Can we talk later?",
    "Sure, what time works?",
    "How about 3pm?",
    "Works for me",
    "See you then!",
    "Running a bit late",
    "No worries, take your time",
    "Just got here",
    "On my way!",
    "Did you see that?",
    "Unbelievable 😂",
    "I know right??",
    "What are you up to this weekend?",
    "Nothing planned, why?",
    "We should hang out",
    "Definitely!",
    "Let me know when you're free",
    "This is amazing 🔥",
    "Agreed completely",
    "Have you tried the new place downtown?",
    "Not yet, is it good?",
    "So good, you have to go",
    "Adding it to the list",
    "👍",
    "❤️",
    "Thanks for everything",
    "Of course, anytime",
]

EMOJI_CORPUS = [
    "Hello 👋 World 🌍",
    "Family: 👨‍👩‍👧‍👦",
    "Flags: 🇺🇸 🇬🇧 🇯🇵",
    "Skin tones: 👍🏻 👍🏼 👍🏽 👍🏾 👍🏿",
    "ZWJ: 👩‍💻 🧑‍🎤 👨‍🏫",
    "Regional: 🇦🇺 🇨🇦 🇩🇪",
    "Combined: 🏳️‍🌈 🏳️‍⚧️",
]

RTL_TEXTS = [
    "مرحبا كيف حالك",
    "שלום מה שלומך",
    "مرحبا بك في التطبيق",
]

TAPBACK_TYPES = {
    "love": 2000,
    "like": 2001,
    "dislike": 2002,
    "laugh": 2003,
    "emphasize": 2004,
    "question": 2005,
}


def unix_to_apple_ns(unix: float) -> int:
    """Convert Unix timestamp to Apple nanosecond epoch (Sonoma+ style)."""
    return int((unix - APPLE_EPOCH_OFFSET) * 1_000_000_000)


def make_guid(prefix: str, n: int) -> str:
    return f"{prefix.upper()}-{n:08X}-0000-0000-0000-000000000000"


def create_schema(conn: sqlite3.Connection) -> None:
    """Create the Apple chat.db schema (subset used by the archiver)."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS _SqliteDatabaseProperties (
            key   TEXT,
            value TEXT,
            UNIQUE(key)
        );

        CREATE TABLE IF NOT EXISTS handle (
            ROWID       INTEGER PRIMARY KEY AUTOINCREMENT,
            id          TEXT NOT NULL,
            country     TEXT,
            service     TEXT NOT NULL DEFAULT 'iMessage',
            uncanonicalized_id TEXT,
            person_centric_id  TEXT,
            UNIQUE(id, service)
        );

        CREATE TABLE IF NOT EXISTS chat (
            ROWID               INTEGER PRIMARY KEY AUTOINCREMENT,
            guid                TEXT UNIQUE NOT NULL,
            style               INTEGER,
            state               INTEGER,
            account_id          TEXT,
            properties          BLOB,
            chat_identifier     TEXT,
            service_name        TEXT,
            room_name           TEXT,
            account_login       TEXT,
            is_archived         INTEGER DEFAULT 0,
            last_addressed_handle TEXT,
            display_name        TEXT,
            group_id            TEXT,
            is_filtered         INTEGER DEFAULT 0,
            successful_query    INTEGER DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS message (
            ROWID                     INTEGER PRIMARY KEY AUTOINCREMENT,
            guid                      TEXT UNIQUE NOT NULL,
            text                      TEXT,
            replace                   INTEGER DEFAULT 0,
            service_center            TEXT,
            handle_id                 INTEGER DEFAULT 0,
            subject                   TEXT,
            country                   TEXT,
            attributedBody            BLOB,
            version                   INTEGER DEFAULT 0,
            type                      INTEGER DEFAULT 0,
            service                   TEXT,
            account                   TEXT,
            account_guid              TEXT,
            error                     INTEGER DEFAULT 0,
            date                      INTEGER,
            date_read                 INTEGER,
            date_delivered            INTEGER,
            is_delivered              INTEGER DEFAULT 0,
            is_finished               INTEGER DEFAULT 1,
            is_emote                  INTEGER DEFAULT 0,
            is_from_me                INTEGER DEFAULT 0,
            is_empty                  INTEGER DEFAULT 0,
            is_delayed                INTEGER DEFAULT 0,
            is_auto_reply             INTEGER DEFAULT 0,
            is_prepared               INTEGER DEFAULT 0,
            is_read                   INTEGER DEFAULT 1,
            is_system_message         INTEGER DEFAULT 0,
            is_sent                   INTEGER DEFAULT 1,
            has_dd_results            INTEGER DEFAULT 0,
            is_service_message        INTEGER DEFAULT 0,
            is_forward                INTEGER DEFAULT 0,
            was_downgraded            INTEGER DEFAULT 0,
            is_archive                INTEGER DEFAULT 0,
            cache_has_attachments     INTEGER DEFAULT 0,
            cache_roomnames           TEXT,
            was_data_detected         INTEGER DEFAULT 0,
            was_deduplicated          INTEGER DEFAULT 0,
            is_audio_message          INTEGER DEFAULT 0,
            is_played                 INTEGER DEFAULT 0,
            date_played               INTEGER,
            item_type                 INTEGER DEFAULT 0,
            other_handle              INTEGER DEFAULT 0,
            group_title               TEXT,
            group_action_type         INTEGER DEFAULT 0,
            share_status              INTEGER DEFAULT 0,
            share_direction           INTEGER DEFAULT 0,
            is_expirable              INTEGER DEFAULT 0,
            expire_state              INTEGER DEFAULT 0,
            message_action_type       INTEGER DEFAULT 0,
            message_source            INTEGER DEFAULT 0,
            associated_message_guid   TEXT,
            associated_message_type   INTEGER DEFAULT 0,
            balloon_bundle_id         TEXT,
            payload_data              BLOB,
            expressive_send_style_id  TEXT,
            associated_message_range_location INTEGER DEFAULT 0,
            associated_message_range_length   INTEGER DEFAULT 0,
            time_expressive_send_played       INTEGER DEFAULT 0,
            message_summary_info      BLOB,
            ck_sync_state             INTEGER DEFAULT 0,
            ck_record_id              TEXT,
            ck_record_change_tag      TEXT,
            destination_caller_id     TEXT,
            sr_ck_sync_state          INTEGER DEFAULT 0,
            sr_ck_record_id           TEXT,
            sr_ck_record_change_tag   TEXT,
            is_corrupt                INTEGER DEFAULT 0,
            reply_to_guid             TEXT,
            sort_id                   INTEGER,
            is_spam                   INTEGER DEFAULT 0,
            has_unseen_mention        INTEGER DEFAULT 0,
            thread_originator_guid    TEXT,
            thread_originator_part    TEXT,
            syndication_ranges        TEXT,
            synced_syndication_ranges TEXT,
            was_phone_call            INTEGER DEFAULT 0,
            after_phone_call          INTEGER DEFAULT 0,
            date_edited               INTEGER DEFAULT 0,
            date_retracted            INTEGER DEFAULT 0,
            part_count                INTEGER
        );

        CREATE TABLE IF NOT EXISTS attachment (
            ROWID          INTEGER PRIMARY KEY AUTOINCREMENT,
            guid           TEXT UNIQUE NOT NULL,
            created_date   INTEGER DEFAULT 0,
            start_date     INTEGER DEFAULT 0,
            filename       TEXT,
            uti            TEXT,
            mime_type      TEXT,
            transfer_state INTEGER DEFAULT 0,
            is_outgoing    INTEGER DEFAULT 0,
            user_info      BLOB,
            transfer_name  TEXT,
            total_bytes    INTEGER DEFAULT 0,
            is_sticker     INTEGER DEFAULT 0,
            sticker_user_info BLOB,
            attribution_info  BLOB,
            hide_attachment   INTEGER DEFAULT 0,
            ck_sync_state     INTEGER DEFAULT 0,
            ck_server_change_token_blob BLOB,
            ck_record_id      TEXT,
            original_guid     TEXT,
            is_commsafety_sensitive INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS chat_message_join (
            chat_id    INTEGER NOT NULL REFERENCES chat(ROWID),
            message_id INTEGER NOT NULL REFERENCES message(ROWID),
            message_date INTEGER DEFAULT 0,
            UNIQUE(chat_id, message_id)
        );

        CREATE TABLE IF NOT EXISTS chat_handle_join (
            chat_id   INTEGER NOT NULL REFERENCES chat(ROWID),
            handle_id INTEGER NOT NULL REFERENCES handle(ROWID),
            UNIQUE(chat_id, handle_id)
        );

        CREATE TABLE IF NOT EXISTS message_attachment_join (
            message_id    INTEGER NOT NULL REFERENCES message(ROWID),
            attachment_id INTEGER NOT NULL REFERENCES attachment(ROWID),
            UNIQUE(message_id, attachment_id)
        );

        INSERT OR IGNORE INTO _SqliteDatabaseProperties(key, value)
        VALUES ('_DKLockStepVersionKey', '11');
    """)
    conn.commit()


def insert_handle(conn: sqlite3.Connection, handle_id: str, service: str) -> int:
    cur = conn.execute(
        "INSERT OR IGNORE INTO handle(id, service) VALUES (?, ?)",
        (handle_id, service),
    )
    if cur.lastrowid:
        return cur.lastrowid
    return conn.execute("SELECT ROWID FROM handle WHERE id=? AND service=?", (handle_id, service)).fetchone()[
        0
    ]


def insert_chat(
    conn: sqlite3.Connection,
    guid: str,
    chat_identifier: str,
    service_name: str,
    display_name: str | None,
    room_name: str | None,
    handle_rowids: list[int],
) -> int:
    cur = conn.execute(
        """INSERT INTO chat(guid, chat_identifier, service_name, display_name, room_name)
           VALUES (?, ?, ?, ?, ?)""",
        (guid, chat_identifier, service_name, display_name, room_name),
    )
    chat_rowid = cur.lastrowid
    for h in handle_rowids:
        conn.execute(
            "INSERT OR IGNORE INTO chat_handle_join(chat_id, handle_id) VALUES (?, ?)",
            (chat_rowid, h),
        )
    return chat_rowid


def insert_message(
    conn: sqlite3.Connection,
    guid: str,
    text: str | None,
    handle_id: int,
    date_ns: int,
    is_from_me: int,
    service: str,
    associated_message_guid: str | None = None,
    associated_message_type: int = 0,
    reply_to_guid: str | None = None,
    thread_originator_guid: str | None = None,
    cache_has_attachments: int = 0,
    date_edited: int = 0,
    date_retracted: int = 0,
    attributed_body: bytes | None = None,
) -> int:
    cur = conn.execute(
        """INSERT INTO message(
            guid, text, handle_id, date, is_from_me, service,
            associated_message_guid, associated_message_type,
            reply_to_guid, thread_originator_guid,
            cache_has_attachments, date_edited, date_retracted,
            attributedBody
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            guid,
            text,
            handle_id,
            date_ns,
            is_from_me,
            service,
            associated_message_guid,
            associated_message_type,
            reply_to_guid,
            thread_originator_guid,
            cache_has_attachments,
            date_edited,
            date_retracted,
            attributed_body,
        ),
    )
    return cur.lastrowid


def insert_attachment(
    conn: sqlite3.Connection,
    guid: str,
    filename: str,
    mime_type: str,
    uti: str,
    total_bytes: int,
) -> int:
    cur = conn.execute(
        """INSERT INTO attachment(guid, filename, mime_type, uti, total_bytes)
           VALUES (?, ?, ?, ?, ?)""",
        (guid, filename, mime_type, uti, total_bytes),
    )
    return cur.lastrowid


def make_tiny_png() -> bytes:
    """Return a minimal valid 1×1 transparent PNG."""
    return bytes(
        [
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            0x00,
            0x00,
            0x00,
            0x0D,
            0x49,
            0x48,
            0x44,
            0x52,
            0x00,
            0x00,
            0x00,
            0x01,
            0x00,
            0x00,
            0x00,
            0x01,
            0x08,
            0x06,
            0x00,
            0x00,
            0x00,
            0x1F,
            0x15,
            0xC4,
            0x89,
            0x00,
            0x00,
            0x00,
            0x0A,
            0x49,
            0x44,
            0x41,
            0x54,
            0x78,
            0x9C,
            0x62,
            0x00,
            0x01,
            0x00,
            0x00,
            0x05,
            0x00,
            0x01,
            0x0D,
            0x0A,
            0x2D,
            0xB4,
            0x00,
            0x00,
            0x00,
            0x00,
            0x49,
            0x45,
            0x4E,
            0x44,
            0xAE,
            0x42,
            0x60,
            0x82,
        ]
    )


def write_attachment_file(guid: str, ext: str, content: bytes) -> str:
    """Write a test attachment file, return the absolute path string.

    We store absolute paths (not ~/Library style) so integration tests can
    resolve them to LOCAL_PRESENT without touching ~/Library/Messages/.
    """
    abs_path = ATTACHMENTS_DIR / f"{guid}{ext}"
    abs_path.write_bytes(content)
    return str(abs_path)


def make_attributed_body(text: str) -> bytes:
    """Build a minimal NSKeyedArchiver bplist for the given text string."""
    root = {
        "$version": 100000,
        "$archiver": "NSKeyedArchiver",
        "$top": {"root": plistlib.UID(1)},
        "$objects": [
            "$null",
            {"$class": plistlib.UID(2), "NS.string": text},
            {"$classname": "NSAttributedString", "$classes": ["NSAttributedString", "NSObject"]},
        ],
    }
    return plistlib.dumps(root, fmt=plistlib.FMT_BINARY)


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------


def build_tiny(path: Path) -> None:
    """tiny.db — 2 chats, 10 messages, 3 attachments. Smoke tests."""
    conn = sqlite3.connect(str(path))
    create_schema(conn)

    h1 = insert_handle(conn, "+14155550101", "iMessage")
    h2 = insert_handle(conn, "+14155550102", "iMessage")

    c1 = insert_chat(conn, make_guid("chat", 1), "+14155550101", "iMessage", None, None, [h1])
    c2 = insert_chat(conn, make_guid("chat", 2), "+14155550102", "iMessage", None, None, [h2])

    base = time.time() - 86400
    msg_rowids: list[int] = []
    msg_guids: list[str] = []
    for i in range(8):
        g = make_guid("msg", i + 1)
        msg_guids.append(g)
        t = unix_to_apple_ns(base + i * 300)
        chat_rowid = c1 if i < 5 else c2
        is_me = i % 2
        handle = 0 if is_me else (h1 if i < 5 else h2)
        rowid = insert_message(conn, g, SAMPLE_TEXTS[i % len(SAMPLE_TEXTS)], handle, t, is_me, "iMessage")
        msg_rowids.append(rowid)
        conn.execute(
            "INSERT INTO chat_message_join(chat_id, message_id, message_date) VALUES (?, ?, ?)",
            (chat_rowid, rowid, t),
        )

    # 3 attachments on first 3 messages
    att_data = [
        ("image/png", "public.png", ".png", make_tiny_png()),
        ("image/png", "public.png", ".png", make_tiny_png()),
        ("text/plain", "public.plain-text", ".txt", b"hello attachment"),
    ]
    for i, (mime, uti, ext, data) in enumerate(att_data):
        ag = make_guid("att", i + 1)
        fpath = write_attachment_file(ag, ext, data)
        att_rowid = insert_attachment(conn, ag, fpath, mime, uti, len(data))
        conn.execute(
            "UPDATE message SET cache_has_attachments=1 WHERE ROWID=?",
            (msg_rowids[i],),
        )
        conn.execute(
            "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (?, ?)",
            (msg_rowids[i], att_rowid),
        )

    conn.commit()
    conn.close()


def build_medium(path: Path) -> None:
    """medium.db — 50 chats, 5000 messages, 200 attachments."""
    rng = random.Random(42)
    conn = sqlite3.connect(str(path))
    create_schema(conn)

    handle_rowids = [insert_handle(conn, h, s) for h, s in HANDLES]

    chat_rowids: list[int] = []
    for i in range(50):
        participants = rng.sample(handle_rowids, rng.randint(1, 3))
        h_id, h_svc = HANDLES[handle_rowids.index(participants[0])]
        cg = make_guid("chat", i + 1)
        is_group = len(participants) > 1
        room = f"room-{i}" if is_group else None
        name = f"Group {i}" if is_group else None
        cr = insert_chat(conn, cg, h_id, h_svc, name, room, participants)
        chat_rowids.append(cr)

    base = time.time() - 365 * 86400
    att_count = 0
    for msg_i in range(5000):
        g = make_guid("msg", msg_i + 1)
        t = unix_to_apple_ns(base + msg_i * 60 + rng.uniform(-30, 30))
        chat_rowid = chat_rowids[msg_i % 50]
        is_me = rng.random() < 0.4
        handle = 0 if is_me else handle_rowids[msg_i % len(handle_rowids)]
        text = rng.choice(SAMPLE_TEXTS)
        has_att = att_count < 200 and rng.random() < 0.04
        rowid = insert_message(
            conn, g, text, handle, int(t), int(is_me), "iMessage", cache_has_attachments=int(has_att)
        )
        conn.execute(
            "INSERT INTO chat_message_join(chat_id, message_id, message_date) VALUES (?, ?, ?)",
            (chat_rowid, rowid, int(t)),
        )
        if has_att:
            ag = make_guid("att", att_count + 1)
            data = make_tiny_png()
            fpath = write_attachment_file(ag, ".png", data)
            att_rowid = insert_attachment(conn, ag, fpath, "image/png", "public.png", len(data))
            conn.execute(
                "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (?, ?)",
                (rowid, att_rowid),
            )
            att_count += 1

    conn.commit()
    conn.close()


def build_large(path: Path) -> None:
    """large.db — 200 chats, 50,000 messages, 1,000 attachments.

    Exercises pagination, FTS5 over a large corpus, and the
    tar-append + INSERT OR IGNORE incremental path. Generated on demand by
    the Phase 7 large-DB integration test, not committed.
    """
    rng = random.Random(7)
    conn = sqlite3.connect(str(path))
    create_schema(conn)

    handle_rowids = [insert_handle(conn, h, s) for h, s in HANDLES]

    chat_rowids: list[int] = []
    for i in range(200):
        participants = rng.sample(handle_rowids, rng.randint(1, 4))
        h_id, h_svc = HANDLES[handle_rowids.index(participants[0])]
        cg = make_guid("chat", 10_000 + i)
        is_group = len(participants) > 1
        room = f"room-large-{i}" if is_group else None
        name = f"Group {i}" if is_group else None
        cr = insert_chat(conn, cg, h_id, h_svc, name, room, participants)
        chat_rowids.append(cr)

    base = time.time() - 3 * 365 * 86400
    att_count = 0
    for msg_i in range(50_000):
        g = make_guid("msg", 100_000 + msg_i)
        t = unix_to_apple_ns(base + msg_i * 30 + rng.uniform(-15, 15))
        chat_rowid = chat_rowids[msg_i % 200]
        is_me = rng.random() < 0.4
        handle = 0 if is_me else handle_rowids[msg_i % len(handle_rowids)]
        text = rng.choice(SAMPLE_TEXTS)
        has_att = att_count < 1_000 and rng.random() < 0.02
        rowid = insert_message(
            conn, g, text, handle, int(t), int(is_me), "iMessage", cache_has_attachments=int(has_att)
        )
        conn.execute(
            "INSERT INTO chat_message_join(chat_id, message_id, message_date) VALUES (?, ?, ?)",
            (chat_rowid, rowid, int(t)),
        )
        if has_att:
            ag = make_guid("att", 10_000 + att_count)
            data = make_tiny_png()
            fpath = write_attachment_file(ag, ".png", data)
            att_rowid = insert_attachment(conn, ag, fpath, "image/png", "public.png", len(data))
            conn.execute(
                "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (?, ?)",
                (rowid, att_rowid),
            )
            att_count += 1

    conn.commit()
    conn.close()


def build_edge(path: Path) -> None:
    """edge.db — edge cases: null text, tapbacks, replies, emoji, RTL, edits, retractions."""
    conn = sqlite3.connect(str(path))
    create_schema(conn)

    h1 = insert_handle(conn, "+14155550101", "iMessage")
    h2 = insert_handle(conn, "+14155550102", "iMessage")
    h3 = insert_handle(conn, "+14155550103", "SMS")
    h_email = insert_handle(conn, "alice@example.com", "iMessage")

    # 1-on-1 chat
    c1 = insert_chat(conn, make_guid("chat", 1), "+14155550101", "iMessage", None, None, [h1])
    # Group chat
    c_group = insert_chat(
        conn, make_guid("chat", 2), "chat-group-1", "iMessage", "Test Group", "room-1", [h1, h2, h3]
    )
    # Email handle chat
    c_email = insert_chat(conn, make_guid("chat", 3), "alice@example.com", "iMessage", None, None, [h_email])

    base = time.time() - 7 * 86400
    msg_n = [0]

    def next_msg_guid() -> str:
        msg_n[0] += 1
        return make_guid("msg", msg_n[0])

    def t(offset_secs: float) -> int:
        return unix_to_apple_ns(base + offset_secs)

    def add(
        chat_rowid: int, text: str | None, handle: int, offset: float, is_me: int = 0, **kwargs: object
    ) -> tuple[int, str]:
        g = next_msg_guid()
        rowid = insert_message(conn, g, text, handle, t(offset), is_me, "iMessage", **kwargs)
        conn.execute(
            "INSERT INTO chat_message_join(chat_id, message_id, message_date) VALUES (?, ?, ?)",
            (chat_rowid, rowid, t(offset)),
        )
        return rowid, g

    # --- Null text (attachment-only) ---
    rowid1, g1 = add(c1, None, h1, 0, cache_has_attachments=1)
    ag1 = make_guid("att", 1)
    fpath1 = write_attachment_file(ag1, ".png", make_tiny_png())
    att1 = insert_attachment(conn, ag1, fpath1, "image/png", "public.png", len(make_tiny_png()))
    conn.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (rowid1, att1))

    # --- Both null (genuinely empty) ---
    add(c1, None, h1, 10)

    # --- attributedBody only (no text column) — exercises reader._resolve_text branch ---
    add(c1, None, h1, 15, attributed_body=make_attributed_body("via attributedBody"))

    # --- Null sender (is_from_me) ---
    add(c1, "Message from me", 0, 20, is_me=1)

    # --- Tapbacks on g1 ---
    tapback_rowid, tg = add(
        c1, None, h1, 30, associated_message_guid=g1, associated_message_type=TAPBACK_TYPES["love"]
    )
    add(c1, None, 0, 35, is_me=1, associated_message_guid=g1, associated_message_type=TAPBACK_TYPES["like"])
    # Remove tapback
    add(c1, None, h1, 40, associated_message_guid=g1, associated_message_type=TAPBACK_TYPES["love"] + 1000)

    # --- Reply thread ---
    _, g_thread_orig = add(c1, "Thread starter", h1, 50)
    add(
        c1,
        "Reply to thread",
        0,
        55,
        is_me=1,
        reply_to_guid=g_thread_orig,
        thread_originator_guid=g_thread_orig,
    )
    add(c1, "Another reply", h1, 60, reply_to_guid=g_thread_orig, thread_originator_guid=g_thread_orig)

    # --- Emoji corpus ---
    for i, emoji_text in enumerate(EMOJI_CORPUS):
        add(c1, emoji_text, h1 if i % 2 else 0, 100 + i * 5, is_me=i % 2)

    # --- RTL text ---
    for i, rtl in enumerate(RTL_TEXTS):
        add(c1, rtl, h1, 200 + i * 5)

    # --- Very long message ---
    add(c1, "A" * 10001, h1, 300)

    # --- Edited message (Sonoma+) ---
    add(c1, "This was edited", h1, 400, date_edited=unix_to_apple_ns(base + 401))

    # --- Retracted message ---
    add(c1, "This was unsent", h1, 410, date_retracted=unix_to_apple_ns(base + 411))

    # --- Same contact under phone and email ---
    add(c_email, "Via email", h_email, 500)
    add(c1, "Via phone", h1, 505)

    # --- Group chat messages ---
    for i in range(10):
        sender = [h1, h2, h3][i % 3]
        add(c_group, SAMPLE_TEXTS[i], sender, 600 + i * 10)

    # --- Multiple attachments on one message ---
    rowid_multi, _ = add(c1, "Here are some files", h1, 700, cache_has_attachments=1)
    for i in range(3):
        ag = make_guid("att", 10 + i)
        ext = ".png"
        data = make_tiny_png()
        fpath = write_attachment_file(ag, ext, data)
        att = insert_attachment(conn, ag, fpath, "image/png", "public.png", len(data))
        conn.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (rowid_multi, att))

    # --- Missing attachment (file won't exist on disk) ---
    rowid_missing, _ = add(c1, None, h1, 750, cache_has_attachments=1)
    ag_missing = make_guid("att", 20)
    att_missing = insert_attachment(
        conn,
        ag_missing,
        "~/Library/Messages/Attachments/xx/nonexistent.jpg",
        "image/jpeg",
        "public.jpeg",
        12345,
    )
    conn.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (rowid_missing, att_missing))

    # --- Zero-byte attachment ---
    rowid_zero, _ = add(c1, None, h1, 760, cache_has_attachments=1)
    ag_zero = make_guid("att", 21)
    fpath_zero = write_attachment_file(ag_zero, ".png", b"")
    att_zero = insert_attachment(conn, ag_zero, fpath_zero, "image/png", "public.png", 0)
    conn.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (rowid_zero, att_zero))

    # --- Non-ASCII filename ---
    rowid_unicode, _ = add(c1, None, h1, 770, cache_has_attachments=1)
    ag_uni = make_guid("att", 22)
    uni_data = make_tiny_png()
    fpath_uni = write_attachment_file(ag_uni, ".png", uni_data)
    fpath_uni_labeled = fpath_uni.replace(ag_uni, f"{ag_uni}-café_photo")
    att_uni = insert_attachment(conn, ag_uni, fpath_uni_labeled, "image/png", "public.png", len(uni_data))
    conn.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (rowid_unicode, att_uni))

    conn.commit()
    conn.close()


def build_schema_variant(path: Path, variant: str, extra_messages: int = 200) -> None:
    """Build a schema-variant fixture (ventura/sonoma/sequoia)."""
    conn = sqlite3.connect(str(path))
    create_schema(conn)

    h1 = insert_handle(conn, "+14155550101", "iMessage")
    c1 = insert_chat(conn, make_guid("chat", 1), "+14155550101", "iMessage", None, None, [h1])

    rng = random.Random(variant)
    base = time.time() - 30 * 86400
    for i in range(extra_messages):
        g = make_guid("msg", i + 1)
        t = unix_to_apple_ns(base + i * 120 + rng.uniform(-60, 60))
        is_me = i % 3 == 0
        handle = 0 if is_me else h1
        rowid = insert_message(
            conn,
            g,
            rng.choice(SAMPLE_TEXTS),
            handle,
            int(t),
            int(is_me),
            "iMessage" if variant != "sequoia" else "RCS",
        )
        conn.execute(
            "INSERT INTO chat_message_join(chat_id, message_id, message_date) VALUES (?, ?, ?)",
            (c1, rowid, int(t)),
        )
        if variant in ("sonoma", "sequoia") and i % 20 == 0:
            # Add a few edited messages
            conn.execute(
                "UPDATE message SET date_edited=? WHERE ROWID=?",
                (unix_to_apple_ns(base + i * 120 + 5), rowid),
            )

    conn.commit()
    conn.close()


def main() -> None:
    print("Generating test fixtures...")

    fixtures = [
        ("tiny.db", build_tiny),
        ("medium.db", build_medium),
        ("edge.db", build_edge),
    ]

    for fname, builder in fixtures:
        fpath = FIXTURES_DIR / fname
        fpath.unlink(missing_ok=True)
        builder(fpath)
        size = fpath.stat().st_size
        print(f"  {fname}: {size:,} bytes")

    for variant in ("ventura", "sonoma", "sequoia"):
        fpath = FIXTURES_DIR / f"{variant}.db"
        fpath.unlink(missing_ok=True)
        build_schema_variant(fpath, variant)
        size = fpath.stat().st_size
        print(f"  {variant}.db: {size:,} bytes")

    print("Done.")


if __name__ == "__main__":
    main()
