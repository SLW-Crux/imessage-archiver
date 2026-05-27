# iMessage Archiver — Build Plan

**Status:** Ready for implementation
**Target:** macOS 13+ archiver (Python/PySide6) + iOS 17+ reader (SwiftUI)
**Licence:** MIT
**Repo:** Public GitHub

---

## 1. Goal

Ship two apps that work together:

1. **Mac archiver** — reads `~/Library/Messages/chat.db`, writes a portable archive bundle to iCloud Drive
2. **iOS reader** — reads the archive bundle from iCloud Drive, browses threads/messages/attachments

Yearly workflow: re-archive, verify, then user enables Messages "Keep Messages: 1 Year" retention.

---

## 2. Components

1. Mac archiver (Python/PySide6, packaged via PyInstaller)
2. Archive bundle format (SQLite + single tarball of attachments)
3. iCloud Drive sync layer (Mac writes, iOS reads, no concurrent writes)
4. iOS reader app (Swift/SwiftUI, GRDB for SQLite)
5. Yearly workflow (calendar reminder, incremental merge, retention prompt)
6. Test harness (synthetic fixtures, round-trip verification, no-data-loss guarantees)

---

## 3. Tech Stack

### Mac archiver
- Python 3.12+
- CLI: `click`, terminal output: `rich`
- GUI: PySide6 (LGPL — MIT-compatible)
- macOS bridging: PyObjC (Contacts.framework, EventKit, iCloud download)
- Packaging: PyInstaller on Apple Silicon
- Tests: pytest

### iOS reader
- Swift 5.9+, SwiftUI, iOS 17+
- Xcode 15+
- GRDB.swift (SQLite, MIT)
- Custom seek-based tar reader (~150 LOC, no third-party dep)
- Apple design language (Human Interface Guidelines)

### Shared
- Archive bundle format is the contract between the two apps — frozen before either is built

---

## 4. Archive Bundle Format

```
~/iCloud Drive/iMessage Archiver/archive.imarchive/
├── archive.sqlite          # all messages, threads, manifest, FTS5 index
├── attachments.tar         # all attachment files concatenated
└── manifest.json           # schema version, created_at, counts, source hashes
```

Verification logs are written to `~/.imessage-archiver/logs/verify-{timestamp}.log` (local only, not synced to iCloud). Keeping them out of the bundle prevents unbounded iCloud re-uploads after each annual run.

### Why single tarball
iCloud Drive handles 2 large files reliably; 50,000 small files badly. Tar with seek-based reader gives O(1) random access via stored offsets.

### Schema (archive.sqlite) — FROZEN at schema_version 1

```sql
CREATE TABLE chats (
  chat_guid TEXT PRIMARY KEY,           -- Apple's stable chat.guid
  display_name TEXT,
  chat_identifier TEXT,                  -- phone number, email, or group ID
  service_name TEXT,                     -- iMessage, SMS, RCS
  is_group INTEGER,
  participants_json TEXT,                -- JSON array of handles
  first_message_at INTEGER,              -- Unix epoch
  last_message_at INTEGER,
  message_count INTEGER
);

CREATE TABLE messages (
  message_guid TEXT PRIMARY KEY,         -- Apple's stable message.guid
  chat_guid TEXT NOT NULL REFERENCES chats(chat_guid),
  sender_handle TEXT,                    -- phone or email
  sender_name TEXT,                      -- resolved via Contacts
  timestamp INTEGER NOT NULL,            -- Unix epoch
  text TEXT,                             -- resolved from text or attributedBody
  is_from_me INTEGER NOT NULL,
  service TEXT,
  reply_to_guid TEXT,                    -- thread replies
  associated_message_guid TEXT,          -- for tapbacks
  associated_message_type INTEGER,       -- 0 = regular, 2000-2005 = tapback added, 3000-3005 = tapback removed
  reactions_json TEXT,                   -- aggregated tapbacks on this message (JSON array)
  has_attachments INTEGER NOT NULL,
  date_edited INTEGER,                   -- Unix epoch of last edit; NULL if never edited (Sonoma+)
  date_retracted INTEGER                 -- Unix epoch of unsend; NULL if not retracted (Sonoma+)
);

CREATE TABLE attachments (
  attachment_guid TEXT PRIMARY KEY,      -- Apple's stable attachment.guid
  message_guid TEXT NOT NULL REFERENCES messages(message_guid),
  filename TEXT,
  mime_type TEXT,
  uti TEXT,
  size INTEGER,
  sha256 TEXT,
  tar_offset INTEGER,                    -- byte offset of file DATA in attachments.tar (past the 512-byte ustar header); NULL if not LOCAL_PRESENT
  tar_length INTEGER,                    -- raw file byte count (not padded); iOS: seek(tar_offset), read(tar_length); NULL if not LOCAL_PRESENT
  state TEXT NOT NULL                    -- LOCAL_PRESENT, MISSING, ZERO_BYTE, UNREADABLE
);

CREATE TABLE archive_runs (
  run_id TEXT PRIMARY KEY,
  started_at INTEGER NOT NULL,
  completed_at INTEGER,
  source_db_sha256 TEXT,
  source_db_path TEXT,
  message_count INTEGER,
  attachment_count INTEGER,
  missing_attachment_count INTEGER,
  archiver_version TEXT
);

CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL
);
-- Seed row inserted when archive.sqlite is first created:
-- INSERT INTO schema_migrations (version, applied_at) VALUES (1, <unix_epoch>)

CREATE VIRTUAL TABLE messages_fts USING fts5(
  message_guid UNINDEXED,
  text,
  sender_name,
  content='messages',
  content_rowid='rowid'
);

CREATE INDEX idx_messages_chat ON messages(chat_guid, timestamp);
CREATE INDEX idx_messages_timestamp ON messages(timestamp);
CREATE INDEX idx_attachments_message ON attachments(message_guid);
```

