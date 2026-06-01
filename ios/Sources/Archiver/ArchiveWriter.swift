#if os(macOS)
import Foundation
import GRDB

/// Builds or incrementally updates an `.imarchive` bundle.
///
/// Non-destructive guarantees enforced here (mirror the Python port's
/// load-bearing invariants):
///
/// - All SQL writes use `INSERT OR IGNORE` keyed on Apple GUIDs.
/// - `archive.sqlite` is written atomically (`.tmp` → rename) on first
///   build so a SIGKILL mid-write doesn't leave a corrupt bundle.
/// - `attachments.tar` is append-only.
/// - `manifest.json` is written atomically (`.tmp` → rename) on every
///   run.
///
/// `@unchecked Sendable` because the class is single-owner per run
/// (CreateArchiveCoordinator's Task), the only state captured into
/// @Sendable closures (archiverVersion lookup) is immutable, and
/// GRDB's DatabaseQueue is itself Sendable.
///
/// Port of `src/imessage_archiver/core/archive.py`.
final class ArchiveWriter: @unchecked Sendable {

    /// Frozen-contract schema version. Both Mac archiver and iOS reader
    /// refuse to open bundles whose schema version exceeds the value
    /// they were compiled with. Bump only when adding additive
    /// migrations. Matches Python's `SCHEMA_VERSION`.
    static let schemaVersion: Int = 1
    static let maxSupportedSchemaVersion: Int = 1

    /// Schema DDL — identical to the Python original's `_DDL` string.
    static let ddl: String = """
    CREATE TABLE IF NOT EXISTS chats (
      chat_guid           TEXT PRIMARY KEY,
      display_name        TEXT,
      chat_identifier     TEXT,
      service_name        TEXT,
      is_group            INTEGER,
      participants_json   TEXT,
      first_message_at    INTEGER,
      last_message_at     INTEGER,
      message_count       INTEGER
    );

    CREATE TABLE IF NOT EXISTS messages (
      message_guid            TEXT PRIMARY KEY,
      chat_guid               TEXT NOT NULL REFERENCES chats(chat_guid),
      sender_handle           TEXT,
      sender_name             TEXT,
      timestamp               INTEGER NOT NULL,
      text                    TEXT,
      is_from_me              INTEGER NOT NULL,
      service                 TEXT,
      reply_to_guid           TEXT,
      associated_message_guid TEXT,
      associated_message_type INTEGER,
      reactions_json          TEXT,
      has_attachments         INTEGER NOT NULL,
      date_edited             INTEGER,
      date_retracted          INTEGER
    );

    CREATE TABLE IF NOT EXISTS attachments (
      attachment_guid  TEXT PRIMARY KEY,
      message_guid     TEXT NOT NULL REFERENCES messages(message_guid),
      filename         TEXT,
      mime_type        TEXT,
      uti              TEXT,
      size             INTEGER,
      sha256           TEXT,
      tar_offset       INTEGER,
      tar_length       INTEGER,
      state            TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS archive_runs (
      run_id                   TEXT PRIMARY KEY,
      started_at               INTEGER NOT NULL,
      completed_at             INTEGER,
      source_db_sha256         TEXT,
      source_db_path           TEXT,
      message_count            INTEGER,
      attachment_count         INTEGER,
      missing_attachment_count INTEGER,
      archiver_version         TEXT
    );

    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    INTEGER PRIMARY KEY,
      applied_at INTEGER NOT NULL
    );

    -- Standalone FTS5 (content=''), NOT external-content tied to
    -- the messages table. We insert message_guid + text + sender_name
    -- directly; we never link the FTS rowid back to messages.rowid.
    -- Declaring content='messages' previously was a lie that would
    -- corrupt the search index if anyone ran the standard FTS5
    -- 'rebuild' incantation (review finding MH4). Standalone matches
    -- the actual write pattern; search behaviour is identical.
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      message_guid UNINDEXED,
      text,
      sender_name,
      content=''
    );

    CREATE INDEX IF NOT EXISTS idx_messages_chat       ON messages(chat_guid, timestamp);
    CREATE INDEX IF NOT EXISTS idx_messages_timestamp  ON messages(timestamp);
    CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_guid);
    """

