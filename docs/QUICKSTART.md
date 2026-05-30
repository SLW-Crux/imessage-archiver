# Honk iMessage Archiver — Quickstart

A one-screen guide to creating your first archive and reading it on iPhone.

Estimated time: 10 minutes for the Mac side + however long the archive takes to sync (depends on how big your Messages history is).

---

## 1. Install the Mac app

1. Download **Honk iMessage Archiver.dmg** from the latest release.
2. Open the DMG, drag the app into `/Applications`.
3. Open the app for the first time. macOS will warn that it's from an unidentified developer — Right-click → Open → Open (one-time approval).
4. macOS will ask for **Full Disk Access** for the app. Click *Open System Settings* → toggle Honk iMessage Archiver on. Restart the app.

You only need to do this once per Mac.

---

## 2. Create your first archive

1. Open Honk iMessage Archiver. You'll see the **Create Archive** screen.
2. Click **Create Archive**.
3. Watch the progress bar:
   - **Snapshotting Messages database** (a few seconds)
   - **Decoding messages** (~1 minute per 50,000 messages)
   - **Scanning attachments** (depends on attachment count)
   - **Sealing archive** (a few seconds)
   - **Verifying** (couple of minutes for large attachment counts — SHA-256 of every attachment)
4. When it's done, the app switches to the **Read** view automatically. Browse your archived chats to confirm they look right.

The archive is written to your iCloud Drive at `Honk iMessage Archiver` → `archive.imarchive`.

Your original Messages history is **never modified**. The app only reads from `~/Library/Messages/`.

---

## 3. Install the iPhone app

1. Open the App Store on your iPhone → search **Honk iMessage Archiver** → install.
   *(Or install via TestFlight if we're not in the App Store yet — see UPDATE_GUIDE.md.)*
2. Open the app. On first launch, it asks for iCloud Drive access — tap **Allow**.
3. If the archive isn't visible yet, the app shows **Waiting for archive…** while iCloud syncs the bundle to your phone. This can take a while on first sync (Wi-Fi recommended).
4. When the sync completes, the app shows your chat list.

---

## 4. Browse your archive

- **Chat list** (left panel on iPad/Mac, full screen on iPhone): sorted by most recent activity. Tap any chat to open it.
- **Thread view**: most recent messages at the bottom (like Messages.app). Scroll up for older. Tap **Load earlier messages** to page back further.
- **Year picker** (calendar icon, top-right): jump to a specific year of a long conversation.
- **Search** (search bar at the top of the chat list, OR the "Search All Messages" entry): search across every message in every chat.
- **Attachments**: tap any thumbnail to open in QuickLook. Long-press → Copy / Share for text messages.

---

## 5. Update your archive

Whenever you want to capture new messages:

1. Open the Mac app.
2. **File menu** → **Update Archive** (or just press **⌘⇧A**).
3. The Mac app reads new messages since the last archive and appends them. Existing messages are not re-processed (incremental). Attachments are deduplicated by SHA-256.
4. Sync happens automatically — the iPhone app sees the updated archive within a minute or two.

Recommended cadence: once a year, around your iMessage data-retention policy. See **Manual** for the calendar reminder feature.

---

## Troubleshooting

### "No Messages database found"
- The Mac app couldn't read `~/Library/Messages/chat.db`. Usually because **Full Disk Access** isn't granted to the app. System Settings → Privacy & Security → Full Disk Access → toggle on.

### "No Archive Yet" on iPhone
- The iCloud sync hasn't completed yet. Open the Files app → iCloud Drive → confirm **Honk iMessage Archiver** appears and **archive.imarchive** is visible. If it's downloading, wait for it to finish (Wi-Fi makes this much faster).
- Verify both devices are signed in to the same iCloud account, and iCloud Drive is enabled in Settings on each.

### Attachments show "Not Included"
- This is expected for messages where the attachment was never on disk (e.g., the sender deleted it before the archive was created, or it was a sticker/effect that doesn't persist). The app surfaces this honestly rather than pretending it can be re-downloaded.

### Messages take forever to load when opening a chat
- Probably the first time you opened the app after a big sync — iCloud is downloading the SQLite metadata. Subsequent opens are instant.

---

## What's archived

- **Every chat** including group chats and 1:1s.
- **Every message** — text, attachments, reactions/tapbacks, replies, retracted messages (marked as such).
- **Every attachment** that exists on disk at archive time — photos, videos, audio, PDFs.
- **Sender names** resolved via Contacts.framework where available, otherwise raw handle (phone / email).

## What's NOT archived

- Messages that have been *unsent* and the original text wiped (iOS 16+ unsend leaves a tombstone, which IS archived).
- Stickers, message effects, GamePigeon games — these aren't real attachments.
- Read receipts (not stored in chat.db).
