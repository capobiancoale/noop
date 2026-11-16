import Foundation
import WhoopStore

/// On-device "Readiness" intelligence.
///
/// Synthesizes a handful of established, non-medical sports-science signals from the daily-metrics
/// history into a single readiness read plus the drivers behind it. Everything here is a pure,
/// deterministic function of the rows you pass in — no networking, no strap commands, no state.
///
/// Signals and their references:
/// - **HRV readiness** — z-score of today's HRV against the personal trailing baseline. A drop of
///   roughly half a standard deviation flags autonomic fatigue (Plews et al. 2013; Buchheit 2014).
/// - **Resting-HR drift** — elevated resting HR vs baseline is a classic overtraining / illness
///   signal (Lamberts et al. 2004). Resting HR moves a few beats from one morning to the next with
///   nothing behind it (Buchheit 2014), so a rise must also clear 3 bpm (watch) / 5 bpm (flag): for a
///   very steady resting HR a 3-4 bpm rise is already 1.5 SD without meaning anything.
///
/// The verdict is anchored to the day's **Charge**, the recovery composite shown right above it, which
/// already weighs HRV, resting HR, sleep, breathing and skin temperature: a red Charge always reads as
/// recover, and a green one is never turned into "recover" by the vitals alone (only a sharp load rise or
/// a breathing-rate rise, which Charge barely weighs, still can). Without a Charge the signals decide alone.
/// - **Respiratory-rate drift** — a rise in sleeping respiratory rate is an early illness signal.
/// - **Training load** — this week's daily training load against the usual of the four weeks before it,
///   the same `TrainingLoad` ratio the Workouts card shows (daily TRIMP behind the stored Effort, uncoupled
///   windows, daily means; Gabbett 2016). A plain reading of the load, not an injury predictor
///   (Impellizzeri et al. 2020); a sharp rise is flagged as a fatigue cue for readiness.
/// - **Training monotony** — mean/SD of the daily load (TRIMP) over the last week; high monotony (low
///   variety) is associated with higher strain and illness (Foster 1998).
///
/// Not medical advice. These are approximations from a consumer strap; they describe trends in
/// *your own* data, nothing more.
public enum ReadinessEngine {

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
    private static let monotonyWindow = 7    // days of daily load behind Foster monotony
    static let rhrWatchMinBpm         = 3.0  // a resting-HR rise smaller than this is never a watch
    static let rhrBadMinBpm           = 5.0  // ...and smaller than this never a flag

    // MARK: Entry point

