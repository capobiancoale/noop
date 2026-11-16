import Foundation
import WhoopStore

// PlanLearning.swift — what the daily plan has noticed about THIS person, from their own history.
//
// ASSOCIATIONS IN ONE PERSON'S DATA, NOT CAUSES. Every finding compares the Charge (`recovery`, 0–100) of
// two groups of days from the last 120 days of one athlete's own log. A difference between the groups can
// come from anything that moves with the grouping (illness, a hard block, travel, a skipped meal, a worn
// strap) and says nothing about what would happen if the athlete changed one habit. It is a prompt to look,
// never advice, never medical, and never a dose of anything. Pure and deterministic: no clock, no
// UserDefaults, no localized text; the caller says what "today" is and builds the words.
//
// Rules (window = the 120 days ending on `today`; a day's row is `DailyMetric.day`)
//  1. shortSleep. The night belongs to the row it is stored on: `DayPlan` reads that row's `totalSleepMin`
//     as "last night" for that same day's Charge, so the pairing here is the SAME row. A = rows with
//     `totalSleepMin` < 420 min, B = rows with >= 420; the measure is that row's Charge.
//  2. hardDayAfterLowCharge. A "hard" day has Effort (`strain`) >= the 75th percentile (type 7, linear
//     interpolation, `DayPlan.percentile`) of the Efforts in the window (rule off with fewer than 14 Efforts).
//     A = days with Charge < 50 and a hard Effort, B = days with Charge < 50 and an Effort that is not hard;
//     the measure is the NEXT calendar day's Charge. A day without a next-day Charge is left out.
//  3. consecutiveHardDays. Same "hard" day. A = hard days whose previous calendar day was also hard (a run of
//     2 or more; a run of 4 contributes its 2nd, 3rd and 4th day, so overlapping anchors are possible);
//     B = hard days whose previous day has an Effort that is NOT hard (a single hard day; an unknown previous
//     day is left out because the run length is unknown). Measure: the NEXT calendar day's Charge.
//  lateNight (bed and wake times) is not offered: `DailyMetric` carries no bed or wake time.
//
// Reliability gate (all three, both groups): n >= 10 days each, |difference| >= 5 Charge points, and a Welch
// t statistic with |t| >= 2. Welch's t = (meanA - meanB) / sqrt(varA/nA + varB/nB) with the sample variance
// (n - 1). With zero variance in both groups the standard error is 0: the t is then taken as infinite when the
// means differ and 0 when they do not. The t gate is a ROUGH SCREEN to throw out gaps that a few noisy days
// would produce; days of one person are serially correlated and the groups overlap in time, so the t is not a
// p-value and passing it is not proof. `difference` is always `groupA.mean - groupB.mean`, A being the
// "risk" group (short night, hard day on low Charge, 2+ hard days in a row).
//
// `personalSleepThresholdMinutes` looks for the cut among 360/390/420/450/480 min that gives the biggest
// Charge gap between longer and shorter nights (rule 1's pairing), with >= 10 days on each side and a gap of
// at least 5 points; nil otherwise. It does NOT apply the t screen (the spec asks for the two gates only).
public enum PlanLearning {

    // MARK: - Constants

    /// Days looked at, ending on `today` (inclusive).
    public static let windowDays = 120
    /// Short night: strictly under this many minutes (7 h).
    public static let shortSleepMinutes = 420.0
    /// "Low Charge" for rule 2: strictly under this.
    public static let lowCharge = 50.0
    /// Each group needs at least this many days.
    public static let minGroupDays = 10
    /// The gap needs at least this many Charge points (>=).
    public static let minDifference = 5.0
    /// Welch |t| needs at least this (>=); a rough screen, not a proof.
    public static let minT = 2.0
    /// Fewest Efforts in the window before "hard" is defined (same as the plan's hard-streak rule).
    public static let minEffortDays = 14
    /// Candidate sleep cuts, minutes.
    public static let sleepCuts = [360, 390, 420, 450, 480]

    // MARK: - Types

    public enum Kind: Int, CaseIterable, Sendable, Equatable {
        case shortSleep = 0, hardDayAfterLowCharge, consecutiveHardDays
    }

    public struct Group: Equatable, Sendable {
        public let n: Int
        public let mean: Double
        public init(n: Int, mean: Double) { self.n = n; self.mean = mean }
    }

    public struct Finding: Equatable, Sendable {
        public let kind: Kind
        public let groupA: Group
        public let groupB: Group
        /// `groupA.mean - groupB.mean`, Charge points.
        public let difference: Double
        /// Welch t of A against B (may be infinite with zero variance); 0 when it cannot be computed.
        public let t: Double
        public let isReliable: Bool
        public init(kind: Kind, groupA: Group, groupB: Group, difference: Double, t: Double, isReliable: Bool) {
            self.kind = kind; self.groupA = groupA; self.groupB = groupB
            self.difference = difference; self.t = t; self.isReliable = isReliable
        }
    }

    // MARK: - Entry points

