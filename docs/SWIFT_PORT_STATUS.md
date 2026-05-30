# Native Swift archiver port — status

Tracking the port of the Python archiver (`src/imessage_archiver/`, ~2000 LoC) into native Swift inside `ios/Sources/Archiver/` so the Mac SwiftUI app does both jobs (Plan B in `docs/EMBEDDED_ARCHIVER_PLAN.md`).

---

## Phase 1 — foundation ✅

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Apple Epoch ↔ Unix | `db/epoch.py` | `Epoch.swift` | ✅ |
| attributedBody decoder | `db/attributed_body.py` | `AttributedBodyDecoder.swift` | ✅ (NSKeyedUnarchiver primary, NSUnarchiver fallback for legacy typedstream) |
| chat.db snapshot via VACUUM INTO | `db/snapshot.py` | `SourceDBSnapshotter.swift` | ✅ |
| chat.db read-only reader | `db/reader.py` | `SourceDBReader.swift` | ✅ |

## Phase 2 — contacts + sender resolution ✅

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Contacts.framework lookup | `db/contacts.py` | `ContactsResolver.swift` | ✅ (actor; LRU-capped per-process cache) |

## Phase 3 — archive writer ✅

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Tar writer (append mode + PAX) | `core/tar_writer.py` | `TarWriter.swift` | ✅ |
| Attachment state + SHA-256 | `core/attachments.py` | `AttachmentScanner.swift` | ✅ (CryptoKit `SHA256`) |
| archive.sqlite + manifest.json | `core/archive.py` (523 LoC) | `ArchiveWriter.swift` | ✅ (schema + inserts + FTS5 + tapback denormalisation + atomic manifest write) |
| Verification (re-hash from tar) | `core/verify.py` | `ArchiveVerifier.swift` | ✅ |

## Phase 4 — locking + incremental merge ✅

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Single-writer lockfile | `core/lock.py` | `ArchiveLock.swift` | ✅ (PID sidecar + dead-PID stealing) |
| Incremental merge | `core/merge.py` | `ArchiveMerger.swift` | ✅ (pre-flight source-vs-bundle timestamp check) |

---

## Phase 5 — SwiftUI integration (next PR)

| Module | Status |
|---|---|
| `CreateArchiveView.swift` SwiftUI screen | ⏳ TODO |
| Wire `RootView` `.noBundle` state to launch the writer | ⏳ TODO |
| Progress bridge (async writer → `@Observable` state) | ⏳ TODO |
| Post-archive prompt for yearly Calendar reminder | ⏳ TODO |

## Phase 6 — distribution

| Item | Status |
|---|---|
| `xcodebuild archive` + `notarytool` script | ⏳ TODO |
| Sparkle in-app auto-updater | ⏳ TODO |
| `.github/workflows/release.yml` on tag | ⏳ TODO |

---

## Architectural notes

- **GRDB everywhere.** Both reader (chat.db) and writer (archive.sqlite) use GRDB.swift to keep the SQL interface uniform across the codebase. The reader opens with `file:?mode=ro&immutable=1`; the writer opens read-write WAL with atomic `.tmp → rename` for first-time builds.
- **Foundation NSUnarchiver** for legacy chat.db typedstream blobs is wrapped in a single `@available(*, deprecated)` function whose comment documents why suppression is intentional and non-removable. `NSKeyedUnarchiver` does not understand typedstream and would silently drop ~75% of older message text — the same lesson Python learned in PR #31.
- **Contacts** uses an actor with a 2048-entry per-process LRU cache. Authorization status is probed before any `unifiedContacts` call to avoid the silent-hang failure mode (`.notDetermined` would block on a permission prompt that may never arrive in CI / headless contexts).
- **Tar writer** is fully byte-compatible with the existing `TarReader`: each `append()` returns the *file-data* byte offset, with PAX extended headers correctly accounted for by deriving offset from end-of-write rather than `header_start + 512` (same fix landed in Python in PR #20).
- **The Python CLI remains useful** for headless / server use. Both implementations write the same bundle format (locked in `docs/SCHEMA.md`), so an archive built by the Python CLI is readable by the SwiftUI reader and vice versa.
