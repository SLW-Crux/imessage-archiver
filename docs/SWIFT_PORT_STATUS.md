# Native Swift archiver port — status

Tracking the port of the Python archiver (`src/imessage_archiver/`, ~2000 LoC) into native Swift inside `ios/Sources/Archiver/` so the Mac SwiftUI app does both jobs (Plan B in `docs/EMBEDDED_ARCHIVER_PLAN.md`).

Phase 1 (this PR) proves the toughest pieces work in Swift. Subsequent phases land their own PRs.

---

## Phase 1 — foundation (this PR) ✅

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Apple Epoch ↔ Unix | `db/epoch.py` | `ios/Sources/Archiver/Epoch.swift` | ✅ Complete |
| attributedBody decoder | `db/attributed_body.py` | `ios/Sources/Archiver/AttributedBodyDecoder.swift` | ✅ Complete (uses Foundation `NSUnarchiver` directly — no Python bridge) |
| chat.db snapshot via VACUUM INTO | `db/snapshot.py` | `ios/Sources/Archiver/SourceDBSnapshotter.swift` | ✅ Complete (GRDB + CryptoKit `SHA256`) |
| chat.db read-only reader (chats / messages / attachments) | `db/reader.py` | `ios/Sources/Archiver/SourceDBReader.swift` | ✅ Complete except contacts resolution |

**What this gives us:** Open the live `chat.db`, snapshot it, hash it, enumerate chats and messages, decode `attributedBody` blobs. Enough to prove the read path works in Swift; not yet enough to write an archive.

---

## Phase 2 — contacts + sender resolution

| Module | Swift port | Status |
|---|---|---|
| Contacts.framework lookup | `ios/Sources/Archiver/ContactsResolver.swift` | ⏳ TODO |

Right now `SourceDBReader.rowToMessage` falls back to using the raw handle string as the sender name for received messages. ContactsResolver will use `CNContactStore` to map phone numbers / emails → display names exactly like the Python `db/contacts.py` does. Same opt-in authorization gate.

---

## Phase 3 — archive writer

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Tar writer (append mode) | `core/tar_writer.py` | `ios/Sources/Archiver/TarWriter.swift` | ⏳ TODO (mirror existing `TarReader`) |
| Attachment state classifier + SHA-256 | `core/attachments.py` | `ios/Sources/Archiver/AttachmentScanner.swift` | ⏳ TODO |
| archive.sqlite writer + manifest.json | `core/archive.py` | `ios/Sources/Archiver/ArchiveWriter.swift` | ⏳ TODO |
| Verification (re-hash every file from tar) | `core/verify.py` | `ios/Sources/Archiver/ArchiveVerifier.swift` | ⏳ TODO |

`core/archive.py` is the heaviest module at 523 LoC. The Swift port will reuse all of the file-format constants (schema, tar layout) defined in `docs/SCHEMA.md`.

---

## Phase 4 — incremental merge + locking

| Module | Python source | Swift port | Status |
|---|---|---|---|
| Single-writer lockfile | `core/lock.py` | `ios/Sources/Archiver/ArchiveLock.swift` | ⏳ TODO |
| Incremental append (skip already-archived messages) | `core/merge.py` | `ios/Sources/Archiver/ArchiveMerger.swift` | ⏳ TODO |

---

## Phase 5 — UI integration

| Module | Status |
|---|---|
| `CreateArchiveView.swift` SwiftUI screen | ⏳ TODO |
| Wire `RootView` so `.noBundle` state offers a Create Archive button | ⏳ TODO |
| Progress reporting (Combine `Publisher` or `AsyncStream`) | ⏳ TODO |
| Post-archive: prompt for yearly Calendar reminder, deep-link to Messages "Keep Messages: 1 Year" | ⏳ TODO |

---

## Phase 6 — distribution

| Item | Status |
|---|---|
| Notarized DMG build via `xcodebuild archive` + `notarytool` | ⏳ TODO |
| Sparkle in-app auto-updater (or document manual update path) | ⏳ TODO |
| `.github/workflows/release.yml` to produce notarized artifact on tag | ⏳ TODO |

---

## Cross-cutting follow-ups

- Tests against the existing Python `tests/fixtures/tiny.db` fixture, run by Xcode unit-test target on the Mac scheme.
- Decide on a CLI vs library split: the Swift archiver should be callable from CI / scripts too, not just the GUI. Probably a small `ArchiverCLI.swift` `@main` shim.
- The Python CLI can stay for headless / server users; both implementations write the same bundle format (locked in `docs/SCHEMA.md`).
