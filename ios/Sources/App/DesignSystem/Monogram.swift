import SwiftUI

/// A circular avatar with a deterministic background colour and 1–2
/// letter glyph. Modelled on Apple's Contacts.app avatars. Seed should
/// be a stable identifier (chat_guid) so the colour doesn't change
/// between launches.
struct Monogram: View {
    let seed: String
    let label: String

    var body: some View {
        Circle()
            .fill(Color.avatarTint(for: seed))
            .overlay {
                Text(label)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(4)
            }
            .accessibilityHidden(true)
    }
}
