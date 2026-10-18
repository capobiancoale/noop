import Foundation

// SleepDebt.swift — a rolling sleep-debt ledger over the last 14 nights.
//
// Pure, deterministic, DB-free. Given a chronological series of nights (total sleep, the deep/REM split
// when known, and the night's need when the WHOOP export carried one), it walks the last 14 calendar
// nights and reports the sleep debt still owed, plus the per-night deltas behind it.
//
// THE MODEL (evidence-based):
//   - The need is a FIXED per-night target, never the person's own average. Using the habitual mean
//     as the need is circular: someone who sleeps short every night would always read "on target", and
//     every above-average night would read as surplus. Adults need at least 7 h (AASM/SRS consensus,
//     Watson 2015, Sleep 38:843); the NSF range is 7–9 h (Hirshkowitz 2015, Sleep Health 1:40);
//     athletes sit at the upper end (Walsh 2021, Br J Sports Med 55:356); and given unrestricted time in
//     bed healthy adults settle at ~8.4 h, about an hour above their habitual sleep (Kitamura 2016,
//     Sci Rep 6:35812). The caller passes the per-night need the WHOOP export carried (without the debt
//     WHOOP already adds to it, which this ledger carries itself), else 8 h
//     (AnalyticsEngine.Rest.defaultNeedHours, the same target the Rest score uses).
//   - Debt adds up and is repaid, but it never goes below zero: D = max(0, D + need − slept), night by
//     night. Lost sleep accumulates across nights (Van Dongen 2003, Sleep 26:117) and extra sleep pays
//     it back, but sleep is not a bank account: hours slept BEFORE a debt don't pre-pay it, and paying a
//     debt back is, if anything, slower than hour-for-hour (Banks 2010, Sleep 33:1013; Kitamura 2016:
//     ~4 days of extended sleep to recover ~1 h of debt). So a run of long nights reads "no debt", never
//     an hours-long "surplus". Repayment is counted 1:1, the optimistic bound, so the debt shown is a
//     floor rather than an inflated figure.
//   - The window is the last 14 CALENDAR nights ending on the newest night with data, so a gap in the
//     record never stretches the ledger back over months.
//   - Nights with no usable total are SKIPPED (no zero-fill): a night without the strap is not a night
//     of debt.
//   - A night whose total, deep and REM are IDENTICAL to the night before is a repeated record, not
//     measured sleep: two real nights don't match to a tenth of a minute on all three. It is excluded
//     and reported, so a copied value can't fill the ledger. A night without a stage split is never
//     flagged: a total alone (often whole minutes) can coincide.
//
// Constant-explicit + dependency-free so it ports 1:1 to Kotlin. The Android mirror (android …
// SleepDebt.kt) still runs the earlier Σ(slept − need) model until this one is ported there.

/// One night as the ledger reads it.
public struct SleepNightInput: Equatable, Sendable {
    /// "yyyy-MM-dd" day key for the night (as carried on the DailyMetric).
    public let day: String
    /// Total sleep (minutes). nil / ≤ 0 = no usable data, the night is skipped.
    public let totalSleepMin: Double?
    /// Deep (slow-wave) minutes, when the night has a stage split.
    public let deepMin: Double?
    /// REM minutes, when the night has a stage split.
    public let remMin: Double?
    /// This night's need (minutes) when a source carried one (the WHOOP export's sleep need);
    /// nil → the ledger's default need.
    public let needMin: Double?

    public init(day: String, totalSleepMin: Double?, deepMin: Double? = nil, remMin: Double? = nil,
                needMin: Double? = nil) {
        self.day = day; self.totalSleepMin = totalSleepMin
        self.deepMin = deepMin; self.remMin = remMin; self.needMin = needMin
    }
}

/// One night's contribution to the ledger.
public struct SleepDebtNight: Equatable, Sendable {
    /// "yyyy-MM-dd" day key for the night.
    public let day: String
    /// Total sleep for the night (minutes).
    public let sleptMin: Double
    /// Signed delta vs the night's need (minutes): sleptMin − needMin. Positive = slept past the need.
    public let deltaMin: Double
    /// The need this night was measured against (minutes).
    public let needMin: Double
    /// Debt still owed after this night (minutes, ≥ 0).
    public let debtMin: Double

    public init(day: String, sleptMin: Double, deltaMin: Double, needMin: Double, debtMin: Double) {
        self.day = day; self.sleptMin = sleptMin; self.deltaMin = deltaMin
        self.needMin = needMin; self.debtMin = debtMin
    }
}

