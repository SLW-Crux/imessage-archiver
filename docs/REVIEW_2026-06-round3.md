# Code Review — June 2026, Round 3

Third pass. Six parallel agents, one per PR (#69 PR-A through #74 UI+MH6). Each agent re-audited the post-merge state on `main` against the original Round 2 review's intent and looked for fixes that regressed, new issues introduced, or original findings papered over rather than solved.

## Triage totals

| PR | Theme | Critical | High |
|---|---|---|---|
| #69 PR-A | Atomic writes & lockfile | 1 | 6 |
| #70 PR-B | Process safety / crash containment | 2 | 2 |
| #71 PR-C | Defensive parsing | 1 | 5 |
| #72 PR-D | Concurrency & races | 0 | 2 |
| #73 PR-E | URI / FTS5 / query | 1 | 5 |
| #74 UI + MH6 | UI polish + close-out | 1 | 2 |
| **Total** | | **6** | **22** |

(Medium / Low surfaced by the agents are tracked in agent transcripts; not duplicated here.)

---

## Critical findings (6)

### R3-C1 — PR-A — Existing-bundle reopen runs `PRAGMA journal_mode=WAL` *before* schema-version check
`ios/Sources/Archiver/ArchiveWriter.swift:295-308` — when reopening an existing bundle whose schema is too new, code enters a `queue.write { ... PRAGMA journal_mode=WAL ... }` block *before* the `schemaTooNew` check. `PRAGMA journal_mode` rewrites the DB header byte and (re)creates -wal/-shm siblings. Direct breach of CLAUDE.md P0 invariant: we mutate a bundle whose schema we don't understand.

### R3-C2 — PR-B — `sweepLeftovers()` deletes peer-process snapshots mid-VACUUM
`ios/Sources/Archiver/SourceDBSnapshotter.swift:152-162` + `CreateArchiveCoordinator.swift:77-81` — sweep runs before this run's lock is acquired and unconditionally `rm -rf`s every `snapshot-*` dir under `workRoot`. A concurrent archive process (double-launch, CLI overlap) gets its mid-VACUUM snapshot deleted out from under it → SQLITE_IOERR or worse. The MC3 fix created a worse failure mode than the leak it prevented.

### R3-C3 — PR-B — `NSUnarchiver` no longer in macOS 26.5 SDK headers; shim brittle
`ios/Sources/Archiver/AttributedBodyDecoderShim.m:14-22` — the SDK at `/Applications/Xcode.app/.../MacOSX26.5.sdk` no longer ships `NSArchiver.h`. The shim compiles only because `-Wobjc-method-access` suppresses warnings and ObjC falls back to `id`-typed dispatch. Class is in the runtime today but the next SDK release that removes the runtime will silently drop 100% of legacy typedstream messages with zero build signal.

### R3-C4 — PR-C — MH8 `catch { }` swallows writer SQLite errors, cancellation, disk-full, OOM
`ios/Sources/Archiver/ArchiveWriter.swift:222-226` — the per-chat catch was supposed to skip a single bad chat from the source reader. Instead it wraps `insertChat` + `insertMessage` + `insertAttachment` + tar writes — so SQLITE_BUSY / SQLITE_FULL / SQLITE_IOERR / disk-full / OOM / `CancellationError` are all silently eaten with the loop continuing and the progress callback firing as if the chat succeeded. **The UI Cancel button becomes a no-op.** User sees "succeeded" archive that may be almost empty. Textbook "fail loudly over fail silently" violation from CLAUDE.md.

### R3-C5 — PR-E — `scripts/patch-archive-text.py` will wipe FTS5 index on new archives
`scripts/patch-archive-text.py:94` — invokes `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')` which is for external-content FTS5. On a standalone (`content=''`) table — which PR-E switched the writer to — the rebuild incantation either errors or wipes the index because there's no source content to rebuild from. The user's only repair path for the existing fat archive + fresh-text overlay workflow is silently broken on every post-PR-73 archive.

### R3-C6 — PR-#74 — MH6 docs claim data loss but the attachment blob IS in the tar
`docs/SCHEMA.md` Known-limitations section — the doc says messages 2..N show "Not Included," implying data loss. In fact `attachments.tar` already contains the blob — only the row-level `attachment ↔ message_guid` join is missing. A reader-side workaround (scan `attributedBody` for embedded attachment GUIDs, or materialise a `message_attachments` view at archive time) would recover the cosmetic case at zero migration cost. The "won't fix" framing is honest about the schema decision but overstates the user-visible loss.

---

## High findings (22)

### Filesystem coordination (4)
- **R3-H1** (PR-A H3) — `replaceItemAt(manifest, .tmp)` not wrapped in `NSFileCoordinator`. iCloud daemon picks up the `manifest.json.tmp` artifact and uploads it.
- **R3-H2** (PR-A H4) — `archive.sqlite.tmp` rename not coordinated either. iCloud uploads the `.tmp`, then sees a rename. Wasted bandwidth + brief broken-state windows on iOS reader.
- **R3-H3** (PR-D M1) — `coordinatedManifestLoad` blocks MainActor synchronously. Reintroduces the slow-iCloud UI stall IH1 was meant to prevent.
- **R3-H4** (PR-D M2) — `.withoutChanges` is wrong option for iCloud read intent — may hand back stale snapshot, defeats `lastSeenUpdatedAt` change-detection.

### Lock primitive (4)
- **R3-H5** (PR-A H1) — `Darwin.write` return value discarded. Partial write → next acquirer reads garbage → treats live lock as stale → steals.
- **R3-H6** (PR-A H2) — missing `O_CLOEXEC` on lock fd.
- **R3-H7** (PR-A H5) — PID-reuse race amplified by retry loop. `flock(LOCK_EX|LOCK_NB)` is the right primitive — auto-releases on process death, eliminates ambiguity.
- **R3-H8** (PR-A H6) — half-initialized `archive.sqlite` after rename failure isn't detected as corruption.

### ObjC shim defensive (1)
- **R3-H9** (PR-B H1) — `@catch (NSException *)` too narrow. Plain-`id` ObjC throws and runtime class-missing `objc_msgSend` aborts aren't caught. Use `@catch (id e)` + `NSClassFromString` guard.

### Concurrency residuals (2)
- **R3-H10** (PR-D H1) — IH5 fix incomplete. `queryDidUpdate` is still `nonisolated` and trampolines via `Task { @MainActor in ... }`. `disable/enable` doesn't synchronously bracket `result(at:)`. Make `queryDidUpdate` itself `@MainActor` and drop the Task hop.
- **R3-H11** (PR-D H2) — IH8 cancel guard leaks `isSearching = true`. Early `return` skips the second `MainActor.run`. Stuck spinner after fast-typing-then-clear.

### UX during long operations (1)
- **R3-H12** (PR-B H2) — `cancel()` while VACUUM is mid-flight: button stays disabled for minutes with no `.cancelling` phase, no `sqlite3_interrupt`. UI looks frozen.

### Defensive parsing residuals (4)
- **R3-H13** (PR-C H1) — IH3 per-element decode via `JSONSerialization` round-trip can down-cast Double→Int on whole-second timestamps.
- **R3-H14** (PR-C H2) — IC2 symlink check has three gaps: (a) fires after `fileExists` short-circuit; (b) doesn't detect hardlinks; (c) `try?` on removeItem silences perm-denied.
- **R3-H15** (PR-C H3) — MH7 GUID fallback breaks for empty GUID → zero-byte tar name. Missing lower-bound precondition.
- **R3-H16** (PR-C H4) — IH2 throw isn't caught with specific error type upstream; any pre-schema_version archives become unloadable.
- **R3-H17** (PR-C H5) — IC1 256 MiB cap may reject legit modern attachments (4K video, ProRes). Should raise to 2 GiB at TarReader level with tighter per-caller caps.

### Schema compatibility cliff (3)
- **R3-H18** (PR-E H1) — Existing 23 GB archive has `content='messages'` + mismatched FTS5 shadow rowids. `snippet()` has been returning text from arbitrary other messages this whole time. PR-E fixes new archives only; no migration, no detection, no doc warning.
- **R3-H19** (PR-E H2) — `docs/SCHEMA.md:86-92` still documents the old `content='messages'` DDL. Frozen contract; needs update.
- **R3-H20** (PR-E H3) — Silent LIMIT clamp leaves no pagination signal. Future caller passing `Int.max` for "give me everything" silently gets 1000 and concludes the chat has 1000 messages.

### Test coverage / URI encoding (1)
- **R3-H21** (PR-E H4+H5) — `SQLiteURI` percent-encoding allowlist is plausible but untested. No `SQLiteURITests.swift`. A regression silently breaks MH5/IH6 fixes.

### UI correctness (2)
- **R3-H22** (PR-#74 H1) — `.multilineTextAlignment(.leading)` on `.lineLimit(1)` Text is a no-op (only affects wrapped lines). Comment about bidi defense is wrong. Load-bearing piece is `.frame(maxWidth: .infinity, alignment: .leading)`.
- **R3-H23** (PR-#74 H2) — **Symptom-vs-mechanism mismatch.** Losing *leading* words isn't a "row too narrow" symptom (narrow rows truncate *trailing* end). User's actual bug may not be fixed. Suspect `Spacer(minLength: 8)` in the title HStack or a parent frame computing negative width on iPad split view.

---

## Remediation plan — Round 3

Six themed PRs again. Most are smaller than Round 2 because the fixes are point-edits rather than restructuring.

| PR | Theme | Findings |
|---|---|---|
| **F** | **Stop the bleeding — Critical only** | R3-C1, R3-C2, R3-C4, R3-C6 (doc) |
| **G** | ObjC shim hardening + UX during VACUUM | R3-C3, R3-H9, R3-H12 |
| **H** | Lock primitive (flock-based rewrite) | R3-H5, R3-H6, R3-H7, R3-H8 |
| **I** | iCloud file coordination on every writer op | R3-H1, R3-H2, R3-H3, R3-H4 |
| **J** | Defensive parsing + schema cliff | R3-H13, R3-H14, R3-H15, R3-H16, R3-H17, R3-H18, R3-H19, R3-H20, R3-H21, R3-C5 |
| **K** | UI correctness | R3-H10, R3-H11, R3-H22, R3-H23 |

PR-F is the urgency floor: those four close the active CLAUDE.md P0 violations and stop the silent data-loss scenarios immediately. PRs G–K can land sequentially over subsequent sessions.

After PR-F merges: full retest (Mac compile + iOS tests + DMG build).

---

## Notes
- Test coverage remains a structural concern — 6 unit tests for a writer + reader + iCloud coordination stack is undertested. Adding `SQLiteURITests.swift` (R3-H21) is a starting point but a broader pass is needed before v1.0.0.
- R3-H18's snippet-bug-in-existing-archive is *technically* a pre-existing bug, not a regression — but the user has been seeing wrong snippet contexts in iOS search this whole time. Decide whether to ship an in-app FTS5 rebuild on first open of an old archive, or warn the user to re-archive.
- R3-C6 (MH6 doc) is a low-effort fix worth bundling into PR-F since it's a one-paragraph edit to `docs/SCHEMA.md`.
