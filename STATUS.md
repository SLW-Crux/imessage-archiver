# Status

## Current phase
Phase 5b — iOS polish (in progress)

## Completed
- Phase 0: foundations, tag v0.0.1-foundations
- Phase 1: db/ package, 100% coverage, tag v0.1.0-db-reader
- Phase 2: core/ package, 100% coverage, tag v0.2.0-archive-writer
- Phase 3: cli/commands.py, tag v0.3.0-cli
- Phase 4: PySide6 GUI + PyInstaller arm64 packaging, tag v0.4.0-gui
- Phase 5a: iOS SwiftUI reader skeleton — GRDB persistence, TarReader, AttachmentCache, iCloudCoordinator, ChatList/Thread/MessageBubble/Search/ArchiveInfo views, all 20 Swift files parse-clean; tag v0.5.0-ios-skeleton

## In progress
- Phase 5b: Team ID correction (7V698GFQCM), iCloud manifest-change refresh detection, Search reachable from toolbar, iOS CI workflow

## Blocked
- (none active — Xcode build verification pending user confirmation)

## Next
- Phase 5c–5f: attachment thumbnail caching polish, FTS5 snippet highlighting, accessibility audit, Dynamic Type / dark mode passes
- Phase 5g: TestFlight upload (requires interactive Apple ID auth — human gate)
- Phase 6: yearly workflow polish
- Phase 7: hardening + v1.0.0