/// The rolling sleep-debt ledger over the last 14 calendar nights.
public struct SleepDebtLedger: Equatable, Sendable {
    /// Sleep debt still owed at the end of the window (minutes, ≥ 0).
    public let debtMin: Double
    /// Counted nights, oldest → newest (skipped and repeated nights are absent). The `deltaMin` values
    /// are the per-night bars.
    public let nights: [SleepDebtNight]
    /// The per-night need the ledger used (minutes): the mean over the counted nights, or the default
    /// when there are none.
    public let needMin: Double
    /// Nights inside the window left out because they repeat the night before exactly, oldest → newest.
    public let repeatedDays: [String]

    public init(debtMin: Double, nights: [SleepDebtNight], needMin: Double, repeatedDays: [String] = []) {
        self.debtMin = debtMin; self.nights = nights; self.needMin = needMin; self.repeatedDays = repeatedDays
    }

    /// Number of nights that contributed.
    public var nightCount: Int { nights.count }
    /// True while any debt is owed.
    public var isDebt: Bool { debtMin > 0 }
    /// True when the debt is inside the "on target" deadband.
    public var isOnTarget: Bool { debtMin < SleepDebt.onTargetBandMin }
    /// The debt as a signed balance (≤ 0), for callers that read it as one.
    public var balanceMin: Double { -debtMin }
    /// Magnitude of the debt in minutes.
    public var magnitudeMin: Double { debtMin }
}

/// One point of the per-night debt history (the debt owed after `day`, over the 14 nights ending there).
public struct SleepDebtPoint: Equatable, Sendable {
    public let day: String
    public let debtMin: Double

    public init(day: String, debtMin: Double) {
        self.day = day; self.debtMin = debtMin
    }
}

public enum SleepDebt {

    /// The ledger covers the last two weeks: recent enough to be actionable, short enough that one
    /// rough patch doesn't read as months of compounding debt.
    public static let defaultWindowNights: Int = 14

    /// "On target" deadband (minutes): a debt under this reads as on target, so a few stray minutes
    /// don't flip the headline.
    public static let onTargetBandMin: Double = 30.0

    /// Two nights count as the same record when total, deep and REM all agree within this (minutes).
    public static let sameNightToleranceMin: Double = 0.05

    /// Default per-night need (minutes): `AnalyticsEngine.Rest.defaultNeedHours` (8 h).
    public static var defaultNeedMin: Double { AnalyticsEngine.Rest.defaultNeedHours * 60.0 }

    /// Build the ledger from chronological nights (oldest → newest, the order `repo.days` carries).
    ///
    /// - Parameters:
    ///   - nights: the nights. A nil / non-positive total or an unparseable day key is skipped.
    ///   - defaultNeedMin: the need (minutes) for a night that carries none. Clamped to ≥ 0.
    ///   - window: calendar nights covered, ending on the newest usable night. Clamped to ≥ 1.
    public static func ledger(nights: [SleepNightInput],
                              defaultNeedMin: Double = SleepDebt.defaultNeedMin,
                              window: Int = defaultWindowNights) -> SleepDebtLedger {
        let fallbackNeed = max(defaultNeedMin, 0.0)
        let usable = usableNights(nights)
        guard let newest = usable.last else {
            return SleepDebtLedger(debtMin: 0, nights: [], needMin: fallbackNeed)
        }
        let repeated = repeatedDays(usable.map { $0.night })
        let first = newest.ordinal - max(window, 1) + 1
        let inWindow = usable.filter { $0.ordinal >= first }
        let measured = inWindow.filter { !repeated.contains($0.night.day) }
        let walked = walk(measured.map { $0.night }, fallbackNeed: fallbackNeed)
        let meanNeed = walked.nights.isEmpty
            ? fallbackNeed
            : walked.nights.map { $0.needMin }.reduce(0, +) / Double(walked.nights.count)
        return SleepDebtLedger(
            debtMin: walked.debt,
            nights: walked.nights,
            needMin: round1(meanNeed),
            repeatedDays: inWindow.map { $0.night.day }.filter { repeated.contains($0) })
    }

    /// Back-compatible entry point: totals only, one need for every night.
    public static func ledger(series: [(day: String, totalSleepMin: Double?)],
                              needHours: Double = AnalyticsEngine.Rest.defaultNeedHours,
                              window: Int = defaultWindowNights) -> SleepDebtLedger {
        ledger(nights: series.map { SleepNightInput(day: $0.day, totalSleepMin: $0.totalSleepMin) },
               defaultNeedMin: max(needHours, 0.0) * 60.0,
               window: window)
    }

