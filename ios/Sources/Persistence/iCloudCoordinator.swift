import Foundation
import Observation

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
        Task { @MainActor in
            guard let query = self.metadataQuery else { return }
            query.disableUpdates()
            defer { query.enableUpdates() }

            if query.resultCount == 0 {
                self.state = .noBundle
                return
            }

            guard let item = query.result(at: 0) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else {
                self.state = .noBundle
                return
            }

            let downloadStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if downloadStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                self.handleReady(bundleURL: url)
            } else {
                let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double ?? 0
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
    private func handleReady(bundleURL: URL) {
        let manifest = try? ArchiveManifest.load(bundleURL: bundleURL)
        let updatedAt = manifest?.lastUpdatedAt
        if let previous = lastSeenUpdatedAt,
           let updatedAt,
           updatedAt > previous {
            NotificationCenter.default.post(
                name: .archiveBundleDidChange,
                object: bundleURL
            )
        }
        if let updatedAt {
            lastSeenUpdatedAt = updatedAt
        }
        state = .ready(bundleURL: bundleURL)
    }
}

extension Notification.Name {
    static let archiveBundleDidChange = Notification.Name("ArchiveBundleDidChange")
}
