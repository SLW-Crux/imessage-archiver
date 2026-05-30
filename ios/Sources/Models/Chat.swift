import Foundation

struct Chat: Identifiable, Hashable, Sendable {
    let chatGuid: String
    let displayName: String?
    let chatIdentifier: String?
    let serviceName: String?
    let isGroup: Bool
    let participants: [String]
    let firstMessageAt: Date?
    let lastMessageAt: Date?
    let messageCount: Int

    /// Text of the most recent message in this chat (NULL when the last
    /// message is attachment-only).
    let lastPreviewText: String?
    /// Whether the most recent message was sent by the archive owner.
    let lastPreviewFromMe: Bool
    /// Whether the most recent message carries attachments. Used to pick
    /// the placeholder preview when there's no text.
    let lastPreviewHasAttachments: Bool

    var id: String { chatGuid }

    /// Title fallback chain. Each step skips empty strings (not just nil),
    /// because the source columns are routinely empty rather than NULL.
    /// `chatGuid` is the never-null terminus, so the row is never blank.
    var title: String {
        displayName?.nilIfBlank
            ?? participantsTitle
            ?? chatIdentifier?.nilIfBlank
            ?? chatGuid
    }

    private var participantsTitle: String? {
        let nonBlank = participants.compactMap { $0.nilIfBlank }
        guard !nonBlank.isEmpty else { return nil }
        return nonBlank.joined(separator: ", ")
    }

    /// 1–2 character monogram for the avatar. Group chats get the first
    /// letter of each of up to two participants; 1:1 chats get the first
    /// two letters of the title. Falls back to `#` for stubs.
    var initials: String {
        if isGroup {
            let parts = participants
                .compactMap { $0.nilIfBlank }
                .prefix(2)
                .compactMap { $0.first.map(String.init) }
            if !parts.isEmpty { return parts.joined().uppercased() }
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "#" }
        // Skip leading "+" (phone numbers) so a phone-number title doesn't
        // monogram to a meaningless "+1".
        let stripped = t.hasPrefix("+") ? String(t.dropFirst()) : t
        let letters = stripped.filter { $0.isLetter }
        if let first = letters.first {
            return String(first).uppercased()
        }
        // No letters — fall back to the first non-whitespace char.
        return String(stripped.first ?? "#").uppercased()
    }

    /// One-line preview rendered under the title in the chat list.
    /// Examples: "You: Sounds good 👍", "Photo", "Attachment".
    /// Empty string when there's no preview content at all.
    var lastPreview: String {
        let prefix = lastPreviewFromMe ? "You: " : ""
        if let text = lastPreviewText?.nilIfBlank {
            return prefix + text
        }
        if lastPreviewHasAttachments {
            return prefix + "Attachment"
        }
        return ""
    }
}

private extension String {
    /// `nil` if the string is empty or whitespace-only, otherwise self.
    /// Lets the fallback chain skip empty `displayName` / `chatIdentifier`
    /// columns rather than treating them as a valid title.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