    /// The debt owed after each measured night, each over the `window` calendar nights ending there:
    /// the history behind the ledger's headline (its last point equals `ledger(...).debtMin` whenever
    /// the newest night is measured). Repeated and unusable nights get no point.
    public static func debtSeries(nights: [SleepNightInput],
                                  defaultNeedMin: Double = SleepDebt.defaultNeedMin,
                                  window: Int = defaultWindowNights) -> [SleepDebtPoint] {
        let fallbackNeed = max(defaultNeedMin, 0.0)
        let usable = usableNights(nights)
        let repeated = repeatedDays(usable.map { $0.night })
        let measured = usable.filter { !repeated.contains($0.night.day) }
        let span = max(window, 1)
        var out: [SleepDebtPoint] = []
        out.reserveCapacity(measured.count)
        var lo = 0
        for i in measured.indices {
            while measured[i].ordinal - measured[lo].ordinal >= span { lo += 1 }
            let walked = walk(measured[lo...i].map { $0.night }, fallbackNeed: fallbackNeed)
            out.append(SleepDebtPoint(day: measured[i].night.day, debtMin: walked.debt))
        }
        return out
    }

    /// Days that repeat the previous usable night exactly: same total, deep and REM (see the header). Pass
    /// chronological nights; unusable ones (no positive total) are ignored, and only nights with a stage
    /// split can be flagged. The first night of a run is kept, the copies after it are returned.
    public static func repeatedDays(_ nights: [SleepNightInput]) -> Set<String> {
        let usable = nights.filter { ($0.totalSleepMin ?? 0) > 0 }
        var out = Set<String>()
        var runStart = 0
        while runStart < usable.count {
            var runEnd = runStart + 1
            while runEnd < usable.count, sameRecord(usable[runEnd], usable[runEnd - 1]) { runEnd += 1 }
            if runEnd - runStart >= 2, hasStages(usable[runStart]) {
                for k in (runStart + 1)..<runEnd { out.insert(usable[k].day) }
            }
            runStart = runEnd
        }
        return out
    }

    // MARK: - Internals

    private struct Dated {
        let night: SleepNightInput
        let ordinal: Int
    }

    /// Usable nights with their day number, sorted oldest → newest (stable for equal days).
    private static func usableNights(_ nights: [SleepNightInput]) -> [Dated] {
        nights.enumerated()
            .compactMap { i, n -> (Int, Dated)? in
                guard (n.totalSleepMin ?? 0) > 0, let ord = dayOrdinal(n.day) else { return nil }
                return (i, Dated(night: n, ordinal: ord))
            }
            .sorted { $0.1.ordinal != $1.1.ordinal ? $0.1.ordinal < $1.1.ordinal : $0.0 < $1.0 }
            .map { $0.1 }
    }

    /// Walk the nights in order: D = max(0, D + need − slept). Returns the per-night rows and final debt.
    private static func walk(_ nights: [SleepNightInput], fallbackNeed: Double)
        -> (nights: [SleepDebtNight], debt: Double) {
        var rows: [SleepDebtNight] = []
        rows.reserveCapacity(nights.count)
        var debt = 0.0
        for n in nights {
            let slept = n.totalSleepMin ?? 0
            let need = n.needMin.flatMap { $0 > 0 ? $0 : nil } ?? fallbackNeed
            let delta = slept - need
            debt = max(0.0, debt - delta)
            rows.append(SleepDebtNight(day: n.day, sleptMin: slept, deltaMin: round1(delta),
                                       needMin: need, debtMin: round1(debt)))
        }
        return (rows, round1(debt))
    }

    private static func sameRecord(_ a: SleepNightInput, _ b: SleepNightInput) -> Bool {
        close(a.totalSleepMin, b.totalSleepMin) && close(a.deepMin, b.deepMin) && close(a.remMin, b.remMin)
    }

    private static func close(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < sameNightToleranceMin
        default: return false
        }
    }

    private static func hasStages(_ n: SleepNightInput) -> Bool {
        guard let deep = n.deepMin, let rem = n.remMin else { return false }
        return deep + rem > 0
    }

    /// Days since 1970-01-01 for a "yyyy-MM-dd" key (proleptic Gregorian, no time zone involved), nil
    /// when the key doesn't parse. Integer-only so a Kotlin port computes the same number.
    static func dayOrdinal(_ day: String) -> Int? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let y0 = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Round to 1 decimal place (the ledger is reported in whole/near-whole minutes; 1 dp keeps the walk
    /// stable without trailing float noise). Mirrors the Kotlin rounding.
    static func round1(_ v: Double) -> Double { (v * 10.0).rounded() / 10.0 }
}
