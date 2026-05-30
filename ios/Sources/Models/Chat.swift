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
}

private extension String {
    /// `nil` if the string is empty or whitespace-only, otherwise self.
    /// Lets the fallback chain skip empty `displayName` / `chatIdentifier`
    /// columns rather than treating them as a valid title.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
