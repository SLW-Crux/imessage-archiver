import Foundation
import GRDB

enum ArchiveReaderError: Error, LocalizedError {
    case schemaTooNew(found: Int, max: Int)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .schemaTooNew(let found, let max):
            return "Archive schema version \(found) is newer than this app supports (\(max)). Update the iOS reader."
        case .openFailed(let details):
            return "Could not open archive: \(details)"
        }
    }
}

final class ArchiveReader: Sendable {
    /// Maximum bundle schema version this reader understands. Per
    /// docs/SCHEMA.md the iOS reader must refuse to open a newer bundle
    /// rather than silently mis-render unknown columns as nil.
    static let maxSupportedSchemaVersion = 1

    // DatabaseQueue, not DatabasePool. DatabasePool requires WAL mode,
    // which creates `archive.sqlite-wal` and `-shm` companion files next
    // to the SQLite. For bundles in an iCloud-managed Documents folder
    // (Mac in particular), writing those companions is denied by the
    // sandbox + iCloud coordination layer — opening the DB then fails
    // with SQLITE_CANTOPEN.
    //
    // DatabaseQueue with readonly = true uses rollback-journal-immutable
    // mode and does no companion writes. Slightly less concurrent than
    // DatabasePool but that's fine for a single-reader UI app.
    private let dbQueue: DatabaseQueue
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

