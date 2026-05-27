import Foundation

enum TarError: Error, LocalizedError {
    case incompleteRead(offset: Int64, expected: Int64)
    case fileNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .incompleteRead(let offset, let expected):
            return "Incomplete read at offset \(offset), expected \(expected) bytes"
        case .fileNotFound(let url):
            return "attachments.tar not found at \(url.path)"
        }
    }
}

final class TarReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(bundleURL: URL) throws {
        let tarURL = bundleURL.appendingPathComponent("attachments.tar")
        guard FileManager.default.fileExists(atPath: tarURL.path) else {
            throw TarError.fileNotFound(tarURL)
        }
        self.handle = try FileHandle(forReadingFrom: tarURL)
    }

    deinit { try? handle.close() }

    func extract(offset: Int64, length: Int64) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)),
              data.count == Int(length)
        else {
            throw TarError.incompleteRead(offset: offset, expected: length)
        }
        return data
    }
}
