import SwiftUI

struct ThreadView: View {
    let chat: Chat
    let reader: ArchiveReader

    @State private var messages: [Message] = []
    @State private var isLoading = true
    @State private var hasMore = false
    @State private var loadError: String?
    @State private var attachmentCache = AttachmentCache()
    @State private var tarReader: TarReader?
    @State private var loadTask: Task<Void, Never>?

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
            if isLoading {
                ProgressView()
            } else if let err = loadError, messages.isEmpty {
                ContentUnavailableView(
                    "Couldn't load messages",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            }
        }
        .onDisappear { loadTask?.cancel() }
    }

    private func loadInitial() async {
        isLoading = true
        loadError = nil
        do {
            try Task.checkCancellation()
            let loaded = try await reader.messages(in: chat.chatGuid, limit: 200)
            try Task.checkCancellation()
            messages = loaded
            hasMore = loaded.count == 200
            // attachments.tar may not yet be downloaded; non-fatal.
            do {
                tarReader = try TarReader(bundleURL: reader.bundleURL)
            } catch {
                tarReader = nil
                // Don't surface — attachments are non-essential for thread browsing.
            }
        } catch is CancellationError {
            // User backed out mid-load; nothing to show.
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let oldest = messages.first else { return }
        do {
            let earlier = try await reader.messages(in: chat.chatGuid, limit: 200, before: oldest.timestamp)
            messages = earlier + messages
            hasMore = earlier.count == 200
        } catch is CancellationError {
            // ignore
        } catch {
            loadError = error.localizedDescription
        }
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
