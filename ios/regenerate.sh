#!/usr/bin/env bash
# Regenerate the Xcode project and restore both entitlement files.
# xcodegen blanks entitlement files on every run (it only declares the
# entitlements *path* in the project, not the content), so we own the
# canonical content here for both the iOS and Mac targets.
set -euo pipefail

cd "$(dirname "$0")"

xcodegen generate

cat > iMessageArchiver.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.slw.imessage-archiver</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudDocuments</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.slw.imessage-archiver</string>
    </array>
</dict>
</plist>
EOF

cat > iMessageArchiverMac.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.slw.imessage-archiver</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudDocuments</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.slw.imessage-archiver</string>
    </array>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Entitlements restored:"
echo "    iMessageArchiver.entitlements (iOS)"
echo "    iMessageArchiverMac.entitlements (Mac)"
