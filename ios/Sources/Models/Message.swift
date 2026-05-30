import Foundation

struct Message: Identifiable, Hashable, Sendable {
    let messageGuid: String
    let chatGuid: String
    let senderHandle: String?
    let senderName: String?
    let timestamp: Date
    let text: String?
    let isFromMe: Bool
    let replyToGuid: String?
    let reactions: [Reaction]
    let hasAttachments: Bool
    let dateEdited: Date?
    let dateRetracted: Date?

    var id: String { messageGuid }

    var isRetracted: Bool { dateRetracted != nil }
    var isEdited: Bool { dateEdited != nil }

    var displaySender: String {
        senderName ?? senderHandle ?? "Unknown"
    }
}

struct Reaction: Hashable, Sendable, Codable {
    let from: String
    let type: String
    let timestamp: Date?

    var emoji: String {
        switch type {
        case "love":      return "❤️"
        case "like":      return "👍"
        case "dislike":   return "👎"
        case "laugh":     return "😂"
        case "emphasize": return "‼️"
        case "question":  return "❓"
        default:          return "•"
        }
    }

    enum CodingKeys: String, CodingKey {
        case from, type, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        type = try c.decode(String.self, forKey: .type)
        // The Mac archiver writes timestamp as a Unix-epoch number, but
        // earlier sketches considered ISO strings. Accept either, so
        // reactions survive a format drift instead of silently dropping
        // every message's reactions (H-8 from review).
        //
        // Use `decode` (not `decodeIfPresent`) with `try?` so the result
        // is a clean `T?` rather than Swift's Optional-flattening of
        // `T??`, which would make the `if let` bind a non-optional T.
        if let tsDouble = try? c.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: tsDouble)
        } else if let tsString = try? c.decode(String.self, forKey: .timestamp) {
            timestamp = ISO8601DateFormatter().date(from: tsString)
        } else {
            timestamp = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(timestamp?.timeIntervalSince1970, forKey: .timestamp)
    }

    init(from: String, type: String, timestamp: Date?) {
        self.from = from
        self.type = type
        self.timestamp = timestamp
    }
}
