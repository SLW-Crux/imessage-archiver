#if os(macOS)
import Foundation
import GRDB
import CryptoKit

/// Snapshots the live `chat.db` via SQLite's `VACUUM INTO` so the rest of
/// the archive pipeline reads from a frozen file and never touches the
/// original.
///
/// Why VACUUM INTO and not file-copy: `chat.db` is in WAL mode. Copying
/// `chat.db` + `chat.db-wal` + `chat.db-shm` with file system APIs is
/// unsafe — Messages.app may write between copies, producing an
/// inconsistent triple. `VACUUM INTO` reads all committed WAL data
/// through SQLite's own merge logic and writes a single, clean,
/// WAL-free file atomically.
///
/// The snapshot directory is created with mode 0o700 inside
/// `~/.imessage-archiver/work/`. The snapshot path is validated before
/// being interpolated into the `VACUUM INTO` SQL — SQLite has no
/// parameter binding for VACUUM, so the path must be safe to inline.
struct SourceDBSnapshotter {

    struct Snapshot {
        /// Filesystem URL of the snapshotted `chat.db`.
        let url: URL
        /// SHA-256 hex digest of the snapshot bytes.
        let sha256: String
    }

    enum SnapshotError: Error, LocalizedError {
        case noFullDiskAccess
        case sourceUnreadable(URL)
        case unsafePath(String)
        case vacuumFailed(underlying: Error)
        case hashFailed

        var errorDescription: String? {
            switch self {
            case .noFullDiskAccess:
                return "Cannot open ~/Library/Messages/chat.db. Grant Full " +
                    "Disk Access to this app in System Settings → Privacy " +
                    "& Security."
            case .sourceUnreadable(let url):
                return "Cannot read source database at \(url.path)."
            case .unsafePath(let path):
                return "Snapshot path contains characters unsafe for " +
                    "VACUUM INTO: \(path)"
            case .vacuumFailed(let underlying):
                return "VACUUM INTO failed: \(underlying.localizedDescription)"
            case .hashFailed:
                return "Could not read snapshot to compute its SHA-256."
            }
        }
    }

    /// Default source path on macOS — the live Messages database.
    static let defaultSourceURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }()

    /// Default working root for snapshots. Snapshots are isolated under
    /// per-run subdirectories (UUID-named) so concurrent archive runs
    /// don't trample each other.
    static let defaultWorkRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".imessage-archiver/work")
    }()

    /// Snapshot `source` into a fresh subdirectory of `workRoot`.
    /// Returns the snapshot path + its SHA-256.
    static func snapshot(
        source: URL = defaultSourceURL,
        workRoot: URL = defaultWorkRoot
    ) throws -> Snapshot {
        let fm = FileManager.default

        // Make the work root with 0o700 in case it's the first run.
        try fm.createDirectory(
            at: workRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Per-run subdirectory. UUID-named is race-free against symlink
        // attacks because we generate the name ourselves and create the
        // directory atomically.
        let snapDir = workRoot.appendingPathComponent(
            "snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(
            at: snapDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let snapURL = snapDir.appendingPathComponent("chat.db")
        let snapPath = snapURL.path

        // Defense-in-depth: refuse any path the SQL would interpret
        // unexpectedly. SQLite VACUUM INTO has no parameter binding, so
        // the path is interpolated directly.
        guard !snapPath.contains("'"), !snapPath.contains("\0") else {
            throw SnapshotError.unsafePath(snapPath)
        }

        // Open the source read-only via URI immutable=1 so SQLite never
        // attempts to write -wal/-shm next to it (same fix as the iOS
        // reader's URI open, mirrored here for the chat.db side).
        guard fm.isReadableFile(atPath: source.path) else {
            throw SnapshotError.noFullDiskAccess
        }

        let escapedSource = source.path
        let sourceURI = "file:\(escapedSource)?mode=ro&immutable=1"

        var config = Configuration()
        config.readonly = true

        do {
            let queue = try DatabaseQueue(path: sourceURI, configuration: config)
            try queue.write { db in
                // VACUUM is a no-op on a readonly connection — we need
                // to attach. SQLite supports `VACUUM main INTO 'path'`
                // even when the source connection is readonly.
                try db.execute(sql: "VACUUM INTO '\(snapPath)'")
            }
        } catch {
            throw SnapshotError.vacuumFailed(underlying: error)
        }

        let sha = try sha256(of: snapURL)
        return Snapshot(url: snapURL, sha256: sha)
    }

    /// Stream-hash a file in 1 MB chunks. Suitable for multi-GB chat.db.
    static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SnapshotError.hashFailed
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 * 1024 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

#endif
