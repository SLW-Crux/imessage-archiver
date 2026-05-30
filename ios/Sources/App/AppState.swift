import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    var coordinator = iCloudCoordinator()
    var reader: ArchiveReader?
    var loadError: Error?

    // nonisolated(unsafe) because `deinit` is implicitly nonisolated and
    // needs to remove the observer. NotificationCenter.removeObserver is
    // thread-safe so this is safe in practice.
    nonisolated private var refreshObserver: NSObjectProtocol?

    init() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .archiveBundleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.onBundleReady(url)
            }
        }
    }

    deinit {
        if let refreshObserver {
            NotificationCenter.default.removeObserver(refreshObserver)
        }
    }

    func onBundleReady(_ bundleURL: URL) {
        do {
            reader = try ArchiveReader(bundleURL: bundleURL)
            loadError = nil
        } catch {
            loadError = error
        }
    }
}
