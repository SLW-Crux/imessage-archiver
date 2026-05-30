import Foundation
import GRDB
import CryptoKit

/// Verify a built archive by re-hashing every attachment in
/// `attachments.tar` and comparing against the SHA-256 stored in
/// `archive.sqlite`.
///
/// Port of `src/imessage_archiver/core/verify.py`.
public enum ArchiveVerifier {

    public struct Result: Sendable {
        public var checked: Int = 0
        public var mismatched: [String] = []  // attachment_guid strings
        public var skipped: Int = 0           // non-LOCAL_PRESENT rows
    }

    public enum Error: Swift.Error, LocalizedError {
        case bundleMissing(URL)
        case dbOpenFailed(underlying: Swift.Error)
        case tarOpenFailed(underlying: Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .bundleMissing(let url):
                return "Archive bundle not found at \(url.path)."
            case .dbOpenFailed(let e):
                return "Couldn't open archive.sqlite: \(e.localizedDescription)"
            case .tarOpenFailed(let e):
                return "Couldn't open attachments.tar: \(e.localizedDescription)"
            }
        }
    }

    /// Walk every `LOCAL_PRESENT` row in the archive's attachments
    /// table, read its bytes from the tar at the stored
    /// `(tar_offset, tar_length)`, hash them, and compare to
    /// `attachments.sha256`. Returns the result struct.
    public static func verify(
        bundleURL: URL,
        progress: (@Sendable (_ checked: Int, _ total: Int) -> Void)? = nil
    ) throws -> Result {
        let fm = FileManager.default
        let sqliteURL = bundleURL.appendingPathComponent("archive.sqlite")
        guard fm.fileExists(atPath: sqliteURL.path) else {
            throw Error.bundleMissing(bundleURL)
        }

        let tarReader: TarReader
        do {
            tarReader = try TarReader(bundleURL: bundleURL)
        } catch {
            throw Error.tarOpenFailed(underlying: error)
        }

        let dbQueue: DatabaseQueue
        do {
            var config = Configuration()
            config.readonly = true
            let uri = "file:\(sqliteURL.path)?mode=ro&immutable=1"
            dbQueue = try DatabaseQueue(path: uri, configuration: config)
        } catch {
            throw Error.dbOpenFailed(underlying: error)
        }

        struct Row {
            let guid: String
            let offset: Int64
            let length: Int64
            let sha: String
        }

        let rows: [Row] = try dbQueue.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT attachment_guid, tar_offset, tar_length, sha256
                FROM attachments
                WHERE state='LOCAL_PRESENT'
                  AND tar_offset IS NOT NULL
                  AND tar_length IS NOT NULL
                  AND sha256 IS NOT NULL
                """).map {
                Row(
                    guid: $0["attachment_guid"],
                    offset: $0["tar_offset"],
                    length: $0["tar_length"],
                    sha: $0["sha256"]
                )
            }
        }

        var result = Result()
        let total = rows.count
        for (i, row) in rows.enumerated() {
            let data = try tarReader.extract(offset: row.offset, length: row.length)
            let hash = SHA256.hash(data: data)
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            result.checked += 1
            if hex != row.sha.lowercased() {
                result.mismatched.append(row.guid)
            }
            progress?(i + 1, total)
        }
        return result
    }
}
