# Test Plan

Data loss prevention is the priority. Every layer must pass before release.

---

## Layer 1 — Synthetic Fixtures

Build `tests/fixtures/generate.py` to produce realistic `chat.db` files programmatically.

### Fixtures to produce

| Fixture | Chats | Messages | Attachments | Purpose |
|---|---|---|---|---|
| `tiny.db` | 2 | 10 | 3 | Smoke tests, fast CI |
| `medium.db` | 50 | 5,000 | 200 | Realistic mid-size archive |
| `large.db` | 1,000 | 500,000 | 20,000 | Performance + large-DB handling |
| `edge.db` | 20 | 500 | 50 | All edge cases (see below) |
| `ventura.db` | 10 | 200 | 20 | macOS 13 schema variant |
| `sonoma.db` | 10 | 200 | 20 | macOS 14 schema (incl. edits/unsends) |
| `sequoia.db` | 10 | 200 | 20 | macOS 15 schema (incl. RCS) |

### Edge cases (`edge.db` must include)

- Messages with `text IS NULL` and `attributedBody` set
- Messages with both NULL (attachment-only messages)
- Null sender (`handle_id IS NULL`)
- Group chats with 3+ participants
- Group chats with renamed participants
- Tapbacks/reactions (all 6 types, both add and remove)
- Reply threads (`thread_originator_guid` set)
- Edited messages (`date_edited` set, Sonoma+)
- Unsent messages (`date_retracted` set, Sonoma+)
- Same contact appearing under both phone and email handles
- Messages with multiple attachments
- Attachments with missing files on disk
- Attachments with zero bytes
- Attachments with non-ASCII filenames
- Attachments with path traversal attempts in filename (security test)
- Emoji corpus: skin tones, ZWJ sequences, flags, family emoji, regional indicators
- Right-to-left text (Arabic, Hebrew)
- Very long messages (>10,000 chars)
- Messages with URLs, mentions, formatting

### Attachment files
Generate paired files in `tests/fixtures/Attachments/` matching DB rows. Use small test images (1KB PNG), test videos (10KB MP4), test PDFs. Real-format files so MIME detection and QuickLook work in tests.

---

## Layer 2 — Unit Tests

### Mac archiver
- **DB reader**: every query against every fixture. Assert row counts, field values, joins.
- **Apple Epoch conversion**: known timestamps (e.g., 2001-01-01 00:00:00 → 978307200 Unix) round-trip. Test nanosecond detection.
- **attributedBody parser**: known typedstream blobs decode to expected UTF-8 strings. Include real samples extracted from a Ventura+ DB.
- **Attachment classifier**: all 5 states exercised (LOCAL_PRESENT, MISSING, ZERO_BYTE, UNREADABLE, NOT_A_FILE).
- **Contact resolver**: mock Contacts framework, assert handle → name resolution and fallback to raw handle.
- **Path resolver**: `~/`, absolute, relative, malicious paths.
- **Tar writer**: append, seek-read round-trip, padding alignment, header correctness.
- **SHA-256**: known files produce known hashes.
- **Lock file**: concurrent run detection, dead PID cleanup.

### iOS reader
- **ArchiveReader**: open fixture bundle, query chats/messages/attachments.
- **TarReader**: extract by offset, byte-equal to source file.
- **AttachmentCache**: LRU eviction at 500MB cap.
- **iCloudCoordinator**: state machine transitions with mocked filesystem.

---

## Layer 3 — Archive Integrity Tests (CRITICAL)

For every Mac archiver fixture:

1. Archive it to a temp directory
2. Open resulting `archive.sqlite`
3. **Assert** `message_count(archive) == message_count(source)`
4. **Assert** every `(chat_guid, message_guid)` in source exists in archive
5. **Assert** every message's resolved text matches source (including `attributedBody`-derived)
6. **Assert** every attachment's SHA-256 matches between source file and tar entry
7. **Assert** every attachment's `state` field is correct
8. **Assert** no orphan rows (every message has valid `chat_guid`, every attachment has valid `message_guid`)
9. **Assert** FTS5 index returns expected hits for known queries

**Zero data loss tolerance — any miss = test failure.**

---

## Layer 4 — Merge Tests

1. Archive `tiny.db` → `archive_v1`
2. Mutate `tiny.db` to add new messages and attachments → `tiny_v2.db`
3. Merge `tiny_v2.db` into `archive_v1` → `archive_v2`
4. **Assert** `archive_v2` contains union of v1 and v2 content
5. **Assert** no duplicate `message_guid` rows
6. **Assert** pre-existing message rows byte-identical to v1 (no mutations)
7. **Assert** pre-existing attachment tar offsets unchanged
8. **Assert** new attachments appended at end of tar
9. **Assert** `archive_runs` table records both runs
10. **Assert** `manifest.json` `created_at` unchanged, `last_updated_at` updated, counts updated

