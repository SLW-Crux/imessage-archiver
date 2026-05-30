import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Extracts the plain-text string from a `chat.db` `attributedBody` BLOB.
///
/// On macOS 10.13+, many messages store their text in the
/// `attributedBody` column as a typedstream- or `NSKeyedArchiver`-
/// wrapped `NSAttributedString` rather than the plain `text` column.
/// Pure-Python decoders for typedstream miss ~75% of messages (the
/// project hit this in PR #31 and switched to PyObjC's `NSUnarchiver`,
/// which decodes both formats exactly the way Messages.app does).
///
/// Native Swift gets the same authoritative path for free: Foundation's
/// `NSUnarchiver` handles both legacy typedstream and modern keyed-
/// archive formats. No Python bridge needed.
///
/// Use `AttributedBodyDecoder.extractText(from: blob)` from the archiver
/// when the `text` column is NULL but `attributedBody` is non-empty.
enum AttributedBodyDecoder {

    /// Hard cap on the attributedBody size we attempt to decode. A
    /// pathologically large blob (corrupted row, tampered chat.db)
    /// would otherwise stall the archive process.
    static let maxBlobSize = 2 * 1024 * 1024

    /// Decode the plain-text payload of an `attributedBody` blob.
    ///
    /// - Returns: the extracted string, or `nil` for empty / oversized /
    ///   malformed input.
    static func extractText(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxBlobSize else {
            return nil
        }

        // Foundation's NSUnarchiver decodes both legacy typedstream and
        // modern NSKeyedArchiver bplists. The objects it produces are
        // either NSAttributedString (which has a .string accessor) or
        // raw NSString.
        //
        // Wrap with try? so any decode failure (corrupt blob, unknown
        // class) returns nil rather than throwing.
        let nsData = data as NSData

        let decoded: Any?
        if let unarchiver = NSUnarchiver(forReadingWith: nsData as Data) {
            decoded = unarchiver.decodeObject()
        } else {
            decoded = nil
        }

        if let attributed = decoded as? NSAttributedString {
            let s = attributed.string
            return s.isEmpty ? nil : s
        }

        if let s = decoded as? String, !s.isEmpty {
            return s
        }

        if let ns = decoded as? NSString {
            let s = ns as String
            return s.isEmpty ? nil : s
        }

        return nil
    }
}
