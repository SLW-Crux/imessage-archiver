import SwiftUI

struct ChatRowView: View {
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chat.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let date = chat.lastMessageAt {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(chat.messageCount) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if chat.isGroup {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chat.title), \(chat.messageCount) messages")
    }
}
