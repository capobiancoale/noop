import Foundation

// MARK: - Blood pressure (measured values only)
//
// NOOP shows blood pressure that was MEASURED: a cuff that writes to Apple Health, or a reading the
// user types into the Lab Book. It never estimates it. A cuffless estimate from a wrist optical
// sensor is not validated without a cuff calibration: the European Society of Hypertension's
// statement on cuffless devices (Stergiou et al., J Hypertens 2022; 40:1449-1460) and the
// ISO 81060-3:2022 standard for continuous non-invasive devices both require calibration and
// dedicated validation, and the strap hands NOOP only heart rate and beat-to-beat intervals, not the
// optical waveform such an estimate would need.
//
// What lives here is pure and platform-free so it is unit-tested:
//   - the ESH 2023 category for a reading (`classify`),
//   - pairing the systolic and diastolic daily series,
//   - merging Apple Health and Lab Book readings into one value per day (`mergeDaily`),
//   - the "latest reading and 30-day averages" summary behind the metric-detail card (`summary`).
//
// INFORMATIONAL ONLY, not medical advice. The category words are the guideline's own labels for a
// number; a single reading, or an average of readings taken in different conditions, is not a
// diagnosis (the guideline itself asks for repeated office or home measurements before one).

/// Blood-pressure classification and daily merging of measured readings.
public enum BloodPressure {

    // MARK: Keys

    /// The metric keys the two halves of a reading are stored under (Apple Health daily aggregate and
    /// Lab Book marker alike).
    public static let systolicKey = "bp_systolic"
    public static let diastolicKey = "bp_diastolic"

    // MARK: Category (ESH 2023)

    /// The blood-pressure categories of the 2023 ESH hypertension guidelines (Mancia et al., J
    /// Hypertens 2023; 41:1874-2071: the classification of office blood pressure). Cases run from
    /// lowest to highest, except `isolatedSystolic`, which is its own row of the table.
    public enum Category: Int, CaseIterable, Sendable {
        case optimal = 0        // < 120 and < 80
        case normal             // 120-129 and/or 80-84
        case highNormal         // 130-139 and/or 85-89
        case grade1             // 140-159 and/or 90-99
        case grade2             // 160-179 and/or 100-109
        case grade3             // >= 180 and/or >= 110
        case isolatedSystolic   // >= 140 and < 90
    }

    /// The ESH 2023 category of a reading in mmHg, or nil when either value is missing, not finite or
    /// not positive.
    ///
    /// Rules, straight from the guideline's table: systolic and diastolic each fall in a band; when
    /// they fall in different bands the HIGHER category wins ("and/or"). A systolic of 140 or more
    /// with a diastolic below 90 is the separate "isolated systolic hypertension" row.
    ///
    /// Blood pressure is reported in whole mmHg, so both values are rounded to the nearest mmHg
    /// first (a daily mean of 129.5 is shown as 130, so it is classified as 130). Halves round up.
    public static func classify(systolic: Double, diastolic: Double) -> Category? {
        guard systolic.isFinite, diastolic.isFinite, systolic > 0, diastolic > 0 else { return nil }
        let sys = systolic.rounded(.toNearestOrAwayFromZero)
        let dia = diastolic.rounded(.toNearestOrAwayFromZero)
        if sys >= 140 && dia < 90 { return .isolatedSystolic }
        let bySystolic = systolicBand(sys)
        let byDiastolic = diastolicBand(dia)
        return bySystolic.rawValue >= byDiastolic.rawValue ? bySystolic : byDiastolic
    }

    /// The category the systolic value alone falls in (never `isolatedSystolic`).
    private static func systolicBand(_ sys: Double) -> Category {
        switch sys {
        case ..<120: return .optimal
        case ..<130: return .normal
        case ..<140: return .highNormal
        case ..<160: return .grade1
        case ..<180: return .grade2
        default:     return .grade3
        }
    }

    /// The category the diastolic value alone falls in (never `isolatedSystolic`).
    private static func diastolicBand(_ dia: Double) -> Category {
        switch dia {
        case ..<80:  return .optimal
        case ..<85:  return .normal
        case ..<90:  return .highNormal
        case ..<100: return .grade1
        case ..<110: return .grade2
        default:     return .grade3
        }
    }

    // MARK: Daily readings

    /// One local day with both halves of a reading.
    public struct DayReading: Equatable, Sendable {
        /// `yyyy-MM-dd`, the local civil day.
        public let day: String
        public let systolic: Double
        public let diastolic: Double

