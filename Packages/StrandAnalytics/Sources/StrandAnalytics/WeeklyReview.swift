import Foundation
import WhoopStore

// WeeklyReview.swift — "what changed this week": keys and numbers only, no sentences. Pure and
// deterministic (no clock, no UserDefaults, no localized text); the screen builds the words.
//
// NOT MEDICAL ADVICE. A comparison of this week with last week in the athlete's own log, plus one suggestion
// taken from the same rules the daily plan uses. Associations, not causes. Nothing here touches glucose
// except an optional weekly time-in-range number the caller passes in, and insulin is never mentioned.
//
// The week is the 7 days from `weekStart` (a Monday key "yyyy-MM-dd", see `mondayKey(of:)`); "last week" is
// the 7 days before it.
//
//  Gate. A week needs >= 4 days with data (a row with a Charge, an Effort or a night's sleep), else the
//  outcome is `.insufficient`. A metric is compared only when BOTH weeks have >= 3 days with a value
//  (>= 4 wake times for the wake-time spread).
//
//  Day strip. Level from the Charge (`recovery`) with the plan's bands: >= 67 push, >= 34 maintain, < 34 easy;
//  nil when the day has no Charge.
//
//  improved / worsened (change = this week - last week; a change exactly at the threshold counts):
//    average sleep         >= 15 min   (more is better)
//    average Charge        >= 4 points (more is better)
//    average HRV           >= 5 %      of last week's mean (more is better)
//    average resting HR    >= 2 bpm    (lower is better)
//    wake-time spread      >= 20 min   (population standard deviation of the week's wake minutes; lower is better)
//    time in range         >= 3 points (more is better; the two weekly values come from the caller)
//    strength records      every movement with an `isRecord` entry in the week (`StrengthProgress.movements`),
//                          its heaviest record load; always in `improved`
//    best WOD results      a result this week that beats every earlier attempt at the same title in the same
//                          RX / scaled group on the title's primary result kind (`WodRanking`); the first
//                          attempt is never a best; always in `improved`
//
//  Load. `TrainingLoad.summary` as of the week's last day: ratio = this week's mean daily load over the usual
//  (the 4 weeks before), nil without enough days there (>= 4 this week, >= 14 before).
//
//  headline, first rule that holds:
//    bothBetter         sleep improved AND at least one strength record or best WOD result
//    strongerLessSleep  sleep worsened AND at least one strength record or best WOD result
//    betterRecovery     at least one of Charge / HRV / resting HR improved and none of the three worsened
//    heavyWeek          load ratio > 1.3 (TrainingLoad bands "higher" and "sharp rise")
//    quietWeek          load ratio < 0.8
//    steady             otherwise
//
//  oneThing, first rule that holds (thresholds are those of `DayPlan`'s "work on" list):
//    1. sleep: >= 4 nights with a value and the average more than 45 min under the need (need = `sleepNeedMin`
//       ?? 480), or a sleep debt >= 60 min -> earlierBedtime(evenings: N, bedtimeMinutes: the plan's bedtime),
//       N = nights of the week under the need, kept within 3...5
//    2. wake times: >= 4 wake times and a standard deviation over 60 min -> steadyWake
//    3. load ratio >= 1.5 -> oneEasierDay
//    4. load ratio < 0.8 -> oneMoreSession
//    5. otherwise keepGoing
//
//  adherence. Each day with an Effort and a level (the plan's level for that day from `planLevelByDay`, else the
//  level from its Charge) is judged against thirds of the athlete's own Efforts of the 28 days ending on the
//  week's last day (needs >= 14 of them): push -> Effort in the top third (>= the 2/3 quantile), easy -> bottom
//  third (<= the 1/3 quantile), maintain -> strictly between. Only when >= 4 days can be judged.
public enum WeeklyReview {

    // MARK: - Thresholds

