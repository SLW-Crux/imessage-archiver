# Updating Honk iMessage Archiver

How to update both the **app** and your **archive**.

---

## Updating the app

There are two distribution paths depending on where you got the app from.

### From the App Store (when available)
The App Store handles updates automatically. If you have **Settings → App Store → Automatic Updates** on, the update happens silently overnight. Otherwise, the App Store will badge with an update notification.

### From a DMG download (current method)
The Mac app is currently shipped as a notarized DMG from the Honk website / GitHub Releases. There's no in-app auto-updater yet (Sparkle integration is on the roadmap).

To update manually:

1. **Quit the running app** (⌘Q).
2. Download the new DMG from [releases page URL].
3. Open the DMG.
4. Drag the new **Honk iMessage Archiver.app** into `/Applications`, accepting the "Replace" prompt.
5. Eject the DMG.
6. Re-open the app.

Your existing archive in iCloud Drive is untouched. The new version reads the same `archive.imarchive` bundle.

**Verifying you have the new version:** App menu → **About Honk iMessage Archiver**. Check the version number matches what's on the releases page.

### iPhone app

The iPhone app updates via the App Store (or TestFlight if you're on the beta channel). Same process as any other iOS app:

- **Automatic:** Settings → App Store → toggle App Updates on. Updates happen overnight while charging.
- **Manual:** App Store → Apple ID icon (top right) → scroll to "Available Updates" → tap **Update** next to Honk iMessage Archiver.

---

## Updating your archive

Archives are not auto-refreshed. New messages in Messages.app don't appear in your archive until you trigger an update.

### Incremental update (recommended)

1. Open the Mac app.
2. **File menu** → **Update Archive** (⌘⇧A).
3. The app:
   - Snapshots your current `chat.db`
   - Finds messages newer than the last archived message
   - Decodes them, fetches new attachments
   - Appends to the existing archive in iCloud
   - Re-seals + verifies
4. iCloud syncs the updated bundle to your iPhone within minutes.

This is fast — only new content is processed. Existing messages and attachments are not re-processed.

### Full re-archive (rare)

If your archive ever feels stale or you've changed iCloud accounts, you can wipe and re-create:

1. Open the Mac app.
2. **File menu** → **Re-create Archive…** → confirm.
3. The app deletes the iCloud archive and starts fresh.
4. Re-archive takes as long as your first archive did.

Use this only when you genuinely need to start over. Incremental updates are nearly always the right choice.

### Scheduled reminders

The Mac app can add a yearly reminder to your Calendar to refresh the archive. After your first archive, the app asks "Add yearly reminder?" — accepting creates a one-shot Calendar event for one year from now.

You can also do this manually: **App menu → Add Yearly Reminder**.

---

## Migrating from an older container

If you originally archived under the legacy `com.slw.imessage-archiver` container (early-access versions):

1. Open the renamed Mac app once so the new container `iCloud.com.honk.imsgarchiver-mac` registers with iCloud.
2. Open the renamed iOS app once on your phone so the iOS container `iCloud.com.honk.imsgarchiver` registers.
3. On the Mac, run this in Terminal to clone the old archive into both new containers:
   ```bash
   SRC="$HOME/Library/Mobile Documents/iCloud~com~slw~imessage-archiver/Documents/archive.imarchive"
   cp -Rc "$SRC" "$HOME/Library/Mobile Documents/iCloud~com~honk~imsgarchiver-mac/Documents/"
   cp -Rc "$SRC" "$HOME/Library/Mobile Documents/iCloud~com~honk~imsgarchiver/Documents/"
   rm -f "$HOME/Library/Mobile Documents/iCloud~com~honk~imsgarchiver-mac/Documents/archive.imarchive/archive.sqlite-"{wal,shm}
   rm -f "$HOME/Library/Mobile Documents/iCloud~com~honk~imsgarchiver/Documents/archive.imarchive/archive.sqlite-"{wal,shm}
   ```
   (`cp -c` uses APFS clone-on-write — both copies share disk blocks until something diverges.)
4. After the next Mac update of your archive, the legacy container can be deleted from iCloud Drive.

---

## Rollback

If a new version misbehaves and you want to roll back:

1. Quit the app.
2. Visit the releases page → download the previous version's DMG.
3. Replace the .app in /Applications.

Archives are forward-compatible with the *current* schema version. Rolling back from a future schema bump may require re-creating the archive on the older version. Schema bumps will be called out in release notes.
