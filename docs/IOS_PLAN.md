# iOS Reader App — Development Plan

Detailed implementation plan for the iOS reader app.

---

## Goal

A read-only SwiftUI app that opens the archive bundle from iCloud Drive and lets the user browse threads, messages, and attachments. Apple Human Interface Guidelines throughout. No custom theming.

---

## Stack

- Swift 5.9+, SwiftUI
- iOS 17+
- Xcode 15+
- GRDB.swift (SQLite, MIT licence)
- QuickLook (built-in) for attachment preview
- Custom seek-based tar reader (~150 LOC, no third-party dep)

---

## Project Setup

### Bundle identifier
`org.imessagearchiver.ios`

### iCloud container
`iCloud.org.imessagearchiver` — must match Mac archiver exactly.

### Capabilities (Xcode)
- iCloud → iCloud Documents
- iCloud → Custom container: `iCloud.org.imessagearchiver`

### Entitlements
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.org.imessagearchiver</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.org.imessagearchiver</string>
</array>
```

### Info.plist
```xml
<key>NSUbiquitousContainers</key>
<dict>
    <key>iCloud.org.imessagearchiver</key>
    <dict>
        <key>NSUbiquitousContainerIsDocumentScopePublic</key>
        <true/>
        <key>NSUbiquitousContainerName</key>
        <string>iMessage Archiver</string>
        <key>NSUbiquitousContainerSupportedFolderLevels</key>
        <string>Any</string>
    </dict>
</dict>
```

---

## Architecture

```
ImessageArchiverIOS/
├── App/
│   ├── ImessageArchiverApp.swift
│   └── AppState.swift                  # @Observable root state
├── Models/
│   ├── Chat.swift
│   ├── Message.swift
│   ├── Attachment.swift
│   ├── Reaction.swift
│   └── ArchiveManifest.swift
├── Persistence/
│   ├── ArchiveReader.swift             # GRDB queries (read-only)
│   ├── TarReader.swift                 # seek-based offset extraction
│   ├── AttachmentCache.swift           # LRU cache, 500MB cap
│   └── iCloudCoordinator.swift         # NSMetadataQuery, download triggers
├── Views/
│   ├── RootView.swift                  # routes based on bundle state
│   ├── ChatListView.swift
│   ├── ChatRowView.swift
│   ├── ThreadView.swift
│   ├── MessageBubbleView.swift
│   ├── ReactionsView.swift
│   ├── AttachmentThumbnailView.swift
│   ├── AttachmentPreviewView.swift     # QuickLook wrapper
│   ├── SearchView.swift
│   ├── SearchResultRow.swift
│   ├── ArchiveInfoView.swift
│   └── NoArchiveView.swift             # shown when no bundle in iCloud
└── Tests/
    ├── ArchiveReaderTests.swift
    ├── TarReaderTests.swift
    ├── MessageRenderingTests.swift
    └── Fixtures/
        └── tiny.imarchive/             # checked-in test bundle
```

---

## Data Models

```swift
struct Chat: Identifiable, Hashable {
    let chatGuid: String                 // PK
    let displayName: String?
    let chatIdentifier: String?
    let serviceName: String
    let isGroup: Bool
    let participants: [String]
    let firstMessageAt: Date
    let lastMessageAt: Date
    let messageCount: Int
    var id: String { chatGuid }
}

struct Message: Identifiable, Hashable {
    let messageGuid: String              // PK
    let chatGuid: String
    let senderHandle: String?
    let senderName: String?
    let timestamp: Date
    let text: String?
    let isFromMe: Bool
    let replyToGuid: String?
    let reactions: [Reaction]
    let hasAttachments: Bool
    var id: String { messageGuid }
}

struct Attachment: Identifiable, Hashable {
    let attachmentGuid: String           // PK
    let messageGuid: String
    let filename: String?
    let mimeType: String?
    let uti: String?
    let size: Int64
    let sha256: String?
    let tarOffset: Int64?
    let tarLength: Int64?
    let state: AttachmentState
    var id: String { attachmentGuid }
}

enum AttachmentState: String {
    case localPresent = "LOCAL_PRESENT"
    case missing = "MISSING"
    case zeroByte = "ZERO_BYTE"
    case unreadable = "UNREADABLE"
}

struct Reaction: Hashable {
    let from: String
    let type: String         // love, like, dislike, laugh, emphasize, question
    let timestamp: Date
}