### Schema migration policy
The `schema_migrations` table is the version of record. On open:
1. Read `MAX(version) FROM schema_migrations` — if table absent, treat as version 0 (legacy).
2. Apply migrations sequentially: each migration is an `ALTER TABLE … ADD COLUMN` or index creation (additive only; no destructive DDL).
3. Bump `schema_migrations` with the new version and current timestamp.
4. Update `manifest.json` `schema_version` to match.

Migrations are additive. Columns added in future versions have `DEFAULT NULL` so existing rows remain valid. The Mac archiver and iOS reader both check `schema_version` in `manifest.json` on open and refuse to read a bundle with a schema version newer than their compiled-in maximum.

### Stable identity
Apple's `chat.guid`, `message.guid`, and `attachment.guid` are stable across re-archives. Incremental merges use `INSERT OR IGNORE` keyed on these GUIDs.

### manifest.json
```json
{
  "schema_version": 1,
  "archiver_version": "0.1.0",
  "created_at": "2026-05-27T14:32:00Z",
  "last_updated_at": "2026-05-27T14:32:00Z",
  "source_db_sha256": "...",
  "source_macos_version": "14.5",
  "chat_count": 234,
  "message_count": 487291,
  "attachment_count": 18374,
  "missing_attachment_count": 42,
  "archive_size_bytes": 23847291038
}
```

---

## 5. Identity & Linking Model

The foundation. Everything sits on this.

### Stable keys
- `chat.guid` — stable identifier for a conversation thread. Survives renames, participant changes.
- `message.guid` — stable identifier for a single message. Generated by Apple, globally unique.
- `attachment.guid` — stable identifier for an attachment.

### Linking
- `messages.chat_guid → chats.chat_guid` (every message belongs to one chat)
- `attachments.message_guid → messages.message_guid` (every attachment belongs to one message)
- `messages.reply_to_guid → messages.message_guid` (thread replies)
- `messages.associated_message_guid → messages.message_guid` (tapbacks attach to target message)

### Cross-archive merge
Two archives merge cleanly because:
- Same chat = same `chat.guid` → row already exists, skip
- Same message = same `message.guid` → row already exists, skip
- New message in existing chat = new `message.guid` → insert with existing `chat_guid` FK
- Attachment tar offsets are append-only; existing offsets never change

### What this means for the iOS app
- A conversation thread = `SELECT * FROM messages WHERE chat_guid = ? ORDER BY timestamp`
- Attachments for a message = `SELECT * FROM attachments WHERE message_guid = ?`
- Tapbacks shown on a message = `SELECT * FROM messages WHERE associated_message_guid = ?`
- After re-archive, threads continue seamlessly because GUIDs are stable

