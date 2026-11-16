import Foundation

/// How old a value is, in calendar days, from two `yyyy-MM-dd` day keys. Pure: no clock, no time zone, no
/// locale. The app asks this one question everywhere a number is read from a multi-day series ("latest
/// HRV", "latest Fitness Age", "last night") and words the answer in one place, so a value that is not from
/// the day being shown never reads as that day's.
public enum DayFreshness {

    /// What the caption should say about a value's day, relative to a reference day (normally today).
    public enum Label: Equatable, Sendable {
        /// Same day as the reference: no caption needed.
        case sameDay
        /// One calendar day earlier.
        case yesterday
        /// 2...`maxRelativeDays` calendar days earlier.
        case daysAgo(Int)
        /// Older than `maxRelativeDays`: the caller prints a short date.
        case onDate
        /// The value's day is AFTER the reference day (a clock or import quirk). Shown as a date.
        case future
        /// A day key that does not parse.
        case unknown
    }

    /// Up to this many days back the caption is relative ("3 days ago"); beyond it, a short date.
    public static let maxRelativeDays = 6

    /// Whole calendar days from `dayKey` to `referenceKey` (reference minus day): 0 same day, 1 the day
    /// before, negative when `dayKey` is later. nil when either key is not a valid `yyyy-MM-dd`.
    public static func ageInDays(dayKey: String, referenceKey: String) -> Int? {
        guard let a = civilDayNumber(dayKey), let b = civilDayNumber(referenceKey) else { return nil }
        return b - a
    }

    /// The caption class for a value from `dayKey`, seen on `referenceKey`.
    public static func label(dayKey: String, referenceKey: String) -> Label {
        guard let age = ageInDays(dayKey: dayKey, referenceKey: referenceKey) else { return .unknown }
        switch age {
        case ..<0: return .future
        case 0: return .sameDay
        case 1: return .yesterday
        case 2...maxRelativeDays: return .daysAgo(age)
        default: return .onDate
        }
    }

    /// Days since 1970-01-01 for a `yyyy-MM-dd` key (proleptic Gregorian, Howard Hinnant's algorithm).
    /// nil for anything that is not a real calendar date.
    static func civilDayNumber(_ key: String) -> Int? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysIn(month: m, year: y) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysIn(month m: Int, year y: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
