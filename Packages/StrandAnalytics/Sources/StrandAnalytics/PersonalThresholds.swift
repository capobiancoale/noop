import Foundation
import WhoopStore

// PersonalThresholds.swift — the cut-offs of "today's plan" read off THIS athlete's own Charge history instead of
// the fixed 67 / 34 and 6 h. Pure and deterministic: no clock, no UserDefaults; the caller says what "today" is.
//
// Rules
//  1. Window: the 90 days BEFORE `today` (today's own Charge is the thing being judged, so it does not move the
//     bar it is judged against). A day counts when its row has a finite Charge (`recovery`).
//  2. With at least 30 such days: push = above the 67th percentile, easy = below the 33rd (linear interpolation,
//     "type 7", `DayPlan.percentile`) of those Charge values; in between is maintain. With fewer, `pushAbove` and
//     `easyBelow` are nil and the plan keeps the standard 67 / 34.
//  3. Short night: `PlanLearning.personalSleepThresholdMinutes(days:today:)` when it returns a value (it has its
//     own gates: >= 10 days on each side and a gap of >= 5 Charge points), else nil and the plan keeps 6 h.
// Percentiles of one person's own scores describe how he scores, not how hard he should train. Not advice.
public enum PersonalThresholds {

    public static let windowDays = 90
    public static let minChargeDays = 30
    public static let pushPercentile = 0.67
    public static let easyPercentile = 0.33

    public struct Result: Equatable, Sendable {
        /// Push when Charge is strictly above this; nil until `minChargeDays` days exist.
        public let pushAbove: Double?
        /// Easy when Charge is strictly below this; nil until `minChargeDays` days exist.
        public let easyBelow: Double?
        /// Days with a Charge in the window (what the thresholds rest on, or will rest on).
        public let chargeDays: Int
        /// The athlete's own short-night cut in minutes, when `PlanLearning` found one.
        public let shortNightMinutes: Int?
        public init(pushAbove: Double?, easyBelow: Double?, chargeDays: Int, shortNightMinutes: Int?) {
            self.pushAbove = pushAbove; self.easyBelow = easyBelow
            self.chargeDays = chargeDays; self.shortNightMinutes = shortNightMinutes
        }

        /// True when the Charge cut-offs are the athlete's own.
        public var hasPersonalCharge: Bool { pushAbove != nil && easyBelow != nil }
        /// Days still to wait before the Charge cut-offs are personal: 30 minus the days available, at least 1.
        public var daysUntilPersonal: Int { max(1, PersonalThresholds.minChargeDays - chargeDays) }
    }

    public static func compute(days: [DailyMetric], today: String) -> Result {
        let values = chargeValues(days: days, today: today)
        let sleepCut = PlanLearning.personalSleepThresholdMinutes(days: days, today: today)
        guard values.count >= minChargeDays,
              let push = DayPlan.percentile(values, pushPercentile),
              let easy = DayPlan.percentile(values, easyPercentile) else {
            return Result(pushAbove: nil, easyBelow: nil, chargeDays: values.count, shortNightMinutes: sleepCut)
        }
        return Result(pushAbove: push, easyBelow: easy, chargeDays: values.count, shortNightMinutes: sleepCut)
    }

    /// Median of the athlete's own Charge over the 90 days before `today`; nil with fewer than 14 days.
    public static func medianCharge(days: [DailyMetric], today: String) -> Double? {
        let values = chargeValues(days: days, today: today)
        guard values.count >= 14 else { return nil }
        return DayPlan.median(values)
    }

    static func chargeValues(days: [DailyMetric], today: String) -> [Double] {
        guard let from = FitnessAgeEngine.shiftDay(today, by: -windowDays) else { return [] }
        var byDay: [String: Double] = [:]
        for d in days where d.day >= from && d.day < today {
            if let c = d.recovery, c.isFinite { byDay[d.day] = c }
        }
        return Array(byDay.values)
    }
}
