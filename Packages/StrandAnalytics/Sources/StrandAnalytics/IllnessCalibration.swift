import Foundation

// IllnessCalibration.swift — personal FALSE-ALARM calibration for the illness heads-up. Pure,
// deterministic, DB-free.
//
// WHAT CAN BE CALIBRATED ON ONE PERSON'S DATA, AND WHAT CANNOT. A person is ill one to three times a
// year: far too few events to estimate how often the detector catches a real illness (its sensitivity).
// But every healthy day is a data point on the opposite question: how often would the detector have
// cried wolf (its false-alarm rate, 1 − specificity)? So NOOP fixes the false-alarm rate on the user's
// own history and keeps the detector as it is. That is a Neyman–Pearson style choice (fix the
// false-alarm rate, then use the most powerful detector available), and it is how Temple et al. set
// their alarm threshold in a wearable influenza challenge study: the classification threshold was set so
// that no alarm was recorded in the 170 healthy days (J Infect Dis 2023;227:864–872). The sensitivity of
// the heads-up to a real illness stays a property of the published studies, never of this calibration.
//
// METHOD
//   1. REPLAY every past day that has the full 31-entry window behind it (no look-ahead: day d uses only
//      days ≤ d), building the engine inputs with `IllnessSignalEngine.inputs(history:endingAt:)` and the
//      score with `IllnessSignalEngine.composite`, the very code the live alert runs.
//   2. HEALTHY days are those on which the heads-up could have fired and nothing explains a signal:
//      a trusted baseline, at least two of the four signals present, no confounder on the day (alcohol,
//      hard or late workout, a low glucose at night, stress, sauna, travel), and not within ±7 days of a
//      day the user logged feeling unwell (the days before and after an illness are not "healthy").
//   3. An ALARM EPISODE is a run of consecutive calendar days that would each RAISE (≥ 2 firing signals
//      and a score at or above the threshold). Episodes are counted, not days: the user feels one alarm
//      per run.
//   4. Choose the smallest personal raise threshold T in [50, 100], never below the shipped 50, whose
//      episode rate on the healthy days is at most one per 60 days. If even T = 100 misses that target,
//      use 100 and report the achieved rate honestly.
//   5. Report the number of healthy days N, the episodes k at T, the empirical rate k / N and the 95 %
//      one-sided Clopper–Pearson upper bound of the per-day alarm rate (Clopper & Pearson, Biometrika
//      1934;26:404–413). For k = 0 that bound is 1 − 0.05^(1/N), about 3 / N.
//   6. Active only with at least 120 healthy replayable days; before that the shipped thresholds apply
//      and the result says how many days are still missing.
public enum IllnessCalibration {

    // MARK: - Constants (pinned by test)

    /// Healthy replayable days needed before the calibration is trusted enough to change the threshold.
    public static let minimumHealthyDays = 120
    /// Target false-alarm rate: at most one alarm episode per this many healthy days.
    public static let targetDaysPerAlarm = 60
    /// Search range for the personal raise threshold. The floor is the shipped default: calibration may
    /// only make the heads-up stricter. The ceiling is the top of the 0–100 composite.
    public static let thresholdFloor = IllnessSignalEngine.raiseThreshold
    public static let thresholdCeiling = 100.0
    /// Grid step of the threshold search.
    public static let thresholdStep = 1.0
    /// A day within this many calendar days of a day logged as unwell is not a healthy day.
    public static let unwellMarginDays = 7
    /// Confidence level of the one-sided upper bound on the per-day alarm rate.
    public static let upperBoundConfidence = 0.95
    /// First replayable entry: the engine needs the full 31-entry window behind a day.
    public static let firstReplayIndex = IllnessSignalEngine.baselineSpan - 1
    /// Recompute when the history grew by this many days, or after this many calendar days.
    public static let recomputeAfterDays = 30
    /// Bumped whenever the method changes, so a stored result from an older method is recomputed.
    public static let version = 1

    // MARK: - Inputs

