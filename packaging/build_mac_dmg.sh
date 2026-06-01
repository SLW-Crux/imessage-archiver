#!/usr/bin/env bash
# Build, sign, notarize, and DMG-package the Mac SwiftUI app.
#
# End-to-end output: a notarized .dmg ready to upload to a website
# / GitHub Releases. Users download it, open it, drag the app into
# Applications. No Gatekeeper warnings.
#
# Prerequisites (one-time):
#
#   1. Developer ID Application certificate in the keychain. Create
#      at developer.apple.com → Certificates → "+" → Developer ID
#      Application (NOT Apple Development), download .cer, double-
#      click to install.
#
#   2. notarytool credentials stored in the keychain under a profile.
#      Recommended path uses an App Store Connect API key
#      (developer.apple.com → Users and Access → Keys → "+"):
#
#         xcrun notarytool store-credentials honk-notary \
#             --key  /path/to/AuthKey_XXXXXXXXXX.p8 \
#             --key-id XXXXXXXXXX \
#             --issuer YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY
#
#      Set NOTARY_PROFILE below if you used a different profile name.
#
# Run from the repo root:
#
#   ./packaging/build_mac_dmg.sh
#
# Output: dist/HonkiMessageArchiver-<version>.dmg (notarized, stapled).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/iMessageArchiverMac.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_NAME="Honk iMessage Archiver"
SCHEME="iMessageArchiverMac"
PROJECT="$REPO_ROOT/ios/iMessageArchiver.xcodeproj"
EXPORT_OPTIONS="$REPO_ROOT/packaging/ExportOptions-DeveloperID.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-honk-notary}"

# Name of the Developer ID Distribution provisioning profile created at
# developer.apple.com. Override via env if you used a different name:
#   DEVID_PROFILE_NAME="My Profile" ./packaging/build_mac_dmg.sh
DEVID_PROFILE_NAME="${DEVID_PROFILE_NAME:-Honk Mac Developer ID}"

# Read MARKETING_VERSION out of project.yml so the DMG filename
# matches the in-app version.
VERSION=$(awk -F': *' '/^ *MARKETING_VERSION/ {gsub(/"/,"",$2); print $2; exit}' \
    "$REPO_ROOT/ios/project.yml")
if [ -z "$VERSION" ]; then VERSION="dev"; fi

DMG_NAME="HonkiMessageArchiver-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
DMG_STAGE="$BUILD_DIR/dmg-stage"

cyan() { printf "\033[36m==> %s\033[0m\n" "$*"; }
green() { printf "\033[32m    ✓ %s\033[0m\n" "$*"; }
red() { printf "\033[31m    ✗ %s\033[0m\n" "$*"; }

# -----------------------------------------------------------------
# 0. Sanity checks
# -----------------------------------------------------------------
cyan "Pre-flight"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    red "No 'Developer ID Application' certificate in the keychain."
    echo "       Create one at developer.apple.com → Certificates →"
    echo "       Developer ID Application, download the .cer, double-click"
    echo "       to install."
    exit 1
fi
green "Developer ID Application cert present"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    red "notarytool profile '$NOTARY_PROFILE' not found in keychain."
    echo "       Run:"
    echo "         xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "             --key /path/to/AuthKey_XXX.p8 --key-id XXX --issuer YYY"
    exit 1
fi
green "notarytool profile '$NOTARY_PROFILE' ready"

# -----------------------------------------------------------------
# 1. Regenerate the xcodeproj from project.yml (canonical source)
# -----------------------------------------------------------------
cyan "Regenerating xcodeproj"
( cd "$REPO_ROOT/ios" && ./regenerate.sh ) > /dev/null
green "regenerate.sh complete"

# -----------------------------------------------------------------
# 2. Archive
# -----------------------------------------------------------------
cyan "Archiving $SCHEME (this takes a couple of minutes)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

