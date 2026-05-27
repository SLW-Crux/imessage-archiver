# Mac Archiver — Export Plan

Detailed implementation plan for the Mac archiver.

---

## Inputs

- `~/Library/Messages/chat.db` (+ `chat.db-wal`, `chat.db-shm`)
- `~/Library/Messages/Attachments/**`
- Contacts.framework for handle → name resolution

## Output

`archive.imarchive/` directory in iCloud Drive container, containing:
- `archive.sqlite` — all extracted data, FTS5 index
- `attachments.tar` — concatenated attachment files
- `manifest.json` — metadata, hashes, counts

Verification logs are written locally to `~/.imessage-archiver/logs/verify-{timestamp}.log` and are not part of the synced bundle.

---

## Sequential Steps

### 1. Pre-flight checks
- Verify Full Disk Access by attempting to open `chat.db`
- If denied: show setup screen with instructions, exit
- Verify iCloud Drive available and writable
- Check available iCloud quota vs estimated archive size
- If insufficient: refuse and report required space

### 2. Acquire lock
- Create `~/.imessage-archiver/lock` file with current PID
- If lock exists with live PID: refuse (concurrent run)
- If lock exists with dead PID: clean up and proceed
- Release lock on exit (signal handlers required)

### 3. Snapshot source DB
`chat.db` runs in WAL mode on all modern macOS versions. Copying `chat.db + chat.db-wal + chat.db-shm` with `shutil.copy2` yields an inconsistent snapshot if Messages.app writes between the three copies. The only safe approach is `VACUUM INTO`, which reads all committed WAL data through SQLite's own merge logic and writes a single, WAL-free file atomically:

```python
snapshot_path = (
    Path.home() / ".imessage-archiver" / "work"
    / f"snapshot-{timestamp}" / "chat.db"
)
snapshot_path.parent.mkdir(parents=True, exist_ok=True)

src = sqlite3.connect(f"file:{chat_db_path}?mode=ro", uri=True)
src.execute(f"VACUUM INTO '{snapshot_path}'")
src.close()
```

- The source connection is opened `mode=ro` — no writes to `chat.db` at any point
- The result is a single file; no `chat.db-wal` or `chat.db-shm` are written
- Hash the snapshot with SHA-256 → record in `manifest.json`

### 4. Open snapshot read-only
```python
conn = sqlite3.connect(
    f"file:{snapshot_path}?mode=ro&immutable=1",
    uri=True
)
```
- `immutable=1` is safe here because `VACUUM INTO` produced a clean, WAL-free file that no other process will ever write to
- Wrap entire extraction in a single transaction for consistency

### 5. Extract chats
```sql
SELECT
  guid,
  display_name,
  chat_identifier,
  service_name,
  is_archived,
  room_name,
  group_id
FROM chat
WHERE guid IS NOT NULL
```

Resolve participants per chat:
```sql
SELECT h.id, h.service
FROM chat_handle_join chj
JOIN handle h ON h.ROWID = chj.handle_id
WHERE chj.chat_id = ?
```

Determine `is_group`: `len(participants) > 1` OR `room_name IS NOT NULL`

### 6. Extract messages per chat
```sql
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
  m.thread_originator_guid,
  m.cache_has_attachments,
  m.date_edited,
  m.date_retracted
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
WHERE cmj.chat_id = ?
ORDER BY m.date ASC
```

### 7. Resolve message text
For each message:
- If `text IS NOT NULL` and non-empty: use it
- Else if `attributedBody IS NOT NULL`: parse the typedstream blob
  - Use `typedstream` library or hand-rolled parser
  - Extract the UTF-8 string from the NSAttributedString blob
- Else: text is genuinely empty (likely attachment-only message)

### 8. Resolve sender
- `is_from_me == 1`: sender_name = "Me", sender_handle = own Apple ID/phone (from `_SqliteDatabaseProperties` table if available)
- Else: resolve `handle_id` → `handle.id` (phone/email) → query Contacts.framework for display name
- Cache handle→name lookups (avoid repeated framework calls)
- Fallback if Contacts denies or no match: use raw handle string

