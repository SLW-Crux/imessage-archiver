import Foundation

enum AttachmentError: Error, LocalizedError {
    case notPresent
    case noTarReader

    var errorDescription: String? {
        switch self {
        case .notPresent: return "Attachment data not present in archive"
        case .noTarReader: return "attachments.tar not yet downloaded"
        }
    }
}

@MainActor
final class AttachmentCache {
    private let maxBytes: Int64 = 500 * 1024 * 1024
    private let cacheDir: URL
    // guid → (filename, byteSize) in LRU order (front = oldest)
    private var lru: [(guid: String, filename: String, size: Int64)] = []
    private var index: [String: Int] = [:]  // guid → lru position (rebuilt on mutation)
    private var totalBytes: Int64 = 0

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("AttachmentCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        rebuildFromDisk()
    }

    func url(for attachment: Attachment, tarReader: TarReader) async throws -> URL {
        let cacheFilename = "\(attachment.attachmentGuid)-\(attachment.filename ?? "file")"
        let cachedURL = cacheDir.appendingPathComponent(cacheFilename)

        if index[attachment.attachmentGuid] != nil {
            touch(attachment.attachmentGuid)
            return cachedURL
        }

        guard attachment.isExtractable,
              let offset = attachment.tarOffset,
              let length = attachment.tarLength
        else {
            throw AttachmentError.notPresent
        }

        let data = try await Task.detached {
            try tarReader.extract(offset: offset, length: length)
        }.value

        try data.write(to: cachedURL)
        insert(guid: attachment.attachmentGuid, filename: cacheFilename, size: Int64(data.count))
        evictIfNeeded()
        return cachedURL
    }

    // MARK: - LRU management

    private func insert(guid: String, filename: String, size: Int64) {
        lru.append((guid: guid, filename: filename, size: size))
        index[guid] = lru.count - 1
        totalBytes += size
    }

    private func touch(_ guid: String) {
        guard let pos = index[guid] else { return }
        let entry = lru.remove(at: pos)
        lru.append(entry)
        rebuildIndex()
    }

    private func evictIfNeeded() {
        while totalBytes > maxBytes, !lru.isEmpty {
            let entry = lru.removeFirst()
            index.removeValue(forKey: entry.guid)
            totalBytes -= entry.size
            let url = cacheDir.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: url)
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        index = Dictionary(uniqueKeysWithValues: lru.enumerated().map { ($1.guid, $0) })
    }

    private func rebuildFromDisk() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        let sorted = items.compactMap { url -> (url: URL, date: Date, size: Int64)? in
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let date = vals?.contentModificationDate,
                  let size = vals?.fileSize else { return nil }
            return (url: url, date: date, size: Int64(size))
        }.sorted { $0.date < $1.date }

        for item in sorted {
            let name = item.url.lastPathComponent
            // filename format: {guid}-{original filename}
            let guidPart = String(name.prefix(36))
            lru.append((guid: guidPart, filename: name, size: item.size))
            totalBytes += item.size
        }
        rebuildIndex()
        evictIfNeeded()
    }
}
