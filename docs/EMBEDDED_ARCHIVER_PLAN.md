# Embedded archiver — one .app, zero external installs

**Goal:** Customer downloads `Honk iMessage Archiver.app`, opens it, taps a button, gets an archive in iCloud. No Python, no GitHub, no terminal.

Today: archive creation is a Python CLI (`imessage-archiver archive`) that a developer runs from the repo after `uv pip install -e .`. The Mac SwiftUI app is reader-only.

This plan folds the archiver into the Mac SwiftUI app so the unified `.app` does both jobs.

---

## Architecture options

| Option | Effort | Distribution | Bundle size |
|---|---|---|---|
| **A. Embedded Python via PyInstaller** | ~1 week | Notarized DMG ✓<br>Mac App Store ✗ (sandbox) | +35 MB |
| **B. Native Swift port of the archiver** | ~3–4 weeks | Notarized DMG ✓<br>Mac App Store ✓ | +0 |

**Recommendation: A first** (ship the unified-app experience this week), then B as a follow-up if App Store distribution becomes a goal.

---

## Plan A — Embedded Python (recommended MVP)

### What changes
1. **PyInstaller spec** at `packaging/imessage_archiver_cli.spec`. Produces a single-file executable `imessage-archiver-bin` that bundles the Python interpreter + the `imessage_archiver` package + all dependencies (PyObjC, click, rich).
2. **Mac build step**: `packaging/build_macos_arm64.sh` runs PyInstaller, copies the binary into the `.app`'s `Contents/Resources/imessage-archiver-bin`, then signs the binary so notarization passes.
3. **Swift wrapper** at `ios/Sources/Archiver/EmbeddedArchiver.swift`. Wraps `Process` invoking the bundled binary; parses stdout for progress JSON (`{"step": "decoded", "progress": 0.45}`).
4. **Archive UI** in the Mac SwiftUI app:
   - Adds a sidebar item "Create Archive" alongside the existing chat list when an archive doesn't exist (or as a menu item when it does)
   - Calls `EmbeddedArchiver.archive(destinationURL:)`
   - Shows progress, success, error
   - Triggers `iCloudCoordinator` to re-scan after completion
5. **Python CLI changes**:
   - Add `--json-progress` flag that emits one JSON line per phase (decoded N messages, processed N attachments, sealing, verifying, complete)
   - Suppress rich progress bars when `--json-progress` is set (terminal UI would corrupt the JSON stream)

### Distribution
- Sign the `.app` with Developer ID (you already have team `7V698GFQCM`)
- Notarize via `notarytool`
- Ship as a `.dmg` from a website / GitHub Releases (no source clone required by users)

### Trade-offs
- **+35 MB** bundle. Acceptable for a desktop app.
- **Subprocess plumbing**. Process launch is reliable on macOS; progress parsing needs care to avoid stdout buffering issues.
- **Sandbox-incompatible**. The Python subprocess accesses `~/Library/Messages/chat.db` directly, which is incompatible with App Sandbox. Users must grant Full Disk Access to the parent .app, which works only for non-sandboxed apps. This rules out Mac App Store but matches our current Mac entitlement choice (sandbox already disabled per `iMessageArchiverMac.entitlements`).
- **PyInstaller + macOS 26**: occasional codesign signature issues on freshly-built binaries. Fix via `codesign --remove-signature` then re-sign as part of the build script.

### Implementation order
1. PyInstaller spec + build script — verify single-binary works on Mac
2. JSON progress in the CLI
3. Swift `EmbeddedArchiver` wrapper with Process
4. SwiftUI "Create Archive" screen
5. Wire to existing iCloudCoordinator post-completion
6. Update CI to build the bundled .app artifact

### File touchpoints
- NEW `packaging/imessage_archiver_cli.spec`
- NEW `packaging/build_macos_arm64.sh`
- NEW `ios/Sources/Archiver/EmbeddedArchiver.swift`
- NEW `ios/Sources/Views/CreateArchiveView.swift`
- MODIFY `src/imessage_archiver/cli/commands.py` (add `--json-progress`)
- MODIFY `ios/Sources/Views/RootView.swift` (add Create-Archive entry point in `.noBundle` state)
- MODIFY `.github/workflows/build_app.yml` (artifact = signed notarized DMG)

---

## Plan B — Native Swift port (long-term)

Each Python module gets a Swift equivalent:

| Python | Swift |
|---|---|
| `db/reader.py` | `Sources/Archiver/SourceDBReader.swift` (GRDB query of chat.db) |
| `db/snapshot.py` | `Sources/Archiver/ChatDBSnapshotter.swift` (copy + sha256) |
| `db/attributed_body.py` | `Sources/Archiver/AttributedBodyDecoder.swift` (NSUnarchiver — already used in PR #31's Python fix; the Swift API is the same Foundation type) |
| `db/contacts.py` | `Sources/Archiver/ContactsResolver.swift` (Contacts.framework via direct Swift import) |
| `core/archive.py` | `Sources/Archiver/ArchiveWriter.swift` (write archive.sqlite + manifest.json) |
| `core/tar_writer.py` | `Sources/Archiver/TarWriter.swift` (we already have TarReader; mirror as writer) |
| `core/attachments.py` | `Sources/Archiver/AttachmentScanner.swift` |
| `core/verify.py` | `Sources/Archiver/ArchiveVerifier.swift` |

Most Swift-side work is mechanical translation. The `attributedBody` decoder is the most novel — but Foundation's `NSUnarchiver` works in Swift directly, no Python bridge needed.

App Sandbox would then be re-enableable since the Mac app would request the bookmarked `~/Library/Messages/` directory via NSOpenPanel + security-scoped bookmark, instead of needing FDA on a subprocess.

---

## Open decisions for you

1. **Plan A or Plan B first?** (A: ship in a week; B: cleaner architecture but month-long port)
2. **Distribution model?** Notarized DMG from a website is simplest. GitHub Releases works fine. Sparkle for in-app auto-update is a follow-up.
3. **Branding on the binary?** PyInstaller can give the binary any name. Currently I've assumed `imessage-archiver-bin`; could be `honk-archiver-bin` or similar.
