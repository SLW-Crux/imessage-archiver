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

    enum ManifestError: Error, LocalizedError {
        case missingOrInvalidSchemaVersion

        var errorDescription: String? {
            switch self {
            case .missingOrInvalidSchemaVersion:
                return "Archive manifest is missing or has an invalid " +
                    "schema_version. The bundle may be corrupted or was " +
                    "written by an incompatible archiver."
            }
        }
    }

    static func load(bundleURL: URL) throws -> ArchiveManifest {
        let url = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // schema_version MUST be present and an Int. Anything else (missing,
        // wrong type, null, JSON corrupt) fails the load — defaulting to 1
        // here would defeat the PR #16 schema-version refusal entirely:
        // a v2 archive whose manifest got truncated would silently be
        // opened as v1 and the reader would read garbage from columns
        // that moved (review finding IH2).
        guard let schemaVersion = raw["schema_version"] as? Int,
              schemaVersion > 0 else {
            throw ManifestError.missingOrInvalidSchemaVersion
        }

        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date {
            (raw[key] as? String).flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        }

        return ArchiveManifest(
            schemaVersion: schemaVersion,
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
