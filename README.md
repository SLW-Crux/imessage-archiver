# iMessage Archiver

Archive your iMessage conversations to a portable bundle in iCloud Drive, then browse them on your iPhone.

---

## What it does

iMessage Archiver is a two-app system for keeping your iMessage history safe **after** you turn on macOS Messages' **"Keep Messages: 1 Year"** option (which deletes messages older than a year and saves a lot of Mac disk space).

- **Mac archiver** (Python + PySide6) reads `~/Library/Messages/chat.db` once a year, snapshots it safely (never modifies your messages), and writes a single self-contained `archive.imarchive` bundle to iCloud Drive. The bundle contains every conversation, every message, every attachment.
- **iOS reader** (SwiftUI) opens the bundle from iCloud Drive on your iPhone. You browse threads in a Messages-style UI, tap attachments for QuickLook preview, full-text search across every message you've ever sent or received.

The bundle is **portable**. If you ever stop using this app, the archive is a plain SQLite database plus a tar of attachments — you can read it with any tool that speaks those formats, indefinitely.

---

## Why

Apple's "Keep Messages: 1 Year" setting is great for Mac performance but it actually **deletes** the old messages — no undo, no backup, gone. Most people are reluctant to enable it because of that. This archiver gives you a "yes, I have a backup, it's fine to enable the 1-year limit" workflow.

The yearly cadence comes from the reality that people forget. The app installs a yearly calendar reminder when you finish an archive so you don't have to remember.

---

## Components

| Component | Where it runs | Purpose |
|---|---|---|
| **Mac archiver CLI** (`imessage-archiver`) | Terminal, macOS 13+ | Scripted/cron-friendly archive runs |
| **Mac archiver GUI** | macOS 13+ Apple Silicon | Three-panel browse + archive UI |
| **iOS reader app** | iOS 17+ | Read-only browse of the archive in iCloud Drive |

---

## Non-destructive guarantees

These are non-negotiable invariants. Every feature is built around them:

1. Never writes to `~/Library/Messages/chat.db`.
2. Never deletes from `~/Library/Messages/Attachments/`.
3. Always works against a SQLite snapshot, never the live database.
4. Atomic writes only — partial archives never replace good ones.
5. SHA-256 verified before promotion to final location.
6. Append-only `archive.sqlite` — never updates user-data rows.

If any guarantee is violated, the archive aborts with a clear error.

---

## Get started

- **[QUICKSTART.md](docs/QUICKSTART.md)** — install and run your first archive in 5 minutes
- **[HELP.md](docs/HELP.md)** — full user manual with screenshots
- **[SCHEMA.md](docs/SCHEMA.md)** — bundle format reference (for tool authors)
- **[BUILDPLAN.md](docs/BUILDPLAN.md)** — architecture and implementation plan

---

## Status

See [STATUS.md](STATUS.md) for current development status.

## License

MIT
