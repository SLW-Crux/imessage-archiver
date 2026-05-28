# Status

## Current phase
Post-review remediation complete. Awaiting Layer-7 manual sign-off for v1.0.0.

## Completed
- Phase 0–4: Foundations, DB reader, archive writer, CLI, PySide6 GUI
- Phase 5a–5cf: iOS SwiftUI skeleton + search/polish
- Phase 6: yearly workflow polish (Feb-29 fix, 10am default)
- Phase 7: hardening — 50K-message stress, cross-version schema, incremental at scale

## Post-review remediation (PR #12–#18)
Resolves 6 Critical + 14 High + ~18 Medium findings from a 4-agent code review:

- **PR #12** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/12)): align Mac archiver destination with iOS ubiquity container (the two halves can now actually see each other); doc bundle-ID drift fix; .gitignore cleanup
- **PR #13** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/13)): schema-version refusal + atomic writes (write→fsync→rename→fsync-parent) + lock O_EXCL atomicity + tapback filter
- **PR #14** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/14)): GUI now reads from a snapshot (was opening live chat.db with immutable=1 — direct CLAUDE.md violation); worker race fixes (last-write-wins, closeEvent cleanup); pytest-qt + pytest-timeout
- **PR #15** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/15)): iOS AttachmentCache path-traversal sanitisation + containment check; pin/unpin to protect QuickLook URL; TarReader bounds checks + short-read loop; JSON index sidecar
- **PR #16** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/16)): iOS schema-version refusal; Reaction decoder accepts both Double + String timestamps; FTS5 query sanitisation; PUA sentinels (no FSI/PDI collisions); manifest-load failure path; event-token ordering
- **PR #17** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/17)): attachment-path containment to ~/Library/Messages/Attachments/; attributed_body 2 MiB size cap; FDA detection distinguishes ENOENT from EACCES; subprocess returncode check
- **PR #18** ([merged](https://github.com/SLW-Crux/imessage-archiver/pull/18)): CLI failure-path coverage; CI destructive-SQL grep self-test; real FTS5 content tests; deterministic fixture timestamps

## Test totals
- **225 tests pass** (was 188 before remediation; +37 net) in 14.4s
- ruff, black, mypy all clean
- 21 Swift files parse-clean (`swiftc -parse`)

## Remaining — human gates only
1. **Layer 7 manual checklist** — run archiver against your real chat.db, eyeball fidelity in Mac GUI + iOS app per docs/TEST_PLAN.md. Required per CLAUDE.md before `v1.0.0`.
2. **Tag `v1.0.0`** — once Layer 7 signed off.
3. **(Optional) Phase 5g TestFlight** — only if distributing to others.

## Notes
- `/code-review ultra` would be a useful second pass before v1.0.0 (more thorough than my 4-agent parallel review; user-billed/user-triggered).
- iOS CI workflow expects an iOS Simulator runtime — you may need to install it via Xcode → Settings → Components if not already present.
