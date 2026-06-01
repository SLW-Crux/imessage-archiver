import Foundation

enum TarError: Error, LocalizedError {
    case incompleteRead(offset: Int64, expected: Int64, got: Int)
    case fileNotFound(URL)
    case invalidOffset(Int64)
    case invalidLength(Int64)
    case lengthExceedsFile(offset: Int64, length: Int64, fileSize: UInt64)

    var errorDescription: String? {
        switch self {
        case .incompleteRead(let offset, let expected, let got):
            return "Incomplete read at offset \(offset): expected \(expected) bytes, got \(got)"
        case .fileNotFound(let url):
            return "attachments.tar not found at \(url.path)"
        case .invalidOffset(let o):
            return "Invalid tar_offset: \(o) (must be non-negative)"
        case .invalidLength(let l):
            return "Invalid tar_length: \(l) (must be non-negative and <= 256 MiB)"
        case .lengthExceedsFile(let o, let l, let f):
            return "Read range [\(o)..\(o+l)] exceeds tar file size \(f)"
        }
    }
}

final class TarReader: @unchecked Sendable {
    private let handle: FileHandle
    private let fileSize: UInt64
    private let lock = NSLock()

    /// Reject any single attachment larger than this. iMessage attachments
    /// are practically capped at ~100 MB by Apple's own limits, so 256 MiB
    /// is a comfortable ceiling that still catches bit-flips / crafted
    /// `tar_length` values long before they OOM the app.
    ///
    /// This cap is enforced inside `extract()` so every caller inherits
    /// the same bound regardless of their own validation
    /// (review finding IC1 — `AttachmentCache` has a tighter 100 MB gate,
    /// but `Thumbnailer` and any future caller without per-caller gates
    /// still need this defense in depth).
    private static let maxAttachmentBytes: Int64 = 256 * 1024 * 1024  // 256 MiB

    init(bundleURL: URL) throws {
        let tarURL = bundleURL.appendingPathComponent("attachments.tar")
        guard FileManager.default.fileExists(atPath: tarURL.path) else {
            throw TarError.fileNotFound(tarURL)
        }
        self.handle = try FileHandle(forReadingFrom: tarURL)
        // Cache the file size once. We use it to validate every extract()
        // call's (offset + length) range before allocating any memory.
        self.fileSize = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func extract(offset: Int64, length: Int64) throws -> Data {
        // Validate bounds BEFORE allocating memory. A negative offset cast
        // to UInt64 becomes ~9 EiB; a huge length silently truncates on
        // 32-bit Int conversion. Catch both up front.
        guard offset >= 0 else { throw TarError.invalidOffset(offset) }
        guard length >= 0, length <= Self.maxAttachmentBytes else {
            throw TarError.invalidLength(length)
        }
        // offset + length must not overflow Int64 and must fit in the file.
        let (sum, overflow) = offset.addingReportingOverflow(length)
        if overflow || UInt64(sum) > fileSize {
            throw TarError.lengthExceedsFile(offset: offset, length: length, fileSize: fileSize)
        }

        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        // Loop until we have the full requested length or hit EOF. POSIX
        // read() may return short even for local files under some conditions.
        var collected = Data()
        collected.reserveCapacity(Int(length))
        while collected.count < Int(length) {
            let remaining = Int(length) - collected.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }
            collected.append(chunk)
        }
        if collected.count != Int(length) {
            throw TarError.incompleteRead(
                offset: offset, expected: length, got: collected.count
            )
        }
        return collected
    }
}