---

## 6. iCloud Sync Model

### Container
Custom iCloud container: `iCloud.org.imessagearchiver`

Both apps use matching container ID:
- Mac app: `~/Library/Mobile Documents/iCloud~org~imessagearchiver/Documents/`
- iOS app: `FileManager.url(forUbiquityContainerIdentifier: "iCloud.org.imessagearchiver")`

### Write/read pattern
- **Single writer:** Mac app only
- **Multi-reader:** iOS app(s)
- Mac writes atomically: write to temp path, fsync, rename
- iOS opens `archive.sqlite` read-only via GRDB

### Download triggers
iOS app must explicitly download:
1. On first launch: `startDownloadingUbiquitousItem` on `archive.sqlite`, wait, then open
2. On attachment tap: `startDownloadingUbiquitousItem` on `attachments.tar` (downloads whole tar on first need; cached after)

### Storage cost
A 20GB Messages archive consumes 20GB of user's iCloud quota. Surface in UI before first archive.

---

## 7. Export Plan (Mac archiver workflow)

### Inputs
- `~/Library/Messages/chat.db` (+ `chat.db-wal`, `chat.db-shm`)
- `~/Library/Messages/Attachments/**`
- Contacts.framework for name resolution

### Steps
1. **Verify Full Disk Access** — attempt to open `chat.db`; if fails, show setup screen
2. **Snapshot** — copy `chat.db*` to `~/.imessage-archiver/work/` (avoids races with live Messages.app)
3. **Hash source** — SHA-256 of snapshotted `chat.db` (recorded in manifest)
4. **Open snapshot read-only** via `sqlite3.connect("file:...?mode=ro", uri=True)`
5. **Extract chats** — `SELECT guid, display_name, chat_identifier, service_name, ... FROM chat`
6. **Extract messages per chat** — join `message` ↔ `chat_message_join`; pull `guid, text, attributedBody, date, is_from_me, handle_id, associated_message_guid, associated_message_type, thread_originator_guid`
7. **Resolve text** — prefer `text` column; if null, parse `attributedBody` blob (typedstream/NSKeyedArchiver)
8. **Resolve sender** — join `handle`; resolve handle (phone/email) → contact name via Contacts.framework; fallback to raw handle
9. **Extract attachments** — join `message_attachment_join` ↔ `attachment`; resolve `filename` paths (expand `~`)
10. **Classify each attachment** — LOCAL_PRESENT / MISSING / ZERO_BYTE / UNREADABLE (filesystem checks: `exists()` → `is_file()` → `stat().st_size > 0` → read one byte)
11. **Compute SHA-256** of every present attachment
12. **Open destination archive.sqlite** (existing for merge, new for fresh archive)
13. **Insert chats** — `INSERT OR IGNORE` keyed on `chat_guid`
14. **Insert messages** — `INSERT OR IGNORE` keyed on `message_guid`
15. **Append attachments to tar** — for each LOCAL_PRESENT attachment not already in archive, append to `attachments.tar`, record `(tar_offset, tar_length)` in `attachments` row
16. **Build/update FTS5 index** — rebuild for new messages
17. **Write manifest.json** — counts, hashes, timestamps
18. **Verify** — re-open archive.sqlite, walk every attachment row, seek into tar, hash bytes, compare against stored SHA-256; write log to `~/.imessage-archiver/logs/verify-{timestamp}.log` (local only)
19. **Atomic rename** — write to `archive.imarchive.tmp`, fsync, rename to `archive.imarchive`
20. **Calendar reminder** — write `.ics` for +12 months (via EventKit/PyObjC if granted, else file)
21. **Post-archive prompt** — show success summary; if user confirms validation, link to Messages settings to enable "Keep Messages: 1 Year"

### Hard guarantees
- chat.db is **never** written to
- archive.sqlite is **append-only** (no deletes, no updates to existing rows except FTS rebuilds)
- Partial archives can't replace good ones (atomic rename only after verification succeeds)
- Pre-merge backup of existing archive bundle to `~/.imessage-archiver/backups/`
- Keep last 3 archive backups, auto-delete older

---

## 8. iOS Reader App Plan

