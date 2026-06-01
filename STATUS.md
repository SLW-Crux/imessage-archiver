# Status

## Current phase
Post-second-review remediation complete. Awaiting Layer-7 manual sign-off for v1.0.0.

## Completed
- Phase 0–4: Foundations, DB reader, archive writer, CLI, PySide6 GUI
- Phase 5a–5cf: iOS SwiftUI skeleton + search/polish
- Phase 6: yearly workflow polish (Feb-29 fix, 10am default)
- Phase 7: hardening — 50K-message stress, cross-version schema, incremental at scale
- Plan B: complete native Swift port of the Mac archiver (PRs #52, #55–#57)
- Honk rename + iCloud container migration (PR #50, hotfix #67–#68)
- Notarized DMG release pipeline (PRs #58–#66)

## Post-review remediation — Round 1 (PR #12–#18)
Resolved 6 Critical + 14 High + ~18 Medium findings from the original 4-agent code review. See git history for detail.

## Post-review remediation — Round 2 (PR #69–#73)
Resolved 5 Critical + 15 High findings from the June 2026 review (`docs/REVIEW_2026-06.md`). One High deferred — see "Open" section below.

- **PR #69 — PR-A: atomic writes & lockfile safety** — MC1 (orphaned WAL/SHM after rename), MC2 (ArchiveLock O_EXCL atomicity), MH3 (atomic manifest write).
- **PR #70 — PR-B: process safety & crash containment** — MC3 (snapshot dir leak), MH1 (NSUnarchiver ObjC exception shim), MH2 (cancel/start race).
- **PR #71 — PR-C: defensive parsing** — IC1 (TarReader cap 2 GiB → 256 MiB), IC2 (AttachmentCache symlink overwrite), IH2 (manifest schema_version required), IH3 (per-element Reaction decode), MH7 (TarWriter UTF-8 boundary), MH8 (per-chat try/catch in run).
- **PR #72 — PR-D: concurrency & races** — IH1 (manifest read NSFileCoordinator), IH5 (NSMetadataQuery operationQueue), IH7 (ThreadView yearsTask cancellation), IH8 (SearchView post-await cancel check).
- **PR #73 — PR-E: URI / FTS5 / query** — MH4 (FTS5 content='' fix), MH5 + IH6 (strict SQLite URI percent-encoding), IH4 (clamp messages/search LIMIT).

## Open — Round 2 follow-ups
- **MH6 — `attachment_guid` PRIMARY KEY drops N:M joins.** When one attachment is referenced by N messages (forwarded photo, repeat sticker), only the first survives. Fix needs a `message_attachments` link table + schema_version bump + migration plan for the existing 23 GB archive. Tracked separately because it forces a re-archive (or a one-time migration). Decide when ready for v1.0.0 tag.
- ~36 Medium + Low findings deferred — agents' raw reports captured the detail; can be triaged in a follow-up pass.

## Test totals
- Swift: `xcodebuild test` — 6/6 passing
- Mac compile (Debug): BUILD SUCCEEDED
- End-to-end DMG: built, notarized (accepted), stapled, `stapler validate` OK → `dist/HonkiMessageArchiver-0.4.0.dmg`
- iOS unit tests: 6/6 passing on iPhone 17 simulator

## Remaining — human gates only
1. **Layer 7 manual checklist** — install on iPhone + iPad, eyeball fidelity vs the Mac app per `docs/TEST_PLAN.md`. PR #67 + #68 just unblocked this on the user's devices.
2. **Decide on MH6** — re-archive or write migration path.
3. **Tag `v1.0.0`** — once Layer 7 signed off and MH6 resolved.
4. **(Optional) Phase 5g TestFlight** — only if distributing to others.

## Notes
- `/code-review ultra` is queued as a third pass before tagging v1.0.0 (user-triggered, billed).
- The Python codebase under `src/imessage_archiver/` was in scope for the review but the agents focused on the Swift port. Python is legacy; the production Mac archiver is now Swift end-to-end.