    /// Behaviours and events on one day that explain a signal away. Any one makes the day not healthy.
    public struct DayFlags: Equatable, Sendable {
        public var alcohol: Bool
        public var stress: Bool
        public var sauna: Bool
        public var hardOrLateWorkout: Bool
        public var travel: Bool
        public var nocturnalLow: Bool
        public init(alcohol: Bool = false, stress: Bool = false, sauna: Bool = false,
                    hardOrLateWorkout: Bool = false, travel: Bool = false, nocturnalLow: Bool = false) {
            self.alcohol = alcohol; self.stress = stress; self.sauna = sauna
            self.hardOrLateWorkout = hardOrLateWorkout; self.travel = travel
            self.nocturnalLow = nocturnalLow
        }
        /// True iff at least one confounder is present.
        public var any: Bool {
            alcohol || stress || sauna || hardOrLateWorkout || travel || nocturnalLow
        }
    }

    /// What a journal question means for the illness watch. A plain substring match on the lowercased
    /// question, exactly as the live alert has always read the journal, so the calibration and the live
    /// alert classify every entry the same way.
    public struct QuestionTags: Equatable, Sendable {
        public var alcohol = false
        public var workout = false
        public var unwell = false
        public init(alcohol: Bool = false, workout: Bool = false, unwell: Bool = false) {
            self.alcohol = alcohol; self.workout = workout; self.unwell = unwell
        }
    }

    public static func tags(forQuestion question: String) -> QuestionTags {
        let q = question.lowercased()
        return QuestionTags(
            alcohol: q.contains("alcohol") || q.contains("drink"),
            workout: q.contains("workout") || q.contains("train") || q.contains("exercise"),
            unwell: q.contains("sick") || q.contains("ill") || q.contains("unwell"))
    }

    /// Per-day confounder flags and the days logged as unwell, from journal answers (a "yes" only) and
    /// the days with a low glucose at night. Only the confounders the LIVE alert suppresses on (alcohol,
    /// a workout, a night low) are flagged: a day the live alert would have raised on anyway is a real
    /// alarm opportunity, so it must count toward the false-alarm rate.
    public static func dayFlags(
        entries: [(day: String, question: String, answeredYes: Bool)],
        nightLowDays: Set<String>
    ) -> (flags: [String: DayFlags], unwellDays: Set<String>) {
        var flags: [String: DayFlags] = [:]
        var unwell = Set<String>()
        for e in entries where e.answeredYes {
            let t = tags(forQuestion: e.question)
            if t.alcohol { flags[e.day, default: DayFlags()].alcohol = true }
            if t.workout { flags[e.day, default: DayFlags()].hardOrLateWorkout = true }
            if t.unwell { unwell.insert(e.day) }
        }
        for day in nightLowDays { flags[day, default: DayFlags()].nocturnalLow = true }
        return (flags, unwell)
    }

    // MARK: - Output

    public struct Result: Equatable, Sendable, Codable {
        /// True iff there were enough healthy days for the personal threshold to apply.
        public let active: Bool
        /// The raise threshold in use: the personal one when active, else the shipped default.
        public let raiseThreshold: Double
        /// Healthy replayable days the calibration is based on.
        public let healthyDays: Int
        /// Healthy days still missing before the calibration starts (0 once active).
        public let missingDays: Int
        /// Alarm episodes the healthy days would have produced at `raiseThreshold`.
        public let episodes: Int
        /// Empirical alarm-episode rate per healthy day (`episodes / healthyDays`), nil without days.
        public let alarmRate: Double?
        /// 95 % one-sided Clopper–Pearson upper bound of the per-day alarm rate, nil without days.
        public let alarmRateUpper95: Double?
        /// True iff `raiseThreshold` reaches the target of at most one episode per 60 healthy days.
        public let targetMet: Bool

        public init(active: Bool, raiseThreshold: Double, healthyDays: Int, missingDays: Int,
                    episodes: Int, alarmRate: Double?, alarmRateUpper95: Double?, targetMet: Bool) {
            self.active = active; self.raiseThreshold = raiseThreshold; self.healthyDays = healthyDays
            self.missingDays = missingDays; self.episodes = episodes; self.alarmRate = alarmRate
            self.alarmRateUpper95 = alarmRateUpper95; self.targetMet = targetMet
        }

        /// The personal threshold to hand to `IllnessSignalEngine.Context.personalRaiseThreshold`:
        /// nil while the calibration is not active (the shipped default applies).
        public var personalRaiseThreshold: Double? { active ? raiseThreshold : nil }