### Stack
- SwiftUI, Swift 5.9+, iOS 17+
- Xcode 15+
- GRDB.swift for SQLite (read-only)
- Apple design language (HIG) — no custom theming, native components

### Architecture
```
ImessageArchiverIOS/
├── App/
│   └── ImessageArchiverApp.swift
├── Models/
│   ├── Chat.swift
│   ├── Message.swift
│   ├── Attachment.swift
│   └── ArchiveBundle.swift          # opens and represents a loaded archive
├── Persistence/
│   ├── ArchiveReader.swift          # GRDB queries, read-only
│   ├── TarReader.swift              # seek-based extraction by offset
│   └── iCloudCoordinator.swift      # NSMetadataQuery, download triggers
├── Views/
│   ├── ChatListView.swift           # NavigationStack root
│   ├── ThreadView.swift             # messages in a chat
│   ├── MessageBubbleView.swift      # native Messages-style bubble
│   ├── AttachmentView.swift         # QuickLook integration
│   ├── SearchView.swift             # FTS5-backed search
│   └── ArchiveInfoView.swift        # bundle metadata, last archived
└── Tests/
```

### iCloud setup
- Apple Developer account required
- Enable iCloud capability in Xcode
- Custom container: `iCloud.org.imessagearchiver`
- Entitlement: `com.apple.developer.icloud-container-identifiers`

### On-launch flow
1. Locate iCloud container
2. Look for `archive.imarchive/archive.sqlite`
3. If placeholder (not downloaded): trigger `startDownloadingUbiquitousItem`, show progress UI
4. Once downloaded: open `archive.sqlite` read-only via GRDB
5. Read manifest.json, show last-archived timestamp
6. Show `ChatListView`

### Views

**ChatListView** — `List` of chats sorted by `last_message_at DESC`. Each row: display name (or participants), last message preview, timestamp. Tap → ThreadView.

**ThreadView** — `ScrollView` of messages ordered by timestamp. Native iMessage-style bubbles: right-aligned blue for `is_from_me`, left-aligned grey for others, sender name above for group chats. Reactions (tapbacks) shown attached to target message. Tap attachment → AttachmentView.

**AttachmentView** — `QLPreviewController` wrapped in SwiftUI. Handles images, videos, PDFs, audio, generic files. Triggers tar extraction on demand:
1. Query `attachments` table for `(tar_offset, tar_length, filename, mime_type)`
2. Open file handle on `attachments.tar`, seek to offset, read `tar_length` bytes
3. Write to app's temp dir as `{attachment_guid}-{filename}`
4. Hand path to QuickLook
5. LRU cache cap (500MB), evict oldest

**SearchView** — full-text search via FTS5. Returns matching messages with context (preceding/following message). Filters: chat, date range, has-attachment.

**ArchiveInfoView** — manifest data: created_at, last_updated_at, chat_count, message_count, attachment_count, missing_attachment_count, archive_size.

### Design notes
- Use SF Symbols throughout
- Native `Label`, `List`, `NavigationStack`, `Form` — no custom UI primitives
- Dynamic Type support
- Dark mode automatic via system
- Accessibility: VoiceOver labels on all interactive elements

---

## 9. Yearly Workflow

### After first successful archive
1. App shows summary: "Archived 487,291 messages, 18,374 attachments. 42 attachments unavailable (iCloud-only on source Mac)."
2. Prompt: "Add calendar reminder to re-archive in 12 months?"
3. If yes: write `.ics` event to default Calendar or use EventKit (PyObjC) for direct insert
4. Prompt: "Now safe to enable Messages → Settings → General → Keep Messages: 1 Year. [Open Messages Settings]"
5. App does NOT toggle the setting itself — user does it in Messages.app

### 12 months later
1. Calendar reminder fires
2. User opens Mac archiver
3. App detects existing `archive.imarchive` in iCloud Drive
4. Runs incremental archive (merge new messages by GUID)
5. Re-verifies entire bundle
6. Updates calendar reminder for next year

### Merge semantics
- Existing chats: `INSERT OR IGNORE` — pre-existing rows untouched
- New chats: inserted with new `chat_guid`
- Existing messages: `INSERT OR IGNORE` — pre-existing rows untouched
- New messages: inserted with reference to existing `chat_guid` (continuity preserved)
- Existing attachments in tar: untouched, offsets unchanged
- New attachments: appended to tar, new offsets recorded
- FTS5 index rebuilt for new messages only (incremental)

