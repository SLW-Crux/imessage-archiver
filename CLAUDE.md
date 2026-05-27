# CLAUDE.md — iMessage Archiver

Instructions for Claude Code (claude.ai/code CLI) to autonomously build this project.

---

## Mission

Build the iMessage Archiver: a macOS app (Python/PySide6) that archives iMessage data to a portable SQLite+tar bundle in iCloud Drive, plus an iOS app (Swift/SwiftUI) that reads the bundle. See `BUILDPLAN.md`, `EXPORT_PLAN.md`, `IOS_PLAN.md`, `TEST_PLAN.md` for the full spec.

**Work autonomously through Phases 0–4 (Mac archiver, CLI, GUI). Pause for human at Phase 5 (iOS, requires Apple Developer account setup and Xcode signing).**

---

## Operating Principles

### Autonomy
- Burn tokens until done. No need to check in for routine decisions.
- Make sensible choices and document them in commit messages.
- When uncertain between two reasonable options, pick one, document the trade-off, proceed.
- Pause and ask only at the defined human-in-the-loop gates (see below).

### Non-destructive guarantees
These are NON-NEGOTIABLE. Violating any of these is a P0 bug.

1. **NEVER write to `~/Library/Messages/chat.db`** or any file under `~/Library/Messages/`. Read-only operations only.
2. **NEVER delete files from `~/Library/Messages/Attachments/`** under any circumstances.
3. **Always snapshot before reading.** Copy `chat.db*` to `~/.imessage-archiver/work/` and open the snapshot, never the live file.
4. **Atomic writes only.** Write to `.tmp` paths, fsync, rename. Never overwrite a good archive in place.
5. **Verify before promote.** Every archive must pass SHA-256 verification before atomic rename promotes it to final location.
6. **Append-only archive.sqlite.** Use `INSERT OR IGNORE` for all incremental writes. Never `UPDATE` or `DELETE` user data rows.

If you find yourself writing code that violates these, stop and reconsider.

### Code quality
- Python: 3.12+, type hints on all functions, docstrings on public APIs, `ruff` for lint, `black` for format.
- Swift: idiomatic SwiftUI, no force unwraps, no `print` in production code.
- Tests required for every module before it's considered done.
- Coverage target: 100% on `db/reader.py`, `core/archive.py`, `core/attachments.py`. ≥80% elsewhere.

### Git workflow
- Work on feature branches: `feat/phase-1-db-reader`, `feat/phase-2-archive-writer`, etc.
- Commit frequently, atomic commits with clear messages.
- Open PRs from feature branches to `main`.
- Squash-merge on green CI.
- Tag releases: `v0.1.0`, `v0.2.0`, etc.
- Push to GitHub (remote already configured on dev machine).

### CI enforcement
- GitHub Actions runs on every push and PR.
- Workflow: lint → unit tests → integration tests → archive integrity tests → merge tests.
- **CI must block any PR containing destructive SQL against `chat.db`.** Add a grep step:
  ```yaml
  - name: Reject destructive SQL on chat.db
    run: |
      ! grep -rE "(INSERT|UPDATE|DELETE|DROP|ALTER|REPLACE|TRUNCATE|VACUUM).*chat\.db" src/
  ```

---

## Environment

The dev machine has:
- macOS 13+ (Apple Silicon)
- Python 3.12+ via Homebrew or system
- Xcode 15+ (for Phase 5)
- `git` and `gh` CLI configured with GitHub auth
- Full Disk Access granted to Terminal/iTerm

You can:
- Run shell commands
- Read and write files in the project directory
- Use `gh` CLI for GitHub operations
- Use `git` for version control
- Install Python packages via `uv` or `pip`
- Run `xcodebuild` for iOS work (Phase 5)
- Read `~/Library/Messages/chat.db` for real-data testing (only after Phase 1 reader is built and tested against synthetic fixtures)

You cannot (must not):
- Write to anything under `~/Library/Messages/`
- Modify the user's Calendar without asking
- Push to anywhere other than this project's repo
- Install system-wide software without asking

---

## Project Setup (do this first)

```bash
# Create repo
mkdir -p/Users/stephen-mm/Crux/Xx_Github/SLW_iMessageArchiver
cd/Users/stephen-mm/Crux/Xx_Github/SLW_iMessageArchiver
git init
gh repo create imessage-archiver --public --source=. --remote=origin

# Project structure
mkdir -p src/imessage_archiver/{db,core,formats,gui,cli}
mkdir -p tests/{fixtures,unit,integration}
mkdir -p packaging assets docs

# Standard files
# - README.md (start with stub, fill in over time)
# - LICENSE (MIT)
# - .gitignore (Python, macOS, PyInstaller)
# - pyproject.toml
# - CLAUDE.md (copy this file)
# - BUILDPLAN.md, EXPORT_PLAN.md, IOS_PLAN.md, TEST_PLAN.md (copy from docs)

# Python environment
uv venv
source .venv/bin/activate
uv pip install --upgrade pip
```

