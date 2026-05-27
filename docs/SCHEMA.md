# Archive Bundle Schema — FROZEN at schema_version 1

This document is the contract between the Mac archiver and the iOS reader.
**Do not change this document without bumping schema_version and writing a migration.**

---

## Bundle Layout

```
archive.imarchive/
├── archive.sqlite      — all messages, threads, FTS5 index, migration tracking
├── attachments.tar     — concatenated attachment files (POSIX ustar format)
└── manifest.json       — schema version, counts, source hashes, timestamps
```

Verification logs are written to `~/.imessage-archiver/logs/verify-{timestamp}.log`
(local only, not synced to iCloud).

---

## archive.sqlite Schema

```sql
CREATE TABLE chats (
  chat_guid           TEXT PRIMARY KEY,   -- Apple's stable chat.guid
  display_name        TEXT,
  chat_identifier     TEXT,               -- phone number, email, or group ID
  service_name        TEXT,               -- iMessage, SMS, RCS
  is_group            INTEGER,
  participants_json   TEXT,               -- JSON array of handle strings
  first_message_at    INTEGER,            -- Unix epoch seconds
  last_message_at     INTEGER,
  message_count       INTEGER
);

CREATE TABLE messages (
  message_guid            TEXT PRIMARY KEY,  -- Apple's stable message.guid
  chat_guid               TEXT NOT NULL REFERENCES chats(chat_guid),
  sender_handle           TEXT,              -- phone or email
  sender_name             TEXT,              -- resolved via Contacts.framework
  timestamp               INTEGER NOT NULL,  -- Unix epoch seconds
  text                    TEXT,              -- resolved from text or attributedBody; NULL = attachment-only
  is_from_me              INTEGER NOT NULL,
  service                 TEXT,
  reply_to_guid           TEXT,              -- thread reply: references messages.message_guid
  associated_message_guid TEXT,              -- tapback target: references messages.message_guid
  associated_message_type INTEGER,           -- 0 = normal, 2000-2005 = tapback added, 3000-3005 = tapback removed
  reactions_json          TEXT,              -- denormalised tapbacks on THIS message (JSON array)
  has_attachments         INTEGER NOT NULL,
  date_edited             INTEGER,           -- Unix epoch of last edit; NULL if never edited (Sonoma+)
  date_retracted          INTEGER            -- Unix epoch of unsend; NULL if not retracted (Sonoma+)
);

CREATE TABLE attachments (
  attachment_guid  TEXT PRIMARY KEY,         -- Apple's stable attachment.guid
  message_guid     TEXT NOT NULL REFERENCES messages(message_guid),
  filename         TEXT,
  mime_type        TEXT,
  uti              TEXT,
  size             INTEGER,
  sha256           TEXT,
  tar_offset       INTEGER,  -- byte offset of file DATA in attachments.tar (past 512-byte ustar header); NULL if not LOCAL_PRESENT
  tar_length       INTEGER,  -- raw file byte count (not padded); NULL if not LOCAL_PRESENT
  state            TEXT NOT NULL  -- LOCAL_PRESENT | MISSING | ZERO_BYTE | UNREADABLE
);

CREATE TABLE archive_runs (
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

CREATE TABLE schema_migrations (
  version    INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL
);
-- Seed row on creation: INSERT INTO schema_migrations VALUES (1, <unix_epoch>)

CREATE VIRTUAL TABLE messages_fts USING fts5(
  message_guid UNINDEXED,
  text,
  sender_name,
  content='messages',
  content_rowid='rowid'
);

CREATE INDEX idx_messages_chat      ON messages(chat_guid, timestamp);
CREATE INDEX idx_messages_timestamp ON messages(timestamp);
CREATE INDEX idx_attachments_message ON attachments(message_guid);
```

### Key invariants

- All writes use `INSERT OR IGNORE` keyed on Apple GUIDs — rows are never deleted or updated (except `reactions_json` updates for tapbacks and FTS maintenance).
- `tar_offset` points to the first byte of FILE DATA (= header_start + 512). iOS reader: `seek(tar_offset)`, `read(tar_length)`.
- Tapback messages are stored as normal `messages` rows (`associated_message_type != 0`) AND their effect is denormalised into the target message's `reactions_json`.

---

## attachments.tar Format

- **Format:** POSIX ustar (no PAX extensions required — filenames are `{attachment_guid}-{safe_basename}`, guaranteed ≤ 100 chars)
- **Entry layout:** 512-byte header block + file data + zero-padding to next 512-byte boundary
- **`tar_offset`:** byte position of the first file-data byte (= header start + 512)
- **`tar_length`:** raw file byte count (not padded)
- **Append-only:** existing entries are never moved; new entries are always appended

---

## manifest.json

```json
{
  "schema_version": 1,
  "archiver_version": "0.1.0",
  "created_at": "2026-05-27T00:00:00Z",
  "last_updated_at": "2026-05-27T00:00:00Z",
  "source_db_sha256": "<hex>",
  "source_macos_version": "14.5",
  "chat_count": 0,
  "message_count": 0,
  "attachment_count": 0,
  "missing_attachment_count": 0,
  "archive_size_bytes": 0
}
```

- `created_at` is set once on first archive and never changed.
- `last_updated_at` is updated on every archive run.
- `archive_size_bytes` = size of `attachments.tar` at completion.

---

## reactions_json format

Stored on the target message, not the tapback message:

```json
[
  {"from": "Alice", "type": "love",  "timestamp": 1716800000},
  {"from": "Bob",   "type": "like",  "timestamp": 1716800050}
]
```

Types: `love`, `like`, `dislike`, `laugh`, `emphasize`, `question`

---

## Schema migration policy

1. Read `MAX(version) FROM schema_migrations` on open (absent = version 0, legacy).
2. Apply migrations sequentially (additive `ALTER TABLE … ADD COLUMN` only).
3. Insert new row into `schema_migrations` and update `manifest.json schema_version`.
4. Both Mac and iOS refuse to open a bundle with `schema_version` newer than their compiled-in maximum.
