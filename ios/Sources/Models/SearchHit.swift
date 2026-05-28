import Foundation
import SwiftUI

struct SearchHit: Identifiable, Hashable, Sendable {
    let message: Message
    let snippet: String

    var id: String { message.messageGuid }

    /// Parses the FTS5 `snippet()` output into an AttributedString where the
    /// matched substrings carry a foreground colour and bold weight. The
    /// markers `⁨MATCH_START⁩` / `⁨MATCH_END⁩` are unlikely to appear in real
    /// message text (FSI/PDI control codes used as sentinels).
    func highlightedAttributedString() -> AttributedString {
        let raw = snippet
        var result = AttributedString()
        var cursor = raw.startIndex

        // U+E000 / U+E001 are Private Use Area codepoints — guaranteed not
        // to appear in valid Unicode text by convention. Replaces the
        // FSI/PDI sentinels which could collide with bidirectional text.
        let startMarker = "\u{E000}"
        let endMarker = "\u{E001}"

        while cursor < raw.endIndex {
            guard let startRange = raw.range(of: startMarker, range: cursor..<raw.endIndex) else {
                result += AttributedString(raw[cursor..<raw.endIndex])
                break
            }
            result += AttributedString(raw[cursor..<startRange.lowerBound])

            let afterStart = startRange.upperBound
            guard let endRange = raw.range(of: endMarker, range: afterStart..<raw.endIndex) else {
                result += AttributedString(raw[afterStart..<raw.endIndex])
                break
            }
            var highlighted = AttributedString(raw[afterStart..<endRange.lowerBound])
            highlighted.font = .body.weight(.semibold)
            highlighted.foregroundColor = .accentColor
            result += highlighted

            cursor = endRange.upperBound
        }
        return result
    }
}
