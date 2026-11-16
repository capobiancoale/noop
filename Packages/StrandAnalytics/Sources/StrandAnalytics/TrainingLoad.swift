import Foundation

// TrainingLoad.swift — "this week's training load vs your usual", from the daily Effort history.
//
// A plain comparison of the last 7 days with the four weeks before them, so a load that climbs fast is
// noticed. NOT an injury predictor and NOT advice (see Impellizzeri et al. below): the app only says how this
// week compares with the weeks before.
//
//   • Daily load is the day's Edwards TRIMP (arbitrary units). NOOP stores each day's Effort (0–100) in
//     `DailyMetric.strain`, made from TRIMP by `StrainScorer.trimpToStrain`:
//         effort = maxStrain · ln(TRIMP + 1) / ln(D)        (maxStrain 100, D = 7201)
//     Effort is logarithmic, so Effort values must never be summed or averaged as if they were load. They are
//     turned back into TRIMP first:  TRIMP = exp(effort · ln(D) / maxStrain) − 1.  The stored Effort already
//     includes the logged-WOD session-RPE excess (Foster et al. 2001; Tibana et al. 2018), so nothing more is
//     added here. Days imported from a WHOOP export carry WHOOP's strain rescaled to 0–100; undoing the
//     logarithm on those is an approximation (WHOOP's curve is not NOOP's), which is fine for a comparison of
//     a person's own weeks.
//   • Acute load = Σ TRIMP over the last 7 days (today and the 6 days before).
//   • Chronic load = the usual WEEK of the 4 weeks before those 7 days (days 8–35 back, counting today as
//     day 1): the mean daily TRIMP of the days there that have an Effort, × 7. The chronic window
//     deliberately leaves the acute week out ("uncoupled": Lolli et al. 2019; Windt & Gabbett 2019), so the
//     ratio is not pulled toward 1 by the two windows sharing days.
//   • Ratio = this week's mean daily load ÷ the usual mean daily load (the acute:chronic ratio of Gabbett
//     2016, Br J Sports Med 50:273, on daily means). Gabbett reported 0.8–1.3 as the "sweet spot".
//     Impellizzeri et al. 2020 (Int J Sports Physiol Perform) showed the ratio is NOT a validated injury
//     predictor, so the bands below are readings of the number, never a risk statement.
//   • A day without an Effort is unknown, not zero training. Both windows are compared on the days that have
//     data (daily means), so a few unworn days in either window don't skew the ratio (a sum ÷ 4 over a
//     chronic window with 22 of 28 days read the usual week 21 % low); the ratio is only given when both
//     windows are mostly covered (see `Summary`). A recorded Effort of 0 is a known easy day.
//
// Pure maths on "yyyy-MM-dd" day keys (no time zone, no clock): the caller says what "today" is.
public enum TrainingLoad {

    // MARK: - Windows and gates

    /// Length of the acute block, and of every rolling block in `Summary.weeks`.
    public static let blockDays = 7
    /// How many weekly blocks make up the chronic window (days 8–35 back).
    public static let chronicWeeks = 4
    /// The acute week needs at least this many days with an Effort before a ratio is shown.
    public static let minAcuteDays = 4
    /// The chronic window (28 days) needs at least this many days with an Effort before a ratio, or a
    /// "usual week", is shown. Two weeks of five is about the least that says anything about a usual week.
    public static let minChronicDays = 14

    // MARK: - Effort → TRIMP

    /// The training impulse (arbitrary units) that produces `effort` through `StrainScorer.trimpToStrain`:
    /// `exp(effort · ln(D) / maxStrain) − 1`. 0 for an Effort of 0 or less (and for a non-finite one), since
    /// `trimpToStrain` maps TRIMP ≤ 0 to 0. Effort is stored to 2 decimals, so the round trip is only as
    /// exact as that rounding.
    public static func trimp(fromEffort e: Double) -> Double {
        guard e.isFinite, e > 0 else { return 0 }
        return exp(e * StrainScorer.lnStrainDenominator / StrainScorer.maxStrain) - 1
    }

    // MARK: - Bands

    /// How this week reads against the usual, as a plain word. Not a risk level.
    public enum Band: String, Sendable {
        /// Ratio below 0.8: less than usual.
        case below
        /// 0.8 up to and including 1.3: in line with the usual.
        case steady
        /// Above 1.3 up to and including 1.5: more than usual.
        case higher
        /// Above 1.5: a sharp rise on the usual.
        case sharpRise
    }

    /// The band for an acute:chronic ratio (finite and ≥ 0). Edges: < 0.8 below, ≤ 1.3 steady, ≤ 1.5 higher,
    /// else a sharp rise.
    public static func band(ratio: Double) -> Band {
        if ratio < 0.8 { return .below }
        if ratio <= 1.3 { return .steady }
        if ratio <= 1.5 { return .higher }
        return .sharpRise
    }

    // MARK: - Summary

    /// One rolling 7-day block: `start`…`end` inclusive ("yyyy-MM-dd").
    public struct Week: Equatable, Sendable {
        public let start: String
        public let end: String
        /// Σ TRIMP of the days that have an Effort (a day without one adds nothing, it is not filled in).
        public let load: Double
        /// How many of the 7 days have an Effort.
        public let daysWithData: Int

