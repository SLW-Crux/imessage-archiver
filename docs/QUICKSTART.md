# Quickstart

Five-minute path from "nothing installed" to "archive in iCloud Drive, browsing on your iPhone."

This guide assumes you have:

- A Mac running macOS 13 (Ventura) or newer
- An iPhone running iOS 17 or newer, signed into the same iCloud account as the Mac
- The iOS reader app installed on your iPhone (from TestFlight or the App Store)
- Active iCloud Drive on both devices

If you are building the apps yourself from source, see [HELP.md → Building from source](HELP.md#building-from-source) first.

---

## Step 1 — Grant Full Disk Access (one-time)

The archiver reads `~/Library/Messages/chat.db`, which macOS protects. You need to allow this once.

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Toggle on **Terminal** (or your preferred terminal app — iTerm2, Ghostty, etc.)
3. If you're using the GUI app: toggle on **iMessage Archiver**

> If you skip this step the app will show a setup screen explaining what to do, with a button that opens the right settings pane.

---

## Step 2 — Run your first archive

Two options. Pick one.

### Option A — GUI (recommended for first time)

1. Open the **iMessage Archiver** app
2. The three-panel window appears — your conversations are in the left list, click any to preview on the right
3. Click **Archive All Messages** in the right-hand panel
4. A progress bar tracks the run. Typical times:
   - 10,000 messages: ~5 seconds
   - 100,000 messages: ~30 seconds
   - 500,000 messages: ~3 minutes
5. When it completes, you'll see a "Next steps" panel with two buttons:
   - **Add Yearly Reminder to Calendar** — recommended, this is the whole point
   - **Open Messages Settings…** — to enable "Keep Messages: 1 Year"

### Option B — CLI

```bash
imessage-archiver archive
```

That's it. Defaults are sensible — output goes to the iOS app's iCloud container so the iPhone can find it.

Useful flags:

```bash
imessage-archiver archive --dry-run        # count messages without writing
imessage-archiver archive --dest /path     # custom output location
imessage-archiver verify                   # SHA-256 check existing archive
imessage-archiver stats                    # show counts and dates
imessage-archiver info                     # show full manifest + run history
```

---

## Step 3 — Wait for iCloud to sync

The archive is now at:

```
~/Library/Mobile Documents/iCloud~com~slw~imessage-archiver/Documents/archive.imarchive/
```

iCloud uploads it in the background. Typical times:

- 1 GB archive: 5–30 minutes depending on upload speed
- 20 GB archive: a few hours

The Mac doesn't have to stay awake — but it does have to be plugged in or on Wi-Fi for iCloud to upload.

---

## Step 4 — Open the iOS reader

1. On your iPhone, open **iMessage Archive** (the iOS app)
2. First time only, the app will download the bundle from iCloud (you'll see a progress indicator)
3. Once the chat list appears, browse normally:
   - Tap any conversation to read the thread
   - Tap the search icon (top-left) to search across all messages
   - Tap an attachment to view in QuickLook
   - Tap the info icon (top-right) for archive stats

> The first attachment tap triggers download of `attachments.tar` — the file is large (this is where most of the bytes live) so this can take a few minutes on cellular. Subsequent attachments are instant because the tar is cached locally.

---

## Step 5 — Enable "Keep Messages: 1 Year" on the Mac

This is the whole point.

1. Open **Messages → Settings → General**
2. Set **Keep Messages** to **One Year**

> Don't worry — your archive in iCloud Drive is independent of what Messages keeps. If you ever need a message older than a year, open the iOS app or `imessage-archiver verify` your bundle and you'll find it there.

---

## Step 6 — Confirm the yearly reminder

Open **Calendar** on your Mac. Search for "Archive iMessages". You should see a yearly recurring event at 10am one year from now. When it fires, run **Step 2** again.

---

## Troubleshooting

**"Full Disk Access required" screen on first launch**
You skipped Step 1. Click **Open Privacy Settings** and toggle on Terminal / iMessage Archiver.

**"Archive run already in progress"**
A previous archive crashed and left a stale lockfile. Either wait for it to finish (most likely) or delete `~/.imessage-archiver/archive.lock` and try again.

**iOS app shows "No archive found"**
Either (a) the iCloud upload hasn't finished, (b) the Mac archive ran but to the wrong location. Check `imessage-archiver info` on the Mac to confirm the bundle exists at the expected path.

**iOS app schema-too-new error**
Your Mac archiver is newer than your iOS reader. Update the iOS app via TestFlight / App Store.

**Calendar reminder didn't appear**
The first time you click "Add Yearly Reminder" macOS asks for Calendar access. Click **Allow**, then click the button again — the first click is consumed by the permission prompt.

---

For the full feature reference, see [HELP.md](HELP.md).
