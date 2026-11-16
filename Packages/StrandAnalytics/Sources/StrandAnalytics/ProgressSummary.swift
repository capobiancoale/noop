import Foundation

// ProgressSummary.swift — "Am I improving?" for the Progress screen.
//
// Pure: no clock, no storage. For one metric and one window (28 / 84 / 365 days) it compares the mean of
// the window with the mean of the previous window of the same length and says whether the change is
// better, worse or within the stability band. Too little data in either window gives nil (the screen then
// says "Not enough data yet" instead of a number). The summary sentence is chosen by fixed rules and
// returned as KEYS only; the view builds the words.
//
// Not a medical device: this only compares the user's own numbers with their own earlier numbers.

public enum ProgressSummary {

    /// The five rows of the Progress screen, in display order.
    public enum Metric: String, CaseIterable, Sendable {
        case strength   // estimated 1RM (kg) of the most-logged lift
        case engine     // VO2max estimate (ml/kg/min)
        case sleep      // average sleep per night (minutes)
        case recovery   // average Charge (0-100)
        case glucose    // time in range (%)

        /// Every metric here is "higher is better".
        public var higherIsBetter: Bool { true }

        /// Changes smaller than this (absolute, same unit as the value) count as stable.
        public var stabilityBand: Double {
            switch self {
            case .strength: return 2.5   // kg
            case .engine:   return 0.5   // ml/kg/min
            case .sleep:    return 10    // minutes
            case .recovery: return 3     // Charge points
            case .glucose:  return 2     // percentage points
            }
        }

        /// Minimum number of values required in EACH window (daily metrics 7, strength 2 entries).
        public var minimumValues: Int { self == .strength ? 2 : 7 }
    }

    public enum Direction: String, Equatable, Sendable { case better, worse, stable }

    /// One dated value ("yyyy-MM-dd", the app's local day key).
    public struct Point: Equatable, Sendable {
        public var day: String
        public var value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }

    public struct Row: Equatable, Sendable {
        public var metric: Metric
        /// Mean of the window.
        public var value: Double
        /// Mean of the previous window of the same length.
        public var previous: Double
        /// value - previous (signed, unit of the metric).
        public var change: Double
        public var direction: Direction
        /// The window's values oldest to newest, thinned to at most `maxSeriesPoints` for a sparkline.
        public var series: [Double]
        public var currentCount: Int
        public var previousCount: Int
    }

    public static let windowChoices: [Int] = [28, 84, 365]
    public static let maxSeriesPoints = 24

    /// One row, or nil when either window has fewer than `metric.minimumValues` values.
    /// `today` is "yyyy-MM-dd". The current window is the `windowDays` days ending on `today` (inclusive),
    /// the previous window the `windowDays` days before that. Several points on one day are averaged.
    public static func row(metric: Metric, points: [Point], today: String, windowDays: Int) -> Row? {
        guard windowDays > 0, let t = dayNumber(today) else { return nil }
        var perDay: [Int: (sum: Double, n: Int)] = [:]
        for p in points where p.value.isFinite {
            guard let d = dayNumber(p.day) else { continue }
            let old = perDay[d] ?? (0, 0)
            perDay[d] = (old.sum + p.value, old.n + 1)
        }
        let days = perDay.keys.sorted()
        var current: [Double] = []
        var previous: [Double] = []
        for d in days {
            let v = perDay[d].map { $0.sum / Double($0.n) } ?? 0
            if d > t - windowDays && d <= t { current.append(v) }
            else if d > t - 2 * windowDays && d <= t - windowDays { previous.append(v) }
        }
        guard current.count >= metric.minimumValues, previous.count >= metric.minimumValues else { return nil }
        let value = mean(current), before = mean(previous)
        let change = value - before
        return Row(metric: metric, value: value, previous: before, change: change,
                   direction: direction(metric: metric, change: change),
                   series: thin(current, to: maxSeriesPoints),
                   currentCount: current.count, previousCount: previous.count)
    }

    /// The window's own mean and sparkline when the window has enough values but the period before it does
    /// not (a metric that only started recently): shown as a value with no comparison. nil when the window
    /// itself is short, or when `row` would succeed (use `row` then).
    public static func currentOnly(metric: Metric, points: [Point], today: String,
                                   windowDays: Int) -> (value: Double, series: [Double])? {
        guard windowDays > 0, let t = dayNumber(today) else { return nil }
        var perDay: [Int: (sum: Double, n: Int)] = [:]
        for p in points where p.value.isFinite {
            guard let d = dayNumber(p.day), d > t - windowDays, d <= t else { continue }
            let old = perDay[d] ?? (0, 0)
            perDay[d] = (old.sum + p.value, old.n + 1)
        }
        let current = perDay.keys.sorted().compactMap { perDay[$0].map { $0.sum / Double($0.n) } }
        guard current.count >= metric.minimumValues,
              row(metric: metric, points: points, today: today, windowDays: windowDays) == nil else { return nil }
        return (mean(current), thin(current, to: maxSeriesPoints))
    }

    /// Better / worse / stable for a change: within the metric's band (strictly smaller) is stable.
    public static func direction(metric: Metric, change: Double) -> Direction {
        if abs(change) < metric.stabilityBand { return .stable }
        let up = change > 0
        return (up == metric.higherIsBetter) ? .better : .worse
    }

    // MARK: Summary sentence (keys only)

    public enum SummaryKey: Equatable, Sendable {
        case notEnoughData
        case allBetter
        case allWorse
        case allStable
        case betterOnly([Metric])
        case worseOnly([Metric])
        case mixed(better: [Metric], worse: [Metric])
    }

    /// Fixed rules over the rows that have data (metrics in `Metric.allCases` order):
    /// no rows: notEnoughData; all better / all worse / all stable; some better and none worse: betterOnly;
    /// some worse and none better: worseOnly; both: mixed. A single row with direction better is allBetter.
    public static func summaryKey(_ rows: [Row]) -> SummaryKey {
        guard !rows.isEmpty else { return .notEnoughData }
        let ordered = rows.sorted { Self.order($0.metric) < Self.order($1.metric) }
        let better = ordered.filter { $0.direction == .better }.map(\.metric)
        let worse = ordered.filter { $0.direction == .worse }.map(\.metric)
        if better.count == ordered.count { return .allBetter }
        if worse.count == ordered.count { return .allWorse }
        if better.isEmpty && worse.isEmpty { return .allStable }
        if worse.isEmpty { return .betterOnly(better) }
        if better.isEmpty { return .worseOnly(worse) }
        return .mixed(better: better, worse: worse)
    }

    private static func order(_ m: Metric) -> Int { Metric.allCases.firstIndex(of: m) ?? 0 }

    // MARK: Helpers

    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    /// Thins a series to at most `limit` points by averaging consecutive chunks; keeps the order.
    static func thin(_ xs: [Double], to limit: Int) -> [Double] {
        guard limit > 0, xs.count > limit else { return xs }
        var out: [Double] = []
        for i in 0..<limit {
            let lo = i * xs.count / limit
            let hi = max(lo + 1, (i + 1) * xs.count / limit)
            out.append(mean(Array(xs[lo..<min(hi, xs.count)])))
        }
        return out
    }

    /// Days since 1970-01-01 for "yyyy-MM-dd" (proleptic Gregorian), or nil when malformed.
    static func dayNumber(_ s: String) -> Int? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