        public init(start: String, end: String, load: Double, daysWithData: Int) {
            self.start = start; self.end = end; self.load = load; self.daysWithData = daysWithData
        }
    }

    public struct Summary: Equatable, Sendable {
        /// Σ TRIMP over the last 7 days (today and the 6 before).
        public let acute: Double
        /// Days among those 7 that have an Effort.
        public let acuteDays: Int
        /// The usual week: the mean daily TRIMP of the days 8–35 back that have an Effort, × 7; nil when
        /// fewer than `minChronicDays` of those 28 days have one.
        public let chronicWeekly: Double?
        /// Days among those 28 that have an Effort.
        public let chronicDays: Int
        /// This week's mean daily TRIMP ÷ the usual mean daily TRIMP (both over days with an Effort); nil
        /// unless the acute week has ≥ `minAcuteDays` days with an Effort, the chronic window has
        /// ≥ `minChronicDays`, and the usual load is above 0.
        public let ratio: Double?
        /// The band of `ratio`; nil exactly when `ratio` is.
        public let band: Band?
        /// Rolling 7-day blocks ending on `today` and stepping back 7 days each, oldest → newest; the last
        /// one is the acute week.
        public let weeks: [Week]

        public init(acute: Double, acuteDays: Int, chronicWeekly: Double?, chronicDays: Int,
                    ratio: Double?, band: Band?, weeks: [Week]) {
            self.acute = acute; self.acuteDays = acuteDays; self.chronicWeekly = chronicWeekly
            self.chronicDays = chronicDays; self.ratio = ratio; self.band = band; self.weeks = weeks
        }
    }

    /// The training-load comparison as of `today`.
    ///
    /// - Parameters:
    ///   - days: one entry per day, `effort` being the stored daily Effort (0–100) or nil when the day has
    ///     none. A nil, non-finite or negative Effort is ignored (the day is unknown), and for a repeated day
    ///     the last usable entry wins. An Effort above `StrainScorer.maxStrain` cannot be produced by the
    ///     scorer and is capped at it.
    ///   - today: the "yyyy-MM-dd" day the acute week ends on.
    ///   - weeks: how many rolling 7-day blocks to return in `Summary.weeks` (at least 1). The acute and
    ///     chronic figures do not depend on it.
    ///
    /// Gaps are unknown days: sums (`acute`, each week's `load`) add only the recorded days, and the ratio
    /// compares daily means over the recorded days, which is why it needs both windows to be mostly covered
    /// (`minAcuteDays`, `minChronicDays`).
    public static func summary(days: [(day: String, effort: Double?)], today: String, weeks: Int = 8) -> Summary {
        let blocks = max(1, weeks)
        // Look-back, in days, that covers the acute week, the chronic window and every returned block.
        let span = max(blockDays * (1 + chronicWeeks), blockDays * blocks)

        var trimpByDay: [String: Double] = [:]
        for d in days {
            guard let e = d.effort, e.isFinite, e >= 0 else { continue }
            trimpByDay[d.day] = trimp(fromEffort: min(e, StrainScorer.maxStrain))
        }

        // keys[k] is the day k days before today ("yyyy-MM-dd"); trimps[k] its TRIMP, nil when unknown.
        var keys: [String] = []
        var trimps: [Double?] = []
        keys.reserveCapacity(span)
        trimps.reserveCapacity(span)
        for k in 0..<span {
            guard let key = FitnessAgeEngine.shiftDay(today, by: -k) else {
                // An unparseable "today": nothing to anchor the windows on.
                return Summary(acute: 0, acuteDays: 0, chronicWeekly: nil, chronicDays: 0,
                               ratio: nil, band: nil, weeks: [])
            }
            keys.append(key)
            trimps.append(trimpByDay[key])
        }

        func total(_ range: Range<Int>) -> (load: Double, days: Int) {
            var load = 0.0
            var n = 0
            for k in range {
                if let t = trimps[k] { load += t; n += 1 }
            }
            return (load, n)
        }

        let acute = total(0..<blockDays)
        let chronicRange = blockDays..<(blockDays * (1 + chronicWeeks))
        let chronic = total(chronicRange)

        var chronicWeekly: Double?
        if chronic.days >= minChronicDays { chronicWeekly = chronic.load / Double(chronic.days) * Double(blockDays) }

        var ratio: Double?
        if acute.days >= minAcuteDays, let usual = chronicWeekly, usual > 0 {
            ratio = (acute.load / Double(acute.days) * Double(blockDays)) / usual
        }

        var rolling: [Week] = []
        rolling.reserveCapacity(blocks)
        for j in stride(from: blocks - 1, through: 0, by: -1) {
            let first = blockDays * j
            let t = total(first..<(first + blockDays))
            rolling.append(Week(start: keys[first + blockDays - 1], end: keys[first],
                                load: t.load, daysWithData: t.days))
        }

        return Summary(acute: acute.load, acuteDays: acute.days, chronicWeekly: chronicWeekly,
                       chronicDays: chronic.days, ratio: ratio, band: ratio.map { band(ratio: $0) },
                       weeks: rolling)
    }
}
