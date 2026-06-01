#if os(macOS)
import Foundation
import GRDB

/// Read-only interface to a snapshotted `chat.db`.
///
/// All queries hit a `VACUUM INTO`-produced snapshot (see
/// `SourceDBSnapshotter`), opened via `file:<path>?mode=ro&immutable=1`
/// so SQLite never tries to create -wal/-shm next to it.
///
/// This is the Swift port of `src/imessage_archiver/db/reader.py`. The
/// SQL queries are kept verbatim — they're a load-bearing description
/// of `chat.db`'s schema, and the project's first hard-won lessons live
/// in their column choices.
struct SourceDBReader {

    struct ChatRow: Sendable {
        let chatGuid: String
        let displayName: String?
        let chatIdentifier: String?
        let serviceName: String?
        let isGroup: Bool
        let participants: [String]
        let firstMessageAt: Int64?   // Unix epoch seconds
        let lastMessageAt: Int64?
        let messageCount: Int
    }

    struct MessageRow: Sendable {
        let messageGuid: String
        let chatGuid: String
        let senderHandle: String?
        let senderName: String?
        let timestamp: Int64         // Unix epoch seconds
        let text: String?
        let isFromMe: Bool
        let service: String?
        let replyToGuid: String?
        let associatedMessageGuid: String?
        let associatedMessageType: Int
        let hasAttachments: Bool
        let dateEdited: Int64?       // nil = never edited
        let dateRetracted: Int64?    // nil = not retracted
    }

    struct AttachmentRow: Sendable {
        let attachmentGuid: String
        let messageGuid: String
        let filename: String?
        let mimeType: String?
        let uti: String?
        let size: Int64
        let resolvedURL: URL?        // nil if outside trusted roots
    }

    private let dbQueue: DatabaseQueue
    private let snapshotURL: URL

    init(snapshotURL: URL) throws {
        self.snapshotURL = snapshotURL

        var config = Configuration()
        config.readonly = true
        let uri = "file:\(snapshotURL.path)?mode=ro&immutable=1"
        self.dbQueue = try DatabaseQueue(path: uri, configuration: config)
    }

    // MARK: - Public API

