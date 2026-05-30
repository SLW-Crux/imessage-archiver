import Foundation
import Observation
import os

private let kContainerID = "iCloud.com.slw.imessage-archiver"
private let kBundleName  = "archive.imarchive"

@Observable
@MainActor
final class iCloudCoordinator {
    enum State: Equatable {
        case checking
        case noContainer
        case noBundle
        case downloading(progress: Double)
        case ready(bundleURL: URL)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.checking, .checking), (.noContainer, .noContainer), (.noBundle, .noBundle):
                return true
            case (.downloading(let a), .downloading(let b)):
                return a == b
            case (.ready(let a), .ready(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var state: State = .checking
    var lastSeenUpdatedAt: Date?

    private var metadataQuery: NSMetadataQuery?
    private var containerURL: URL?
    // Monotonic event token stamped on every queryDidUpdate notification.
    // The MainActor handler discards anything older than the highest
    // already-processed token so out-of-order @MainActor Task hops can't
    // overwrite a fresh `.ready` with a stale `.downloading` (H-14).
    //
    // OSAllocatedUnfairLock<UInt64> is Sendable-protected storage: the
    // `let` lets us hold it inside a @MainActor class without any
    // nonisolated(unsafe) annotation, and `withLock` gives us atomic
    // mutation across whatever thread NSMetadataQuery calls the
    // notification handler on.
    private let nextEventToken = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var lastProcessedToken: UInt64 = 0

    // nonisolated because queryDidUpdate (the only caller) runs on whatever
    // dispatch queue NSMetadataQuery uses, not on the MainActor.
    private nonisolated func mintEventToken() -> UInt64 {
        nextEventToken.withLock { token in
            token &+= 1
            return token
        }
    }

    func start() {
        Task { await locate() }
    }

    // MARK: - Location

    private func locate() async {
        guard let containerURL = FileManager.default.url(
            forUbiquityContainerIdentifier: kContainerID
        ) else {
            state = .noContainer
            return
        }
        self.containerURL = containerURL
        let docsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        startMetadataQuery(in: docsURL)
    }

    // MARK: - NSMetadataQuery

    private func startMetadataQuery(in directory: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@",
                                       NSMetadataItemFSNameKey, kBundleName)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        self.metadataQuery = query
        query.start()
    }

    @objc private nonisolated func queryDidUpdate(_ note: Notification) {
        // Stamp this event with a monotonically-increasing token BEFORE
        // hopping to the MainActor. The handler discards anything older
        // than what it has already processed.
        let token = mintEventToken()
        Task { @MainActor in
            guard token > self.lastProcessedToken else { return }
            self.lastProcessedToken = token

            guard let query = self.metadataQuery else { return }
            query.disableUpdates()
            defer { query.enableUpdates() }

            if query.resultCount == 0 {
                self.state = .noBundle
                return
            }

            // Pick the FIRST result whose URL is a descendant of OUR
            // ubiquity container's Documents/ folder. Defends against H3 —
            // stray archive.imarchive bundles in other reachable scopes
            // are ignored. Falls back to the first result if no container.
            let url: URL? = {
                let count = query.resultCount
                for i in 0..<count {
                    guard let item = query.result(at: i) as? NSMetadataItem,
                          let candidate = item.value(forAttribute: NSMetadataItemURLKey) as? URL
                    else { continue }
                    if let containerURL = self.containerURL,
                       candidate.standardizedFileURL.path.hasPrefix(
                            containerURL.standardizedFileURL.path) {
                        return candidate
                    }
                }
                if let first = query.result(at: 0) as? NSMetadataItem {
                    return first.value(forAttribute: NSMetadataItemURLKey) as? URL
                }
                return nil
            }()

            guard let url else {
                self.state = .noBundle
                return
            }
            // Sanity: a bundle is a directory. A regular file named
            // archive.imarchive is not what we want.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               !isDir.boolValue {
                self.state = .noBundle
                return
            }

            // Grab the item we picked so we can check its download status.
            let item: NSMetadataItem? = {
                let count = query.resultCount
                for i in 0..<count {
                    if let it = query.result(at: i) as? NSMetadataItem,
                       (it.value(forAttribute: NSMetadataItemURLKey) as? URL) == url {
                        return it
                    }
                }
                return nil
            }()

            let downloadStatus = item?.value(
                forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey
            ) as? String
            if downloadStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                self.handleReady(bundleURL: url)
            } else {
                let progress = item?.value(
                    forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey
                ) as? Double ?? 0
                if progress > 0 {
                    self.state = .downloading(progress: progress / 100.0)
                } else {
                    self.state = .downloading(progress: 0)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
            }
        }
    }

    /// When the bundle becomes available or its manifest changes, post a
    /// notification so AppState can reopen the ArchiveReader against the
    /// fresh data. Without this, a Mac re-archive while the iOS app is
    /// open would never refresh the visible message list.
    ///
    /// Distinguishes a transient manifest-load failure (the JSON may not
    /// have been downloaded yet) from a clean read. If the load throws,
    /// we stay in `.downloading` and trigger a fetch — we do NOT advance
    /// `lastSeenUpdatedAt`, because doing so would mask the next change.
    private func handleReady(bundleURL: URL) {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        do {
            let manifest = try ArchiveManifest.load(bundleURL: bundleURL)
            let updatedAt = manifest.lastUpdatedAt
            if let previous = lastSeenUpdatedAt, updatedAt > previous {
                NotificationCenter.default.post(
                    name: .archiveBundleDidChange,
                    object: bundleURL
                )
            }
            lastSeenUpdatedAt = updatedAt
            state = .ready(bundleURL: bundleURL)
        } catch {
            // Manifest not yet readable (iCloud may have only fetched the
            // placeholder). Don't advance lastSeenUpdatedAt; trigger a
            // download and stay in .downloading.
            state = .downloading(progress: 0)
            try? FileManager.default.startDownloadingUbiquitousItem(at: manifestURL)
        }
    }
}

extension Notification.Name {
    static let archiveBundleDidChange = Notification.Name("ArchiveBundleDidChange")
}