struct ArchiveManifest {
    let schemaVersion: Int
    let archiverVersion: String
    let createdAt: Date
    let lastUpdatedAt: Date
    let chatCount: Int
    let messageCount: Int
    let attachmentCount: Int
    let missingAttachmentCount: Int
    let archiveSizeBytes: Int64
}
```

---

## Persistence Layer

### iCloudCoordinator
Responsibilities:
- Locate iCloud container URL
- Use `NSMetadataQuery` to discover `archive.imarchive` bundle
- Trigger download via `FileManager.startDownloadingUbiquitousItem`
- Publish download progress via `@Observable`
- Detect bundle changes (Mac re-archive) and refresh

```swift
@Observable
final class iCloudCoordinator {
    enum State {
        case checking
        case noContainer
        case noBundle
        case downloading(progress: Double)
        case ready(bundleURL: URL)
        case error(Error)
    }
    var state: State = .checking

    func locate() async { /* NSMetadataQuery */ }
    func ensureDownloaded() async { /* startDownloadingUbiquitousItem */ }

    // Called when NSMetadataQuery fires an NSMetadataQueryDidUpdateNotification.
    // Compare manifest.json `last_updated_at` against the value read at last open.
    // If newer: post a Notification so AppState can reopen ArchiveReader and refresh views.
    func handleBundleUpdate(bundleURL: URL) async { /* read manifest, compare, notify */ }
}
```

### ArchiveReader
Wraps GRDB `DatabasePool` opened read-only on `archive.sqlite`.

```swift
final class ArchiveReader {
    private let dbPool: DatabasePool
    let manifest: ArchiveManifest

    init(bundleURL: URL) throws {
        let sqliteURL = bundleURL.appendingPathComponent("archive.sqlite")
        var config = Configuration()
        config.readonly = true
        self.dbPool = try DatabasePool(path: sqliteURL.path, configuration: config)
        self.manifest = try Self.loadManifest(bundleURL: bundleURL)
    }

    func chats() async throws -> [Chat] { /* SELECT * FROM chats ORDER BY last_message_at DESC */ }
    func messages(in chatGuid: String, limit: Int? = nil) async throws -> [Message]
    func attachments(for messageGuid: String) async throws -> [Attachment]
    func search(query: String, limit: Int = 100) async throws -> [Message]  // FTS5
}
```

### TarReader
Seek-based extraction. The archive's `attachments` table stores `tar_offset` and `tar_length` for each attachment — `tar_offset` is the byte position of the file data (past the 512-byte ustar header), so the iOS reader never needs to parse tar headers.

The `FileHandle` is opened once on `init` and held open for the lifetime of the `TarReader`. Opening a new handle per extraction call causes a system-call burst when rendering a message thread with many attachment thumbnails.

```swift
final class TarReader {
    private let handle: FileHandle

    init(bundleURL: URL) throws {
        let tarURL = bundleURL.appendingPathComponent("attachments.tar")
        self.handle = try FileHandle(forReadingFrom: tarURL)
    }

    deinit { try? handle.close() }

    func extract(offset: Int64, length: Int64) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)),
              data.count == Int(length) else {
            throw TarError.incompleteRead(offset: offset, expected: length)
        }
        return data
    }
}
```

### AttachmentCache
LRU cache, 500MB cap. Extracted attachments written to app's Caches directory as `{attachment_guid}-{filename}` so QuickLook can preview them by file extension.

**LRU mechanism:** an in-memory `OrderedDictionary<String, Int64>` (keyed by `attachment_guid`, value = cached file size in bytes) maintains insertion order. On cache hit, the key is moved to the end (most recently used). On eviction, keys are removed from the front (least recently used) until total bytes fall below the cap. The dictionary is not persisted — it is rebuilt on app launch by scanning `cacheDir` sorted by file modification time.

```swift
@MainActor
final class AttachmentCache {
    private let maxBytes: Int64 = 500 * 1024 * 1024
    private let cacheDir: URL
    private var lru: OrderedDictionary<String, Int64> = [:]  // guid → byte size
    private var totalBytes: Int64 = 0

