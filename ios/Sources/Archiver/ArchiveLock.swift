#if os(macOS)
import Foundation

/// Single-writer lock for an archive bundle.
///
/// Prevents two simultaneous archive runs (CLI invocation + GUI button +
/// scheduled run) from interleaving SQLite writes and tar appends.
/// Writes the lock-holder's PID to a sidecar file. If the lock file
/// exists but the recorded PID is no longer alive, treat the lock as
/// stale and acquire anyway (the previous holder crashed without
/// cleaning up).
///
/// Port of `src/imessage_archiver/core/lock.py`.
final class ArchiveLock {

    enum Error: Swift.Error, LocalizedError {
        case held(byPID: Int32)

        var errorDescription: String? {
            switch self {
            case .held(let pid):
                return "Another archive process is already running (PID \(pid))."
            }
        }
    }

    /// Default lock location is alongside the user's working directory.
    static let defaultURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".imessage-archiver/archive.lock")
    }()

    private let lockURL: URL
    private var ownedByMe: Bool = false

    init(lockURL: URL = ArchiveLock.defaultURL) {
        self.lockURL = lockURL
    }

    /// Acquire the lock. Throws `.held` if another live process owns it.
    func acquire() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if fm.fileExists(atPath: lockURL.path) {
            // Read the PID inside the lock file. If that PID is alive,
            // the lock is real; if not, it's stale and we steal it.
            if let data = try? Data(contentsOf: lockURL),
               let text = String(data: data, encoding: .utf8),
               let trimmed = text.split(separator: "\n").first,
               let pid = Int32(trimmed.trimmingCharacters(in: .whitespaces)),
               Self.pidIsAlive(pid) {
                throw Error.held(byPID: pid)
            }
            // Stale — remove and re-acquire.
            try? fm.removeItem(at: lockURL)
        }

        let payload = "\(getpid())\n"
        try payload.write(to: lockURL, atomically: true, encoding: .utf8)
        ownedByMe = true
    }

    /// Release the lock. Idempotent.
    func release() {
        guard ownedByMe else { return }
        try? FileManager.default.removeItem(at: lockURL)
        ownedByMe = false
    }

    deinit { release() }

    /// `kill(pid, 0)` returns 0 if the process exists and we can signal
    /// it, EPERM if it exists but we can't, ESRCH if it doesn't exist.
    /// Treat anything non-ESRCH as alive.
    private static func pidIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}

#endif
