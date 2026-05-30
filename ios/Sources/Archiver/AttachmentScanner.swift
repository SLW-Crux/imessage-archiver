import Foundation
import CryptoKit

/// State an attachment can be in at archive time. Mirrors the iOS
/// reader's `AttachmentState` enum so the bundle schema is stable.
public enum AttachmentState: String, Sendable {
    case localPresent = "LOCAL_PRESENT"
    case missing      = "MISSING"
    case zeroByte     = "ZERO_BYTE"
    case unreadable   = "UNREADABLE"
}

/// Classify and hash attachments referenced by chat.db.
///
/// Port of `src/imessage_archiver/core/attachments.py`.
public enum AttachmentScanner {

    /// Classify `attachment` by checking whether its resolved file URL
    /// exists, is readable, and is non-empty.
    public static func classify(
        _ attachment: SourceDBReader.AttachmentRow
    ) -> AttachmentState {
        guard let url = attachment.resolvedURL else {
            return .missing
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return .missing
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: url.path)
        } catch {
            // The file exists but we can't stat it — typically a
            // permission issue (e.g. quarantined file the archiver
            // doesn't have access to).
            return .unreadable
        }

        guard let size = attrs[.size] as? Int64 else {
            return .unreadable
        }
        if size == 0 {
            return .zeroByte
        }
        return .localPresent
    }

    /// Stream-hash a file in 1 MB chunks. Returns the lowercase hex
    /// SHA-256 digest.
    public static func sha256(of url: URL) throws -> String {
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

    /// Local error type. Kept narrow on purpose — full archive error
    /// taxonomy is in the existing `ArchiveError` enum used by the
    /// reader UI.
    public enum SnapshotError: Error {
        case hashFailed
    }
}
