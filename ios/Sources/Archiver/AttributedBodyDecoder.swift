#if os(macOS)
import Foundation
import AppKit

/// Extracts the plain-text string from a `chat.db` `attributedBody` BLOB.
///
/// chat.db stores message text in one of TWO encodings:
///
/// 1. **`NSKeyedArchiver` bplist** — modern format (macOS 10.13+). Decodable
///    with `NSKeyedUnarchiver` which is the modern non-deprecated API.
///
/// 2. **Legacy `typedstream`** — older messages, still present in chat.db
///    on every Mac (Messages.app never re-encoded existing rows). The
///    ONLY Foundation API that decodes typedstream is `NSUnarchiver`,
///    which has been deprecated in favour of NSKeyedUnarchiver — but
///    NSKeyedUnarchiver does not understand typedstream and returns
///    nil. The Python port discovered this in PR #31; reading legacy
///    rows with NSKeyedUnarchiver-only would silently drop ~75% of
///    message text on older accounts.
///
/// Order: try NSKeyedUnarchiver first (covers modern messages without
/// touching deprecated API); fall back to NSUnarchiver for typedstream.
/// The deprecation warning on the legacy path is suppressed at its
/// single call site with `@available(*, deprecated)` on the wrapper —
/// chat.db backward-compatibility makes the usage intentional and
/// non-removable.
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

        if let modern = decodeWithKeyedUnarchiver(data) {
            return modern
        }
        return decodeLegacyTypedstream(data)
    }

    // MARK: - Modern bplist NSKeyedArchiver path

    private static func decodeWithKeyedUnarchiver(_ data: Data) -> String? {
        // Try the modern NSAttributedString-shaped decode. Secure
        // coding is enabled by default on the static helpers;
        // attributedBody blobs are produced by NSKeyedArchiver inside
        // Messages.app, so NSSecureCoding compliance holds.
        if let attr = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self,
            from: data
        ) {
            let s = attr.string
            return s.isEmpty ? nil : s
        }
        // Some bplist blobs have a different top-level class (NSString,
        // NSMutableString). Try the broader decode using the modern
        // unarchivedObject(ofClasses:from:) API — a union of every
        // class chat.db is known to use — so we don't fall through
        // to the deprecated unarchiveTopLevelObjectWithData. Same
        // behaviour, no deprecation warning.
        if let any = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [
                NSAttributedString.self,
                NSMutableAttributedString.self,
                NSString.self,
                NSMutableString.self,
            ],
            from: data
        ) {
            if let attr = any as? NSAttributedString {
                let s = attr.string
                return s.isEmpty ? nil : s
            }
            if let ns = any as? NSString {
                let s = ns as String
                return s.isEmpty ? nil : s
            }
            if let s = any as? String {
                return s.isEmpty ? nil : s
            }
        }
        return nil
    }

    // MARK: - Legacy typedstream NSUnarchiver path

    /// Legacy typedstream decode. `NSUnarchiver` is the only Foundation
    /// API that understands typedstream; it's deprecated in favour of
    /// `NSKeyedUnarchiver`, which CANNOT decode this format.
    ///
    /// The call goes through the `HonkDecodeLegacyTypedstream` ObjC
    /// shim (see `AttributedBodyDecoderShim.m`) because `NSUnarchiver`
    /// raises NSExceptions on malformed input and Swift cannot catch
    /// ObjC exceptions — an unwrapped call would abort the whole
    /// archive run on a single corrupt chat.db row (review finding MH1).
    /// The shim returns nil for both "not a typedstream" and "decoder
    /// threw".
    private static func decodeLegacyTypedstream(_ data: Data) -> String? {
        guard let decoded = HonkDecodeLegacyTypedstream(data) else {
            return nil
        }
        if let attr = decoded as? NSAttributedString {
            let s = attr.string
            return s.isEmpty ? nil : s
        }
        if let ns = decoded as? NSString {
            let s = ns as String
            return s.isEmpty ? nil : s
        }
        if let s = decoded as? String {
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

#endif