        public init(day: String, systolic: Double, diastolic: Double) {
            self.day = day
            self.systolic = systolic
            self.diastolic = diastolic
        }

        /// The ESH category of this day's values.
        public var category: Category? { BloodPressure.classify(systolic: systolic, diastolic: diastolic) }
    }

    /// Days that have BOTH a systolic and a diastolic value, ascending by day. A day with only one
    /// half is dropped: half a reading is not a blood pressure.
    public static func pair(systolic: [(day: String, value: Double)],
                            diastolic: [(day: String, value: Double)]) -> [DayReading] {
        let dia = Dictionary(diastolic.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Keyed by day so a repeated day keeps its last value, then sorted so the result is ascending
        // for any input order.
        var byDay: [String: DayReading] = [:]
        for s in systolic {
            guard let d = dia[s.day] else { continue }
            byDay[s.day] = DayReading(day: s.day, systolic: s.value, diastolic: d)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// One value per local day from every measured reading.
    ///
    /// - Parameters:
    ///   - appleDaily: Apple Health's per-day value. Apple Health is read as a daily mean, so each day
    ///     counts as ONE reading here (the number of cuff readings behind it is not stored).
    ///   - labReadings: every Lab Book reading, one entry per measurement, several allowed per day.
    /// - Returns: the arithmetic mean of that day's readings, ascending by day. A day with only Apple
    ///   Health data keeps Apple's value; a day with only Lab Book data is the mean of its readings;
    ///   a day with both is the mean of Apple's value and each Lab Book reading. Non-finite values are
    ///   ignored.
    public static func mergeDaily(appleDaily: [(day: String, value: Double)],
                                  labReadings: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        var sums: [String: (sum: Double, n: Int)] = [:]
        for r in appleDaily + labReadings where r.value.isFinite {
            let cur = sums[r.day] ?? (0, 0)
            sums[r.day] = (cur.sum + r.value, cur.n + 1)
        }
        return sums.keys.sorted().compactMap { day in
            guard let s = sums[day], s.n > 0 else { return nil }
            return (day: day, value: s.sum / Double(s.n))
        }
    }

    // MARK: Summary (metric-detail card)

    /// The latest reading and the recent averages shown on the blood-pressure card.
    public struct Summary: Equatable, Sendable {
        /// The most recent day that has both values.
        public let latest: DayReading
        /// Mean of the daily systolic / diastolic values over the trailing window ending `today`, or
        /// nil when no day in the window has a reading.
        public let avgSystolic: Double?
        public let avgDiastolic: Double?
        /// How many days in the window have a reading.
        public let daysInWindow: Int

        public init(latest: DayReading, avgSystolic: Double?, avgDiastolic: Double?, daysInWindow: Int) {
            self.latest = latest
            self.avgSystolic = avgSystolic
            self.avgDiastolic = avgDiastolic
            self.daysInWindow = daysInWindow
        }
    }

    /// The latest paired day plus the mean of the daily values over the `windowDays` days ending on
    /// `today` (inclusive). The average is the mean of DAILY values, so a day with several readings
    /// weighs the same as a day with one. Nil when there is no paired day at all.
    public static func summary(_ days: [DayReading], today: String, windowDays: Int = 30) -> Summary? {
        guard let latest = days.max(by: { $0.day < $1.day }) else { return nil }
        guard windowDays > 0, let start = shift(day: today, by: -(windowDays - 1)) else {
            return Summary(latest: latest, avgSystolic: nil, avgDiastolic: nil, daysInWindow: 0)
        }
        let inWindow = days.filter { $0.day >= start && $0.day <= today }
        guard !inWindow.isEmpty else {
            return Summary(latest: latest, avgSystolic: nil, avgDiastolic: nil, daysInWindow: 0)
        }
        let n = Double(inWindow.count)
        return Summary(latest: latest,
                       avgSystolic: inWindow.reduce(0) { $0 + $1.systolic } / n,
                       avgDiastolic: inWindow.reduce(0) { $0 + $1.diastolic } / n,
                       daysInWindow: inWindow.count)
    }

    // MARK: Day arithmetic

    /// `yyyy-MM-dd` shifted by whole days on the civil calendar (UTC arithmetic, so a DST change in
    /// the user's zone can never move the result by a day). Nil for an unparseable day.
    static func shift(day: String, by days: Int) -> String? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              let shifted = cal.date(byAdding: .day, value: days, to: date) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
