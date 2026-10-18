import Foundation

/// Decimal text for the design system's own read-outs (gauge value, chart tooltips), written with the
/// reader's decimal separator: "55,1" in Italian, "55.1" in English. `String(format: "%.1f", …)` always
/// prints a dot, whatever the locale. Display only: grouping is off so `en_US` output matches `%.Nf`
/// digit for digit. (The app target has its own `DisplayNumber` in Units.swift; this one is internal to
/// the package so the two modules do not export the same name.)
enum GaugeNumber {
    static func decimal(_ v: Double, digits: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }
}
