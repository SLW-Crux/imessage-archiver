#if os(macOS)
import Foundation
import Darwin

/// Single-writer lock for an archive bundle.
///
/// Prevents two simultaneous archive runs (CLI invocation + GUI button +
/// scheduled run) from interleaving SQLite writes and tar appends.
/// Writes the lock-holder's PID to a sidecar file. If the lock file
/// exists but the recorded PID is no longer alive, treat the lock as
/// stale and acquire anyway (the previous holder crashed without
/// cleaning up).
///
/// Acquisition is atomic via `open(O_CREAT | O_EXCL)` — Foundation's
/// `write(atomically:)` is write-tmp + rename, which clobbers a
/// pre-existing file and lets two racing acquirers both believe they
/// own the lock (review finding MC2).
///
/// Port of `src/imessage_archiver/core/lock.py`.
final class ArchiveLock {

    enum Error: Swift.Error, LocalizedError {
        case held(byPID: Int32)
        case openFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .held(let pid):
                return "Another archive process is already running (PID \(pid))."
            case .openFailed(let e):
                return "Couldn't open lock file (errno \(e))."
            }
        }
    }

    /// Default lock location is alongside the user's working directory.
    static let defaultURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".imessage-archiver/archive.lock")
    }()

    /// Cap on how many stale-takeover loops to attempt before giving up.
    /// In practice we win on the first or second iteration; an unbounded
    /// loop is a denial-of-service risk if two processes thrash forever.
    private static let maxAcquireAttempts = 8

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

        for _ in 0..<Self.maxAcquireAttempts {
            // Atomic exclusive create. Only one process can win this
            // call across the entire system, even if many are racing.
            let fd = lockURL.path.withCString { path in
                Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            }
            if fd >= 0 {
                let payload = "\(getpid())\n"
                _ = payload.withCString { ptr in
                    Darwin.write(fd, ptr, strlen(ptr))
                }
                Darwin.close(fd)
                ownedByMe = true
                return
            }

            let err = errno
            guard err == EEXIST else {
                throw Error.openFailed(errno: err)
            }

            // The file exists — read the PID and decide whether to steal.
            if let data = try? Data(contentsOf: lockURL),
               let text = String(data: data, encoding: .utf8),
               let trimmed = text.split(separator: "\n").first,
               let pid = Int32(trimmed.trimmingCharacters(in: .whitespaces)),
               Self.pidIsAlive(pid) {
                throw Error.held(byPID: pid)
            }

            // Stale (or unreadable) — remove and retry the O_EXCL create.
            // If another stealer beats us to it we lose this iteration
            // and either steal next pass or surface `.held` if their PID
            // is alive.
            try? fm.removeItem(at: lockURL)
        }

        // Reached only if every iteration lost the race against another
        // stealer that itself was promptly stolen from — extremely
        // unlikely in practice.
        throw Error.openFailed(errno: EAGAIN)
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
