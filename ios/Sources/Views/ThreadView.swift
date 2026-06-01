import SwiftUI

struct ThreadView: View {
    let chat: Chat
    let reader: ArchiveReader

    @State private var messages: [Message] = []
    @State private var availableYears: [Int] = []
    @State private var isLoading = true
    @State private var hasMore = false
    @State private var loadError: String?
    @State private var attachmentCache = AttachmentCache()
    @State private var tarReader: TarReader?
    @State private var loadTask: Task<Void, Never>?
    @State private var yearsTask: Task<Void, Never>?
    /// Set by `loadFromYear` so the next layout pass scrolls to the
    /// first message of the chosen year. Cleared on completion so
    /// later loads (loadMore appending) don't disturb scroll position.
    @State private var scrollAnchorGuid: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Spacing is 0 here; each MessageBubbleView contributes its
                // own top padding (8pt at run start, 2pt within a run) so
                // same-sender consecutive bubbles cluster.
                LazyVStack(spacing: 0) {
                    if hasMore {
                        Button("Load earlier messages") {
                            Task { await loadMore() }
                        }
                        .font(.footnote)
                        .padding(.vertical, 8)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, message in
                        let prev = idx > 0 ? messages[idx - 1] : nil
                        let isFirstInRun = prev?.senderHandle != message.senderHandle
                            || prev?.isFromMe != message.isFromMe
                        VStack(spacing: 0) {
                            if shouldShowDateSeparator(message: message, previous: prev) {
                                DateSeparatorView(date: message.timestamp)
                            }
                            MessageBubbleView(
                                message: message,
                                showSender: chat.isGroup && !message.isFromMe && isFirstInRun,
                                isFirstInRun: isFirstInRun,
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
                scrollToLatest(proxy: proxy)
            }
            .onChange(of: scrollAnchorGuid) { _, anchor in
                guard let anchor else { return }
                // Brief delay so SwiftUI lays out the freshly-loaded messages
                // before we scroll into them; otherwise the proxy can't
                // resolve the id.
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(anchor, anchor: .top)
                    scrollAnchorGuid = nil
                }
            }
        }
        .navigationTitle(chat.title)
        .platformInlineTitle()
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
        .toolbar {
            ToolbarItem(placement: .platformTrailing) {
                yearPickerMenu
            }
        }
        .onDisappear {
            loadTask?.cancel()
            yearsTask?.cancel()
        }
    }

    @ViewBuilder
    private var yearPickerMenu: some View {
        if !availableYears.isEmpty {
            Menu {
                Button {
                    Task { await loadLatest() }
                } label: {
                    Label("Jump to Latest", systemImage: "arrow.down.to.line")
                }
                Divider()
                Section("Jump to Year") {
                    ForEach(availableYears, id: \.self) { year in
                        Button("\(year, format: .number.grouping(.never))") {
                            Task { await loadFromYear(year) }
                        }
                    }
                }
            } label: {
                Image(systemName: "calendar")
                    .accessibilityLabel("Jump to year")
            }
        }
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

            // Open the tar reader BEFORE the years query so attachment
            // thumbnails can start loading immediately. The previous
            // ordering let a slow years() block tarReader for seconds
            // on large chats, leaving every attachment stuck loading.
            do {
                tarReader = try TarReader(bundleURL: reader.bundleURL)
            } catch {
                tarReader = nil
            }

            // Year picker is a nice-to-have — load it in a detached
            // task so it never blocks the visible thread / attachments.
            // Store the handle so onDisappear can cancel it; otherwise
            // the years query keeps running after the view dismantles
            // and writes to a @State that no longer exists (review
            // finding IH7).
            let chatGuid = chat.chatGuid
            let reader = reader
            yearsTask = Task { @MainActor in
                let years = (try? await reader.years(in: chatGuid)) ?? []
                guard !Task.isCancelled else { return }
                availableYears = years
            }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadLatest() async {
        do {
            let loaded = try await reader.messages(in: chat.chatGuid, limit: 200)
            messages = loaded
            hasMore = loaded.count == 200
            // Latest jump = scroll to bottom, same as initial load.
            if let lastGuid = messages.last?.messageGuid {
                scrollAnchorGuid = lastGuid
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadFromYear(_ year: Int) async {
        do {
            let loaded = try await reader.messages(in: chat.chatGuid, fromYear: year, limit: 200)
            guard !loaded.isEmpty else { return }
            messages = loaded
            // After year jump, there's almost always older content. Allow
            // the user to page backward via the "Load earlier" button.
            hasMore = true
            scrollAnchorGuid = loaded.first?.messageGuid
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let oldest = messages.first else { return }
        do {
            let earlier = try await reader.messages(in: chat.chatGuid, limit: 200, before: oldest.timestamp)
            messages = earlier + messages
            hasMore = earlier.count == 200
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        if let last = messages.last {
            proxy.scrollTo(last.messageGuid, anchor: .bottom)
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
