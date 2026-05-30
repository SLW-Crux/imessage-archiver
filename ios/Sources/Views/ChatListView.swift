import SwiftUI

struct ChatListView: View {
    let reader: ArchiveReader
    @State private var chats: [Chat] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError: String?

    /// Driving selection state for macOS NavigationSplitView. Unused on iOS,
    /// where row taps push via NavigationLink(value:).
    @State private var selection: SidebarDestination?

    /// Sidebar destinations are typed so the same NavigationLink(value:)
    /// works on both platforms and the macOS detail pane can switch over a
    /// single optional.
    enum SidebarDestination: Hashable {
        case chat(Chat)
        case searchAll
    }

    private var filtered: [Chat] {
        guard !searchText.isEmpty else { return chats }
        let q = searchText.lowercased()
        return chats.filter {
            $0.title.lowercased().contains(q) ||
            ($0.chatIdentifier ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            detail
        }
        // .sidebar placement puts the search field in the sidebar header
        // (where Mail.app puts it), not the toolbar. This is the only
        // search affordance — the previous toolbar magnifying-glass was
        // the source of the dual-search redundancy AND the window-edge
        // clipping flagged in the design review.
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Conversations")
        .task { await loadChats() }
        #else
        NavigationStack {
            sidebar
                .navigationDestination(for: SidebarDestination.self) { dest in
                    switch dest {
                    case .chat(let chat):
                        ThreadView(chat: chat, reader: reader)
                    case .searchAll:
                        SearchView(reader: reader)
                    }
                }
        }
        .searchable(text: $searchText, prompt: "Search Conversations")
        .task { await loadChats() }
        #endif
    }

    @ViewBuilder
    private var sidebar: some View {
        Group {
            if isLoading {
                ProgressView("Loading conversations…")
            } else if let err = loadError {
                ContentUnavailableView(
                    "Couldn’t Load Archive",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else if filtered.isEmpty {
                emptyState
            } else {
                chatList
            }
        }
        .navigationTitle("Archive")
        .toolbar {
            ToolbarItem(placement: .platformTrailing) {
                NavigationLink {
                    ArchiveInfoView(manifest: reader.manifest)
                } label: {
                    Image(systemName: "info.circle")
                        .accessibilityLabel("Archive info")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView(
                "No Conversations",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Your archive contains no conversations.")
            )
        } else {
            // System-standard "No Results for "…"" copy, free.
            ContentUnavailableView.search(text: searchText)
        }
    }

    @ViewBuilder
    private var chatList: some View {
        #if os(macOS)
        // List(selection:) binding drives the detail pane via NavigationLink(value:).
        List(selection: $selection) {
            Section {
                NavigationLink(value: SidebarDestination.searchAll) {
                    Label("Search All Messages", systemImage: "magnifyingglass")
                }
            }
            Section("Conversations") {
                ForEach(filtered) { chat in
                    NavigationLink(value: SidebarDestination.chat(chat)) {
                        ChatRowView(chat: chat)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        #else
        // On iOS, omit the selection: binding — non-nil selection adds
        // edit-mode circles we don't want.
        List {
            Section {
                NavigationLink(value: SidebarDestination.searchAll) {
                    Label("Search All Messages", systemImage: "magnifyingglass")
                }
            }
            Section("Conversations") {
                ForEach(filtered) { chat in
                    NavigationLink(value: SidebarDestination.chat(chat)) {
                        ChatRowView(chat: chat)
                    }
                }
            }
        }
        .listStyle(.plain)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .chat(let chat):
            ThreadView(chat: chat, reader: reader)
        case .searchAll:
            SearchView(reader: reader)
        case nil:
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Select a conversation from the sidebar to view its messages.")
            )
        }
    }
    #endif

    private func loadChats() async {
        isLoading = true
        do {
            chats = try await reader.chats()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
