import SwiftUI

struct ChatListView: View {
    let reader: ArchiveReader
    @State private var chats: [Chat] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadError: String?

    private var filtered: [Chat] {
        guard !searchText.isEmpty else { return chats }
        let q = searchText.lowercased()
        return chats.filter {
            $0.title.lowercased().contains(q) ||
            ($0.chatIdentifier ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading conversations…")
                } else if let err = loadError {
                    Text("Error: \(err)")
                        .foregroundStyle(.red)
                        .padding()
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Conversations" : "No Results",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(searchText.isEmpty
                            ? "Your archive contains no conversations."
                            : "No conversations match \"\(searchText)\".")
                    )
                } else {
                    List(filtered) { chat in
                        NavigationLink(value: chat) {
                            ChatRowView(chat: chat)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Archive")
            .searchable(text: $searchText, prompt: "Search conversations")
            .navigationDestination(for: Chat.self) { chat in
                ThreadView(chat: chat, reader: reader)
            }
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    NavigationLink {
                        SearchView(reader: reader)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .accessibilityLabel("Search all messages")
                    }
                }
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
        .task { await loadChats() }
    }

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
