# Status

## Current phase
Phase 1 — Mac DB reader (complete, PR open)

## Completed
- Phase 0: repo setup, CI pipeline, destructive-SQL grep gate, frozen schema (docs/SCHEMA.md), six synthetic fixtures (tiny/medium/edge/ventura/sonoma/sequoia), tag v0.0.1-foundations
- Phase 1: db/schema.py, db/snapshot.py (VACUUM INTO), db/reader.py, db/attributed_body.py, db/contacts.py, db/epoch.py — 100% coverage on all db/ modules (snapshot.py 97%, one untestable defensive re-raise), 88 unit tests passing

## In progress
- Phase 2: archive writer (core/attachments.py, core/tar_writer.py, core/archive.py, core/verify.py, core/merge.py, core/lock.py)

## Blocked
- None

## Next
- Merge feat/phase-1-db-reader → main, tag v0.1.0-db-reader
- Phase 2: archive writer with Layer 3/4 tests
- Phase 3: CLI (click subcommands, rich progress)
- Phase 4: PySide6 GUI + PyInstaller packaging
- STOP at Phase 5 gate (iOS requires Apple Developer account confirmation)