---

## 10. Test Plan

Data loss prevention is the priority. Every layer must pass before release.

### Layer 1 — Synthetic fixtures
Build `tests/fixtures/generate.py`:
- `tiny.db` — 2 chats, 10 messages, 3 attachments
- `medium.db` — 50 chats, 5,000 messages, 200 attachments
- `large.db` — 1,000 chats, 500,000 messages, 20,000 attachments
- `edge.db` — null senders, missing attachments, attributedBody-only text, group chats, tapbacks, replies, emoji corpus, RCS messages
- `ventura.db`, `sonoma.db`, `sequoia.db` — schema variants

### Layer 2 — Unit tests
- DB reader: every query against every fixture
- Apple Epoch conversion: known timestamps round-trip
- attributedBody parser: known blobs decode correctly
- Attachment classifier: all states exercised
- Contact resolution: handle → name with mocked Contacts framework
- Tar writer: append, seek, read round-trip
- SHA-256 verification: corrupt detection

### Layer 3 — Archive integrity tests (CRITICAL)
For every fixture:
1. Archive it
2. Open resulting archive.sqlite
3. Assert: `message_count(archive) == message_count(source)`
4. Assert: every `(chat_guid, message_guid)` in source exists in archive
5. Assert: every message text matches (including attributedBody-derived)
6. Assert: every attachment SHA-256 matches between source file and tar entry
7. Assert: zero data loss tolerance — any miss = test failure

### Layer 4 — Merge tests
1. Archive fixture → `archive_v1`
2. Add new messages to fixture → `fixture_v2`
3. Merge `archive_v1` with `fixture_v2` → `archive_v2`
4. Assert: `archive_v2` contains union of v1 and v2 messages
5. Assert: no duplicates (GUID uniqueness enforced)
6. Assert: pre-existing messages byte-identical to v1
7. Assert: `attachments.tar` offsets for v1 entries unchanged

### Layer 5 — Round-trip tests (Mac → iOS)
Mac archive → bundle → iOS reader (CI on iOS simulator) → assert:
- Chat count matches
- Message count per chat matches
- Sample 100 random messages: text matches, sender matches, timestamp matches
- Sample 50 random attachments: SHA-256 matches after tar extraction

### Layer 6 — Corruption resistance tests
- Truncate `archive.sqlite` mid-write → next run detects and refuses
- Corrupt one tar entry → verify step catches it, reports which attachment
- iCloud download interruption → app shows error, doesn't claim success
- Concurrent Mac archive runs → second run refuses with lock file