    /// All chats sorted by most-recent-message-first.
    func chats() throws -> [ChatRow] {
        try dbQueue.read { db in
            let rawChats = try Row.fetchAll(db, sql: """
                SELECT ROWID, guid, display_name, chat_identifier, service_name, room_name
                FROM chat WHERE guid IS NOT NULL
                """)

            let handleMap = try chatHandles(db: db)
            let counts = try messageCountsPerChat(db: db)
            let bounds = try firstLastPerChat(db: db)

            var result: [ChatRow] = []
            for row in rawChats {
                let chatRowID: Int64 = row["ROWID"]
                let guid: String = row["guid"]
                let participants = handleMap[chatRowID] ?? []
                let roomName: String? = row["room_name"]
                let isGroup = (roomName != nil) || participants.count > 1
                let (first, last) = bounds[guid] ?? (nil, nil)
                result.append(ChatRow(
                    chatGuid: guid,
                    displayName: row["display_name"],
                    chatIdentifier: row["chat_identifier"],
                    serviceName: row["service_name"],
                    isGroup: isGroup,
                    participants: participants,
                    firstMessageAt: first,
                    lastMessageAt: last,
                    messageCount: counts[guid] ?? 0
                ))
            }
            result.sort { ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0) }
            return result
        }
    }

    /// All messages for a chat, in chronological order.
    func messages(in chatGuid: String) throws -> [MessageRow] {
        try dbQueue.read { db in
            guard let chatRowID: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT ROWID FROM chat WHERE guid = ?",
                arguments: [chatGuid]
            ) else {
                return []
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    m.guid,
                    m.text,
                    m.attributedBody,
                    m.date,
                    m.is_from_me,
                    m.handle_id,
                    m.service,
                    m.associated_message_guid,
                    m.associated_message_type,
                    m.reply_to_guid,
                    m.cache_has_attachments,
                    m.date_edited,
                    m.date_retracted,
                    h.id AS handle_id_str
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE cmj.chat_id = ?
                ORDER BY m.date ASC
                """, arguments: [chatRowID])
            return rows.map { rowToMessage($0, chatGuid: chatGuid) }
        }
    }

    /// All attachments referenced by a single message.
    func attachments(for messageGuid: String) throws -> [AttachmentRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    a.guid,
                    a.filename,
                    a.mime_type,
                    a.uti,
                    a.total_bytes
                FROM attachment a
                JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
                JOIN message m ON m.ROWID = maj.message_id
                WHERE m.guid = ?
                """, arguments: [messageGuid])
            return rows.map { rowToAttachment($0, messageGuid: messageGuid) }
        }
    }

    // MARK: - Private helpers

    private func chatHandles(db: Database) throws -> [Int64: [String]] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT chj.chat_id, h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """)
        var result: [Int64: [String]] = [:]
        for row in rows {
            let chatID: Int64 = row[0]
            let handle: String = row[1]
            result[chatID, default: []].append(handle)
        }
        return result
    }

    private func messageCountsPerChat(db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.guid, COUNT(*) AS cnt
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.guid
            """)
        var result: [String: Int] = [:]
        for row in rows {
            let guid: String = row[0]
            let cnt: Int = row[1]
            result[guid] = cnt
        }
        return result
    }

    private func firstLastPerChat(db: Database) throws -> [String: (Int64?, Int64?)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.guid, MIN(m.date), MAX(m.date)
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.guid
            """)
        var result: [String: (Int64?, Int64?)] = [:]
        for row in rows {
            let guid: String = row[0]
            let first: Int64? = row[1]
            let last: Int64? = row[2]
            result[guid] = (
                first.map { AppleEpoch.toUnix($0) },
                last.map { AppleEpoch.toUnix($0) }
            )
        }
        return result
    }

    private func rowToMessage(_ row: Row, chatGuid: String) -> MessageRow {
        let isFromMeInt: Int64 = row["is_from_me"] ?? 0
        let isFromMe = isFromMeInt != 0

        // Sender resolution. ContactsResolver port still pending — for
        // now `senderName` is just the handle for received messages,
        // or "Me" for sent. Contacts.framework integration lands in
        // the next slice.
        let handleStr: String? = row["handle_id_str"]
        let senderHandle: String? = isFromMe ? nil : handleStr
        let senderName: String? = isFromMe ? "Me" : handleStr

        // Text resolution: prefer the `text` column; fall back to
        // decoding the `attributedBody` BLOB via NSUnarchiver.
        let plainText: String? = row["text"]
        let attributedBlob: Data? = row["attributedBody"]
        let text: String?
        if let plain = plainText, !plain.isEmpty {
            text = plain
        } else if let blob = attributedBlob {
            text = AttributedBodyDecoder.extractText(from: blob)
        } else {
            text = nil
        }

        let rawDate: Int64? = row["date"]
        let timestamp = rawDate.map { AppleEpoch.toUnix($0) } ?? 0

        let rawEdited: Int64? = row["date_edited"]
        let rawRetracted: Int64? = row["date_retracted"]
        let dateEdited = rawEdited.flatMap { $0 == 0 ? nil : AppleEpoch.toUnix($0) }
        let dateRetracted = rawRetracted.flatMap { $0 == 0 ? nil : AppleEpoch.toUnix($0) }

        let hasAttachmentsInt: Int64 = row["cache_has_attachments"] ?? 0
        let associatedType: Int64 = row["associated_message_type"] ?? 0

        return MessageRow(
            messageGuid: row["guid"],
            chatGuid: chatGuid,
            senderHandle: senderHandle,
            senderName: senderName,
            timestamp: timestamp,
            text: text,
            isFromMe: isFromMe,
            service: row["service"],
            replyToGuid: row["reply_to_guid"],
            associatedMessageGuid: row["associated_message_guid"],
            associatedMessageType: Int(associatedType),
            hasAttachments: hasAttachmentsInt != 0,
            dateEdited: dateEdited,
            dateRetracted: dateRetracted
        )
    }

    private func rowToAttachment(_ row: Row, messageGuid: String) -> AttachmentRow {
        let filename: String? = row["filename"]
        let resolved: URL? = filename.flatMap(Self.resolveAttachmentPath)
        let totalBytes: Int64 = row["total_bytes"] ?? 0
        return AttachmentRow(
            attachmentGuid: row["guid"],
            messageGuid: messageGuid,
            filename: filename,
            mimeType: row["mime_type"],
            uti: row["uti"],
            size: totalBytes,
            resolvedURL: resolved
        )
    }

    /// Resolve a chat.db `attachment.filename` to a real file URL,
    /// constrained to the trusted attachment roots.
    ///
    /// Defense in depth: a tampered chat.db could insert a row whose
    /// filename points at `~/.ssh/id_rsa` or similar; we refuse to read
    /// files outside `~/Library/Messages/Attachments/` so a malicious
    /// row cannot exfiltrate arbitrary user data into the archive
    /// bundle. Same rule the Python reader enforces.
    private static func resolveAttachmentPath(_ filename: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let candidate: URL
        if filename.hasPrefix("~") {
            candidate = URL(fileURLWithPath: (filename as NSString).expandingTildeInPath)
        } else if filename.hasPrefix("/") {
            candidate = URL(fileURLWithPath: filename)
        } else {
            candidate = home
                .appendingPathComponent("Library/Messages")
                .appendingPathComponent(filename)
        }

        let resolved = candidate.resolvingSymlinksInPath()
        let attachmentsRoot = home
            .appendingPathComponent("Library/Messages/Attachments")
            .resolvingSymlinksInPath()

        let resolvedPath = resolved.path
        let rootPath = attachmentsRoot.path
        if resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") {
            return resolved
        }
        return nil
    }
}

#endif
