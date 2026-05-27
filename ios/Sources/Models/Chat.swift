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

    var title: String {
        displayName
            ?? (participants.isEmpty ? chatIdentifier : participants.joined(separator: ", "))
            ?? chatGuid
    }
}
