# Screenshots for HELP.md

Placeholders referenced by `docs/HELP.md`. Replace with actual PNGs (≤1MB each, ideally 1200–1600px wide for Mac shots and 750–828px wide for iPhone shots).

## Mac screenshots

| Filename | What to capture |
|---|---|
| `mac-gui-main.png` | Main three-panel window with several conversations loaded in the left list, a message thread visible in the centre, and the archive controls panel on the right (in "Ready" state, before archiving) |
| `mac-gui-fda.png` | The Full Disk Access setup screen — what users see on first launch before granting FDA |
| `mac-gui-completion.png` | The post-archive state: status line shows "Done — N messages…", and the "Next steps" group box is visible at the bottom of the right panel with both buttons |
| `cli-archive.png` | Terminal running `imessage-archiver archive` showing the Rich progress bar mid-run |
| `cli-stats.png` | Terminal output of `imessage-archiver stats` showing the Rich-formatted table |

## iOS screenshots

| Filename | What to capture |
|---|---|
| `ios-launch-no-archive.png` | "No Archive Found" screen with the "Check Again" button |
| `ios-launch-downloading.png` | Download progress screen with iCloud icon and percentage |
| `ios-chat-list.png` | Chat list view with 5+ conversations, search bar visible, toolbar buttons (🔍 and ⓘ) visible |
| `ios-thread-view.png` | A thread with sent (blue) and received (grey) bubbles, a date separator, a reaction visible on at least one message, ideally one bubble with the timestamp revealed (tapped) |
| `ios-attachment-grid.png` | A message bubble with 3-4 image thumbnails in the grid below the text |
| `ios-quicklook.png` | QuickLook open full-screen on a photo attachment |
| `ios-search.png` | Search view with a few results, snippets visible, matched terms highlighted in bold + accent color |
| `ios-archive-info.png` | Archive Info screen showing the manifest details (counts, sizes, dates) |

## Capture tips

- **Mac**: ⌘⇧4 then space then click the window — captures the window only with shadow. Save to `docs/img/`.
- **iOS**: side-button + volume-up. AirDrop to Mac, drop into `docs/img/`.
- Hide sensitive info: blur or replace contact names / phone numbers / message text in the captured shots before committing.

## Workflow

After capturing:

1. `cp ~/Downloads/Screenshot\ 2026-*.png docs/img/mac-gui-main.png` (etc.)
2. Optimise: `pngquant --quality=65-80 docs/img/*.png --ext .png --force`
3. Verify HELP.md references render: open `docs/HELP.md` in any markdown previewer.
