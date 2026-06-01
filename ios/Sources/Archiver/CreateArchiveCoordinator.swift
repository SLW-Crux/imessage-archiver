import Foundation
import Observation

/// `@Observable` state machine that drives `ArchiveWriter` from the
/// SwiftUI UI on the Mac side.
///
/// The coordinator owns the long-running archive task and surfaces a
/// single `phase` value the view binds to. All transitions happen on
/// the main actor so SwiftUI can observe them directly.
///
/// Mac-only — iOS just reads the archive that the Mac app produced.
#if os(macOS)
@MainActor
@Observable
final class CreateArchiveCoordinator {

    enum Phase: Sendable {
        case idle
        case snapshotting
        case archiving(progress: Progress)
        case verifying(checked: Int, total: Int)
        case succeeded(ArchiveWriter.RunStats)
        case failed(Swift.Error)

        struct Progress: Sendable {
            var chatTitle: String
            var messagesSeen: Int
            var messagesWritten: Int
            var attachmentsSeen: Int
            var attachmentsWritten: Int
            var attachmentsMissing: Int
        }
    }

    private(set) var phase: Phase = .idle

    /// Where to write the archive. Defaults to the Mac app's
    /// ubiquity container — the same path the iOS reader looks at
    /// after sync.
    let destinationBundleURL: URL?

    private let chatDBURL: URL
    private var task: Task<Void, Never>?

    init(
        destinationBundleURL: URL? = CreateArchiveCoordinator.defaultDestination(),
        chatDBURL: URL = SourceDBSnapshotter.defaultSourceURL
    ) {
        self.destinationBundleURL = destinationBundleURL
        self.chatDBURL = chatDBURL
    }

    /// Begin the archive run. No-op if a run is already in flight.
    func start() {
        guard task == nil, let bundleURL = destinationBundleURL else { return }
        let chatDB = chatDBURL

        task = Task { [weak self] in
            guard let self else { return }
            await self.runArchive(bundleURL: bundleURL, chatDB: chatDB)
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        // Don't nil `task` or reset `phase` here — the task body itself
        // catches `CancellationError`, transitions phase to .idle, and
        // sets `self.task = nil` after `runArchive` returns. Nilling
        // synchronously here lets `start()` race a second run while
        // the first is still draining (review finding MH2).
    }

    // MARK: - Run

    private func runArchive(bundleURL: URL, chatDB: URL) async {
        // Sweep any snapshots left behind by a previously-crashed run
        // before creating our own. Per-run cleanup (defer below) covers
        // the success / failure / cancel exits of THIS run; the sweep
        // covers prior crashes that never ran defer (MC3).
        SourceDBSnapshotter.sweepLeftovers()

        var snapshotForCleanup: SourceDBSnapshotter.Snapshot?
        defer {
            if let s = snapshotForCleanup {
                SourceDBSnapshotter.cleanup(s)
            }
        }

        do {
            phase = .snapshotting
            // 1. VACUUM INTO snapshot of chat.db. Heavy I/O; run on a
            //    background actor so the main actor stays responsive.
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try SourceDBSnapshotter.snapshot(source: chatDB)
            }.value
            snapshotForCleanup = snapshot

            // 2. Open the snapshot for reading.
            let reader = try SourceDBReader(snapshotURL: snapshot.url)

            // 3. Optionally request Contacts authorization up front so
            //    the writer doesn't see a stale `.notDetermined` status
            //    on the first row.
            _ = await ContactsResolver.shared.requestAccessIfNeeded()

            // 4. Run the writer/merger. Merger does INSERT OR IGNORE
            //    under the hood so first-time runs and incremental
            //    runs use the same path.
            phase = .archiving(progress: Phase.Progress(
                chatTitle: "Starting…",
                messagesSeen: 0,
                messagesWritten: 0,
                attachmentsSeen: 0,
                attachmentsWritten: 0,
                attachmentsMissing: 0
            ))
            let progressCallback: ArchiveWriter.ProgressCallback = { [weak self] chat, stats in
                Task { @MainActor [weak self] in
                    self?.phase = .archiving(progress: Phase.Progress(
                        chatTitle: chat.displayName ?? chat.chatIdentifier ?? chat.chatGuid,
                        messagesSeen: stats.messagesSeen,
                        messagesWritten: stats.messagesWritten,
                        attachmentsSeen: stats.attachmentsSeen,
                        attachmentsWritten: stats.attachmentsWritten,
                        attachmentsMissing: stats.attachmentsMissing
                    ))
                }
            }

            let stats = try await ArchiveMerger.merge(
                bundleURL: bundleURL,
                reader: reader,
                sourceSHA256: snapshot.sha256,
                sourceDBPath: chatDB.path,
                progress: progressCallback
            )

            // 5. Verify the result so the user is told now if something
            //    went wrong, not the first time they open the archive
            //    on iOS.
            phase = .verifying(checked: 0, total: 0)
            let verifyResult = try await Task.detached(priority: .userInitiated) {
                try ArchiveVerifier.verify(bundleURL: bundleURL) { checked, total in
                    Task { @MainActor [weak self] in
                        self?.phase = .verifying(checked: checked, total: total)
                    }
                }
            }.value

            if !verifyResult.mismatched.isEmpty {
                phase = .failed(VerifyMismatch(count: verifyResult.mismatched.count))
                return
            }

            phase = .succeeded(stats)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error)
        }
    }

    // MARK: - Destination

    /// Compute the iCloud container's Documents directory for the
    /// renamed Mac bundle. Returns `nil` if iCloud isn't available
    /// (the app must surface `.noContainer` in that case — same path
    /// the reader UI already handles).
    static func defaultDestination() -> URL? {
        let container = FileManager.default.url(
            forUbiquityContainerIdentifier: "iCloud.com.honk.imsgarchiver-mac"
        )
        return container?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("archive.imarchive", isDirectory: true)
    }
}

private struct VerifyMismatch: Swift.Error, LocalizedError {
    let count: Int
    var errorDescription: String? {
        "\(count) attachment(s) failed SHA-256 verification. The archive may be corrupted; re-run to rebuild."
    }
}
#endif
