import SwiftUI

struct SearchView: View {
    let reader: ArchiveReader
    @State private var query = ""
    @State private var results: [Message] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List(results) { message in
                NavigationLink(value: message) {
                    SearchResultRow(message: message)
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search Messages",
                        systemImage: "magnifyingglass",
                        description: Text("Search across all conversations in your archive."))
                } else if results.isEmpty && !isSearching {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search messages")
            .onChange(of: query) { _, newValue in
                Task { await search(newValue) }
            }
        }
    }

    private func search(_ q: String) async {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        isSearching = true
        results = (try? await reader.search(query: q)) ?? []
        isSearching = false
    }
}

struct SearchResultRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.isFromMe ? "Me" : message.displaySender)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(message.timestamp, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let text = message.text {
                Text(text)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 2)
    }
}