    struct RunStats: Sendable {
        var messagesSeen: Int = 0
        var messagesWritten: Int = 0
        var attachmentsSeen: Int = 0
        var attachmentsWritten: Int = 0
        var attachmentsMissing: Int = 0
    }

    enum Error: Swift.Error, LocalizedError {
        case schemaTooNew(found: Int, supported: Int)
        case bundleSetupFailed(URL)
        case sqliteOpenFailed(underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .schemaTooNew(let found, let supported):
                return "Bundle schema version \(found) is newer than this archiver supports (\(supported))."
            case .bundleSetupFailed(let url):
                return "Could not create archive bundle at \(url.path)."
            case .sqliteOpenFailed(let underlying):
                return "Couldn't open archive.sqlite: \(underlying.localizedDescription)"
            }
        }
    }

    typealias ProgressCallback = @Sendable (SourceDBReader.ChatRow, RunStats) -> Void

    private let bundleURL: URL
    private let sqliteURL: URL
    private let tarURL: URL
    private let manifestURL: URL
    private var dbQueue: DatabaseQueue?
    private let resolver: ContactsResolver

    init(
        bundleURL: URL,
        contactsResolver: ContactsResolver = .shared
    ) {
        self.bundleURL = bundleURL
        self.sqliteURL = bundleURL.appendingPathComponent("archive.sqlite")
        self.tarURL = bundleURL.appendingPathComponent("attachments.tar")
        self.manifestURL = bundleURL.appendingPathComponent("manifest.json")
        self.resolver = contactsResolver
    }

    // MARK: - Public entry point

    /// Archive every chat/message/attachment from `reader` into the
    /// bundle. Returns final statistics.
    @discardableResult
    func run(
        reader: SourceDBReader,
        sourceSHA256: String = "",
        sourceDBPath: String = "",
        progress: ProgressCallback? = nil
    ) async throws -> RunStats {
        let runID = UUID().uuidString
        let startedAt = Int64(Date().timeIntervalSince1970)

        try ensureBundleDirectory()
        try openOrCreateDB()
        guard let dbQueue else {
            throw Error.bundleSetupFailed(bundleURL)
        }

        let runRowID = try await startRun(
            runID: runID,
            startedAt: startedAt,
            sourceSHA: sourceSHA256,
            sourceDBPath: sourceDBPath,
            dbQueue: dbQueue
        )

        var stats = RunStats()
        let chats = try reader.chats()

        let tar = try TarWriter(url: tarURL)
        defer { try? tar.close() }

        for chat in chats {
            // Per-chat try/catch so a single broken row (typically a
            // chat.db column-type variance across macOS versions —
            // see review finding MH8) doesn't abort the whole archive.
            // Skip and continue; the run completes with the rest.
            do {
                try await insertChat(chat, dbQueue: dbQueue)

                let messages = try reader.messages(in: chat.chatGuid)
                for var msg in messages {
                    // Sender resolution via Contacts if we have it; falls
                    // through to the raw handle if not.
                    if !msg.isFromMe, let handle = msg.senderHandle {
                        let resolved = await resolver.resolve(handle)
                        if resolved != handle {
                            msg = msg.withSenderName(resolved)
                        }
                    }
                    let inserted = try await insertMessage(msg, dbQueue: dbQueue)
                    if inserted { stats.messagesWritten += 1 }
                    stats.messagesSeen += 1

                    let atts = try reader.attachments(for: msg.messageGuid)
                    for att in atts {
                        let result = try insertAttachment(att, tar: tar, dbQueue: dbQueue)
                        stats.attachmentsSeen += 1
                        if result.written { stats.attachmentsWritten += 1 }
                        if result.state == .missing { stats.attachmentsMissing += 1 }
                    }
                }
            } catch {
                // Skip this chat and continue. A half-archived bundle
                // is more useful than no archive at all when one chat
                // has a row that GRDB can't decode.
            }
            progress?(chat, stats)
        }

        try await rebuildReactions(dbQueue: dbQueue)
        try await finishRun(runRowID: runRowID, stats: stats, dbQueue: dbQueue)
        try writeManifest(sourceSHA: sourceSHA256)
        return stats
    }

    func close() throws {
        dbQueue = nil  // GRDB releases on deinit
    }

    // MARK: - Setup

    private func ensureBundleDirectory() throws {
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
    }

    private func openOrCreateDB() throws {
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: sqliteURL.path)

        do {
            if isNew {
                // Build the new DB in a .tmp file using DELETE journal
                // mode — no -wal/-shm siblings to orphan when we rename
                // the main file. Only enable WAL after the rename, on
                // the canonical path (review finding MC1).
                let target = sqliteURL.appendingPathExtension("tmp")
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }

                // Local scope so the build queue is fully closed (GRDB
                // releases on deinit) before we rename.
                do {
                    let buildQueue = try DatabaseQueue(path: target.path)
                    try buildQueue.write { db in
                        try db.execute(sql: "PRAGMA journal_mode=DELETE")
                        try db.execute(sql: "PRAGMA foreign_keys=ON")
                        try db.execute(sql: Self.ddl)
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO schema_migrations VALUES (?, ?)",
                            arguments: [Self.schemaVersion, Int(Date().timeIntervalSince1970)]
                        )
                    }
                }

                // Atomic rename — single file, no siblings to drag along.
                try fm.moveItem(at: target, to: sqliteURL)

                // Open the canonical path for the runtime workload and
                // switch to WAL there. The -wal/-shm siblings created
                // from here on share the same path stem as the main
                // file, so subsequent reopens/checkpoints align.
                let queue = try DatabaseQueue(path: sqliteURL.path)
                try queue.write { db in
                    try db.execute(sql: "PRAGMA journal_mode=WAL")
                    try db.execute(sql: "PRAGMA foreign_keys=ON")
                }
                self.dbQueue = queue
            } else {
                // Existing bundle — open in WAL mode, verify schema
                // version is one we understand.
                let queue = try DatabaseQueue(path: sqliteURL.path)
                try queue.write { db in
                    try db.execute(sql: "PRAGMA journal_mode=WAL")
                    try db.execute(sql: "PRAGMA foreign_keys=ON")
                }
                let existing = try queue.read { db -> Int in
                    try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations") ?? 0
                }
                if existing > Self.maxSupportedSchemaVersion {
                    throw Error.schemaTooNew(
                        found: existing,
                        supported: Self.maxSupportedSchemaVersion
                    )
                }
                self.dbQueue = queue
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.sqliteOpenFailed(underlying: error)
        }
    }

    // MARK: - Run lifecycle rows

    private func startRun(
        runID: String,
        startedAt: Int64,
        sourceSHA: String,
        sourceDBPath: String,
        dbQueue: DatabaseQueue
    ) async throws -> Int64 {
        // Read the version OUTSIDE the @Sendable closure so we don't
        // need to capture `self`. The closure is Sendable; ArchiveWriter
        // is @unchecked Sendable but referencing methods on it from the
        // closure still trips the compiler's `self` warning unless we
        // copy the value first.
        let version = archiverVersion()
        return try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO archive_runs(
                    run_id, started_at, source_db_sha256, source_db_path,
                    archiver_version
                ) VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    runID, startedAt, sourceSHA, sourceDBPath, version
                ])
            return db.lastInsertedRowID
        }
    }

    private func finishRun(
        runRowID: Int64,
        stats: RunStats,
        dbQueue: DatabaseQueue
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE archive_runs
                   SET completed_at=?, message_count=?,
                       attachment_count=?, missing_attachment_count=?
                 WHERE rowid=?
                """, arguments: [
                    Int64(Date().timeIntervalSince1970),
                    stats.messagesSeen,
                    stats.attachmentsSeen,
                    stats.attachmentsMissing,
                    runRowID
                ])
        }
    }

    // MARK: - Inserts

    private func insertChat(
        _ chat: SourceDBReader.ChatRow,
        dbQueue: DatabaseQueue
    ) async throws {
        let participantsJSON = (try? JSONSerialization.data(
            withJSONObject: chat.participants,
            options: []
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO chats(
                    chat_guid, display_name, chat_identifier, service_name, is_group,
                    participants_json, first_message_at, last_message_at, message_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    chat.chatGuid,
                    chat.displayName,
                    chat.chatIdentifier,
                    chat.serviceName,
                    chat.isGroup ? 1 : 0,
                    participantsJSON,
                    chat.firstMessageAt,
                    chat.lastMessageAt,
                    chat.messageCount
                ])
        }
    }

    private func insertMessage(
        _ msg: SourceDBReader.MessageRow,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO messages(
                    message_guid, chat_guid, sender_handle, sender_name, timestamp,
                    text, is_from_me, service, reply_to_guid, associated_message_guid,
                    associated_message_type, has_attachments, date_edited, date_retracted
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    msg.messageGuid,
                    msg.chatGuid,
                    msg.senderHandle,
                    msg.senderName,
                    msg.timestamp,
                    msg.text,
                    msg.isFromMe ? 1 : 0,
                    msg.service,
                    msg.replyToGuid,
                    msg.associatedMessageGuid,
                    msg.associatedMessageType,
                    msg.hasAttachments ? 1 : 0,
                    msg.dateEdited,
                    msg.dateRetracted
                ])
            let inserted = db.changesCount > 0
            if inserted, let text = msg.text, !text.isEmpty {
                try db.execute(
                    sql: "INSERT INTO messages_fts(message_guid, text, sender_name) VALUES (?, ?, ?)",
                    arguments: [msg.messageGuid, text, msg.senderName]
                )
            }
            return inserted
        }
    }

    private struct AttachmentInsertResult {
        let written: Bool
        let state: AttachmentState
    }

    private func insertAttachment(
        _ att: SourceDBReader.AttachmentRow,
        tar: TarWriter,
        dbQueue: DatabaseQueue
    ) throws -> AttachmentInsertResult {
        let state = AttachmentScanner.classify(att)

        var tarOffset: Int64? = nil
        var tarLength: Int64? = nil
        var sha: String? = nil

        if state == .localPresent, let url = att.resolvedURL {
            let alreadyArchived = try dbQueue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT tar_offset FROM attachments WHERE attachment_guid=?",
                    arguments: [att.attachmentGuid]
                ) != nil
            }
            if !alreadyArchived {
                let result = try tar.append(
                    attachmentGUID: att.attachmentGuid,
                    sourceURL: url,
                    filename: att.filename
                )
                tarOffset = result.offset
                tarLength = result.length
                sha = try AttachmentScanner.sha256(of: url)
            }
        }

        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO attachments(
                    attachment_guid, message_guid, filename, mime_type, uti,
                    size, sha256, tar_offset, tar_length, state
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    att.attachmentGuid,
                    att.messageGuid,
                    att.filename,
                    att.mimeType,
                    att.uti,
                    att.size,
                    sha,
                    tarOffset,
                    tarLength,
                    state.rawValue
                ])
            return AttachmentInsertResult(
                written: db.changesCount > 0,
                state: state
            )
        }
    }

    // MARK: - Reactions (tapback denormalisation)

    private func rebuildReactions(dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            let tapbacks = try Row.fetchAll(db, sql: """
                SELECT associated_message_guid, associated_message_type,
                       sender_name, sender_handle, timestamp
                  FROM messages
                 WHERE associated_message_type BETWEEN 2000 AND 3005
                 ORDER BY timestamp
                """)

            struct Reaction: Hashable {
                let from: String
                let type: String
                let timestamp: Int64
            }
            var reactionsByTarget: [String: [Reaction]] = [:]

            for row in tapbacks {
                guard let targetGUID: String = row["associated_message_guid"], !targetGUID.isEmpty else {
                    continue
                }
                let rawType: Int = row["associated_message_type"]
                guard TapbackTypes.isTapback(rawType) else { continue }

                let senderName: String? = row["sender_name"]
                let senderHandle: String? = row["sender_handle"]
                let ts: Int64 = row["timestamp"]
                let from = senderName ?? senderHandle ?? "Unknown"
                let base = TapbackTypes.baseType(rawType)
                let typeName = TapbackTypes.name(for: base) ?? "unknown"
                let isRemove = TapbackTypes.isRemove(rawType)

                var existing = reactionsByTarget[targetGUID] ?? []
                existing.removeAll { $0.from == from && $0.type == typeName }
                if !isRemove {
                    existing.append(Reaction(from: from, type: typeName, timestamp: ts))
                }
                reactionsByTarget[targetGUID] = existing
            }

            for (targetGUID, reactions) in reactionsByTarget {
                let json: String? = reactions.isEmpty ? nil : Self.reactionsJSON(reactions.map {
                    ["from": $0.from, "type": $0.type, "timestamp": $0.timestamp] as [String: Any]
                })
                try db.execute(
                    sql: "UPDATE messages SET reactions_json=? WHERE message_guid=?",
                    arguments: [json, targetGUID]
                )
            }
        }
    }

    private static func reactionsJSON(_ raw: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Manifest

    private func writeManifest(sourceSHA: String) throws {
        let fm = FileManager.default
        let now = ISO8601DateFormatter().string(from: Date())

        // Preserve `created_at` from any prior manifest (incremental runs).
        var createdAt = now
        if let existing = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
           let prior = json["created_at"] as? String {
            createdAt = prior
        }

        let tarSize: Int64 = (try? fm.attributesOfItem(atPath: tarURL.path)[.size] as? Int64) ?? 0

        let manifest: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "archiver_version": archiverVersion(),
            "created_at": createdAt,
            "last_updated_at": now,
            "source_db_sha256": sourceSHA,
            "source_macos_version": macOSVersionString(),
            "chat_count": (try? countRows("chats")) ?? 0,
            "message_count": (try? countRows("messages")) ?? 0,
            "attachment_count": (try? countRows("attachments")) ?? 0,
            "missing_attachment_count": (try? countMissing()) ?? 0,
            "archive_size_bytes": tarSize,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Atomic replace. The prior `removeItem(manifest)` + `moveItem(tmp
        // → manifest)` sequence had a crash window where the manifest
        // file was missing entirely (review finding MH3). `replaceItemAt`
        // is rename-backed and atomic on APFS — either the new manifest
        // is fully visible or the prior manifest stays in place.
        let tmp = manifestURL.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tmp.path) {
            try fm.removeItem(at: tmp)
        }
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: manifestURL.path) {
            _ = try fm.replaceItemAt(manifestURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: manifestURL)
        }
    }

    // MARK: - Counting helpers

    private func countRows(_ table: String) throws -> Int {
        guard let dbQueue else { return 0 }
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func countMissing() throws -> Int {
        guard let dbQueue else { return 0 }
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM attachments WHERE state='MISSING'"
            ) ?? 0
        }
    }

    private func archiverVersion() -> String {
        // Reads MARKETING_VERSION-equivalent from the bundle.
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Tapback range constants & helpers. Mirrors `db/schema.py`.
enum TapbackTypes {
    static let addMin = 2000
    static let addMax = 2005
    static let removeMin = 3000
    static let removeMax = 3005

    private static let nameByType: [Int: String] = [
        2000: "love",
        2001: "like",
        2002: "dislike",
        2003: "laugh",
        2004: "emphasize",
        2005: "question",
    ]

    static func isTapback(_ t: Int) -> Bool {
        (addMin...addMax).contains(t) || (removeMin...removeMax).contains(t)
    }

    static func isRemove(_ t: Int) -> Bool {
        (removeMin...removeMax).contains(t)
    }

    static func baseType(_ t: Int) -> Int {
        (removeMin...removeMax).contains(t) ? t - 1000 : t
    }

    static func name(for baseType: Int) -> String? {
        nameByType[baseType]
    }
}

// MARK: - Sender-name rewrite helper

extension SourceDBReader.MessageRow {
    /// Return a copy with `senderName` replaced. Used by ArchiveWriter
    /// when the ContactsResolver finds a display name for the raw
    /// handle.
    func withSenderName(_ newName: String) -> SourceDBReader.MessageRow {
        SourceDBReader.MessageRow(
            messageGuid: messageGuid,
            chatGuid: chatGuid,
            senderHandle: senderHandle,
            senderName: newName,
            timestamp: timestamp,
            text: text,
            isFromMe: isFromMe,
            service: service,
            replyToGuid: replyToGuid,
            associatedMessageGuid: associatedMessageGuid,
            associatedMessageType: associatedMessageType,
            hasAttachments: hasAttachments,
            dateEdited: dateEdited,
            dateRetracted: dateRetracted
        )
    }
}

#endif
