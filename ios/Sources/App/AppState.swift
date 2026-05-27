import Foundation
import Observation

@Observable
final class AppState {
    var coordinator = iCloudCoordinator()
    var reader: ArchiveReader?
    var loadError: Error?

    @MainActor
    func onBundleReady(_ bundleURL: URL) {
        do {
            reader = try ArchiveReader(bundleURL: bundleURL)
        } catch {
            loadError = error
        }
    }
}