    public static let minDaysWithData = 4
    public static let minDaysPerMetric = 3
    public static let minWakeNights = 4
    public static let sleepChangeMin = 15.0
    public static let chargeChange = 4.0
    public static let hrvChangePct = 5.0
    public static let restingHrChange = 2.0
    public static let wakeSpreadChange = 20.0
    public static let timeInRangeChange = 3.0
    public static let pushCharge = 67.0
    public static let maintainCharge = 34.0
    public static let heavyRatio = 1.3
    public static let sharpRiseRatio = 1.5
    public static let lowRatio = 0.8
    public static let shortSleepMargin = 45.0
    public static let debtMinutes = 60.0
    public static let irregularWakeSd = 60.0
    public static let minAdherenceDays = 4
    public static let minEffortDaysForThirds = 14
    public static let defaultNeedMin = 480.0

    // MARK: - Types

    public struct DayCell: Equatable, Sendable {
        public let day: String
        public let charge: Int?
        /// push / maintain / easy by the Charge; nil without a Charge.
        public let level: DayPlan.Training?
        public init(day: String, charge: Int?, level: DayPlan.Training?) {
            self.day = day; self.charge = charge; self.level = level
        }
    }

    public enum Metric: Int, Sendable, Equatable {
        case sleep = 0, charge, hrv, restingHr, wakeSpread, timeInRange
    }

    public struct Change: Equatable, Sendable {
        public let metric: Metric
        public let thisWeek: Double
        public let lastWeek: Double
        /// thisWeek - lastWeek in the metric's own unit (minutes, points, ms, bpm).
        public let change: Double
        /// change / lastWeek * 100 when lastWeek > 0.
        public let changePct: Double?
        public init(metric: Metric, thisWeek: Double, lastWeek: Double, change: Double, changePct: Double?) {
            self.metric = metric; self.thisWeek = thisWeek; self.lastWeek = lastWeek
            self.change = change; self.changePct = changePct
        }
    }

    public struct WodBest: Equatable, Sendable {
        public let title: String
        public let row: WodLogRow
        public init(title: String, row: WodLogRow) { self.title = title; self.row = row }
    }

    public enum Item: Equatable, Sendable {
        case metric(Change)
        case strengthRecord(name: String, weightKg: Double)
        case wodBest(WodBest)
    }

    public enum Headline: String, Sendable, Equatable, CaseIterable {
        case bothBetter, strongerLessSleep, betterRecovery, heavyWeek, quietWeek, steady
    }

    public enum OneThing: Equatable, Sendable {
        case earlierBedtime(evenings: Int, bedtimeMinutes: Int?)
        case steadyWake(sdMinutes: Int)
        case oneEasierDay
        case oneMoreSession
        case keepGoing
    }

    public struct Adherence: Equatable, Sendable {
        public let judged: Int
        public let matched: Int
        public init(judged: Int, matched: Int) { self.judged = judged; self.matched = matched }
    }

    public struct Inputs {
        public var days: [DailyMetric]
        public var weekStart: String
        /// Minutes after local midnight of the morning wake-up, by the day it happened on.
        public var wakeMinutesByDay: [String: Int]
        public var wods: [WodLogRow]
        /// The plan's training level per day, when known (may be empty or partial).
        public var planLevelByDay: [String: DayPlan.Training]
        public var timeInRangeThisWeek: Double?
        public var timeInRangeLastWeek: Double?
        public var sleepNeedMin: Double?
        public var sleepDebtMin: Double?
        /// The plan's bedtime, minutes after midnight, when known.
        public var bedtimeMinutes: Int?
        public init(days: [DailyMetric], weekStart: String, wakeMinutesByDay: [String: Int] = [:],
                    wods: [WodLogRow] = [], planLevelByDay: [String: DayPlan.Training] = [:],
                    timeInRangeThisWeek: Double? = nil, timeInRangeLastWeek: Double? = nil,
                    sleepNeedMin: Double? = nil, sleepDebtMin: Double? = nil, bedtimeMinutes: Int? = nil) {
            self.days = days; self.weekStart = weekStart; self.wakeMinutesByDay = wakeMinutesByDay
            self.wods = wods; self.planLevelByDay = planLevelByDay
            self.timeInRangeThisWeek = timeInRangeThisWeek; self.timeInRangeLastWeek = timeInRangeLastWeek
            self.sleepNeedMin = sleepNeedMin; self.sleepDebtMin = sleepDebtMin
            self.bedtimeMinutes = bedtimeMinutes
        }
    }

