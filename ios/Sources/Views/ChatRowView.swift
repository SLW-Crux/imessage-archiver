import SwiftUI

struct ChatRowView: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: Spacing.rowSpacing) {
            Monogram(seed: chat.chatGuid, label: chat.initials)
                .frame(width: Spacing.avatarSize, height: Spacing.avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chat.title).chatTitleStyle()
                    Spacer(minLength: 8)
                    if let date = chat.lastMessageAt {
                        // layoutPriority lets the timestamp keep its width
                        // when the title is long enough to demand truncation.
                        Text(date, format: .smartArchive)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                if !chat.lastPreview.isEmpty {
                    Text(chat.lastPreview).chatPreviewStyle()
                } else if chat.isGroup {
                    // Empty preview on a group chat — surface participant
                    // count rather than a totally blank row.
                    Text("\(chat.participants.count) participants")
                        .chatPreviewStyle()
                }
            }
            // Claim the full remaining row width so the inner HStack's
            // Spacer actually has room to expand. Without this the VStack
            // hugged its content, leaving the timestamp pinned right
            // beside the title with empty trailing whitespace instead of
            // at the row's trailing edge like Mail.app.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(minHeight: Spacing.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts: [String] = [chat.title]
        if !chat.lastPreview.isEmpty {
            parts.append(chat.lastPreview)
        }
        if let date = chat.lastMessageAt {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: ", ")
    }
}
