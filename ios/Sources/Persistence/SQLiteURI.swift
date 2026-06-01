import Foundation

/// Build a SQLite `file:` URI with the path percent-encoded strictly
/// enough that a path containing `?`, `#`, `&`, or `%` doesn't corrupt
/// the URI parse.
///
/// `.urlPathAllowed` (per RFC 3986) leaves `?`, `#`, `&` *inside* path
/// components alone — fine for a real URI path, but we're building a
/// URI string by concatenation: `file:<path>?<query>`. A literal `?`
/// inside `<path>` would be split as the path/query separator. In the
/// worst case, a path substring like `?mode=rwc` would re-parse and
/// SQLite would open the database WRITABLE — directly violating the
/// non-destructive guarantee on `chat.db`
/// (review findings MH5 + IH6).
///
/// We subtract `?#&%` from `.urlPathAllowed` so any of those characters
/// in the input path are percent-encoded.
enum SQLiteURI {
    private static let pathAllowedExceptURISeparators: CharacterSet = {
        var s = CharacterSet.urlPathAllowed
        s.remove(charactersIn: "?#&%")
        return s
    }()

    /// Returns `file:<encoded-path>?<query>` for the given path + query
    /// string. Query is passed through verbatim — callers control it.
    static func buildURI(path: String, query: String) -> String {
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: pathAllowedExceptURISeparators
        ) ?? path
        return "file:\(encoded)?\(query)"
    }

    /// Convenience for the canonical read-only/immutable open.
    static func readOnlyImmutable(path: String) -> String {
        buildURI(path: path, query: "mode=ro&immutable=1")
    }
}