    /// Evaluate readiness from daily metrics. `days` may be in any order; the most recent day is
    /// treated as "today" unless `today` (a YYYY-MM-DD string) is given.
    public static func evaluate(days: [DailyMetric], today: String? = nil) -> Readiness {
        // v7.0.2 perf (#707): `evaluate` SORTS the entire daily history and walks trailing windows every
        // call, and it is read from a SwiftUI computed property — so a `body` re-evaluation (the iOS twin of
        // a Compose recompose) re-runs the full-history sort on each ~1 Hz live-HR tick. The Today view also
        // memoizes this at the View layer (its `todayInputKey`); this engine-level cache additionally shields
        // every OTHER caller and the first/uncached read. Key = `today` + a fingerprint over ONLY the row
        // fields the synthesis reads (day + avgHrv/restingHr/respRateBpm/strain/recovery), so a new sync re-keys but a
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
            h = (h &* 1099511628211) ^ (d.recovery ?? -1).bitPattern
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
        let history = sorted.filter { $0.day < latest.day }   // everything before today

        var signals: [Signal] = []

        // HRV readiness ------------------------------------------------------
        let hrvSignal = zSignal(
            value: latest.avgHrv,
            baseline: history.suffix(baselineWindow).compactMap { $0.avgHrv },
            key: "hrv", label: "HRV",
            unit: "ms",
            decimals: 0,
            higherIsBetter: true,
            goodText: "above your baseline - well recovered",
            neutralText: "in your normal range",
            watchText: "a touch below baseline",
            badText: "suppressed - a sign of autonomic fatigue")
        if let s = hrvSignal { signals.append(s) }

        // Resting-HR drift ---------------------------------------------------
        let rhrSignal = zSignal(
            value: latest.restingHr.map(Double.init),
            baseline: history.suffix(baselineWindow).compactMap { $0.restingHr.map(Double.init) },
            key: "rhr", label: "Resting HR",
            unit: "bpm",
            decimals: 0,
            higherIsBetter: false,
            watchMinDelta: rhrWatchMinBpm, badMinDelta: rhrBadMinBpm,
            goodText: "at or below baseline",
            neutralText: "in your normal range",
            watchText: "running a little high",
            badText: "elevated - overtraining or illness can do this")
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
                        detail: "up vs baseline - sometimes an early sign of getting sick", flag: .bad))
                } else if z >= 1.5 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "slightly raised vs baseline", flag: .watch))
                }
            }
        }

        // Training load + monotony ------------------------------------------
        // Effort is logarithmic, so both read the daily TRIMP behind it (`TrainingLoad`), never the Effort
        // values themselves; the ratio is the Workouts card's, so the two screens never disagree.
        let load = TrainingLoad.summary(days: sorted.map { (day: $0.day, effort: $0.strain) }, today: latest.day)
        let acwr = load.ratio
        if let ratio = load.ratio, let band = load.band, let usual = load.chronicWeekly {
            signals.append(loadSignal(ratio, band: band, acute: load.acute, usual: usual))
        }
        // Foster monotony over the last week's daily load: mean ÷ SD.
        var monotony: Double? = nil
        if let weekStart = FitnessAgeEngine.shiftDay(latest.day, by: -(monotonyWindow - 1)) {
            let week = sorted.filter { $0.day >= weekStart && $0.day <= latest.day }
                .compactMap { $0.strain }.map { TrainingLoad.trimp(fromEffort: $0) }
            // An SD at floating-point noise (identical loads every day, e.g. a synthetic week) is no spread
            // to divide by: it would read as an astronomically "monotonous" week.
            if week.count >= 4, let sd = sampleSD(week), let m = mean(week), sd > 1e-9 * max(1, m) {
                let mono = m / sd
                monotony = mono
                if mono >= 2.0 {
                    signals.append(Signal(key: "monotony", label: "Training variety",
                        evidence: "monotony \(NumberText.decimal(mono))",
                        detail: "low - a similar load every day, which Foster linked to more strain and illness",
                        flag: .watch))
                }
            }
        }

        let (level, headline, summary) = synthesize(signals: signals,
                                                    hasHistory: !history.isEmpty || acwr != nil,
                                                    charge: latest.recovery)
        return Readiness(level: level, headline: headline, summary: summary,
                         signals: signals, acwr: acwr, monotony: monotony)
    }

    // MARK: Signal builders

    /// Build a z-score signal for a metric where the baseline is the trailing window. `watchMinDelta` /
    /// `badMinDelta` are the smallest moves in the worse direction (in the metric's own unit) that may count
    /// as watch / bad, so a very steady baseline (tiny SD) can't turn a trivial change into a flag.
    private static func zSignal(value: Double?, baseline: [Double],
                                key: String, label: String, unit: String, decimals: Int,
                                higherIsBetter: Bool,
                                watchMinDelta: Double = 0, badMinDelta: Double = 0,
                                goodText: String, neutralText: String,
                                watchText: String, badText: String) -> Signal? {
        guard let v = value, baseline.count >= minBaseline,
              let m = mean(baseline), let sd = sampleSD(baseline), sd > 0 else { return nil }
        // Orient z so positive always means "better".
        let worse = higherIsBetter ? (m - v) : (v - m)
        let z = -worse / sd
        var flag: Flag
        switch z {
        case 0.5...:        flag = .good
        case -0.5..<0.5:    flag = .neutral
        case -1.0 ..< -0.5: flag = .watch
        default:            flag = .bad
        }
        if flag == .bad, worse < badMinDelta { flag = .watch }
        if flag == .watch, worse < watchMinDelta { flag = .neutral }
        let text: String
        switch flag {
        case .good:    text = goodText
        case .neutral: text = neutralText
        case .watch:   text = watchText
        case .bad:     text = badText
        }
        return Signal(key: key, label: label,
                      evidence: evidence(value: v, baseline: m, unit: unit, decimals: decimals),
                      detail: text, flag: flag)
    }

    /// The training-load signal for a `TrainingLoad` ratio and its band. The key stays "acwr" (the screens and
    /// stored traces read it). A lighter week is no readiness concern (neutral); a sharp rise is flagged as a
    /// fatigue cue, never as an injury risk.
    private static func loadSignal(_ ratio: Double, band: TrainingLoad.Band, acute: Double, usual: Double) -> Signal {
        let x = NumberText.decimal(ratio, digits: 2)
        let evidence = "7d \(NumberText.decimal(acute, digits: 0)) / usual week \(NumberText.decimal(usual, digits: 0))"
        switch band {
        case .below:
            return Signal(key: "acwr", label: "Training load", evidence: evidence,
                          detail: "below your usual (x\(x)) - a lighter week", flag: .neutral)
        case .steady:
            return Signal(key: "acwr", label: "Training load", evidence: evidence,
                          detail: "in line with your usual (x\(x))", flag: .good)
        case .higher:
            return Signal(key: "acwr", label: "Training load", evidence: evidence,
                          detail: "higher than usual (x\(x)) - watch for fatigue", flag: .watch)
        case .sharpRise:
            return Signal(key: "acwr", label: "Training load", evidence: evidence,
                          detail: "a sharp rise on your usual (x\(x)) - watch for fatigue", flag: .bad)
        }
    }

    private static func evidence(value: Double, baseline: Double, unit: String, decimals: Int) -> String {
        "\(format(value, decimals: decimals)) vs \(format(baseline, decimals: decimals)) \(unit)"
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        decimals == 0
            ? String(Int(value.rounded()))
            : NumberText.decimal(value, digits: decimals)
    }

    // MARK: Synthesis

    static func synthesize(signals: [Signal], hasHistory: Bool, charge: Double? = nil) -> (Level, String, String) {
        guard hasHistory, !signals.isEmpty else {
            return (.insufficient, "Readiness",
                    "A few more nights of data and your readiness read will sharpen.")
        }
        let bad = signals.filter { $0.flag == .bad }
        let watch = signals.filter { $0.flag == .watch }
        let good = signals.filter { $0.flag == .good }
        let recoveryDown = signals.contains { ["hrv", "rhr", "respRate"].contains($0.key) && ($0.flag == .bad) }
        let loadHigh = signals.contains { $0.key == "acwr" && $0.flag == .bad }
        let breathingUp = signals.contains { $0.key == "respRate" && $0.flag == .bad }

        let rundown: (Level, String, String) = (.rundown, "Run down",
            "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.")
        let strained: (Level, String, String) = (.strained, "Strained",
            "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.")
        let primed: (Level, String, String) = (.primed, "Primed",
            "Your signals are aligned and your load is supported. A harder session is well backed today.")
        let balanced: (Level, String, String) = (.balanced, "Balanced",
            "Nothing's flagging. Train to feel - your body's holding steady.")

        // Anchor to Charge (see the type doc): red always reads as recover, green is never overturned by
        // the vitals Charge already weighs.
        if let charge, charge.isFinite {
            if charge < RecoveryScorer.bandRedMax {
                return (bad.count >= 1 || loadHigh) ? rundown : strained
            }
            if charge >= RecoveryScorer.bandYellowMax {
                if loadHigh || breathingUp { return strained }
                return (good.count >= 2 && watch.isEmpty && bad.isEmpty) ? primed : balanced
            }
        }

        if bad.count >= 2 || (recoveryDown && loadHigh) { return rundown }
        if recoveryDown || loadHigh || bad.count >= 1 { return strained }
        if good.count >= 2 && watch.isEmpty { return primed }
        return balanced
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