### 9. Convert timestamps
Apple Epoch: seconds since 2001-01-01 00:00:00 UTC
Some macOS versions store nanoseconds: detect by magnitude
```python
APPLE_EPOCH_OFFSET = 978307200  # 2001-01-01 in Unix epoch
def apple_to_unix(value: int) -> int:
    # Newer macOS stores nanoseconds since Apple epoch
    if value > 1_000_000_000_000_000_000:  # nanoseconds
        return value // 1_000_000_000 + APPLE_EPOCH_OFFSET
    return value + APPLE_EPOCH_OFFSET
```

### 10. Aggregate tapbacks
Tapbacks are stored in `chat.db` as ordinary message rows with `associated_message_type != 0`:
- Types 2000–2005: reaction added (love, like, dislike, laugh, emphasize, question)
- Types 3000–3005: reaction removed
- `associated_message_guid` points to the target message

**Storage decision:** tapback rows ARE archived as normal `messages` rows (via `INSERT OR IGNORE` like all other messages). They are identified by `associated_message_type != 0`. This is required for correct incremental merges — if tapbacks were only folded into `reactions_json` and not stored as rows, a re-archive would have no way to detect which tapbacks are already known.

In addition, for fast display without a JOIN, the target message's `reactions_json` column is populated with the current net set of reactions (adds minus removes):
```json
[
  {"from": "Alice", "type": "love", "timestamp": 1716800000},
  {"from": "Bob", "type": "like", "timestamp": 1716800050}
]
```

On incremental archive, recompute `reactions_json` for any target message that has at least one tapback row with a timestamp newer than the last `archive_runs.completed_at`. Use `UPDATE messages SET reactions_json = ? WHERE message_guid = ?` for this targeted recomputation only — this is the sole permitted `UPDATE` on user-visible rows.

### 11. Extract attachments
```sql
SELECT
  a.guid,
  a.filename,
  a.mime_type,
  a.uti,
  a.total_bytes,
  a.transfer_name,
  a.is_sticker,
  maj.message_id,
  m.guid AS message_guid
FROM attachment a
JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
JOIN message m ON m.ROWID = maj.message_id
```

### 12. Resolve attachment paths
Apple stores paths with `~/` prefix typically pointing to `~/Library/Messages/Attachments/`:
```python
def resolve_path(filename: str) -> Path:
    if filename.startswith("~"):
        return Path(filename).expanduser()
    if filename.startswith("/"):
        return Path(filename)
    return Path.home() / "Library" / "Messages" / filename
```

### 13. Classify attachment state
For each attachment, run the classifier:
```python
def classify(path: Path) -> str:
    if not path.exists():
        return "MISSING"
    if not path.is_file():
        return "NOT_A_FILE"
    try:
        size = path.stat().st_size
    except OSError:
        return "UNREADABLE"
    if size == 0:
        return "ZERO_BYTE"
    try:
        with path.open("rb") as f:
            f.read(1)  # placeholder files block here
    except OSError:
        return "UNREADABLE"
    return "LOCAL_PRESENT"
```

### 14. Compute SHA-256 for present attachments
Stream-hash in 1MB chunks to handle large files:
```python
def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()
```

### 15. Open or create destination archive.sqlite

**First archive (no existing `archive.imarchive`):**
- Destination path: `{icloud_container}/archive.imarchive.tmp/archive.sqlite`
- Create schema from scratch; seed `schema_migrations` with version 1

**Incremental archive (existing `archive.imarchive` present):**
- Before touching the existing archive, copy it to a local backup:
  `~/.imessage-archiver/backups/archive-{timestamp}/`
  This copy stays on local disk (not iCloud). It is O(archive-size) but happens fully locally on APFS — for a 20 GB archive on an M1 Mac this takes roughly 30–60 s. Acceptable for a yearly workflow; surface "Backing up existing archive…" progress to the user.
- Work destination is `{icloud_container}/archive.imarchive.tmp/` — a fresh directory
- The working `archive.sqlite` starts as a copy of the existing one (so `INSERT OR IGNORE` correctly skips already-archived rows); the working `attachments.tar` starts empty and only new attachments are written into it
- Apply any schema migrations before inserting new rows
- After verification (step 22), merge the working tar into the existing one and swap in the new sqlite (step 23)

Note: the backup is written before any modification to the iCloud bundle, so if the machine loses power mid-run the existing good archive is untouched.

