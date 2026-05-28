# iMessage Archiver — User Manual

> Looking for the 5-minute path? See [QUICKSTART.md](QUICKSTART.md).

---

## Contents

1. [What this is](#what-this-is)
2. [Concepts](#concepts)
3. [Mac app — GUI](#mac-app--gui)
4. [Mac app — CLI](#mac-app--cli)
5. [iOS reader app](#ios-reader-app)
6. [The yearly workflow](#the-yearly-workflow)
7. [Bundle anatomy](#bundle-anatomy)
8. [Privacy & security](#privacy--security)
9. [Troubleshooting](#troubleshooting)
10. [Building from source](#building-from-source)

---

## What this is

iMessage Archiver lets you safely turn on macOS Messages' **"Keep Messages: 1 Year"** setting without losing anything. It does that by archiving every conversation to a portable bundle in iCloud Drive that you can browse on your iPhone.

There are two apps:

- **Mac archiver** — reads `chat.db`, writes the bundle. CLI + native GUI.
- **iOS reader** — read-only browse of the bundle from iCloud Drive.

You run the archiver once a year. The yearly calendar reminder is built in.

---

## Concepts

### The archive bundle

Everything lives in one folder called `archive.imarchive`. macOS treats it as a single document. Inside:

```
archive.imarchive/
├── archive.sqlite        — every message, every chat, every attachment row, FTS5 search index
├── attachments.tar       — concatenated attachment files (photos, videos, audio)
└── manifest.json         — version info, counts, source hash, timestamps
```

The schema is **frozen at version 1**. Future versions will be additive only — older readers refuse to open newer bundles (with a clear error), not silently mis-interpret them.

### Snapshots, not the live database

The archiver never reads `chat.db` directly. It first runs SQLite's `VACUUM INTO` to produce a clean, WAL-free copy in `~/.imessage-archiver/work/`, then reads from that snapshot. This is essential: if you read the live file while Messages.app is checkpointing the WAL, you can get `SQLITE_CORRUPT` errors and a mangled archive.

### Append-only writes

Every write to `archive.sqlite` is `INSERT OR IGNORE` keyed on Apple's stable GUIDs. Running the same archive twice is a no-op (well, it counts every message as "seen" but writes zero new rows). This means the yearly workflow is dead-simple: just run it again. No state to manage.

### Atomic operations

`manifest.json` is written via `tmp → fsync → rename → fsync(parent)` so it can never be torn by a crash. `attachments.tar` is appended-then-fsynced before the SQLite commit that records the new offsets. The lockfile uses `O_CREAT | O_EXCL` for race-free creation.

---

## Mac app — GUI

Launch from Applications or via `imessage-archiver-gui` (after `pip install`).

### Window layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ◀ Search conversations…                                                  ▶ │
├────────────────┬────────────────────────────────┬───────────────────────────┤
│  Alice Smith   │                                │  Archive Destination      │
│  Bob Jones     │                                │  ┌─────────────────────┐  │
│  Family Group  │       Message preview          │  │ ~/Library/Mobile…   │  │
│  Carol White   │       (last 50 messages)       │  └──── [Browse…] ────┘  │
│  Dave Brown    │                                │                           │
│  Eve Green     │       Tap a message bubble     │  Ready                    │
│  ...           │       to reveal its timestamp  │                           │
│                │                                │  [Archive All Messages]   │
│                │                                │                           │
│                │                                │                           │
│  ──────────    │                                │                           │
│  47 conversations                               │                           │
└────────────────┴────────────────────────────────┴───────────────────────────┘
```

Three panels: left = chat list with search, centre = message preview, right = archive controls.

![main three-panel window with a few conversations loaded](img/mac-gui-main.png)
<sup>📷 *main three-panel window with a few conversations loaded* — capture this and save as `docs/img/mac-gui-main.png`. See [docs/img/README.md](img/README.md).</sup>

### Setup screen (first launch)

If Full Disk Access isn't granted, you see this instead:

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│            Full Disk Access Required                     │
│                                                          │
│   iMessage Archiver needs Full Disk Access to read       │
│   your messages.                                         │
│                                                          │
│   1. Open System Settings                                │
│   2. Go to Privacy & Security → Full Disk Access         │
│   3. Click the lock and authenticate                     │
│   4. Toggle on Terminal (or your current app)            │
│   5. Click Check Again below                             │
│                                                          │
│              [Open Privacy Settings]                     │
│                                                          │
│              [Check Again]                               │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

![the FDA setup screen](img/mac-gui-fda.png)
<sup>📷 *the FDA setup screen* — capture this and save as `docs/img/mac-gui-fda.png`. See [docs/img/README.md](img/README.md).</sup>

### Browsing conversations

The chat list (left panel) loads in the background after the app takes a snapshot of `chat.db` (this takes a few seconds). The status line at the bottom shows "Snapshotting chat.db…" → "Loading conversations…" → "N conversations".

Click any conversation. The right pane loads the last 50 messages with sender names, timestamps, attachment placeholders, and reactions.

**Search.** Type in the search box at the top — the chat list filters live by display name or chat identifier.

### Running an archive

1. **Destination** — defaults to `~/Library/Mobile Documents/iCloud~com~slw~imessage-archiver/Documents/archive.imarchive`. The iOS app's iCloud container — don't change unless you know what you're doing (the iOS app won't find a bundle elsewhere).

2. **Archive All Messages** — click to start. The button disables, a progress bar appears, and the status line shows the chat currently being processed.

3. **During the run** — every 100 messages or so, progress updates. You can keep using the rest of the app (browse conversations) while the archive runs in a background thread.

4. **Completion** — the progress bar disappears, the status line shows totals: `Done — 47,213 messages, 1,224 new attachments`. A new panel appears at the bottom:

```
┌──────────────────────────────────────────────────────┐
│  Next steps — set up the yearly workflow             │
│                                                       │
│  Your messages are now safely archived. To keep     │
│  your Mac fast, enable Messages → Keep Messages:    │
│  1 Year, then set a yearly reminder to re-run        │
│  this archiver.                                       │
│                                                       │
│  [Add Yearly Reminder to Calendar]                    │
│                                                       │
│  [Open Messages Settings…]                            │
└──────────────────────────────────────────────────────┘
```

![post-archive Next-steps panel visible](img/mac-gui-completion.png)
<sup>📷 *post-archive Next-steps panel visible* — capture this and save as `docs/img/mac-gui-completion.png`. See [docs/img/README.md](img/README.md).</sup>

### Add Yearly Reminder to Calendar

Click once. The first click triggers a macOS permission prompt for Calendar access — that prompt is asynchronous, so the click that triggered it can't actually create the event. Click **Allow**, then click the button again. The event is created with:

- **Title**: "Archive iMessages (yearly)"
- **Time**: 10:00 AM, one year from today
- **Recurrence**: yearly
- **Notes**: a one-paragraph explanation

If today is Feb 29 (leap day) the event is created on Feb 28 next year — yearly recurrence then handles future Feb 29s correctly.

### Open Messages Settings

Opens **System Settings → Messages** in the right pane. Look for **Keep Messages** and choose **One Year**.

---

## Mac app — CLI

Installed as `imessage-archiver` via `pip install`.

### Commands

| Command | What it does |
|---|---|
| `imessage-archiver archive` | Snapshot chat.db and write/update the archive bundle |
| `imessage-archiver verify` | SHA-256 every attachment in an existing bundle |
| `imessage-archiver stats` | Print summary statistics (chat count, message count, size) |
| `imessage-archiver merge` | Merge a different chat.db snapshot into an existing bundle |
| `imessage-archiver info` | Print full manifest + last 5 archive runs |
| `imessage-archiver setup` | Check Full Disk Access and walk through first-run setup |

### Common flags

```bash
# Archive
imessage-archiver archive                        # defaults — write to iCloud container
imessage-archiver archive --dry-run              # snapshot + count, no writes
imessage-archiver archive --dest /tmp/test       # write elsewhere
imessage-archiver archive --source backup.db     # snapshot a non-default source

# Verify
imessage-archiver verify                         # default location
imessage-archiver verify --archive /path/...     # specific bundle

# Stats (lightweight — reads manifest.json only)
imessage-archiver stats

# Info (heavier — reads manifest + archive_runs table)
imessage-archiver info
```

### Output format

`archive` uses [rich](https://github.com/Textualize/rich) for live progress bars; `stats` and `info` print Rich tables. Exit codes: `0` success, `1` user error (missing FDA, lock held, missing bundle, verify failure), `2` IO error.

![terminal showing `imessage-archiver archive` with the progress bar](img/cli-archive.png)
<sup>📷 *terminal showing `imessage-archiver archive` with the progress bar* — capture this and save as `docs/img/cli-archive.png`. See [docs/img/README.md](img/README.md).</sup>
![terminal showing the stats Rich table](img/cli-stats.png)
<sup>📷 *terminal showing the stats Rich table* — capture this and save as `docs/img/cli-stats.png`. See [docs/img/README.md](img/README.md).</sup>

---

## iOS reader app

Read-only. Designed to feel like Messages.app.

### First launch

The app reaches into your iCloud container. Three things can happen:

| State | What you see | What to do |
|---|---|---|
| **iCloud not signed in** | "iCloud Not Available" screen | Sign into iCloud in Settings → [Your Name] |
| **No archive yet** | "No Archive Found" screen with "Check Again" button | Run the Mac archiver first; wait for sync |
| **Archive downloading** | iCloud download progress with percentage | Wait — usually a few minutes |
| **Ready** | Chat list appears | Start browsing |

![the No Archive Found screen](img/ios-launch-no-archive.png)
<sup>📷 *the No Archive Found screen* — capture this and save as `docs/img/ios-launch-no-archive.png`. See [docs/img/README.md](img/README.md).</sup>
![the downloading progress screen](img/ios-launch-downloading.png)
<sup>📷 *the downloading progress screen* — capture this and save as `docs/img/ios-launch-downloading.png`. See [docs/img/README.md](img/README.md).</sup>

### Chat list

```
┌───────────────────────────────────────────┐
│  🔍              Archive             ⓘ    │
│  ─────────────────────────────────────    │
│  ⎵ Search conversations            ✕     │
│  ─────────────────────────────────────    │
│                                           │
│  Alice Smith                  2 days ago  │
│  1,247 messages                           │
│  ─────────────────────────────────────    │
│  Bob Jones                    1 week ago  │
│  342 messages                             │
│  ─────────────────────────────────────    │
│  Family 👨‍👩‍👧‍👦              3 weeks ago    │
│  4,891 messages          [group]          │
│  ─────────────────────────────────────    │
│  ...                                      │
└───────────────────────────────────────────┘
```

- Tap a conversation to open the thread.
- 🔍 (top-left) opens **Search** — full-text search across every message.
- ⓘ (top-right) opens **Archive Info** — manifest stats.
- The local search bar filters the displayed conversations by name.

![the chat list view with several conversations](img/ios-chat-list.png)
<sup>📷 *the chat list view with several conversations* — capture this and save as `docs/img/ios-chat-list.png`. See [docs/img/README.md](img/README.md).</sup>

### Thread view

iMessage-style bubbles. Right-aligned blue for messages you sent, left-aligned grey for everyone else. Sender name above each message in group chats (only on the first message in a sequence from the same sender, like Messages.app does).

- **Tap a bubble** — reveals its timestamp underneath.
- **Date separators** between days.
- **Pagination** — 200 messages at a time. Scroll to the top and tap **Load earlier messages** to fetch the next batch.
- **Reactions** — small bubbles below the message text, grouped by emoji with a count if multiple people sent the same one.
- **Edited messages** — show "(edited)" inline.
- **Unsent messages** — show "Message unsent" in italics where the text used to be.

![a thread with multiple messages, reactions visible, date separator](img/ios-thread-view.png)
<sup>📷 *a thread with multiple messages, reactions visible, date separator* — capture this and save as `docs/img/ios-thread-view.png`. See [docs/img/README.md](img/README.md).</sup>

### Attachments

Messages with attachments show a thumbnail grid below the text:

- **Images** — actual thumbnail loaded from the cache
- **Videos** — play-icon placeholder
- **Audio** — waveform placeholder
- **Other** — generic file icon with the filename

Tap any thumbnail to open **QuickLook**, the same preview macOS uses in Finder — supports images, videos, PDFs, audio, text, and most common formats.

> **First attachment tap is slow.** `attachments.tar` is large (this is where most of the bytes live) and iCloud doesn't support partial download. The first time you tap an attachment in a session, iOS downloads the entire tar. Subsequent taps are instant. The download is one-time per session.

![thread with image thumbnails](img/ios-attachment-grid.png)
<sup>📷 *thread with image thumbnails* — capture this and save as `docs/img/ios-attachment-grid.png`. See [docs/img/README.md](img/README.md).</sup>
![QuickLook open on a photo](img/ios-quicklook.png)
<sup>📷 *QuickLook open on a photo* — capture this and save as `docs/img/ios-quicklook.png`. See [docs/img/README.md](img/README.md).</sup>

### Search

Full-text search backed by SQLite FTS5. Results show:

- Sender name
- Date
- Snippet with matched terms **highlighted in bold + accent color**

Tap a result to jump to that message in its thread.

Search input is sanitised on the client — typing parens, colons, hyphens, etc. won't produce FTS5 syntax errors. Type any word, phrase, or partial: the app wraps each whitespace-separated token in quotes implicitly.

![search view with results showing highlighted snippets](img/ios-search.png)
<sup>📷 *search view with results showing highlighted snippets* — capture this and save as `docs/img/ios-search.png`. See [docs/img/README.md](img/README.md).</sup>

### Archive Info

Tap ⓘ on the chat list. Shows:

- Schema version, archiver version
- Created date, last updated date
- Conversation / message / attachment / missing-attachment counts
- Archive size on disk

![Archive Info screen](img/ios-archive-info.png)
<sup>📷 *Archive Info screen* — capture this and save as `docs/img/ios-archive-info.png`. See [docs/img/README.md](img/README.md).</sup>

### Refresh

The app watches the bundle in iCloud. When the Mac re-archives (a year later) and the new manifest syncs, the app detects the `last_updated_at` change and reloads automatically — you'll see the new messages without restarting.

---

## The yearly workflow

The intended cadence:

1. **Year 1 — Initial archive.** Run the Mac archiver. It captures everything in your `chat.db` (probably 5+ years of history) into a single bundle.
2. **Click "Add Yearly Reminder to Calendar"** in the post-archive panel.
3. **Click "Open Messages Settings…"** and enable Keep Messages: 1 Year. Messages.app starts pruning anything older than a year.
4. **Year 2+** — calendar reminder fires. Run the archiver again. It merges the new year's messages into the existing bundle (idempotent — already-archived rows are no-ops).
5. **Browse on iPhone** any time. The bundle is always in iCloud Drive.

Why yearly: Apple's setting is "1 year" — anything between archive runs that's older than a year gets deleted from `chat.db`. As long as you archive at least annually, you lose nothing.

---

## Bundle anatomy

For reference; you shouldn't need to touch this.

### archive.sqlite tables

| Table | Purpose |
|---|---|
| `chats` | One row per conversation thread |
| `messages` | One row per message (including tapbacks as full rows) |
| `attachments` | One row per attached file with tar offset + length + SHA-256 |
| `archive_runs` | History of every archive invocation (timestamp, source hash, counts) |
| `schema_migrations` | Bundle schema version |
| `messages_fts` | FTS5 external-content index over message text |

### attachments.tar layout

POSIX ustar. Each attachment is one entry: 512-byte header + raw file data + zero padding to next 512-byte boundary. The `tar_offset` column in `attachments` points at the first byte of file data (`header_start + 512`); `tar_length` is the raw file size, unpadded.

iOS reader: `seek(tar_offset)`, `read(tar_length)`, you have the file. No tar header parsing needed.

### manifest.json

Schema version, archiver version, ISO timestamps, source SHA-256, source macOS version, counts. See [SCHEMA.md](SCHEMA.md) for the exact format.

---

## Privacy & security

- **Your messages never leave your devices.** The Mac archiver is local-only; the iOS app reads from your own iCloud container.
- **Read-only against the source.** `chat.db` and `~/Library/Messages/Attachments/` are mounted with `mode=ro&immutable=1` and never modified.
- **No telemetry.** No analytics, no crash reporting to third parties, no network calls except iCloud sync (which is between your Apple devices, end-to-end encrypted by iCloud).
- **Path containment** on attachment reads — a tampered `chat.db` can't drive arbitrary file reads outside `~/Library/Messages/Attachments/`.
- **Bundle integrity** — SHA-256 verified before promotion; iOS reader refuses to open bundles with a schema version it doesn't understand.

The full security review is in the commit history (PRs #12–#18 if you're curious).

---

## Troubleshooting

### "Archive run already in progress (PID nnnn)"

A previous archive crashed and left a stale lockfile. Two cases:

- **PID is running** — actually a previous archive is still going. Wait.
- **PID is dead** — the new lock implementation should reclaim automatically. If it doesn't, delete `~/.imessage-archiver/archive.lock` manually.

### "Cannot open chat.db. Grant Full Disk Access…"

You haven't granted FDA, or you granted it to a different app than the one that's running. Re-check **System Settings → Privacy & Security → Full Disk Access**.

### "Bundle schema version N is newer than this archiver supports"

You opened a bundle written by a future version of the Mac archiver with an older copy. Update.

### iOS app stuck on "Checking iCloud…"

iCloud Drive disabled at the system level. Open **Settings → [Your Name] → iCloud → iCloud Drive** and toggle on.

### iOS app shows "No Archive Found" even after running the Mac archiver

Two possibilities:

1. **iCloud hasn't synced yet.** Bundles can be hundreds of MB to tens of GB. First sync can take hours. Check the Mac's iCloud upload progress in **Finder → iCloud Drive**.
2. **Mac wrote to the wrong location.** Run `imessage-archiver info` on the Mac. The "Bundle" path must end in `iCloud~com~slw~imessage-archiver/Documents/archive.imarchive`. If it ends in `com~apple~CloudDocs/...` you have an old/custom config — re-run with the default `--dest`.

### iOS app shows messages but no attachments

`attachments.tar` is still downloading. Tap any attachment to trigger the download. iCloud cannot partial-download a tar, so the entire file (which can be many GB) must arrive before any attachment opens. Once downloaded, it's cached locally.

### "Verify failed: N failures out of M"

A corrupted attachments.tar or archive.sqlite. Causes:

- iCloud sync interrupted mid-upload
- Disk error on the Mac
- Manual modification

Recovery: rename the bad bundle (don't delete!), run a fresh archive (`imessage-archiver archive`). Compare bundles using `imessage-archiver info` on both.

---

## Building from source

### Mac archiver

```bash
git clone https://github.com/SLW-Crux/imessage-archiver.git
cd imessage-archiver
uv venv && source .venv/bin/activate
uv pip install -e ".[dev,gui]"

# Generate test fixtures (optional but recommended)
python tests/fixtures/generate.py

# Run tests
pytest

# Use the CLI
imessage-archiver --help

# Use the GUI
python -m imessage_archiver.gui.app

# Build a .app bundle (Apple Silicon)
./packaging/build_macos_arm64.sh
```

### iOS reader

```bash
brew install xcodegen
cd ios
./regenerate.sh                # generates iMessageArchiver.xcodeproj
open iMessageArchiver.xcodeproj

# In Xcode:
# - Pick your device or simulator
# - Cmd-R to run
# - First build will prompt for code signing — pick your Team ID
```

> The Xcode project's `DEVELOPMENT_TEAM` is set to `7V698GFQCM` (the maintainer's). Override in `project.yml` for your own team.

---

## Where to file bugs / ask questions

GitHub Issues on the repo. Include:

- macOS version (Mac issues) or iOS version (iOS issues)
- A `imessage-archiver info` output (Mac archiver) — never contains message text, just counts and timestamps
- What you did, what you expected, what happened
