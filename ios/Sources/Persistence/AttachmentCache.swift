import Foundation

enum AttachmentError: Error, LocalizedError {
    case notPresent
    case noTarReader
    case oversize
    case unsafeFilename(String)

    var errorDescription: String? {
        switch self {
        case .notPresent: return "Attachment data not present in archive"
        case .noTarReader: return "attachments.tar not yet downloaded"
        case .oversize: return "Attachment too large to cache (> 500MB)"
        case .unsafeFilename(let name): return "Refusing to cache attachment with unsafe filename: \(name)"
        }
    }
}

/// Sanitises an untrusted attachment filename for use as a cache file name.
///
/// The Mac archiver writes whatever name the source `chat.db` had into the
/// archive bundle. On iOS we treat it as untrusted: strip path separators,
/// NUL bytes, and clamp to 80 chars so a malicious or corrupt bundle can't
/// escape the cache directory.
func sanitisedAttachmentFilename(_ raw: String?) -> String {
    let base = raw ?? "file"
    // Take only the last path component (Apple sometimes stores full paths)
    let lastComponent = (base as NSString).lastPathComponent
    // Strip path separators, NULs, leading dots (hidden-file evasion).
    let forbidden = CharacterSet(charactersIn: "/\\:\0")
    let cleaned = lastComponent
        .components(separatedBy: forbidden)
        .joined(separator: "_")
        .drop { $0 == "." }
    let trimmed = String(cleaned.prefix(80))
    return trimmed.isEmpty ? "file" : trimmed
}

@MainActor
final class AttachmentCache {
    /// 500 MB. A single attachment larger than this is refused; it is
    /// extracted to a one-shot temp file by the caller instead.
    private let maxBytes: Int64 = 500 * 1024 * 1024
    /// Per-attachment hard cap. Prevents a single oversize attachment from
    /// degenerating the cache into a 1-entry thrashing loop (M9 fix).
    private let maxSingleAttachmentBytes: Int64 = 100 * 1024 * 1024

    private let cacheDir: URL

    // Ordered LRU: front = least recently used, back = most recent.
    private var lru: [(guid: String, filename: String, size: Int64)] = []
    private var index: [String: Int] = [:]
    private var totalBytes: Int64 = 0

    // Guids whose cached file is currently being shown to the user (e.g.
    // by QuickLook). Pinned entries are never evicted. The caller is
    // responsible for unpin() when the preview is dismissed.
    private var pinned: Set<String> = []

