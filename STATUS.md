# Status

## Current phase
Phase 7 — hardening (complete; v1.0.0 paused on human-in-the-loop gate)

## Completed
- Phase 0: foundations, tag v0.0.1-foundations
- Phase 1: db/ package, 100% coverage, tag v0.1.0-db-reader
- Phase 2: core/ package, 100% coverage, tag v0.2.0-archive-writer
- Phase 3: cli/commands.py, tag v0.3.0-cli
- Phase 4: PySide6 GUI + PyInstaller arm64 packaging, tag v0.4.0-gui
- Phase 5a: iOS SwiftUI reader skeleton, tag v0.5.0-ios-skeleton
- Phase 5b: Team ID correction, bundle refresh detection, iOS CI, tag v0.5.1-ios-polish
- Phase 5c-f: FTS5 snippet highlighting, debounced search, test fixture, tag v0.5.2-ios-search
- Phase 6: yearly workflow polish (Feb 29 fix, 10am default, better copy), tag v0.6.0-yearly-workflow
- Phase 7: hardening — large-DB stress test (50K msgs <60s), cross-version schema coverage (ventura/sonoma/sequoia), incremental idempotence at scale; 188 tests passing

## In progress
- (none — Phase 7 work landed, v1.0.0 awaiting human gate)

## Blocked / Human gates
- **v1.0.0 release**: requires Layer 7 manual checklist sign-off per CLAUDE.md
- **Phase 5g (TestFlight)**: requires interactive Apple ID auth; cable install via Xcode is the easier alternative for now

## Next
- Manual Layer 7 walkthrough on real chat.db (Layer 7 checklist in TEST_PLAN.md)
- Sign-off and tag v1.0.0 — needs human confirmation
