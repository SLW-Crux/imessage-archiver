import Foundation
import Observation

/// Mutable holder so a @MainActor class can keep an NSObjectProtocol
/// observer that's set in init and torn down in deinit without
/// resorting to `nonisolated(unsafe)` on the stored property.
private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

@Observable
@MainActor
final class AppState {
    var coordinator = iCloudCoordinator()
    var reader: ArchiveReader?
    var loadError: Error?

    // `let`-held box is implicitly Sendable-accessible from the
    // nonisolated `deinit`. The previous direct `nonisolated(unsafe)
    // var` triggered Swift 6's "has no effect" warning whose
    // suggested fix (plain nonisolated) doesn't compile for var.
    private let observerBox = ObserverBox()

    init() {
        observerBox.token = NotificationCenter.default.addObserver(
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
        if let token = observerBox.token {
            NotificationCenter.default.removeObserver(token)
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
