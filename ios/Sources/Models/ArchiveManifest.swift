import Foundation

struct ArchiveManifest: Sendable {
    let schemaVersion: Int
    let archiverVersion: String
    let createdAt: Date
    let lastUpdatedAt: Date
    let chatCount: Int
    let messageCount: Int
    let attachmentCount: Int
    let missingAttachmentCount: Int
    let archiveSizeBytes: Int64

    static func load(bundleURL: URL) throws -> ArchiveManifest {
        let url = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date {
            (raw[key] as? String).flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        }

        return ArchiveManifest(
            schemaVersion: raw["schema_version"] as? Int ?? 1,
            archiverVersion: raw["archiver_version"] as? String ?? "",
            createdAt: date("created_at"),
            lastUpdatedAt: date("last_updated_at"),
            chatCount: raw["chat_count"] as? Int ?? 0,
            messageCount: raw["message_count"] as? Int ?? 0,
            attachmentCount: raw["attachment_count"] as? Int ?? 0,
            missingAttachmentCount: raw["missing_attachment_count"] as? Int ?? 0,
            archiveSizeBytes: raw["archive_size_bytes"] as? Int64
                ?? Int64(raw["archive_size_bytes"] as? Int ?? 0)
        )
    }
}