    public struct Review: Equatable, Sendable {
        public let weekStart: String
        public let weekEnd: String
        public let days: [DayCell]
        public let daysWithData: Int
        public let improved: [Item]
        public let worsened: [Item]
        public let headline: Headline
        public let oneThing: OneThing
        public let adherence: Adherence?
        public let loadRatio: Double?
        public init(weekStart: String, weekEnd: String, days: [DayCell], daysWithData: Int, improved: [Item],
                    worsened: [Item], headline: Headline, oneThing: OneThing, adherence: Adherence?,
                    loadRatio: Double?) {
            self.weekStart = weekStart; self.weekEnd = weekEnd; self.days = days
            self.daysWithData = daysWithData; self.improved = improved; self.worsened = worsened
            self.headline = headline; self.oneThing = oneThing; self.adherence = adherence
            self.loadRatio = loadRatio
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Fewer than 4 days with data (the day strip is still given).
        case insufficient(days: [DayCell], daysWithData: Int)
        case ready(Review)
    }

    // MARK: - Week keys

    /// The Monday on or before `day` ("yyyy-MM-dd"); nil when unparseable.
    public static func mondayKey(of day: String) -> String? {
        let p = day.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let wd = cal.component(.weekday, from: date) // 1 = Sunday
        return FitnessAgeEngine.shiftDay(day, by: -((wd + 5) % 7))
    }

    /// The 7 day keys of the week starting on `weekStart`; nil when unparseable.
    public static func weekKeys(_ weekStart: String) -> [String]? {
        let keys = (0..<7).compactMap { FitnessAgeEngine.shiftDay(weekStart, by: $0) }
        return keys.count == 7 ? keys : nil
    }

    // MARK: - Entry point

