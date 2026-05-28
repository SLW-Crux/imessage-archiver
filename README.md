# iMessage Archiver

Archive your iMessage conversations and attachments to a portable bundle in iCloud Drive, then browse them on iOS.

## Components

- **Mac archiver** — reads `~/Library/Messages/chat.db`, writes a portable `archive.imarchive` bundle to iCloud Drive
- **iOS reader** — browses the archive bundle from iCloud Drive (Phase 5, requires Apple Developer account)

## Status

See [STATUS.md](STATUS.md) for current progress.

## Non-destructive guarantees

- Never writes to `~/Library/Messages/chat.db` or any source file
- Never deletes attachments from `~/Library/Messages/Attachments/`
- Atomic writes only — partial archives never replace good ones
- SHA-256 verified before promotion

## Requirements

- macOS 13+
- Python 3.12+
- Full Disk Access granted to Terminal

## Install (development)

```bash
uv venv
source .venv/bin/activate
uv pip install -e ".[dev]"
```

## Usage

```bash
imessage-archiver archive          # archive to iCloud Drive
imessage-archiver verify           # verify existing archive
imessage-archiver stats            # show archive statistics
imessage-archiver info             # show manifest info
imessage-archiver setup            # Full Disk Access walkthrough
```

## iOS reader

SwiftUI app that opens the `.imarchive` bundle from iCloud Drive.

```bash
# Generate the test fixture (one time, after the Python CLI works)
./ios/Tests/Fixtures/generate_fixture.sh

# Generate / regenerate the Xcode project
cd ios && xcodegen generate

# Open in Xcode
open ios/iMessageArchiver.xcodeproj
```

Bundle ID `com.slw.imessage-archiver`, iCloud container
`iCloud.com.slw.imessage-archiver` (auto-created on first signed build with
`-allowProvisioningUpdates`). Requires iOS 17+, Swift 6, Xcode 26.

## License

MIT
