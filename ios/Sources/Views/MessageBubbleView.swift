import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    let showSender: Bool
    let reader: ArchiveReader
    let cache: AttachmentCache
    let tarReader: TarReader?

    @State private var showTimestamp = false
    @State private var attachments: [Attachment] = []

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            if showSender && !message.isFromMe {
                Text(message.displaySender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            HStack {
                if message.isFromMe { Spacer(minLength: 60) }

                VStack(alignment: .leading, spacing: 4) {
                    bubbleContent
                    if !message.reactions.isEmpty {
                        ReactionsView(reactions: message.reactions)
                    }
                }
                .background(bubbleColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !message.isFromMe { Spacer(minLength: 60) }
            }

            if showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { showTimestamp.toggle() }
        }
        .task(id: message.messageGuid) {
            if message.hasAttachments {
                attachments = (try? await reader.attachments(for: message.messageGuid)) ?? []
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isRetracted {
            Text("Message unsent")
                .italic()
                .foregroundStyle(message.isFromMe ? .white.opacity(0.8) : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let text = message.text, !text.isEmpty {
                    Text(text)
                        .foregroundStyle(message.isFromMe ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                }
                if message.isEdited {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(message.isFromMe ? .white.opacity(0.7) : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
                if !attachments.isEmpty {
                    AttachmentGridView(
                        attachments: attachments,
                        cache: cache,
                        tarReader: tarReader
                    )
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var bubbleColor: Color {
        message.isFromMe ? .blue : Color.platformSecondaryBackground
    }

    private var accessibilityText: String {
        let sender = message.isFromMe ? "Me" : message.displaySender
        let body = message.text ?? (message.hasAttachments ? "Attachment" : "")
        return "\(sender): \(body)"
    }
}
