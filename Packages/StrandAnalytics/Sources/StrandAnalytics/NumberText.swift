import Foundation

/// Decimal text for the engines' user-facing strings (driver values, readiness evidence, hydration card),
/// written with the reader's decimal separator: "12,3" in Italian, "12.3" in English. `String(format:
/// "%.1f", …)` always prints a dot, whatever the locale. Only strings that are DISPLAYED go through here;
/// anything logged, exported or compared byte-for-byte keeps the POSIX `String(format:)`.
///
/// Grouping is off so the output matches `%.Nf` digit for digit in `en_US`/POSIX (the locale the tests
/// run in); only the separator moves. Pass `locale` to pin one.
enum NumberText {
    static func decimal(_ v: Double, digits: Int = 1, locale: Locale = .autoupdatingCurrent) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }
}