        /// Expected days between false alarms (`healthyDays / episodes`), nil when none occurred.
        public var daysPerAlarm: Double? {
            episodes > 0 ? Double(healthyDays) / Double(episodes) : nil
        }

        /// "At most one false alarm every this many days" at 95 %, rounded down so it never flatters.
        public var daysPerAlarmAtMost: Int? {
            guard let upper = alarmRateUpper95, upper > 0 else { return nil }
            return Int((1.0 / upper).rounded(.down))
        }
    }

    /// A calibration result with when it was computed, as persisted by the app.
    public struct Snapshot: Equatable, Sendable, Codable {
        public let result: Result
        /// Local day the calibration ran (YYYY-MM-DD).
        public let computedDay: String
        /// How many days of history it saw.
        public let historyDays: Int
        public let version: Int
        public init(result: Result, computedDay: String, historyDays: Int, version: Int = IllnessCalibration.version) {
            self.result = result; self.computedDay = computedDay
            self.historyDays = historyDays; self.version = version
        }

        /// True when the snapshot should be recomputed: the method changed, the history shrank (a
        /// reset or delete), the history grew by 30 days or more, or a month has passed.
        public func isStale(historyDays now: Int, today: String) -> Bool {
            if version != IllnessCalibration.version { return true }
            if now < historyDays { return true }
            if now - historyDays >= IllnessCalibration.recomputeAfterDays { return true }
            guard let a = IllnessCalibration.dayNumber(computedDay),
                  let b = IllnessCalibration.dayNumber(today) else { return true }
            return b - a >= IllnessCalibration.recomputeAfterDays || b < a
        }
    }

    // MARK: - Calibrate

    /// Replay `history` (oldest first) and choose the personal raise threshold.
    ///
    /// - Parameters:
    ///   - history: one entry per day, oldest first (the same series the live alert reads).
    ///   - flags: confounders by day key. The live alert reads the last two entries, so a day is only
    ///     healthy when neither of its two window entries carries a flag.
    ///   - unwellDays: day keys on which the user logged feeling unwell.
    public static func calibrate(history: [IllnessSignalEngine.DayVitals],
                                 flags: [String: DayFlags] = [:],
                                 unwellDays: Set<String> = []) -> Result {
        let days = healthyDays(history: history, flags: flags, unwellDays: unwellDays)
        let healthy = days.count
        func meetsTarget(_ k: Int) -> Bool { k * targetDaysPerAlarm <= healthy }

        var chosen = thresholdCeiling
        var chosenEpisodes = episodes(in: days, at: thresholdCeiling)
        var met = meetsTarget(chosenEpisodes)
        var t = thresholdFloor
        while t <= thresholdCeiling {
            let k = episodes(in: days, at: t)
            if meetsTarget(k) { chosen = t; chosenEpisodes = k; met = true; break }
            t += thresholdStep
        }

        guard healthy >= minimumHealthyDays else {
            // Not enough days: keep the shipped threshold and report the episodes it would have given.
            let k = episodes(in: days, at: thresholdFloor)
            return Result(active: false, raiseThreshold: thresholdFloor, healthyDays: healthy,
                          missingDays: minimumHealthyDays - healthy, episodes: k,
                          alarmRate: healthy > 0 ? Double(k) / Double(healthy) : nil,
                          alarmRateUpper95: healthy > 0 ? upperBound(episodes: k, days: healthy) : nil,
                          targetMet: healthy > 0 && meetsTarget(k))
        }
        return Result(active: true, raiseThreshold: chosen, healthyDays: healthy, missingDays: 0,
                      episodes: chosenEpisodes, alarmRate: Double(chosenEpisodes) / Double(healthy),
                      alarmRateUpper95: upperBound(episodes: chosenEpisodes, days: healthy),
                      targetMet: met)
    }

    /// One replayed healthy day: its day number, composite score and number of firing signals.
    typealias HealthyDay = (dayNumber: Int, score: Double, signalCount: Int)