### 16. Insert chats
```sql
INSERT OR IGNORE INTO chats (chat_guid, display_name, ...)
VALUES (?, ?, ...)
```
`INSERT OR IGNORE` is the key — re-archives don't disturb existing rows.

### 17. Insert messages
```sql
INSERT OR IGNORE INTO messages (message_guid, chat_guid, ...)
VALUES (?, ?, ...)
```

For messages already in archive: skipped. Existing rows are never modified.

### 18. Append attachments to tar
**Tar format:** POSIX ustar. Each entry is a 512-byte header block followed by the file data padded to the next 512-byte boundary. Filenames in the header are stored as `{attachment_guid}-{safe_basename}`, where `safe_basename` is the original filename with all path separators stripped. This naming scheme guarantees the filename fits in the 100-character ustar header field, eliminating the need for PAX extended headers.

**`tar_offset` and `tar_length` semantics — important for iOS reader:**
- `tar_offset` = byte position of the first byte of **file data** (= the header block start + 512 bytes)
- `tar_length` = count of raw file bytes, **not** rounded up to a 512-byte boundary
- iOS reader: `seek(to: tar_offset)` then `read(exactly: tar_length)` — no header parsing ever required

For each new attachment (not already in `attachments` table) with state LOCAL_PRESENT:
1. Open the working `attachments.tar` in append mode; get current file position → `header_start`
2. Compute `tar_offset = header_start + 512`
3. Write 512-byte ustar header (filename, size = `file_size`, mode, mtime)
4. Write exactly `file_size` bytes of file content; record `tar_length = file_size`
5. Write `(512 - file_size % 512) % 512` zero-padding bytes to align to next 512-byte block
6. Insert row in `attachments` table with `tar_offset`, `tar_length`, `sha256`, `state`

For attachments not LOCAL_PRESENT: insert row with `tar_offset = NULL`, `tar_length = NULL`, recording the state for the iOS app to display.

### 19. Maintain FTS5 index
`messages_fts` is an external-content FTS5 table (`content='messages'`). Because `messages` is append-only — only `INSERT OR IGNORE`, never `UPDATE` or `DELETE` on normal rows — the FTS index only ever needs insertions. No full rebuild is required.

For each new message row inserted in step 17, insert the matching FTS row immediately:
```sql
INSERT INTO messages_fts(rowid, message_guid, text, sender_name)
VALUES (last_insert_rowid(), ?, ?, ?)
```
Do this per-message at insert time so the FTS index stays consistent even if the archive run is interrupted mid-way.

On first archive, use `executemany` for bulk performance. On incremental, only new rows are inserted — rows already in `messages` were skipped by `INSERT OR IGNORE` and their FTS rows already exist.

### 20. Record archive run
```sql
INSERT INTO archive_runs (
  run_id, started_at, completed_at,
  source_db_sha256, source_db_path,
  message_count, attachment_count, missing_attachment_count,
  archiver_version
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
```

### 21. Write manifest.json
```json
{
  "schema_version": 1,
  "archiver_version": "0.1.0",
  "created_at": "2026-05-27T14:32:00Z",
  "last_updated_at": "2026-05-27T14:32:00Z",
  "source_db_sha256": "abc123...",
  "source_macos_version": "14.5",
  "chat_count": 234,
  "message_count": 487291,
  "attachment_count": 18374,
  "missing_attachment_count": 42,
  "archive_size_bytes": 23847291038
}
```

If existing manifest: preserve `created_at`, update `last_updated_at` and counts.

### 22. Verification pass (CRITICAL)
For every attachment row with `tar_offset IS NOT NULL`:
1. Seek to `tar_offset` in the working `attachments.tar`
2. Read exactly `tar_length` bytes
3. SHA-256 the bytes
4. Compare against `attachments.sha256` column
5. Mismatch = HARD FAIL — abort, leave `.tmp` in place for debugging, do NOT promote

Write the verification log to `~/.imessage-archiver/logs/verify-{timestamp}.log` (local, not in the iCloud bundle):
```
2026-05-27T14:35:00Z VERIFY attachment_guid=ABC-123 OK
2026-05-27T14:35:00Z VERIFY attachment_guid=DEF-456 OK
...
2026-05-27T14:36:12Z VERIFY_COMPLETE 18332/18332 PASSED
```
Keeping this file local prevents a large log from triggering an iCloud re-upload after every annual archive.

