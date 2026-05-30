#!/usr/bin/env bash
# capture-screenshots.sh — produce the canonical set of screenshots used
# by the QUICKSTART guide and any future App Store listing.
#
# What this captures:
#   1. mac/01-no-archive.png    — Mac app at first launch, "No Archive Yet"
#   2. mac/02-create-progress.png — Mac app mid-archive (you trigger; we shoot at +15s)
#   3. mac/03-chat-list.png     — Mac app browsing the archive
#   4. mac/04-thread.png        — Mac app inside a chat thread
#   5. ios/01-no-archive.png    — pulled from a Simulator (requires renamed iOS app installed)
#   6. ios/02-chat-list.png     — Simulator chat list
#   7. ios/03-thread.png        — Simulator thread view
#
# Requirements:
#   - Renamed apps (PR #50) installed on this Mac and on at least one Simulator
#   - The Mac app shown on a primary display (screencapture default)
#   - For iOS: an iOS Simulator running the renamed app
#
# Usage:
#   bash scripts/capture-screenshots.sh
#
# All outputs land in assets/screenshots/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/assets/screenshots"
mkdir -p "$OUT_DIR/mac" "$OUT_DIR/ios"

MAC_APP_BUNDLE_ID="com.honk.imsgarchiver-mac"
IOS_SIM_BUNDLE_ID="com.honk.imsgarchiver"

confirm() {
    read -r -p "$1 [Enter when ready, Ctrl-C to abort]" _
}

shoot_mac_window() {
    local out="$1"
    # -o = no shadow, -W = interactive window pick by clicking
    # Click the Honk window to pick it.
    echo "    Shoot: click the Honk iMessage Archiver window…"
    screencapture -o -W "$out"
    echo "    → $out"
}

###########################
# Mac screenshots
###########################

echo "==> Mac app screenshots"
echo "    Quit and re-open the renamed Mac app, then come back here."
confirm "Mac app is open at 'No Archive Yet'?"
shoot_mac_window "$OUT_DIR/mac/01-no-archive.png"

confirm "Click 'Create Archive' and wait ~15s for progress to settle, then return."
shoot_mac_window "$OUT_DIR/mac/02-create-progress.png"

confirm "Archive finished. The app should be at the chat list now."
shoot_mac_window "$OUT_DIR/mac/03-chat-list.png"

confirm "Open a chat with a mix of text + attachments."
shoot_mac_window "$OUT_DIR/mac/04-thread.png"

###########################
# iOS Simulator screenshots
###########################

echo ""
echo "==> iOS Simulator screenshots"
echo "    Start an iPhone Simulator with the renamed iOS app installed."

if ! xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
    echo "    ⚠️  No booted Simulator found. Boot one in Xcode → Window → Devices and Simulators → Simulators → Boot."
    exit 1
fi

SIM_UDID=$(xcrun simctl list devices booted -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for d in devices:
        if d.get('state') == 'Booted':
            print(d['udid'])
            sys.exit(0)
")
echo "    Using Simulator: $SIM_UDID"

confirm "Open the iOS app on the Simulator. App should show 'No Archive Yet' (no iCloud setup)."
xcrun simctl io "$SIM_UDID" screenshot "$OUT_DIR/ios/01-no-archive.png"
echo "    → $OUT_DIR/ios/01-no-archive.png"

confirm "If you want chat list + thread shots, manually drag the archive bundle into the Simulator's iCloud Drive container, then return."
xcrun simctl io "$SIM_UDID" screenshot "$OUT_DIR/ios/02-chat-list.png" 2>/dev/null || true
echo "    → $OUT_DIR/ios/02-chat-list.png (may be the same as 01 if no archive present)"

confirm "Open any chat for the thread shot."
xcrun simctl io "$SIM_UDID" screenshot "$OUT_DIR/ios/03-thread.png" 2>/dev/null || true
echo "    → $OUT_DIR/ios/03-thread.png"

echo ""
echo "==> All screenshots in $OUT_DIR"
ls -la "$OUT_DIR/mac" "$OUT_DIR/ios"