    private let indexSidecar: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("AttachmentCache", isDirectory: true)
        indexSidecar = cacheDir.appendingPathComponent(".index.json", isDirectory: false)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadIndexFromDiskOrRebuild()
    }

    func url(for attachment: Attachment, tarReader: TarReader) async throws -> URL {
        guard attachment.isExtractable,
              let offset = attachment.tarOffset,
              let length = attachment.tarLength
        else {
            throw AttachmentError.notPresent
        }
        if length > maxSingleAttachmentBytes {
            throw AttachmentError.oversize
        }

        let safeName = sanitisedAttachmentFilename(attachment.filename)
        let cacheFilename = "\(attachment.attachmentGuid)__\(safeName)"
        let cachedURL = cacheDir.appendingPathComponent(cacheFilename)

        // Containment check: the resolved path must stay inside cacheDir.
        let stdCached = cachedURL.standardizedFileURL.path
        let stdRoot = cacheDir.standardizedFileURL.path
        guard stdCached.hasPrefix(stdRoot + "/") else {
            throw AttachmentError.unsafeFilename(safeName)
        }

        if index[attachment.attachmentGuid] != nil
            && FileManager.default.fileExists(atPath: cachedURL.path) {
            touch(attachment.attachmentGuid)
            return cachedURL
        }

        // Refuse to overwrite a symlink. On macOS (App Sandbox disabled
        // per PR #29) a swapped-in symlink at the cache path would
        // redirect the attachment bytes to a write target inside the
        // user's home (review finding IC2). On iOS the sandbox bounds
        // the blast radius but the check is cheap and defense in depth
        // is the right default.
        if let values = try? cachedURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            try? FileManager.default.removeItem(at: cachedURL)
        }

        // Extract + write on a background thread so the main actor is not
        // blocked by a multi-MB disk write.
        try await Task.detached(priority: .userInitiated) {
            let data = try tarReader.extract(offset: offset, length: length)
            try data.write(to: cachedURL, options: .atomic)
        }.value

        let size = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size] as? Int64) ?? 0
        insertOrTouch(guid: attachment.attachmentGuid, filename: cacheFilename, size: size)
        evictIfNeeded()
        persistIndex()
        return cachedURL
    }

    /// Pin a guid so it cannot be evicted while in use (e.g. while
    /// QuickLook is presenting the file).
    func pin(_ guid: String) { pinned.insert(guid) }
    func unpin(_ guid: String) { pinned.remove(guid) }

    // MARK: - LRU management

    private func insertOrTouch(guid: String, filename: String, size: Int64) {
        if let pos = index[guid] {
            let prev = lru[pos]
            totalBytes -= prev.size
            lru.remove(at: pos)
        }
        lru.append((guid: guid, filename: filename, size: size))
        totalBytes += size
        rebuildIndex()
    }

    private func touch(_ guid: String) {
        guard let pos = index[guid] else { return }
        let entry = lru.remove(at: pos)
        lru.append(entry)
        rebuildIndex()
    }

    private func evictIfNeeded() {
        // Evict from the front (oldest). Skip pinned entries. Stop if the
        // only remaining entries are pinned — better to exceed the cap than
        // discard a file the user is currently looking at.
        while totalBytes > maxBytes {
            guard let frontIdx = lru.firstIndex(where: { !pinned.contains($0.guid) }) else {
                break
            }
            let entry = lru.remove(at: frontIdx)
            totalBytes -= entry.size
            let url = cacheDir.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: url)
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        index = Dictionary(uniqueKeysWithValues: lru.enumerated().map { ($1.guid, $0) })
    }

    // MARK: - Index persistence (replaces the fragile prefix(36) parsing)

    private struct IndexEntry: Codable {
        let guid: String
        let filename: String
        let size: Int64
    }

    private func persistIndex() {
        let snapshot = lru.map { IndexEntry(guid: $0.guid, filename: $0.filename, size: $0.size) }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexSidecar, options: .atomic)
    }

    private func loadIndexFromDiskOrRebuild() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: indexSidecar),
           let entries = try? JSONDecoder().decode([IndexEntry].self, from: data) {
            for entry in entries {
                let url = cacheDir.appendingPathComponent(entry.filename)
                if fm.fileExists(atPath: url.path) {
                    lru.append((guid: entry.guid, filename: entry.filename, size: entry.size))
                    totalBytes += entry.size
                }
            }
            rebuildIndex()
            return
        }
        // No sidecar (first launch or older app version) — best-effort
        // scan with strict filename validation: drop anything that doesn't
        // match the expected "<guid>__<name>" format.
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        let sorted = items.compactMap { url -> (url: URL, date: Date, size: Int64)? in
            let v = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
            ])
            guard v?.isRegularFile == true,
                  let date = v?.contentModificationDate,
                  let size = v?.fileSize else { return nil }
            return (url, date, Int64(size))
        }.sorted { $0.date < $1.date }
        for item in sorted {
            let name = item.url.lastPathComponent
            guard let guidEnd = name.range(of: "__") else {
                try? fm.removeItem(at: item.url)
                continue
            }
            let guid = String(name[..<guidEnd.lowerBound])
            lru.append((guid: guid, filename: name, size: item.size))
            totalBytes += item.size
        }
        rebuildIndex()
        evictIfNeeded()
        persistIndex()
    }
}