    func url(for attachment: Attachment, tarReader: TarReader) async throws -> URL {
        let cachedURL = cacheDir.appendingPathComponent(
            "\(attachment.attachmentGuid)-\(attachment.filename ?? "file")"
        )
        if lru[attachment.attachmentGuid] != nil {
            lru.moveToEnd(attachment.attachmentGuid)   // mark as recently used
            return cachedURL
        }
        guard let offset = attachment.tarOffset, let length = attachment.tarLength else {
            throw AttachmentError.notPresent
        }
        let data = try await Task.detached { try tarReader.extract(offset: offset, length: length) }.value
        try data.write(to: cachedURL)
        lru[attachment.attachmentGuid] = Int64(data.count)
        totalBytes += Int64(data.count)
        evictIfNeeded()
        return cachedURL
    }

    private func evictIfNeeded() {
        while totalBytes > maxBytes, let (guid, size) = lru.first {
            let url = cacheDir.appendingPathComponent(/* reconstruct filename */)
            try? FileManager.default.removeItem(at: url)
            lru.removeValue(forKey: guid)
            totalBytes -= size
        }
    }
}
```

---

## Views

### RootView
Routes based on `iCloudCoordinator.state`:
- `.checking` / `.downloading`: progress UI
- `.noContainer`: instructions to enable iCloud
- `.noBundle`: `NoArchiveView` with instructions
- `.ready`: `NavigationStack` → `ChatListView`
- `.error`: error detail

### ChatListView
Native `List` with `NavigationStack`. Sections optional (Pinned later). Each row shows display name (or comma-separated participants), last message preview, relative timestamp.

```swift
NavigationStack {
    List(chats) { chat in
        NavigationLink(value: chat) {
            ChatRowView(chat: chat)
        }
    }
    .navigationTitle("Archive")
    .searchable(text: $searchText)
    .navigationDestination(for: Chat.self) { chat in
        ThreadView(chat: chat)
    }
    .toolbar {
        ToolbarItem {
            NavigationLink {
                ArchiveInfoView(manifest: manifest)
            } label: {
                Image(systemName: "info.circle")
            }
        }
    }
}
```

### ThreadView
Native Messages-style bubbles. Right-aligned blue for `is_from_me`, left-aligned grey otherwise. Sender name above each message in group chats. Date separators between days.

Pagination: load 200 messages initially, load more on scroll-to-top.

```swift
ScrollView {
    LazyVStack(spacing: 4) {
        ForEach(messages) { message in
            MessageBubbleView(message: message)
                .id(message.messageGuid)
        }
    }
}
.navigationTitle(chat.displayName ?? chat.participants.joined(separator: ", "))
.navigationBarTitleDisplayMode(.inline)
```

### MessageBubbleView
- Bubble background: `Color.blue` for `is_from_me`, `Color(.secondarySystemBackground)` otherwise
- Text colour: `.white` / `.primary`
- Bubble shape: rounded corners (`.continuous` style, radius 18)
- Timestamp: shown on tap (Messages.app behaviour)
- Attachments: thumbnail grid below text
- Reactions: small bubble overlay top-trailing
- Sender name: shown only in group chats, only on first message in a sequence from same sender

### AttachmentThumbnailView
- Images: load thumbnail from cached extraction
- Video: first-frame thumbnail + play icon overlay
- Audio: waveform icon + duration
- Other: generic file icon + filename

Tap → presents `AttachmentPreviewView` (QuickLook).

### AttachmentPreviewView
`UIViewControllerRepresentable` wrapping `QLPreviewController`:

```swift
struct AttachmentPreviewView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
```

QuickLook handles images, videos, PDFs, audio, text, and most common formats natively.

### SearchView
FTS5-backed search. Results show snippet with matched term highlighted, sender, chat, timestamp.

```swift
List(results) { result in
    NavigationLink(value: result) {
        SearchResultRow(message: result)
    }
}
.searchable(text: $query)
.onChange(of: query) { _, newValue in
    Task { results = try await reader.search(query: newValue) }
}
```

### ArchiveInfoView
Form-style view showing manifest data: created, last updated, chat count, message count, attachment count, missing count, archive size. Last 5 archive runs from `archive_runs` table.

### NoArchiveView
Shown when iCloud container exists but no bundle found. Instructions:
1. Run Mac archiver on your Mac
2. Wait for iCloud sync
3. Pull to refresh

---

## On-Launch Flow

1. `iCloudCoordinator` locates container
2. `NSMetadataQuery` searches for `archive.imarchive` bundle
3. If `archive.sqlite` is a placeholder: `startDownloadingUbiquitousItem`, show progress
4. Once downloaded: instantiate `ArchiveReader`, read manifest
5. Show `ChatListView`

**`attachments.tar` download trade-off:** `attachments.tar` is NOT downloaded eagerly — it only begins downloading when the user taps an attachment. iCloud does not support ranged/partial downloads of a ubiquitous item; once a download is triggered the entire file must arrive before any seek is possible. For a large archive this file may be 15–20 GB.

Mitigations:
- All messages and metadata are fully accessible without `attachments.tar` — users can browse every conversation before any attachment is downloaded
- The first attachment tap shows a one-time download prompt with the file size (from `manifest.json` `archive_size_bytes`) and a progress indicator backed by `NSMetadataQuery` download progress
- Once `attachments.tar` is fully downloaded, iCloud keeps it in the local cache; subsequent taps are instant
- `TarReader` opens a persistent `FileHandle` on the local cached file, so repeated seeks are cheap

There is no mechanism to download only a portion of the tar. If this limitation proves unacceptable in practice, a future schema version could split `attachments.tar` into per-year sub-archives; this is a v2 concern.

---

## Apple Design Compliance

- Use `List`, `Form`, `NavigationStack`, `Section`, `Label` exclusively for structure
- SF Symbols throughout (`info.circle`, `magnifyingglass`, `photo`, `play.circle.fill`, `doc`, `mic`)
- System colours only (`Color.blue`, `Color(.systemBackground)`, etc.) — no hardcoded hex
- Dynamic Type via `.font(.body)`, `.font(.caption)` etc.
- Dark mode automatic via system
- Accessibility labels on every interactive element
- Swipe actions where natural (e.g., swipe chat row for "Show Info")
- Haptic feedback on key actions (`UIImpactFeedbackGenerator`)

---

## Testing

### Unit tests
- `ArchiveReaderTests`: open fixture bundle, assert chat/message/attachment counts match expected
- `TarReaderTests`: extract by offset, verify SHA-256 of extracted bytes matches stored hash
- `MessageRenderingTests`: snapshot tests of `MessageBubbleView` for various message types

### Integration tests
- Open `tiny.imarchive` fixture from `Tests/Fixtures/`
- Navigate from list → thread → attachment preview
- Verify search returns expected results
- Verify reactions display correctly
- Verify group chat sender names display

### Round-trip tests (cross-platform)
The Mac archiver test suite produces a known archive. iOS test suite opens it and asserts every chat, message, attachment is accessible and matches source data.

---

## Phases (within iOS development)

### Phase 5a — Project skeleton
- Xcode project, target settings, iCloud capability
- Bundle ID, signing setup
- GRDB integration
- Open hardcoded fixture bundle from app bundle resources
- ChatListView with mocked data, then real GRDB query

### Phase 5b — Thread browsing
- ThreadView with pagination
- MessageBubbleView in iMessage style
- Sender resolution, date separators
- Group chat handling
- Reactions display

### Phase 5c — Attachments
- TarReader implementation
- AttachmentCache with LRU eviction
- AttachmentThumbnailView for image/video/audio/other
- QuickLook integration for full preview
- Missing attachment placeholder UI

### Phase 5d — Search
- FTS5 query in ArchiveReader
- SearchView with debounced input
- Snippet rendering with match highlighting
- Filter by chat, date range (later)

### Phase 5e — iCloud integration
- iCloudCoordinator with NSMetadataQuery
- Download progress UI
- Refresh detection when Mac re-archives
- Error states

### Phase 5f — Polish
- ArchiveInfoView
- NoArchiveView
- Empty states
- Loading states
- Accessibility audit
- Dynamic Type verification at all sizes
- Dark mode verification

### Phase 5g — TestFlight
- App Store Connect setup
- Build upload
- TestFlight distribution to dev's device

---

## Human-in-the-Loop Pause Points

The iOS app requires human action that AI cannot automate:

1. **Apple Developer account** — must already exist
2. **Xcode signing setup** — first-time signing certs and provisioning profiles
3. **iCloud container creation** — done in developer.apple.com portal
4. **App Store Connect record** — for TestFlight
5. **TestFlight upload** — Xcode-driven, may require interactive auth
6. **Manual device testing** — only human can verify visual fidelity matches Messages.app

The Mac archiver can be developed and tested fully autonomously. iOS work pauses at these gates.

---

## Out of Scope (v1)

- Editing or annotating messages
- Exporting from iOS app
- Sharing messages outside the app
- Multi-archive support (one bundle at a time)
- Live sync with Mac (Mac writes, iOS reads, no live updates required)
- iPad-specific layout (works on iPad but no split view optimisation)
- macOS Catalyst build