### .gitignore must include
```
.venv/
__pycache__/
*.pyc
.pytest_cache/
.ruff_cache/
.coverage
htmlcov/
build/
dist/
*.spec.bak

# macOS
.DS_Store

# NEVER commit anyone's Messages data
*.db
*.db-wal
*.db-shm
chat.db*
.imessage-archiver/
tests/fixtures/real/

# Build artifacts
*.app/
*.dmg
*.zip
```

### pyproject.toml
```toml
[build-system]
requires = ["setuptools>=69", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "imessage-archiver"
version = "0.1.0"
description = "macOS desktop app for archiving iMessage conversations and attachments"
readme = "README.md"
requires-python = ">=3.12"
license = { text = "MIT" }

dependencies = [
    "click>=8.1",
    "rich>=13.0",
    "pyobjc-core>=10.0",
    "pyobjc-framework-Cocoa>=10.0",
    "pyobjc-framework-Contacts>=10.0",
    "pyobjc-framework-EventKit>=10.0",
]

[project.optional-dependencies]
gui = ["PySide6>=6.8"]
build = ["pyinstaller>=6.0"]
dev = [
    "pytest>=8.0",
    "pytest-cov>=5.0",
    "ruff>=0.5",
    "black>=24.0",
    "mypy>=1.10",
]

[project.scripts]
imessage-archiver = "imessage_archiver.cli.commands:cli"

[tool.setuptools.packages.find]
where = ["src"]

[tool.ruff]
line-length = 100
target-version = "py312"

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-v --cov=imessage_archiver --cov-report=term-missing"
```

---

## Execution Order

Follow phases sequentially. Each phase must pass its tests before moving on.

### Phase 0 — Foundations
1. Repo setup (above)
2. CI workflow (`.github/workflows/ci.yml`): lint, type-check, test
3. Add destructive-SQL grep gate to CI
4. Write `tests/fixtures/generate.py` that produces synthetic `chat.db` files
5. Generate `tiny.db`, `medium.db`, `edge.db`, commit to `tests/fixtures/`
6. **Freeze archive bundle format** — write `docs/SCHEMA.md` documenting `archive.sqlite` schema, tar layout, `manifest.json` format
7. Commit, push, tag `v0.0.1-foundations`

### Phase 1 — Mac DB reader
1. `src/imessage_archiver/db/schema.py` — schema constants for source `chat.db`
2. `src/imessage_archiver/db/snapshot.py` — copy `chat.db*` to working dir, hash, return path
3. `src/imessage_archiver/db/reader.py` — all read-only queries
   - `list_chats()`, `messages_in_chat(chat_guid)`, `attachments_for_message(message_guid)`, etc.
   - Use `sqlite3.connect("file:...?mode=ro&immutable=1", uri=True)`
4. `src/imessage_archiver/db/attributed_body.py` — typedstream parser for `attributedBody` blobs
5. `src/imessage_archiver/db/contacts.py` — handle → name resolution via Contacts.framework (PyObjC)
6. `src/imessage_archiver/db/epoch.py` — Apple Epoch ↔ Unix conversion with nanosecond detection
7. Unit tests for every module against fixtures
8. Coverage check: 100% on `db/` package
9. Open PR, merge, tag `v0.1.0-db-reader`

### Phase 2 — Archive writer
1. `src/imessage_archiver/core/attachments.py` — state classifier (LOCAL_PRESENT, MISSING, etc.) + SHA-256
2. `src/imessage_archiver/core/tar_writer.py` — append-mode tar writer, returns `(offset, length)` per write
3. `src/imessage_archiver/core/archive.py`:
   - Schema creation in `archive.sqlite`
   - Insert chats, messages, attachments (INSERT OR IGNORE)
   - Build FTS5 index
   - Write `manifest.json`
4. `src/imessage_archiver/core/verify.py` — read every attachment row, seek tar, hash, compare
5. `src/imessage_archiver/core/merge.py` — incremental merge logic
6. `src/imessage_archiver/core/lock.py` — lockfile with PID, dead-PID cleanup
7. Layer 3 (archive integrity) and Layer 4 (merge) tests passing
8. Open PR, merge, tag `v0.2.0-archive-writer`

### Phase 3 — Mac CLI
1. `src/imessage_archiver/cli/commands.py` — `click` group with subcommands
   - `archive [--dest PATH] [--dry-run]`
   - `verify [--archive PATH]`
   - `stats [--archive PATH]`
   - `merge --source CHAT_DB --archive PATH`
   - `info [--archive PATH]`
   - `setup`