---

## Layer 5 — Round-Trip Tests (Mac → iOS)

Mac archive → bundle → iOS reader on simulator.

### Setup
- Both jobs require a `macos-14` GitHub Actions runner (Xcode pre-installed). macOS runners cost ~10× Linux runners; Layer 5 runs only on release tags to contain cost.
- Mac CI job produces `medium.imarchive` bundle
- Bundle uploaded as CI artifact
- iOS CI job downloads artifact, loads it in an iPhone simulator, runs assertion suite

### Assertions
- Chat count matches source
- Message count per chat matches
- Sample 100 random messages: text matches, sender matches, timestamp matches
- Sample 50 random attachments: extract via TarReader, SHA-256 matches stored hash
- Search for known terms returns expected message GUIDs
- Reactions render correctly for messages with known tapbacks

---

## Layer 6 — Corruption Resistance Tests

| Scenario | Expected behaviour |
|---|---|
| Corrupt `archive.sqlite.tmp` mid-build (kill -9 process) | Next archive run detects orphaned `.tmp`, refuses to promote, logs path for inspection |
| Corrupt one byte in tar entry | Verification pass catches it, reports which attachment, aborts atomic rename |
| Delete `manifest.json` | iOS app refuses to open, shows error |
| Schema version mismatch in manifest | iOS app refuses, prompts user to update |
| iCloud download interrupted | iOS shows error, retries on user action |
| Concurrent Mac archive runs | Second run detects lock, refuses |
| Disk full during tar append | Abort, clean up `.tmp`, leave good `archive.imarchive` intact |
| Source `chat.db` changes mid-snapshot | Snapshot captures point-in-time copy; live changes don't affect archive |

---

## Layer 7 — Manual Acceptance Tests

Pre-release checklist (human signs off):

- [ ] Real `chat.db` (developer's own, 5+ years of messages)
- [ ] Archive completes without error
- [ ] Verification log shows all green
- [ ] Bundle appears in iCloud Drive on Mac
- [ ] Bundle syncs to iPhone
- [ ] iOS app opens bundle, shows all chats
- [ ] Spot-check 10 random conversations: messages match Messages.app
- [ ] Verify 5 random images render correctly
- [ ] Verify 2 random videos play correctly
- [ ] Verify 1 voice memo plays correctly
- [ ] Verify 1 PDF opens via QuickLook
- [ ] Verify group chat participants display correctly
- [ ] Verify tapbacks/reactions display
- [ ] Verify emoji renders identically to Messages.app (including skin tones, family emoji)
- [ ] Search returns expected results
- [ ] Run incremental merge — prior content unchanged, new content added
- [ ] Verify archive across macOS 13, 14, 15 if available
- [ ] Verify iOS reader on iOS 17 and 18
- [ ] Calendar reminder appears in Calendar.app

---

## CI Gates

| Gate | Tests | Blocking? |
|---|---|---|
| PR to feature branch | Layer 1, 2 | Yes |
| PR to main | Layers 1, 2, 3, 4 | Yes |
| Release tag | Layers 1, 2, 3, 4, 5 | Yes |
| Nightly | Layer 6 | No (alerts only) |
| Pre-release sign-off | Layer 7 | Yes (human) |

**Coverage requirement: 100% of DB reader and archive writer code paths.**

---

## Non-Negotiable Rules

1. **No code that writes to source `chat.db` can be merged.**
   - CI grep blocks any PR containing patterns like `INSERT INTO chat`, `DELETE FROM message`, etc., against the source DB path.
   - Detection rule: any SQL string targeting `chat.db` (vs `archive.sqlite`) with `INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `CREATE`, `REPLACE`, `TRUNCATE`, `VACUUM` is auto-rejected.

2. **No code that deletes attachment files from `~/Library/Messages/Attachments/`.**
   - The archiver is read-only on the source. Pruning is explicitly out of scope.

3. **Atomic rename is mandatory.**
   - No partial bundle can replace a good one. `.tmp` directory + rename pattern enforced in code review.

4. **SHA-256 verification before promotion.**
   - No archive promoted to final path without passing full verification.

5. **Append-only archive.**
   - `archive.sqlite` rows are never UPDATEd or DELETEd (except FTS rebuild internals, which use SQLite's content-rowid pattern and are functionally append-only at the user-visible layer).

---

## Performance Targets

| Operation | Target |
|---|---|
| Archive 500k messages, 20k attachments | < 10 min on M1 Mac |
| Verification pass (20k attachments) | < 2 min |
| Incremental merge (1k new messages) | < 30s |
| iOS app cold start with 500k-msg archive | < 2s to chat list |
| iOS thread view scroll (10k messages) | 60fps with LazyVStack |
| Attachment tap → QuickLook preview | < 500ms |
| FTS5 search across 500k messages | < 1s |

If targets miss by >2x: investigate before release.
