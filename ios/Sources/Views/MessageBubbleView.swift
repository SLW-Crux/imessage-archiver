import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MessageBubbleView: View {
    let message: Message
    /// Show the sender's name above the bubble — group chats, received
    /// messages, first message of a same-sender run only.
    let showSender: Bool
    /// First message of a same-sender run. Drives the top padding so
    /// consecutive same-sender bubbles cluster (2pt) while sender changes
    /// get a breathing gap (8pt). The run grouping is what conveys
    /// authorship without drawing a custom tail shape.
    let isFirstInRun: Bool
    let reader: ArchiveReader
    let cache: AttachmentCache
    let tarReader: TarReader?

    @State private var showTimestamp = false
    @State private var attachments: [Attachment] = []

    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
            if showSender {
                Text(message.displaySender)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.bubblePaddingHorizontal)
            }

            // Attachments + bubble + reactions stack as siblings inside one
            // hugging column so each piece can size itself. Spacers cap the
            // column width to roughly (container − bubbleMaxWidthInset).
            HStack(spacing: 0) {
                if message.isFromMe {
                    Spacer(minLength: Spacing.bubbleMaxWidthInset)
                }

                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                    // Attachments render OUTSIDE the bubble background — a
                    // bubble behind a photo is a third-party tell. Bubble
                    // colour applies only to the text view below.
                    if !attachments.isEmpty {
                        AttachmentGridView(
                            attachments: attachments,
                            cache: cache,
                            tarReader: tarReader
                        )
                    }

                    textBubble

                    if !message.reactions.isEmpty {
                        ReactionsView(reactions: message.reactions)
                    }
                }

                if !message.isFromMe {
                    Spacer(minLength: Spacing.bubbleMaxWidthInset)
                }
            }

            if showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
        }
        .padding(.top, isFirstInRun ? Spacing.bubbleGroupSpacing : Spacing.bubbleRunSpacing)
        .padding(.bottom, 0)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { showTimestamp.toggle() }
        }
        .task(id: message.messageGuid) {
            if message.hasAttachments {
                attachments = (try? await reader.attachments(for: message.messageGuid)) ?? []
            }
        }
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The text bubble, sized to its content. Emits nothing for a
    /// photo-only message — the @ViewBuilder closure produces an empty
    /// view when no branch matches, so an attachment-only message
    /// doesn't get a stray empty bubble.
    @ViewBuilder
    private var textBubble: some View {
        if message.isRetracted {
            Text("Message unsent")
                .italic()
                .foregroundStyle(message.isFromMe ? .white.opacity(0.8) : .secondary)
                .padding(.horizontal, Spacing.bubblePaddingHorizontal)
                .padding(.vertical, Spacing.bubblePaddingVertical)
                .background(bubbleBackground, in: RoundedRectangle.bubble)
                .tint(message.isFromMe ? .white : .accentColor)
        } else if let text = message.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .textSelection(.enabled)
                if message.isEdited {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(message.isFromMe ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, Spacing.bubblePaddingHorizontal)
            .padding(.vertical, Spacing.bubblePaddingVertical)
            .background(bubbleBackground, in: RoundedRectangle.bubble)
            // .tint propagates to any auto-detected link styling inside Text,
            // so a URL inside a sent (accent-coloured) bubble doesn't render
            // as accent-on-accent and disappear.
            .tint(message.isFromMe ? .white : .accentColor)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let text = message.text, !text.isEmpty {
            Button {
                copyToPasteboard(text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            // ShareLink bridges to NSSharingServicePicker on macOS and
            // UIActivityViewController on iOS automatically — one API,
            // platform-appropriate UI both places.
            ShareLink(item: text) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private var bubbleBackground: Color {
        message.isFromMe ? .bubbleSent : .bubbleReceived
    }

    private var accessibilityText: String {
        let sender = message.isFromMe ? "Me" : message.displaySender
        let body = message.text ?? (message.hasAttachments ? "Attachment" : "")
        return "\(sender): \(body)"
    }
}
