import SwiftUI

struct ThreadView: View {
    let chat: Chat
    let reader: ArchiveReader

    @State private var messages: [Message] = []
    @State private var isLoading = true
    @State private var hasMore = false
    @State private var attachmentCache = AttachmentCache()
    @State private var tarReader: TarReader?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if hasMore {
                        Button("Load earlier messages") {
                            Task { await loadMore() }
                        }
                        .font(.footnote)
                        .padding(.vertical, 8)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, message in
                        let prev = idx > 0 ? messages[idx - 1] : nil
                        VStack(spacing: 0) {
                            if shouldShowDateSeparator(message: message, previous: prev) {
                                DateSeparatorView(date: message.timestamp)
                            }
                            MessageBubbleView(
                                message: message,
                                showSender: chat.isGroup && message.senderHandle != prev?.senderHandle,
                                reader: reader,
                                cache: attachmentCache,
                                tarReader: tarReader
                            )
                            .id(message.messageGuid)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .task {
                await loadInitial()
                if let last = messages.last {
                    proxy.scrollTo(last.messageGuid, anchor: .bottom)
                }
            }
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView() }
        }
    }

    private func loadInitial() async {
        isLoading = true
        do {
            let loaded = try await reader.messages(in: chat.chatGuid, limit: 200)
            messages = loaded
            hasMore = loaded.count == 200
            tarReader = try? TarReader(bundleURL: reader.bundleURL)
        } catch { }
        isLoading = false
    }

    private func loadMore() async {
        guard let oldest = messages.first else { return }
        do {
            let earlier = try await reader.messages(in: chat.chatGuid, limit: 200, before: oldest.timestamp)
            messages = earlier + messages
            hasMore = earlier.count == 200
        } catch { }
    }

    private func shouldShowDateSeparator(message: Message, previous: Message?) -> Bool {
        guard let prev = previous else { return true }
        return !Calendar.current.isDate(message.timestamp, inSameDayAs: prev.timestamp)
    }
}

struct DateSeparatorView: View {
    let date: Date

    var body: some View {
        Text(date, style: .date)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}
