import SwiftUI

struct ReactionsView: View {
    let reactions: [Reaction]

    private var grouped: [(emoji: String, count: Int)] {
        var counts: [(String, Int)] = []
        var seen: [String: Int] = [:]
        for r in reactions {
            if let idx = seen[r.emoji] {
                counts[idx].1 += 1
            } else {
                seen[r.emoji] = counts.count
                counts.append((r.emoji, 1))
            }
        }
        return counts.map { (emoji: $0.0, count: $0.1) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { item in
                HStack(spacing: 2) {
                    Text(item.emoji)
                        .font(.caption)
                    if item.count > 1 {
                        Text("\(item.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemBackground))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}