    public static func make(_ i: Inputs) -> Outcome {
        guard let keys = weekKeys(i.weekStart), let lastKeys = weekKeys(FitnessAgeEngine.shiftDay(i.weekStart, by: -7) ?? "") else {
            return .insufficient(days: [], daysWithData: 0)
        }
        let byDay = Dictionary(i.days.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let cells = keys.map { cell(byDay[$0], day: $0) }
        let withData = keys.filter { k in
            guard let d = byDay[k] else { return false }
            return finite(d.recovery) != nil || finite(d.strain) != nil || finite(d.totalSleepMin) != nil
        }.count
        guard withData >= minDaysWithData else { return .insufficient(days: cells, daysWithData: withData) }

        func vals(_ ks: [String], _ f: (DailyMetric) -> Double?) -> [Double] {
            ks.compactMap { byDay[$0].flatMap(f).flatMap { $0.isFinite ? $0 : nil } }
        }
        let weekEnd = keys[6]

        // Metric changes
        var improved: [Item] = [], worsened: [Item] = []
        var recoveryUp = 0, recoveryDown = 0
        func add(_ c: Change?, higherIsBetter: Bool, threshold: Double, percent: Bool = false) {
            guard let c else { return }
            let delta = percent ? (c.changePct ?? 0) : c.change
            if abs(delta) < threshold { return }
            let better = higherIsBetter ? delta > 0 : delta < 0
            if better { improved.append(.metric(c)) } else { worsened.append(.metric(c)) }
            if c.metric == .charge || c.metric == .hrv || c.metric == .restingHr {
                if better { recoveryUp += 1 } else { recoveryDown += 1 }
            }
        }
        add(change(.sleep, vals(keys) { $0.totalSleepMin }, vals(lastKeys) { $0.totalSleepMin }),
            higherIsBetter: true, threshold: sleepChangeMin)
        add(change(.charge, vals(keys) { $0.recovery }, vals(lastKeys) { $0.recovery }),
            higherIsBetter: true, threshold: chargeChange)
        add(change(.hrv, vals(keys) { $0.avgHrv }, vals(lastKeys) { $0.avgHrv }),
            higherIsBetter: true, threshold: hrvChangePct, percent: true)
        add(change(.restingHr, vals(keys) { $0.restingHr.map(Double.init) },
                   vals(lastKeys) { $0.restingHr.map(Double.init) }),
            higherIsBetter: false, threshold: restingHrChange)
        let wakeThis = keys.compactMap { i.wakeMinutesByDay[$0] }.map(Double.init)
        let wakeLast = lastKeys.compactMap { i.wakeMinutesByDay[$0] }.map(Double.init)
        if wakeThis.count >= minWakeNights, wakeLast.count >= minWakeNights {
            add(makeChange(.wakeSpread, populationSd(wakeThis), populationSd(wakeLast)),
                higherIsBetter: false, threshold: wakeSpreadChange)
        }
        if let t = finite(i.timeInRangeThisWeek), let l = finite(i.timeInRangeLastWeek) {
            add(makeChange(.timeInRange, t, l), higherIsBetter: true, threshold: timeInRangeChange)
        }

        // Records and bests (always improvements)
        let records = strengthRecords(i.wods, from: keys[0], to: weekEnd)
        let bests = wodBests(i.wods, from: keys[0], to: weekEnd)
        for r in records { improved.append(.strengthRecord(name: r.name, weightKg: r.weightKg)) }
        for b in bests { improved.append(.wodBest(b)) }
        let performanceUp = !records.isEmpty || !bests.isEmpty

        // Load
        let efforts: [(day: String, effort: Double?)] = i.days.map { (day: $0.day, effort: $0.strain) }
        let ratio = TrainingLoad.summary(days: efforts, today: weekEnd).ratio.flatMap { $0.isFinite ? $0 : nil }

        // Headline
        let sleepUp = improved.contains { if case .metric(let c) = $0 { return c.metric == .sleep } else { return false } }
        let sleepDown = worsened.contains { if case .metric(let c) = $0 { return c.metric == .sleep } else { return false } }
        let headline: Headline
        if sleepUp && performanceUp { headline = .bothBetter }
        else if sleepDown && performanceUp { headline = .strongerLessSleep }
        else if recoveryUp >= 1 && recoveryDown == 0 { headline = .betterRecovery }
        else if let r = ratio, r > heavyRatio { headline = .heavyWeek }
        else if let r = ratio, r < lowRatio { headline = .quietWeek }
        else { headline = .steady }

        // One thing
        let need = i.sleepNeedMin ?? defaultNeedMin
        let sleepThis = vals(keys) { $0.totalSleepMin }
        var one: OneThing = .keepGoing
        let shortAverage = sleepThis.count >= 4 && need - mean(sleepThis) > shortSleepMargin
        let inDebt = (finite(i.sleepDebtMin) ?? 0) >= debtMinutes
        if shortAverage || inDebt {
            let shortNights = sleepThis.filter { $0 < need }.count
            one = .earlierBedtime(evenings: min(max(shortNights, 3), 5), bedtimeMinutes: i.bedtimeMinutes)
        } else if wakeThis.count >= minWakeNights, populationSd(wakeThis) > irregularWakeSd {
            one = .steadyWake(sdMinutes: Int(populationSd(wakeThis).rounded()))
        } else if let r = ratio, r >= sharpRiseRatio {
            one = .oneEasierDay
        } else if let r = ratio, r < lowRatio {
            one = .oneMoreSession
        }

        let adherence = computeAdherence(i, byDay: byDay, keys: keys)
        return .ready(Review(weekStart: i.weekStart, weekEnd: weekEnd, days: cells, daysWithData: withData,
                             improved: improved, worsened: worsened, headline: headline, oneThing: one,
                             adherence: adherence, loadRatio: ratio))
    }

    // MARK: - Pieces

    /// Level from a Charge with the plan's bands.
    public static func level(charge c: Double) -> DayPlan.Training {
        if c >= pushCharge { return .push }
        if c >= maintainCharge { return .maintain }
        return .easy
    }

    static func cell(_ d: DailyMetric?, day: String) -> DayCell {
        guard let c = finite(d?.recovery) else { return DayCell(day: day, charge: nil, level: nil) }
        return DayCell(day: day, charge: Int(c.rounded()), level: level(charge: c))
    }

    static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

    static func populationSd(_ v: [Double]) -> Double {
        let m = mean(v)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    static func makeChange(_ metric: Metric, _ this: Double, _ last: Double) -> Change {
        Change(metric: metric, thisWeek: this, lastWeek: last, change: this - last,
               changePct: last > 0 ? (this - last) / last * 100 : nil)
    }

    private static func change(_ metric: Metric, _ this: [Double], _ last: [Double]) -> Change? {
        guard this.count >= minDaysPerMetric, last.count >= minDaysPerMetric else { return nil }
        return makeChange(metric, mean(this), mean(last))
    }

    static func strengthRecords(_ wods: [WodLogRow], from: String, to: String) -> [(name: String, weightKg: Double)] {
        var out: [(name: String, weightKg: Double)] = []
        for m in StrengthProgress.movements(from: wods) {
            let loads = m.entries.filter { $0.isRecord && $0.day >= from && $0.day <= to }.map(\.weightKg)
            if let top = loads.max() { out.append((m.displayName, top)) }
        }
        return out.sorted { $0.weightKg != $1.weightKg ? $0.weightKg > $1.weightKg : $0.name < $1.name }
    }

    static func wodBests(_ wods: [WodLogRow], from: String, to: String) -> [WodBest] {
        var latest: [String: WodBest] = [:]
        for g in WodRanking.groupByTitle(wods) {
            let rows = g.rows
            let kind = WodRanking.primaryKind(of: rows)
            guard kind != .none else { continue }
            let ranked = rows.filter { $0.effectiveResultKind == kind }
                .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }
            for (idx, r) in ranked.enumerated() where r.day >= from && r.day <= to {
                let grp = WodRanking.group(of: r, among: rows)
                let earlier = ranked[..<idx].filter { WodRanking.group(of: $0, among: rows) == grp }
                if !earlier.isEmpty, earlier.allSatisfy({ WodRanking.isBetter(r, than: $0) }) {
                    latest["\(WodRanking.titleKey(g.title))|\(grp)"] = WodBest(title: g.title, row: r)
                }
            }
        }
        return latest.values.sorted {
            let a = $0.title.lowercased(), b = $1.title.lowercased()
            return a != b ? a < b : $0.row.ts < $1.row.ts
        }
    }

    static func computeAdherence(_ i: Inputs, byDay: [String: DailyMetric], keys: [String]) -> Adherence? {
        var efforts: [Double] = []
        for k in 0..<28 {
            if let key = FitnessAgeEngine.shiftDay(keys[6], by: -k), let s = finite(byDay[key]?.strain) { efforts.append(s) }
        }
        guard efforts.count >= minEffortDaysForThirds,
              let lo = DayPlan.percentile(efforts, 1.0 / 3.0), let hi = DayPlan.percentile(efforts, 2.0 / 3.0) else { return nil }
        var judged = 0, matched = 0
        for k in keys {
            guard let d = byDay[k], let s = finite(d.strain) else { continue }
            let level = i.planLevelByDay[k] ?? finite(d.recovery).map { WeeklyReview.level(charge: $0) }
            guard let level else { continue }
            judged += 1
            switch level {
            case .push: if s >= hi { matched += 1 }
            case .easy: if s <= lo { matched += 1 }
            case .maintain: if s > lo && s < hi { matched += 1 }
            }
        }
        return judged >= minAdherenceDays ? Adherence(judged: judged, matched: matched) : nil
    }
}