    /// Replay every past day with the full window behind it and keep the healthy ones (see the method
    /// notes at the top of the file), each with the score and signal count the live path would compute.
    static func healthyDays(history: [IllnessSignalEngine.DayVitals], flags: [String: DayFlags],
                            unwellDays: Set<String>) -> [HealthyDay] {
        let unwell = unwellDays.compactMap { dayNumber($0) }
        var out: [HealthyDay] = []
        guard history.count > firstReplayIndex else { return out }
        for i in firstReplayIndex..<history.count {
            guard let n = dayNumber(history[i].day),
                  let window = IllnessSignalEngine.inputs(history: history, endingAt: i),
                  window.baselineTrusted,
                  presentCount(window.inputs) >= IllnessSignalEngine.minCorroboratingSignals
            else { continue }
            // The live alert reads the last two entries, so either one carrying a flag rules the day out.
            if flags[history[i].day]?.any == true || flags[history[i - 1].day]?.any == true { continue }
            if unwell.contains(where: { abs($0 - n) <= unwellMarginDays }) { continue }
            let c = IllnessSignalEngine.composite(window.inputs)
            out.append((dayNumber: n, score: c.score, signalCount: c.firedKeys.count))
        }
        return out
    }

    /// Alarm episodes the healthy days would have produced at a raise threshold.
    static func episodes(in days: [HealthyDay], at threshold: Double) -> Int {
        let raising = Set(days.compactMap { d -> Int? in
            IllnessSignalEngine.wouldRaise(score: d.score, signalCount: d.signalCount,
                                           personalRaiseThreshold: threshold) ? d.dayNumber : nil
        })
        return countEpisodes(raisingDays: raising)
    }

    /// Alarm episodes among the days (as day numbers) that would each raise: one per run of consecutive
    /// calendar days, i.e. the days whose previous day is not also raising.
    static func countEpisodes(raisingDays: Set<Int>) -> Int {
        raisingDays.filter { !raisingDays.contains($0 - 1) }.count
    }

    /// Number of signals with usable data in a window (not the number firing).
    static func presentCount(_ inputs: IllnessSignalEngine.Inputs) -> Int {
        [inputs.restingHR, inputs.skinTemp, inputs.hrv, inputs.respiration]
            .filter { $0?.present == true }.count
    }

    // MARK: - Statistics

    /// The 95 % one-sided Clopper–Pearson upper bound of a per-day alarm rate after `episodes` alarms in
    /// `days` healthy days.
    static func upperBound(episodes: Int, days: Int) -> Double {
        clopperPearsonUpper(successes: episodes, trials: days, confidence: upperBoundConfidence)
    }

    /// One-sided Clopper–Pearson upper confidence limit for a binomial proportion: the p at which
    /// P(X ≤ k | n, p) = 1 − confidence, i.e. the `confidence` quantile of Beta(k + 1, n − k). For k = 0
    /// it is the closed form 1 − (1 − confidence)^(1/n); for k = n it is 1.
    public static func clopperPearsonUpper(successes k: Int, trials n: Int, confidence: Double) -> Double {
        guard n > 0, k >= 0 else { return 1 }
        if k >= n { return 1 }
        let alpha = 1 - confidence
        if k == 0 { return 1 - pow(alpha, 1 / Double(n)) }
        let a = Double(k + 1), b = Double(n - k)
        var lo = 0.0, hi = 1.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if regularizedIncompleteBeta(mid, a: a, b: b) < confidence { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Regularized incomplete beta function I_x(a, b) for positive integer a and b (continued fraction,
    /// modified Lentz; Press et al., Numerical Recipes). Integer arguments let ln B(a, b) come from exact
    /// log-factorials, so nothing depends on a platform `lgamma`.
    static func regularizedIncompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnBeta = logFactorial(Int(a) - 1) + logFactorial(Int(b) - 1) - logFactorial(Int(a + b) - 1)
        let front = exp(a * log(x) + b * log(1 - x) - lnBeta)
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(x, a: a, b: b) / a
        }
        return 1 - front * betaContinuedFraction(1 - x, a: b, b: a) / b
    }

    private static func logFactorial(_ n: Int) -> Double {
        guard n > 1 else { return 0 }
        var s = 0.0
        for i in 2...n { s += log(Double(i)) }
        return s
    }

    private static func betaContinuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for step in 1...500 {
            let m = Double(step), m2 = 2 * m
            var aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 1e-15 { break }
        }
        return h
    }

    // MARK: - Calendar helper

    /// Days since 1970-01-01 for a "yyyy-MM-dd" key (proleptic Gregorian, Hinnant's days-from-civil), or
    /// nil for a malformed key. Pure integer maths: no calendar, time zone or locale involved.
    static func dayNumber(_ key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
