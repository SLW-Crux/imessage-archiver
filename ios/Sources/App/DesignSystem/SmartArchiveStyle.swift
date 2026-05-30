import Foundation

/// A `FormatStyle` that renders dates the way Messages and Mail do in
/// their chat lists:
///   - today          → "3:42 PM"
///   - yesterday      → "Yesterday"
///   - within a week  → "Mon"
///   - older          → "5/30/26"
///
/// Use via `Text(date, format: .smartArchive)`. The relative comparison
/// is against `Calendar.current` / `.now`, so the row updates correctly
/// across the day boundary on re-render.
struct SmartArchiveStyle: FormatStyle {
    typealias FormatInput = Date
    typealias FormatOutput = String

    func format(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = cal.dateComponents([.day], from: date, to: .now).day,
           days >= 0, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(
            .dateTime
                .month(.defaultDigits)
                .day()
                .year(.twoDigits)
        )
    }
}

extension FormatStyle where Self == SmartArchiveStyle {
    /// `Text(date, format: .smartArchive)`
    static var smartArchive: SmartArchiveStyle { SmartArchiveStyle() }
}
