import Foundation
import WhoopStore

/// On-device "Readiness" intelligence.
///
/// Synthesizes a handful of established, non-medical sports-science signals from the daily-metrics
/// history into a single readiness read plus the drivers behind it. Everything here is a pure,
/// deterministic function of the rows you pass in — no networking, no strap commands, no state.
///
/// Descriptive personal trends only. Thresholds and synthesis are experimental UI heuristics,
/// not diagnostic cut-offs or an injury-risk model. Missing calendar days are never rest days.
public enum ReadinessEngine {
    public static let methodVersion = "readiness-calendar-v2"

    /// Civil-day arithmetic in UTC prevents DST or the current device time zone changing history.
    public static func dayKey(_ key: String, adding days: Int) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        f.calendar = calendar
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let date = f.date(from: key), f.string(from: date) == key,
              let next = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return f.string(from: next)
    }


    // MARK: Output types

    public enum Level: String, Sendable, Equatable {
        case primed       // signals aligned, load supported
        case balanced     // nothing notable either way
        case strained     // one meaningful signal down / load high
        case rundown      // several recovery signals down
        case insufficient // not enough history yet
    }

    public enum Flag: String, Sendable, Equatable {
        case good, neutral, watch, bad
    }

    public struct Signal: Sendable, Equatable {
        public let key: String      // "hrv" | "rhr" | "respRate" | "acwr" | "monotony"
        public let label: String    // short human label
        public let evidence: String?
        public let detail: String   // one-line plain-English read
        public let flag: Flag
        public init(key: String, label: String, evidence: String? = nil, detail: String, flag: Flag) {
            self.key = key; self.label = label; self.evidence = evidence
            self.detail = detail; self.flag = flag
        }
    }

    public struct Readiness: Sendable, Equatable {
        public let level: Level
        public let headline: String
        public let summary: String
        public let signals: [Signal]
        /// Acute:chronic workload ratio (nil if not enough strain history).
        public let acwr: Double?
        /// Foster training monotony over the last week (nil if not enough strain history).
        public let monotony: Double?
        public init(level: Level, headline: String, summary: String,
                    signals: [Signal], acwr: Double?, monotony: Double?) {
            self.level = level; self.headline = headline; self.summary = summary
            self.signals = signals; self.acwr = acwr; self.monotony = monotony
        }
    }

    // MARK: Tunables (named so the thresholds are auditable)

    private static let baselineWindow = 30   // days for HRV / RHR / RR baselines
    private static let minBaseline    = 7    // need at least this many baseline nights
    private static let acuteWindow    = 7
    private static let chronicWindow  = 28
    private static let minChronic     = 14   // need at least this much strain history for ACWR

    // MARK: Entry point

    /// Evaluate readiness from daily metrics. `days` may be in any order; the most recent day is
    /// treated as "today" unless `today` (a YYYY-MM-DD string) is given.
    public static func evaluate(days: [DailyMetric], today: String? = nil) -> Readiness {
        // v7.0.2 perf (#707): `evaluate` SORTS the entire daily history and walks trailing windows every
        // call, and it is read from a SwiftUI computed property — so a `body` re-evaluation (the iOS twin of
        // a Compose recompose) re-runs the full-history sort on each ~1 Hz live-HR tick. The Today view also
        // memoizes this at the View layer (its `todayInputKey`); this engine-level cache additionally shields
        // every OTHER caller and the first/uncached read. Key = `today` + a fingerprint over ONLY the row
        // fields the synthesis reads (day + avgHrv/restingHr/respRateBpm/strain), so a new sync re-keys but a
        // cosmetic reorder does not. Result is a small `Readiness`; no row arrays are retained.
        let key = ReadinessKey(today: today, rows: Self.rowsFingerprint(days))
        return evaluateCache.value(key) { evaluateUncached(days: days, today: today) }
    }

    private struct ReadinessKey: Hashable { let today: String?; let rows: StreamFingerprint }
    private static let evaluateCache = AnalyticsMemoCache<ReadinessKey, Readiness>(capacity: 16)

    /// Fingerprint the readiness-relevant columns of the daily rows without re-sorting or copying them.
    /// Order-independent per-row hash (folded into the checksum), so two identical histories in different
    /// order key the same — `evaluate` sorts internally, so order never changes the result.
    private static func rowsFingerprint(_ days: [DailyMetric]) -> StreamFingerprint {
        var sum: UInt64 = 1469598103934665603
        var minDayHash = 0, maxDayHash = 0
        for (i, d) in days.enumerated() {
            // All folds stay in UInt64 — `Double.bitPattern` is already a UInt64 (its sign bit can exceed
            // Int64.max, so an Int64 round-trip would TRAP), and `Int.bitPattern` reinterprets without loss.
            var h: UInt64 = UInt64(bitPattern: Int64(d.day.hashValue))
            h = (h &* 1099511628211) ^ (d.avgHrv ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.restingHr.map { UInt64(bitPattern: Int64($0)) } ?? .max)
            h = (h &* 1099511628211) ^ (d.respRateBpm ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.strain ?? -1).bitPattern
            sum ^= h                                   // commutative fold → order-independent
            let dh = d.day.hashValue
            if i == 0 { minDayHash = dh; maxDayHash = dh } else { minDayHash = min(minDayHash, dh); maxDayHash = max(maxDayHash, dh) }
        }
        return StreamFingerprint(count: days.count, firstTs: minDayHash, lastTs: maxDayHash, checksum: sum)
    }

    private static func evaluateUncached(days: [DailyMetric], today: String?) -> Readiness {
        let sorted = days.sorted { $0.day < $1.day }
        // When an explicit `today` is given (the dashboard passes the device's real local day key), use
        // the row for THAT day and nothing else: a stale historical import has no row for today, so the
        // readiness card reads "insufficient" rather than synthesizing off the newest stored — possibly
        // months-old — row (issue #23/#24). With no `today` (live-strap default callers) fall back to the
        // most recent row exactly as before, so nothing wearing the strap nightly changes.
        let latestRow: DailyMetric?
        if let today { latestRow = sorted.first { $0.day == today } } else { latestRow = sorted.last }
        guard let latest = latestRow else {
            return Readiness(level: .insufficient,
                             headline: "Readiness",
                             summary: "Wear the strap for a few nights and your readiness read will appear here.",
                             signals: [], acwr: nil, monotony: nil)
        }
        guard let baselineStart = dayKey(latest.day, adding: -baselineWindow) else {
            return Readiness(level: .insufficient, headline: "Readiness", summary: "Invalid day.", signals: [], acwr: nil, monotony: nil)
        }
        let history = sorted.filter { $0.day >= baselineStart && $0.day < latest.day }   // everything before today

        var signals: [Signal] = []

        // HRV readiness ------------------------------------------------------
        let hrvSignal = zSignal(
            value: latest.avgHrv,
            baseline: history.suffix(baselineWindow).compactMap { $0.avgHrv },
            key: "hrv", label: "HRV",
            unit: "ms",
            decimals: 0,
            higherIsBetter: true,
            goodText: "above your personal baseline",
            neutralText: "in your normal range",
            watchText: "a touch below baseline",
            badText: "below your personal baseline")
        if let s = hrvSignal { signals.append(s) }

        // Resting-HR drift ---------------------------------------------------
        let rhrSignal = zSignal(
            value: latest.restingHr.map(Double.init),
            baseline: history.suffix(baselineWindow).compactMap { $0.restingHr.map(Double.init) },
            key: "rhr", label: "Resting HR",
            unit: "bpm",
            decimals: 0,
            higherIsBetter: false,
            goodText: "at or below baseline",
            neutralText: "in your normal range",
            watchText: "running a little high",
            badText: "above your personal baseline")
        if let s = rhrSignal { signals.append(s) }

        // Respiratory-rate drift (illness early signal) ----------------------
        // respRateBpm may be a clean cloud value OR a higher-variance on-device RSA estimate, so gate
        // BOTH the latest value and the baseline mean to the plausible sleeping-RR band (8–25 bpm) and
        // use wider resp-only z thresholds (WATCH 1.5 / BAD 2.0) than HRV/RHR so a single noisy night
        // can't flip RUNDOWN. Mirrors the Kotlin reference (#78) for cross-platform parity.
        if let rr = latest.respRateBpm, SleepStager.respPlausibleRangeBpm.contains(rr) {
            let base = history.suffix(baselineWindow).compactMap { $0.respRateBpm }
            if base.count >= minBaseline, let m = mean(base),
               SleepStager.respPlausibleRangeBpm.contains(m), let sd = sampleSD(base), sd > 0 {
                let z = (rr - m) / sd
                if z >= 2.0 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "above your personal baseline", flag: .bad))
                } else if z >= 1.5 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "slightly raised vs baseline", flag: .watch))
                }
            }
        }

        // Training Stress Balance (ACWR) + monotony --------------------------
        let chronicStart = dayKey(latest.day, adding: -(chronicWindow - 1))!
        let acuteStart = dayKey(latest.day, adding: -(acuteWindow - 1))!
        let eligible = sorted.filter { $0.day >= chronicStart && $0.day <= latest.day }
        let byDay = Dictionary(eligible.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let chronicRows = byDay.values.compactMap { row -> Double? in
            guard let v = row.strain, v.isFinite, v >= 0 else { return nil }
            return v
        }
        let acuteRows = byDay.values.filter { $0.day >= acuteStart }.compactMap { row -> Double? in
            guard let v = row.strain, v.isFinite, v >= 0 else { return nil }
            return v
        }
        var acwr: Double? = nil
        var monotony: Double? = nil
        // Complete calendar windows are required: an absent value is unknown, an explicit zero is rest.
        if chronicRows.count == chronicWindow, acuteRows.count == acuteWindow,
           let acute = mean(acuteRows), let chronic = mean(chronicRows), chronic > 0 {
            let ratio = acute / chronic
            acwr = ratio
            signals.append(acwrSignal(ratio, acute: acute, chronic: chronic))
        }
        if acuteRows.count == acuteWindow, let sd = sampleSD(acuteRows), sd > 0,
           let m = mean(acuteRows) {
            monotony = m / sd
        }

        let (level, headline, summary) = synthesize(signals: signals,
                                                    hasHistory: !history.isEmpty || acwr != nil)
        return Readiness(level: level, headline: headline, summary: summary,
                         signals: signals, acwr: acwr, monotony: monotony)
    }

    // MARK: Signal builders

    /// Build a z-score signal for a metric where the baseline is the trailing window.
    private static func zSignal(value: Double?, baseline: [Double],
                                key: String, label: String, unit: String, decimals: Int,
                                higherIsBetter: Bool,
                                goodText: String, neutralText: String,
                                watchText: String, badText: String) -> Signal? {
        let baseline = baseline.filter { $0.isFinite && $0 > 0 }
        guard let v = value, v.isFinite, v > 0, baseline.count >= minBaseline,
              let m = mean(baseline), let sd = sampleSD(baseline), sd > 0 else { return nil }
        // Orient z so positive always means "better".
        let z = (higherIsBetter ? (v - m) : (m - v)) / sd
        let flag: Flag
        let text: String
        switch z {
        case 0.5...:        flag = .good;    text = goodText
        case -0.5..<0.5:    flag = .neutral; text = neutralText
        case -1.0 ..< -0.5: flag = .watch;   text = watchText
        default:            flag = .bad;     text = badText
        }
        return Signal(key: key, label: label,
                      evidence: evidence(value: v, baseline: m, unit: unit, decimals: decimals),
                      detail: text, flag: flag)
    }

    private static func acwrSignal(_ ratio: Double, acute: Double, chronic: Double) -> Signal {
        let pct = String(format: "%.2f", ratio)
        let evidence = "7d \(String(format: "%.1f", acute)) / 28d \(String(format: "%.1f", chronic))"
        switch ratio {
        case ..<0.8:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                detail: "lower recent load (acute:chronic \(pct))", flag: .watch)
        case 0.8..<1.3:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                detail: "similar recent load (acute:chronic \(pct))", flag: .good)
        case 1.3..<1.5:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                detail: "higher recent load (acute:chronic \(pct))", flag: .watch)
        default:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                detail: "markedly higher recent load (acute:chronic \(pct))", flag: .bad)
        }
    }

    private static func evidence(value: Double, baseline: Double, unit: String, decimals: Int) -> String {
        "\(format(value, decimals: decimals)) vs \(format(baseline, decimals: decimals)) \(unit)"
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(decimals)f", value)
    }

    // MARK: Synthesis

    private static func synthesize(signals: [Signal], hasHistory: Bool) -> (Level, String, String) {
        guard hasHistory, !signals.isEmpty else {
            return (.insufficient, "Readiness",
                    "A few more nights of data and your readiness read will sharpen.")
        }
        let bad = signals.filter { $0.flag == .bad }
        let watch = signals.filter { $0.flag == .watch }
        let good = signals.filter { $0.flag == .good }
        let recoveryDown = signals.contains { ["hrv", "rhr", "respRate"].contains($0.key) && ($0.flag == .bad) }
        let loadHigh = signals.contains { $0.key == "acwr" && $0.flag == .bad }

        if bad.count >= 2 || (recoveryDown && loadHigh) {
            return (.rundown, "Run down",
                    "Several signals differ from your baseline. Compare them with your check-in and recent sessions.")
        }
        if recoveryDown || loadHigh || bad.count >= 1 {
            return (.strained, "Strained",
                    "One or more signals differ from your baseline. This does not determine whether you should train.")
        }
        if good.count >= 2 && watch.isEmpty {
            return (.primed, "Primed",
                    "Your recorded signals are aligned. They do not predict today's performance.")
        }
        return (.balanced, "Balanced",
                "Your recorded signals are near their usual range. Your own sensations provide additional context.")
    }

    // MARK: Stats helpers

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n-1). nil for fewer than 2 points.
    static func sampleSD(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
