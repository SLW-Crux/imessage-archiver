import Foundation

/// Apple-epoch ↔ Unix-epoch conversion for `chat.db` date columns.
///
/// `chat.db` stores dates as seconds since `2001-01-01 00:00:00 UTC`
/// (the "Apple epoch"). macOS 10.13+ (High Sierra) switched to
/// nanoseconds instead. Both formats coexist in the wild — a single
/// `chat.db` can have message dates in seconds and reaction dates in
/// nanoseconds.
///
/// We detect nanoseconds by magnitude: Apple seconds through the year
/// 2100 top out around 3.1×10⁹; nanoseconds for any message after
/// 2001-01-02 are ≥8.64×10¹³. A threshold of 10¹³ cleanly separates the
/// two for every real iMessage.
enum AppleEpoch {

    /// `2001-01-01 00:00:00 UTC` as a Unix timestamp.
    static let unixOffset: Int64 = 978_307_200

    private static let nanosecondThreshold: Int64 = 10_000_000_000_000

    /// Convert a `chat.db` date value to a Unix timestamp (seconds).
    static func toUnix(_ value: Int64) -> Int64 {
        if value >= nanosecondThreshold {
            return value / 1_000_000_000 + unixOffset
        }
        return value + unixOffset
    }

    /// Convert a Unix timestamp (seconds) to Apple-epoch seconds.
    static func fromUnix(_ unix: Int64) -> Int64 {
        unix - unixOffset
    }

    /// Convert a Unix timestamp (fractional seconds) to Apple-epoch
    /// nanoseconds — the format Sonoma+ uses for new rows.
    static func fromUnixNanoseconds(_ unix: TimeInterval) -> Int64 {
        Int64((unix - TimeInterval(unixOffset)) * 1_000_000_000)
    }

    /// Convenience: Date → Unix-epoch seconds Int64.
    static func unixSeconds(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970)
    }
}