2. `rich` progress bars for long operations
3. Integration test: full archive run end-to-end on `medium.db` fixture
4. **Test on real chat.db** (developer's own) — verify completes, then run Layer 7 manual checks on a few conversations
5. Open PR, merge, tag `v0.3.0-cli`

### Phase 4 — Mac GUI
1. `src/imessage_archiver/gui/app.py` — QApplication entry
2. Three-panel layout (`QSplitter` + `QListView` + custom delegates)
3. Conversation list model backed by `db/reader.py`
4. `QSortFilterProxyModel` for search
5. Preview panel with last 50 messages of selected chat
6. Archive controls panel: destination picker, "Archive All" button, progress
7. Setup screen for Full Disk Access (detect, instruct, link)
8. Post-archive flow: summary + calendar reminder prompt + Messages settings deep link
9. EventKit integration for calendar reminder
10. PyInstaller packaging:
    - `packaging/imessage_archiver.spec`
    - `packaging/build_macos_arm64.sh`
    - Verify `arm64` output via `lipo -archs`
11. GitHub Actions workflow for `.app` build on `macos-14` runner
12. Open PR, merge, tag `v0.4.0-gui`

### PHASE 5 GATE — STOP HERE

**Before starting Phase 5, ask the human:**
- Confirm Apple Developer account is active
- Confirm `iCloud.org.imessagearchiver` container is created in developer.apple.com
- Confirm Xcode signing identity is set up
- Get bundle ID confirmation (suggested: `org.imessagearchiver.ios`)
- Get team ID

### Phase 5 — iOS reader (paused start; resume after gate)
1. Create Xcode project: `xcodebuild` or scripted via `xcodegen` with a `project.yml`
2. Configure iCloud capability, entitlements
3. Add GRDB.swift via Swift Package Manager
4. Implement modules per `IOS_PLAN.md`:
   - 5a: project skeleton, ChatListView with fixture
   - 5b: ThreadView, MessageBubbleView, group chat handling
   - 5c: TarReader, AttachmentCache, AttachmentPreviewView (QuickLook)
   - 5d: SearchView with FTS5
   - 5e: iCloudCoordinator with NSMetadataQuery
   - 5f: polish (info view, empty states, accessibility)
   - 5g: TestFlight upload (human must intervene for signing)
5. Round-trip tests passing (Layer 5)
6. Commit each phase, tag `v0.5.0-ios-skeleton` through `v0.5.6-ios-polish`

### Phase 6 — Yearly workflow polish
1. Refine calendar reminder copy and timing
2. Post-archive "enable Keep Messages: 1 Year" deep link to Messages settings
3. Incremental archive UX in GUI
4. Tag `v0.6.0-yearly-workflow`

### Phase 7 — Hardening
1. Large database tests (use synthetic 50GB+ fixture)
2. iCloud sync edge cases
3. Cross-version macOS/iOS testing
4. Documentation polish
5. Release `v1.0.0`

---

## Human-in-the-Loop Gates

Pause and ask the human before proceeding at these points:

1. **End of Phase 4 / start of Phase 5** — Apple Developer account, iCloud container, signing.
2. **TestFlight upload** — first time only, may require interactive Apple ID auth.
3. **First archive run against real `chat.db`** — confirm developer wants to proceed and has backed up Mac if paranoid.
4. **Tagging `v1.0.0`** — confirm Layer 7 manual checklist signed off.

Outside these gates, work autonomously. When you make a judgement call, document it in the commit message.

---

## Decision Defaults

When the plan is ambiguous, default to:
- Smaller scope over larger
- Read-only over read-write
- Explicit confirmation over silent action
- Native Apple APIs over third-party (especially in iOS)
- Standard library over dependencies (Python)
- Append-only over mutation
- Verify before promote
- Fail loudly over fail silently

---

## When You Get Stuck

If you hit a genuine blocker (not just a routine decision):
1. Document what you tried in a commit on a `wip/` branch
2. Open a GitHub issue describing the blocker
3. Ask the human in your next response
4. Continue with other work that isn't blocked

Genuine blockers include:
- API keys or credentials you don't have
- Apple Developer account actions
- Permissions on the dev machine you can't grant yourself
- Hardware you don't have access to (other Macs for cross-version testing)

Not blockers (just decide):
- Library choices when two are equivalent
- Naming
- File layout within a module
- UI copy
- CI timeout values

---

## Reporting Progress

After every phase, write a `STATUS.md` update at the repo root:
```markdown
# Status

## Current phase
Phase X — [name]

## Completed
- [list]

## In progress
- [list]

## Blocked
- [list, with reasons]

## Next
- [list]
```

Push this with every meaningful commit batch.

---

## Final Notes

This project archives people's personal conversations. Treat the data with the care you'd want for your own messages. When in doubt, do less, verify more, and never write to the source.

Now build it.