### Layer 7 — Manual acceptance tests (checklist before release)
- [ ] Real chat.db (developer's own, 5+ years of messages)
- [ ] Archive completes without error
- [ ] Spot-check 10 random conversations in iOS app
- [ ] Verify 5 random images, 2 videos, 1 voice memo, 1 PDF render correctly
- [ ] Verify group chat participants display correctly
- [ ] Verify tapbacks/reactions display
- [ ] Verify emoji renders identically to Messages.app
- [ ] Verify search returns expected results
- [ ] Verify incremental merge preserves all prior content

### CI gates
- Layers 1–4 pass before merge to main
- Layer 5 runs on every release tag
- Layer 6 runs nightly
- Layer 7 signed off by human before tagging release
- **Coverage requirement: 100% of DB reader and archive writer code paths**

### Non-negotiable rule
**No code that writes to source chat.db can be merged.** CI grep blocks any PR containing write SQL against the source DB path.

---

## 11. Phases

### Phase 0 — Foundations
- Repo, MIT licence, CI skeleton, CLAUDE.md
- Synthetic chat.db generator
- **Archive bundle format frozen** (this is the contract between Mac and iOS)
- Test fixtures committed

### Phase 1 — Mac DB reader
- Read-only chat.db access with snapshot
- All extraction queries (chats, messages, attachments, handles)
- `attributedBody` parser
- Apple Epoch conversion
- Contact name resolution via Contacts.framework (PyObjC)
- Layer 1–2 tests passing

### Phase 2 — Mac archive writer
- Write `archive.sqlite` from extracted data
- Write `attachments.tar` with SHA-256 manifest
- Write `manifest.json`
- FTS5 index build
- Integrity verification (read back, hash check)
- Incremental merge logic keyed on GUIDs
- Layer 3–4 tests passing

### Phase 3 — Mac CLI
- `click` commands: `archive`, `verify`, `stats`, `merge`, `info`
- Dry-run mode
- Progress reporting (`rich`)
- Shippable as v0.1 (CLI-only) for early testing

### Phase 4 — Mac GUI
- PySide6 three-panel layout (conversation list, preview, archive controls)
- iCloud Drive destination picker
- Full Disk Access setup screen
- Calendar reminder writer (EventKit via PyObjC, fallback to `.ics`)
- Post-archive validation prompt + link to Messages settings
- Packaging via PyInstaller, arm64 `.app` bundle
- Ad-hoc signed; Gatekeeper workaround documented

### Phase 5 — iOS reader app
- **Pause point: human-in-the-loop required for Xcode/iCloud container setup, Apple Developer account, signing certs**
- SwiftUI project scaffold
- iCloud container configured (matching `iCloud.org.imessagearchiver`)
- GRDB integration, archive.sqlite read-only access
- Seek-based tar reader
- ChatListView, ThreadView, MessageBubbleView
- AttachmentView with QuickLook
- SearchView with FTS5
- ArchiveInfoView
- TestFlight build
- Layer 5 tests passing on simulator

### Phase 6 — Yearly workflow polish
- Calendar reminder copy and UX
- Post-archive "enable Keep Messages: 1 Year" deep link
- Incremental archive UX
- Data-loss-prevention checks before any source-side action

### Phase 7 — Hardening
- Large database tests (50GB+ chat.db)
- iCloud sync edge cases (offline, partial download, quota full)
- Cross-version macOS (13, 14, 15)
- Cross-version iOS (17, 18)
- Documentation, README, HELP.md rewrite

---

## 12. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Apple changes chat.db schema | Medium | High | Schema abstraction in `db/reader.py`; version detection; attributedBody parser already required for Ventura+ |
| Full Disk Access not granted | High | High | Detect on launch, show setup screen |
| iCloud-only attachments unrecoverable | High | Medium | State classifier + manifest + user prompt to download in Messages |
| User confusion: archive vs delete | Medium | High | UI wording emphasises archive-only; deletion is Apple's retention setting, not our app |
| iCloud sync quota exhausted | Medium | Medium | Show archive size before write; refuse if quota insufficient |
| Concurrent Mac writes corrupt bundle | Low | High | Lock file in archive bundle dir |
| iOS app reads partial bundle mid-Mac-write | Low | Medium | Atomic rename on Mac side; iOS checks manifest.json before opening |
| Bundle size 250–450 MB for Mac app | High | Low | Accept; evaluate Nuitka later if needed |
| Contacts API access from non-sandboxed Python | Medium | High | Prototype early in Phase 1; fall back to raw handles if blocked |
| Large chat.db performance | Medium | Medium | Lazy loading from day 1; pagination in GUI conversation list |
| GUID assumptions break for some message types | Medium | High | Test fixtures must include edge cases; manual verification on real DB |

---

## 13. Open Questions (resolve during build)

The following were resolved before Phase 0 and are now reflected in the frozen schema:

- **Edited messages (RESOLVED)** — Archive all edits. `messages.date_edited` is NULL for unedited messages and set to the Unix epoch of the last edit for edited ones. The `text` column stores the *current* (post-edit) text. Historical edit bodies are not stored; this matches Messages.app behaviour and avoids schema complexity.
- **Unsent messages (RESOLVED)** — Archive all retracted messages. `messages.date_retracted` is NULL for normal messages and set to the Unix epoch of the unsend for retracted ones. The `text` column stores whatever text was present at time of retraction (typically still readable in `chat.db`). iOS app shows retracted messages with a "This message was unsent" label when `date_retracted IS NOT NULL`.

The following are still open and investigated during Phase 1 against real fixtures:

1. **RCS messages** — verify they land in chat.db on Sequoia and how.
2. **Reply threads** — `thread_originator_guid` semantics. Verify and test.
3. **Voice memos** — special handling needed? Test with real samples.

None of these affect the frozen schema — they are read-path concerns resolved in `db/reader.py`.
