# Status

## Current phase
Phase 4 — GUI (complete, merged, tagged v0.4.0-gui)

## Completed
- Phase 0: foundations, tag v0.0.1-foundations
- Phase 1: db/ package, 100% coverage, tag v0.1.0-db-reader
- Phase 2: core/ package, 100% coverage on archive/tar/verify/merge, tag v0.2.0-archive-writer
- Phase 3: cli/commands.py — archive, verify, stats, merge, info, setup subcommands with rich progress bars; tag v0.3.0-cli
- Phase 4: PySide6 GUI — three-panel layout (chat list | message preview | archive panel), FDA setup screen, EventKit calendar reminder, Messages settings deep link, PyInstaller arm64 packaging, macOS CI workflow; tag v0.4.0-gui

## In progress
- (none)

## Blocked
- Phase 5 (iOS) waiting on human gate (see below)

## Next — PHASE 5 GATE

**Do NOT start Phase 5 until the human confirms:**
1. Apple Developer account is active
2. `iCloud.org.imessagearchiver` container created at developer.apple.com
3. Xcode signing identity is configured
4. Bundle ID (suggested: `org.imessagearchiver.ios`)
5. Team ID

Once confirmed, proceed with Phase 5 (iOS SwiftUI reader).