    /// Only the reliable findings, strongest first (largest |t|, then largest |difference|, then rule order).
    public static func findings(days: [DailyMetric], today: String) -> [Finding] {
        guard let window = windowRows(days: days, today: today) else { return [] }
        var out: [Finding] = []

        // 1. short sleep, same row
        var short: [Double] = [], long: [Double] = []
        for d in window.rows {
            guard let s = d.totalSleepMin, s.isFinite, let c = charge(d) else { continue }
            if s < shortSleepMinutes { short.append(c) } else { long.append(c) }
        }
        out.append(compare(kind: .shortSleep, a: short, b: long))

        // 2 and 3 need a "hard" threshold
        if let hard = hardThreshold(window.rows) {
            let byDay = Dictionary(window.rows.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
            func nextCharge(_ d: DailyMetric) -> Double? {
                guard let k = FitnessAgeEngine.shiftDay(d.day, by: 1), k <= today, let n = byDay[k] else { return nil }
                return charge(n)
            }
            func isHard(_ d: DailyMetric?) -> Bool? {
                guard let s = d?.strain, s.isFinite else { return nil }
                return s >= hard
            }

            var lowHard: [Double] = [], lowEasy: [Double] = []
            var afterRun: [Double] = [], afterSingle: [Double] = []
            for d in window.rows {
                guard let h = isHard(d), let next = nextCharge(d) else { continue }
                if let c = charge(d), c < lowCharge {
                    if h { lowHard.append(next) } else { lowEasy.append(next) }
                }
                if h {
                    let prev = FitnessAgeEngine.shiftDay(d.day, by: -1).flatMap { byDay[$0] }
                    switch isHard(prev) {
                    case .some(true): afterRun.append(next)
                    case .some(false): afterSingle.append(next)
                    case .none: break
                    }
                }
            }
            out.append(compare(kind: .hardDayAfterLowCharge, a: lowHard, b: lowEasy))
            out.append(compare(kind: .consecutiveHardDays, a: afterRun, b: afterSingle))
        }
        return sortStrongestFirst(out.filter(\.isReliable))
    }

    /// The sleep cut (minutes) with the biggest same-row Charge gap, or nil. Window: the 120 days ending on
    /// `today`, or on the newest row's day when `today` is nil.
    public static func personalSleepThresholdMinutes(days: [DailyMetric], today: String? = nil) -> Int? {
        guard let anchor = today ?? days.map(\.day).max(),
              let window = windowRows(days: days, today: anchor) else { return nil }
        let pairs: [(sleep: Double, charge: Double)] = window.rows.compactMap { d in
            guard let s = d.totalSleepMin, s.isFinite, let c = charge(d) else { return nil }
            return (s, c)
        }
        var best: (cut: Int, gap: Double)?
        for cut in sleepCuts {
            let below = pairs.filter { $0.sleep < Double(cut) }.map(\.charge)
            let above = pairs.filter { $0.sleep >= Double(cut) }.map(\.charge)
            guard below.count >= minGroupDays, above.count >= minGroupDays else { continue }
            let gap = mean(above) - mean(below)
            guard gap >= minDifference else { continue }
            if best == nil || gap > best!.gap { best = (cut, gap) }
        }
        return best?.cut
    }

    // MARK: - Statistics

    /// One finding from two samples; the reliability gate lives here.
    static func compare(kind: Kind, a: [Double], b: [Double]) -> Finding {
        let ma = a.isEmpty ? 0 : mean(a), mb = b.isEmpty ? 0 : mean(b)
        let diff = ma - mb
        let t = welchT(a, b) ?? 0
        let reliable = a.count >= minGroupDays && b.count >= minGroupDays
            && abs(diff) >= minDifference && abs(t) >= minT
        return Finding(kind: kind, groupA: Group(n: a.count, mean: ma), groupB: Group(n: b.count, mean: mb),
                       difference: diff, t: t, isReliable: reliable)
    }

    /// Welch's t for (mean a - mean b); nil with fewer than 2 values in a group. Zero standard error gives
    /// +/- infinity when the means differ and 0 when they do not.
    static func welchT(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count >= 2, b.count >= 2 else { return nil }
        let diff = mean(a) - mean(b)
        let se = (variance(a) / Double(a.count) + variance(b) / Double(b.count)).squareRoot()
        if se == 0 { return diff == 0 ? 0 : (diff > 0 ? .infinity : -.infinity) }
        return diff / se
    }

    /// Strongest first: |t| descending, then |difference| descending, then rule order.
    static func sortStrongestFirst(_ f: [Finding]) -> [Finding] {
        f.sorted { x, y in
            let tx = abs(x.t), ty = abs(y.t)
            if tx != ty { return tx > ty }
            let dx = abs(x.difference), dy = abs(y.difference)
            if dx != dy { return dx > dy }
            return x.kind.rawValue < y.kind.rawValue
        }
    }

    static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

    /// Sample variance (n - 1).
    static func variance(_ v: [Double]) -> Double {
        guard v.count >= 2 else { return 0 }
        let m = mean(v)
        return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)
    }

    // MARK: - Helpers

    private static func charge(_ d: DailyMetric) -> Double? {
        guard let c = d.recovery, c.isFinite else { return nil }
        return c
    }

    private static func windowRows(days: [DailyMetric], today: String) -> (rows: [DailyMetric], from: String)? {
        guard let from = FitnessAgeEngine.shiftDay(today, by: -(windowDays - 1)) else { return nil }
        var byDay: [String: DailyMetric] = [:]
        for d in days where d.day >= from && d.day <= today { byDay[d.day] = d }
        return (byDay.values.sorted { $0.day < $1.day }, from)
    }

    private static func hardThreshold(_ rows: [DailyMetric]) -> Double? {
        let efforts = rows.compactMap { $0.strain }.filter { $0.isFinite }
        guard efforts.count >= minEffortDays else { return nil }
        return DayPlan.percentile(efforts, 0.75)
    }
}
