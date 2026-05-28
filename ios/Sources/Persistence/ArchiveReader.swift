import Foundation
import GRDB

enum ArchiveReaderError: Error, LocalizedError {
    case schemaTooNew(found: Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .schemaTooNew(let found, let max):
            return "Archive schema version \(found) is newer than this app supports (\(max)). Update the iOS reader."
        }
    }
}

final class ArchiveReader: Sendable {
    /// Maximum bundle schema version this reader understands. Per
    /// docs/SCHEMA.md the iOS reader must refuse to open a newer bundle
    /// rather than silently mis-render unknown columns as nil.
    static let maxSupportedSchemaVersion = 1

    private let dbPool: DatabasePool
    let manifest: ArchiveManifest
    let bundleURL: URL

    init(bundleURL: URL) throws {
        self.bundleURL = bundleURL
        let manifest = try ArchiveManifest.load(bundleURL: bundleURL)
        if manifest.schemaVersion > Self.maxSupportedSchemaVersion {
            throw ArchiveReaderError.schemaTooNew(
                found: manifest.schemaVersion,
                max: Self.maxSupportedSchemaVersion
            )
        }
        self.manifest = manifest

        let sqliteURL = bundleURL.appendingPathComponent("archive.sqlite")
        var config = Configuration()
        config.readonly = true
        self.dbPool = try DatabasePool(path: sqliteURL.path, configuration: config)
    }

    func chats() async throws -> [Chat] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT chat_guid, display_name, chat_identifier, service_name,
                       is_group, participants_json, first_message_at, last_message_at,
                       message_count
                FROM chats
                ORDER BY last_message_at DESC NULLS LAST
                """)
            return rows.map(Self.chatFromRow)
        }
    }

    func messages(in chatGuid: String, limit: Int = 200, before: Date? = nil) async throws -> [Message] {
        try await dbPool.read { db in
            var sql = """
                SELECT message_guid, chat_guid, sender_handle, sender_name,
                       timestamp, text, is_from_me, reply_to_guid,
                       reactions_json, has_attachments, date_edited, date_retracted
                FROM messages
                WHERE chat_guid = ?
                """
            var args: [DatabaseValueConvertible] = [chatGuid]
            if let before {
                sql += " AND timestamp < ?"
                args.append(Int64(before.timeIntervalSince1970))
            }
            sql += " ORDER BY timestamp ASC"
            if limit > 0 {
                sql += " LIMIT ?"
                args.append(limit)
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.messageFromRow)
        }
    }

    func attachments(for messageGuid: String) async throws -> [Attachment] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT attachment_guid, message_guid, filename, mime_type, uti,
                       size, sha256, tar_offset, tar_length, state
                FROM attachments
                WHERE message_guid = ?
                ORDER BY rowid
                """, arguments: [messageGuid])
            return rows.map(Self.attachmentFromRow)
        }
    }

    func search(query: String, limit: Int = 100) async throws -> [SearchHit] {
        let sanitised = Self.sanitiseFTS5Query(query)
        guard !sanitised.isEmpty else { return [] }
        return try await dbPool.read { db in
            // SQLite FTS5 snippet(table, col, before, after, ellipsis, tokens):
            // col -1 = all FTS-indexed columns. Markers are Private Use Area
            // codepoints (U+E000/U+E001) which are guaranteed not to appear
            // in valid Unicode text, avoiding FSI/PDI collisions in RTL text.
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.message_guid, m.chat_guid, m.sender_handle, m.sender_name,
                       m.timestamp, m.text, m.is_from_me, m.reply_to_guid,
                       m.reactions_json, m.has_attachments, m.date_edited, m.date_retracted,
                       snippet(messages_fts, -1,
                               '\u{E000}',
                               '\u{E001}',
                               '…', 16) AS snippet
                FROM messages_fts
                JOIN messages m ON m.message_guid = messages_fts.message_guid
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [sanitised, limit])
            return rows.map { row in
                SearchHit(
                    message: Self.messageFromRow(row),
                    snippet: row["snippet"] as? String ?? ""
                )
            }
        }
    }

    /// Convert raw user input into a valid FTS5 MATCH expression.
    ///
    /// FTS5 has its own mini-language: `"`, `*`, `:`, `(`, `)`, `-`, `+`,
    /// `OR`, `AND`, `NOT`, `NEAR` are syntactically significant. A user
    /// typing `the matrix (1999)` would throw "fts5: syntax error near (".
    /// To avoid that, wrap each whitespace-separated token in double
    /// quotes (escaping any internal `"`), joined with spaces (implicit AND).
    static func sanitiseFTS5Query(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        let quoted: [String] = tokens.compactMap { tok in
            // Strip any character that would break out of the quoted phrase.
            let cleaned = tok.replacingOccurrences(of: "\"", with: "")
            return cleaned.isEmpty ? nil : "\"\(cleaned)\""
        }
        return quoted.joined(separator: " ")
    }

    // MARK: - Row mappers

    private static func chatFromRow(_ row: Row) -> Chat {
        let participantsJson = row["participants_json"] as? String ?? "[]"
        let participants = (try? JSONDecoder().decode([String].self,
                                                      from: Data(participantsJson.utf8))) ?? []
        return Chat(
            chatGuid: row["chat_guid"],
            displayName: row["display_name"],
            chatIdentifier: row["chat_identifier"],
            serviceName: row["service_name"],
            isGroup: (row["is_group"] as? Int64 ?? 0) != 0,
            participants: participants,
            firstMessageAt: (row["first_message_at"] as? Int64).map { Date(timeIntervalSince1970: Double($0)) },
            lastMessageAt: (row["last_message_at"] as? Int64).map { Date(timeIntervalSince1970: Double($0)) },
            messageCount: Int(row["message_count"] as? Int64 ?? 0)
        )
    }

    private static func messageFromRow(_ row: Row) -> Message {
        let reactionsJson = row["reactions_json"] as? String ?? "[]"
        let reactions = (try? JSONDecoder().decode([Reaction].self,
                                                   from: Data(reactionsJson.utf8))) ?? []
        return Message(
            messageGuid: row["message_guid"],
            chatGuid: row["chat_guid"],
            senderHandle: row["sender_handle"],
            senderName: row["sender_name"],
            timestamp: Date(timeIntervalSince1970: Double(row["timestamp"] as? Int64 ?? 0)),
            text: row["text"],
            isFromMe: (row["is_from_me"] as? Int64 ?? 0) != 0,
            replyToGuid: row["reply_to_guid"],
            reactions: reactions,
            hasAttachments: (row["has_attachments"] as? Int64 ?? 0) != 0,
            dateEdited: (row["date_edited"] as? Int64).map { Date(timeIntervalSince1970: Double($0)) },
            dateRetracted: (row["date_retracted"] as? Int64).map { Date(timeIntervalSince1970: Double($0)) }
        )
    }

    private static func attachmentFromRow(_ row: Row) -> Attachment {
        Attachment(
            attachmentGuid: row["attachment_guid"],
            messageGuid: row["message_guid"],
            filename: row["filename"],
            mimeType: row["mime_type"],
            uti: row["uti"],
            size: row["size"] as? Int64 ?? 0,
            sha256: row["sha256"],
            tarOffset: row["tar_offset"],
            tarLength: row["tar_length"],
            state: AttachmentState(rawValue: row["state"] as? String ?? "") ?? .missing
        )
    }
}
