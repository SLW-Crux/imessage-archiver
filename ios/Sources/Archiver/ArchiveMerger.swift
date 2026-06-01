#if os(macOS)
import Foundation
import GRDB

/// Incremental merge / refresh of an existing `.imarchive` bundle.
///
/// The Python merge module is small because INSERT OR IGNORE on the
/// Apple-GUID primary keys does the actual deduplication; this Swift
/// port is the same thin wrapper. The point of having it exist as its
/// own type is to centralise pre-flight validation: refuse to merge a
/// source whose schema/timeframe doesn't make sense relative to the
/// existing bundle.
///
/// Port of `src/imessage_archiver/core/merge.py`.
enum ArchiveMerger {

    enum Error: Swift.Error, LocalizedError {
        case bundleMissing(URL)
        case sourceOlderThanLastRun(sourceTimestamp: Int64, lastRunTimestamp: Int64)
        case dbOpenFailed(underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .bundleMissing(let url):
                return "Archive bundle not found at \(url.path)."
            case .sourceOlderThanLastRun(let src, let last):
                return "Source chat.db's latest message (\(src)) predates this bundle's last archive run (\(last)). Refusing to merge — re-creating the bundle would be safer."
            case .dbOpenFailed(let e):
                return "Couldn't open archive.sqlite: \(e.localizedDescription)"
            }
        }
    }

    /// Pre-flight check: the source's newest message must not be older
    /// than the most recent archive run. If it is, the source is
    /// probably a stale backup or a snapshot from a different account.
    static func validateForMerge(
        bundleURL: URL,
        sourceReader: SourceDBReader
    ) throws {
        let sqliteURL = bundleURL.appendingPathComponent("archive.sqlite")
        guard FileManager.default.fileExists(atPath: sqliteURL.path) else {
            // Nothing to merge into — caller should fall through to a
            // first-time run.
            return
        }

        var config = Configuration()
        config.readonly = true
        let uri = "file:\(sqliteURL.path)?mode=ro&immutable=1"

        let lastRunStart: Int64
        do {
            let queue = try DatabaseQueue(path: uri, configuration: config)
            lastRunStart = try queue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT MAX(started_at) FROM archive_runs"
                ) ?? 0
            }
        } catch {
            throw Error.dbOpenFailed(underlying: error)
        }

        // Find the source's newest message timestamp across all chats.
        let chats = (try? sourceReader.chats()) ?? []
        let sourceNewest: Int64 = chats.compactMap { $0.lastMessageAt }.max() ?? 0

        // Allow a small clock-skew margin (24h). A source newer than
        // last_run - 24h is fine.
        let skewMargin: Int64 = 24 * 60 * 60
        if sourceNewest > 0, sourceNewest + skewMargin < lastRunStart {
            throw Error.sourceOlderThanLastRun(
                sourceTimestamp: sourceNewest,
                lastRunTimestamp: lastRunStart
            )
        }
    }

    /// Convenience wrapper: validate, then call ArchiveWriter.run().
    /// Returns the final stats.
    @discardableResult
    static func merge(
        bundleURL: URL,
        reader: SourceDBReader,
        sourceSHA256: String = "",
        sourceDBPath: String = "",
        progress: ArchiveWriter.ProgressCallback? = nil
    ) async throws -> ArchiveWriter.RunStats {
        try validateForMerge(bundleURL: bundleURL, sourceReader: reader)

        let lock = ArchiveLock()
        try lock.acquire()
        defer { lock.release() }

        let writer = ArchiveWriter(bundleURL: bundleURL)
        return try await writer.run(
            reader: reader,
            sourceSHA256: sourceSHA256,
            sourceDBPath: sourceDBPath,
            progress: progress
        )
    }
}

#endif
