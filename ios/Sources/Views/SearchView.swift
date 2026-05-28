import SwiftUI

struct SearchView: View {
    let reader: ArchiveReader
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List(hits) { hit in
            SearchResultRow(hit: hit)
        }
        .listStyle(.plain)
        .overlay {
            if query.isEmpty {
                ContentUnavailableView(
                    "Search Messages",
                    systemImage: "magnifyingglass",
                    description: Text("Search across all conversations in your archive.")
                )
            } else if hits.isEmpty && !isSearching {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search messages")
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task { await debouncedSearch(newValue) }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func debouncedSearch(_ q: String) async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            await MainActor.run { hits = [] }
            return
        }
        await MainActor.run { isSearching = true }
        let results = (try? await reader.search(query: q)) ?? []
        await MainActor.run {
            hits = results
            isSearching = false
        }
    }
}

struct SearchResultRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.message.isFromMe ? "Me" : hit.message.displaySender)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(hit.message.timestamp, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(hit.highlightedAttributedString())
                .font(.body)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.message.displaySender), \(hit.snippet.removingFTSMarkers())")
    }
}

private extension String {
    func removingFTSMarkers() -> String {
        replacingOccurrences(of: "\u{E000}", with: "")
            .replacingOccurrences(of: "\u{E001}", with: "")
    }
}