### 23. Promote working archive

**First archive:**
- Rename `archive.imarchive.tmp/` → `archive.imarchive/` (single atomic directory rename within iCloud container)
- No existing archive to deal with

**Incremental archive:**
- Append the verified working `attachments.tar` (new attachments only) to the end of the existing `archive.imarchive/attachments.tar` (sequential write, no copy of existing bytes)
- Replace `archive.imarchive/archive.sqlite` with the working copy: rename existing to `archive.sqlite.old`, rename working into place, delete `.old`
- Replace `archive.imarchive/manifest.json` with updated version
- Delete the now-empty `archive.imarchive.tmp/` directory
- The local backup in `~/.imessage-archiver/backups/archive-{timestamp}/` (written in step 15) is retained as rollback point; keep last 3 backups, delete older

### 24. Calendar reminder
If first archive, or if existing reminder absent:
- Request EventKit access via PyObjC
- If granted: insert event in default calendar, +12 months from now, title "Re-archive iMessage"
- If denied: write `.ics` file to Desktop, prompt user to double-click

### 25. Release lock and exit
- Print summary: chats, messages, attachments, missing, archive size, location
- Show prompt: "Now safe to enable Messages → Settings → General → Keep Messages: 1 Year"
- Provide "Open Messages Settings" button (deep link via `open` command or AppleScript)

---

## CLI Commands

```
imessage-archiver archive [--dest PATH] [--dry-run]
imessage-archiver verify [--archive PATH]
imessage-archiver stats [--archive PATH]
imessage-archiver merge --source CHAT_DB --archive PATH
imessage-archiver info [--archive PATH]
imessage-archiver setup       # Full Disk Access walkthrough
```

### `archive`
Runs steps 1–25. Default destination is iCloud Drive container.

### `verify`
Runs only steps 22 against an existing archive. Useful as a standalone integrity check.

### `stats`
Reads archive.sqlite, prints: chat count, message count by year, attachment count by type, top 10 chats by message count, total size.

### `merge`
Merges a separate `chat.db` snapshot into an existing archive. Useful for combining multiple Macs.

### `info`
Prints manifest.json contents and last 5 `archive_runs` rows.

### `setup`
Walks user through granting Full Disk Access in System Settings.

---

## GUI Workflow (Phase 4)

Three-panel layout:
- **Left:** conversation list (sortable, searchable, with sizes)
- **Centre:** preview of selected conversation (last 50 messages)
- **Right:** archive controls + stats

Main flow:
1. App launches → checks Full Disk Access
2. If granted: opens chat.db read-only, populates conversation list
3. User clicks "Archive All to iCloud Drive"
4. Progress UI: snapshot, extract, write, verify (with progress bar per phase)
5. On success: summary screen + calendar reminder prompt + Messages settings deep link
6. On failure: error detail, log path, retry option

---

## Hard Guarantees

- `chat.db` is **never** written to (CI grep enforces this in code)
- `archive.sqlite` is **append-only** (no DELETE or UPDATE on existing rows; FTS rebuilds are tracked separately)
- Partial archives can't replace good ones (atomic rename only after verification succeeds)
- Pre-merge backup of existing archive bundle to `~/.imessage-archiver/backups/`
- All paths sanitised before tar writes (no path traversal)
- Lock file prevents concurrent runs
- Source DB is hashed and recorded — any tampering detectable

---

## Error Handling

| Condition | Behaviour |
|---|---|
| Full Disk Access denied | Show setup screen, exit |
| iCloud Drive unavailable | Refuse, suggest local destination |
| iCloud quota insufficient | Show required vs available, refuse |
| chat.db locked by Messages.app | Wait 5s, retry once, then proceed with snapshot |
| Attachment file missing | Record state, continue |
| Attachment SHA-256 mismatch during verify | HARD FAIL, abort, preserve .tmp |
| Disk full during tar write | Abort, clean up .tmp, report |
| EventKit denied | Fall back to .ics file on Desktop |
| Contacts denied | Fall back to raw handles, warn user |
| Snapshot copy fails | Abort, no changes made |