# Extract the actual team identifier from the installed Developer ID
# cert. The keychain identifier (e.g. G5TTCDCAUG) may differ from the
# project.yml DEVELOPMENT_TEAM (7V698GFQCM, which iOS uses) when Apple
# has migrated the account through a team rename — the cert OU is what
# xcodebuild matches against, not what's printed in find-identity's
# parenthetical.
DEVID_LINE=$(security find-identity -v -p codesigning | /usr/bin/grep "Developer ID Application" | head -1)
DEVID_TEAM=$(echo "$DEVID_LINE" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')
if [ -z "$DEVID_TEAM" ]; then
    red "Could not extract team identifier from Developer ID cert."
    exit 1
fi
echo "    Using Developer ID team: $DEVID_TEAM"

# Confirm the Developer ID Distribution provisioning profile is
# installed. Mac apps with iCloud capability require a profile even
# under Manual / Developer ID signing — the profile is what
# authorizes the iCloud entitlement at runtime.
if ! find "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" -name "*.provisionprofile" -exec sh -c '
    security cms -D -i "$1" 2>/dev/null | /usr/bin/grep -q "<string>'"$DEVID_PROFILE_NAME"'</string>"
' _ {} \; -print 2>/dev/null | grep -q .; then
    red "Developer ID provisioning profile '$DEVID_PROFILE_NAME' not installed."
    echo "       Create it at developer.apple.com:"
    echo "         Profiles → + → Distribution → Developer ID"
    echo "         App ID: com.honk.imsgarchiver-mac"
    echo "         Cert:   Developer ID Application: Stephen Williams ($DEVID_TEAM)"
    echo "         Name:   $DEVID_PROFILE_NAME"
    echo "       Download, double-click to install, then re-run."
    exit 1
fi
green "Developer ID profile '$DEVID_PROFILE_NAME' present"

# Automatic signing during Archive — Xcode will pick the matching Mac
# Team Provisioning Profile + Apple Development cert for the app, and
# unsigned builds for GRDB's library targets (which can't accept a
# provisioning profile). Forcing Manual + PROVISIONING_PROFILE_SPECIFIER
# on the CLI applies the setting to EVERY target including SPM
# libraries, which then error with "GRDB_GRDB does not support
# provisioning profiles."
#
# The Developer ID re-signing happens at the Export step below, where
# the export plist's method=developer-id directs xcodebuild to
# re-sign the .app with the Developer ID Application cert. That's
# Apple's canonical Developer-ID-distribution flow.
#
# We still override DEVELOPMENT_TEAM on the CLI because project.yml's
# value (the personal Apple Developer Program identifier visible in
# the Apple Development cert's CN) is not the actual team identifier
# xcodebuild's automatic provisioning resolves against.
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$DEVID_TEAM" \
    > "$BUILD_DIR/archive.log" 2>&1 \
    || { red "xcodebuild archive failed — see $BUILD_DIR/archive.log"; tail -30 "$BUILD_DIR/archive.log"; exit 1; }
green "Archive: $ARCHIVE_PATH"

# -----------------------------------------------------------------
# 3. Export the .app from the archive (signs with Developer ID)
# -----------------------------------------------------------------
cyan "Exporting + signing with Developer ID"
mkdir -p "$EXPORT_DIR"

# Build the ExportOptions plist on the fly so the team matches the
# Developer ID cert we just extracted, rather than hardcoding it.
DYNAMIC_EXPORT_OPTIONS="$BUILD_DIR/ExportOptions-generated.plist"
cat > "$DYNAMIC_EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$DEVID_TEAM</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$DYNAMIC_EXPORT_OPTIONS" \
    > "$BUILD_DIR/export.log" 2>&1 \
    || { red "xcodebuild -exportArchive failed — see $BUILD_DIR/export.log"; tail -30 "$BUILD_DIR/export.log"; exit 1; }

# Find the exported .app — its filename comes from PRODUCT_NAME
# (iMessageArchiverMac), not from APP_NAME. Rename to user-facing.
RAW_APP=$(find "$EXPORT_DIR" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$RAW_APP" ]; then
    red "Exported .app not found in $EXPORT_DIR"
    exit 1
fi
FINAL_APP="$EXPORT_DIR/$APP_NAME.app"
if [ "$RAW_APP" != "$FINAL_APP" ]; then
    mv "$RAW_APP" "$FINAL_APP"
fi
green "Exported: $FINAL_APP"

# Verify signature before notarizing — saves a round trip if signing
# is broken.
cyan "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$FINAL_APP" 2>&1 | tail -3
spctl --assess --type execute --verbose "$FINAL_APP" 2>&1 || true
green "Signature verified"

# -----------------------------------------------------------------
# 4. Notarize the .app
# -----------------------------------------------------------------
cyan "Notarizing .app (Apple typically takes 1–15 minutes)"
# notarytool only accepts zip / dmg / pkg, not a raw .app. Wrap.
ZIP_PATH="$BUILD_DIR/app-for-notary.zip"
ditto -c -k --keepParent "$FINAL_APP" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    | tee "$BUILD_DIR/notary-app.log"

if ! grep -q "status: Accepted" "$BUILD_DIR/notary-app.log"; then
    red "Notarization did not succeed — see $BUILD_DIR/notary-app.log"
    SUBMIT_ID=$(grep "id:" "$BUILD_DIR/notary-app.log" | head -1 | awk '{print $2}')
    if [ -n "$SUBMIT_ID" ]; then
        echo "    Fetching detailed log for submission $SUBMIT_ID …"
        xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE"
    fi
    exit 1
fi
green ".app notarization accepted"

# Staple the notarization ticket onto the .app so Gatekeeper can
# verify offline.
xcrun stapler staple "$FINAL_APP"
green "Notarization ticket stapled"

# -----------------------------------------------------------------
# 5. Build the DMG
# -----------------------------------------------------------------
cyan "Building DMG"
rm -rf "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$DMG_STAGE" "$DIST_DIR"

# Layout: app on the left, Applications symlink on the right (so
# users drag the icon across to install — the standard macOS DMG
# convention).
cp -R "$FINAL_APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" > /dev/null
green "DMG built: $DMG_PATH"

# -----------------------------------------------------------------
# 6. Notarize the DMG too (Apple recommends; means Gatekeeper checks
#    pass even before the .app is extracted from the DMG)
# -----------------------------------------------------------------
cyan "Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    | tee "$BUILD_DIR/notary-dmg.log"

if ! grep -q "status: Accepted" "$BUILD_DIR/notary-dmg.log"; then
    red "DMG notarization did not succeed — see $BUILD_DIR/notary-dmg.log"
    exit 1
fi
green "DMG notarization accepted"

xcrun stapler staple "$DMG_PATH"
green "DMG notarization ticket stapled"

# -----------------------------------------------------------------
# 7. Verify the final DMG is Gatekeeper-clean
# -----------------------------------------------------------------
cyan "Final verification"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 | head -2 || true

echo ""
cyan "Done"
echo "    DMG:  $DMG_PATH"
echo "    Size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "    Upload it to your website / GitHub Releases. End users:"
echo "      1. Download $DMG_NAME"
echo "      2. Open it"
echo "      3. Drag Honk iMessage Archiver to Applications"
echo "      4. Launch — no Gatekeeper warnings."