        self.dbQueue = try Self.openDatabase(at: sqliteURL, configuration: config)
    }

    /// Open the archive's SQLite in immutable URI mode, wrapped in
    /// NSFileCoordinator.
    ///
    /// Two production issues compounded here:
    ///
    /// 1. The Mac archiver writes archive.sqlite in WAL journal mode.
    ///    Opening a WAL database normally requires SQLite to create
    ///    `-wal` and `-shm` companion files next to the SQLite. On iOS
    ///    (simulator OR device) the sandbox refuses those creations
    ///    inside the iCloud-managed Documents directory, even with
    ///    `config.readonly = true`, yielding SQLITE_CANTOPEN. The same
    ///    file opens fine in the sqlite3 CLI because that process has
    ///    unrestricted file-creation rights.
    ///
    /// 2. Files inside ~/Library/Mobile Documents/iCloud~*/ aren't
    ///    materialized for the process until NSFileCoordinator declares
    ///    a read intent — without coordination GRDB's raw POSIX open()
    ///    can fail on the first schema read even when the bytes are on
    ///    disk.
    ///
    /// The fix is a URI open: `file:<path>?mode=ro&immutable=1` tells
    /// SQLite (a) the file is read-only, and (b) immutable — skip ALL
    /// journal/WAL management entirely, treat the file as a frozen
    /// blob. SQLite then never tries to create or touch -wal/-shm.
    /// URI handling requires sqlite3_open_v2 with SQLITE_OPEN_URI,
    /// which GRDB enables by default — the `file:` prefix is enough.
    ///
    /// The coordinator wrap stays for case (2). It's a no-op for paths
    /// outside iCloud (the test bundle's tmp copy, future App Store
    /// sandboxed bundle paths) but is necessary for the Mac iCloud
    /// case in production.
    private static func openDatabase(
        at sqliteURL: URL,
        configuration: Configuration
    ) throws -> DatabaseQueue {
        // Percent-encode the path so spaces and other URL-unsafe
        // characters survive the URI parse. The path-encoded form is
        // what sqlite3_open_v2 expects after the `file:` scheme.
        let encoded = sqliteURL.path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? sqliteURL.path
        let uri = "file:\(encoded)?mode=ro&immutable=1"

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var openedQueue: DatabaseQueue?
        var openError: Error?

        coordinator.coordinate(
            readingItemAt: sqliteURL,
            options: [.resolvesSymbolicLink],
            error: &coordinationError
        ) { _ in
            // Use the URI (constructed from the original sqliteURL.path),
            // not coordinatedURL.path — SQLite needs the URI form, and
            // the coordinator's coordinatedURL is the same file the
            // original URL points at (the coordinate call only ensures
            // availability, doesn't relocate).
            do {
                openedQueue = try DatabaseQueue(
                    path: uri,
                    configuration: configuration
                )
            } catch {
                openError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let openError {
            throw openError
        }
        guard let openedQueue else {
            throw ArchiveReaderError.openFailed(
                "NSFileCoordinator returned without an opened DatabaseQueue"
            )
        }
        return openedQueue
    }

    func chats() async throws -> [Chat] {
        try await dbQueue.read { db in
            // Pulls the literal last message per chat (by timestamp) into
            // the same row, so the chat-list view doesn't have to fan out
            // a query per row. The window function runs once over messages,
            // partitioned by chat_guid — SQLite 3.25+, which is iOS 13+.
            let rows = try Row.fetchAll(db, sql: """
                WITH last_per_chat AS (
                    SELECT chat_guid, text, is_from_me, has_attachments,
                           ROW_NUMBER() OVER (
                             PARTITION BY chat_guid ORDER BY timestamp DESC
                           ) AS rn
                    FROM messages
                )
                SELECT c.chat_guid, c.display_name, c.chat_identifier, c.service_name,
                       c.is_group, c.participants_json, c.first_message_at, c.last_message_at,
                       c.message_count,
                       lpc.text AS last_text,
                       lpc.is_from_me AS last_from_me,
                       lpc.has_attachments AS last_has_attachments
                FROM chats c
                LEFT JOIN last_per_chat lpc
                       ON lpc.chat_guid = c.chat_guid AND lpc.rn = 1
                ORDER BY c.last_message_at DESC NULLS LAST
                """)
            return rows.map(Self.chatFromRow)
        }
    }

    /// Load up to `limit` messages anchored at the most recent. `before`
    /// pages backward — pass the oldest currently-loaded message's
    /// timestamp to get the next window of older messages.
    ///
    /// Query selects `ORDER BY timestamp DESC LIMIT ?` to take the most
    /// recent rows; the result is then reversed in Swift so callers
    /// receive messages in chronological order (oldest first) for
    /// display in a top-down thread. Without the DESC + reverse, the
    /// first call would return the oldest 200 messages in the chat —
    /// not what anyone wants when they open a conversation.
    func messages(in chatGuid: String, limit: Int = 200, before: Date? = nil) async throws -> [Message] {
        try await dbQueue.read { db in
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
            sql += " ORDER BY timestamp DESC"
            if limit > 0 {
                sql += " LIMIT ?"
                args.append(limit)
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(Self.messageFromRow).reversed()
        }
    }

    /// Load up to `limit` messages from the start of `year` forward, in
    /// chronological order. Drives the year-picker "jump to year" flow
    /// in `ThreadView`.
    func messages(in chatGuid: String, fromYear year: Int, limit: Int = 200) async throws -> [Message] {
        let yearStart = Calendar.current.date(from: DateComponents(year: year)) ?? Date()
        let yearStartUnix = Int64(yearStart.timeIntervalSince1970)
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT message_guid, chat_guid, sender_handle, sender_name,
                       timestamp, text, is_from_me, reply_to_guid,
                       reactions_json, has_attachments, date_edited, date_retracted
                FROM messages
                WHERE chat_guid = ? AND timestamp >= ?
                ORDER BY timestamp ASC
                LIMIT ?
                """, arguments: [chatGuid, yearStartUnix, limit])
            return rows.map(Self.messageFromRow)
        }
    }

    /// Calendar years that span this chat's message range, newest year
    /// first. Powers the year-picker menu.
    ///
    /// Implementation note: the previous version ran
    /// `SELECT DISTINCT strftime('%Y', timestamp)` over every message in
    /// the chat — strftime per row + DISTINCT + ORDER BY, on chats with
    /// 100k+ messages, took long enough to delay `tarReader` init in
    /// ThreadView's loadInitial(), which in turn left every attachment
    /// stuck in `.loading` until the year query came back. Now we ask
    /// for MIN and MAX timestamps in a single aggregate (sub-millisecond
    /// with an index) and expand the year range in Swift.
    ///
    /// Trade-off: gives a contiguous range, so a chat with messages in
    /// 2018 and 2024 but a gap in 2020 will list 2020 even though there
    /// are no messages in it. The year-picker query for 2020 will
    /// simply return the next available year's messages, so the UX is
    /// still correct.
    func years(in chatGuid: String) async throws -> [Int] {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(timestamp) AS lo, MAX(timestamp) AS hi
                FROM messages
                WHERE chat_guid = ?
                """, arguments: [chatGuid])
            guard let row,
                  let lo = row["lo"] as? Int64,
                  let hi = row["hi"] as? Int64 else {
                return []
            }
            let cal = Calendar.current
            let loYear = cal.component(.year, from: Date(timeIntervalSince1970: Double(lo)))
            let hiYear = cal.component(.year, from: Date(timeIntervalSince1970: Double(hi)))
            return Array((loYear...hiYear).reversed())
        }
    }

    func attachments(for messageGuid: String) async throws -> [Attachment] {
        try await dbQueue.read { db in
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
        return try await dbQueue.read { db in
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
            messageCount: Int(row["message_count"] as? Int64 ?? 0),
            lastPreviewText: row["last_text"],
            lastPreviewFromMe: (row["last_from_me"] as? Int64 ?? 0) != 0,
            lastPreviewHasAttachments: (row["last_has_attachments"] as? Int64 ?? 0) != 0
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
