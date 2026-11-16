import Foundation
import WhoopStore

// DayPlan.swift — "today's plan": how hard to train, how long to sleep tonight, rough energy / protein /
// carbohydrate / fluid ranges, and up to three things to work on. Pure and deterministic: no clock, no
// UserDefaults, no Calendar.current, no localized text. The output is keys and numbers; the app builds the words.
//
// NOT MEDICAL ADVICE. These are general sports-science rules of thumb read off a consumer strap. Insulin is
// never computed here and nothing in this file knows about glucose. The carbohydrate range is general sports
// nutrition for a healthy athlete; anyone on diabetes treatment decides carbohydrate and insulin with their
// own diabetes team.
//
// Rules
//  1. Training. Today's row is the DailyMetric whose `day` equals `today`.
//     Base from its Charge (`recovery`, 0–100): >= 67 push, 34 ..< 67 maintain, < 34 easy (the same bands as
//     the Coach prompt); no Charge -> maintain with `.noCharge`. Then, in this order:
//       (a) last night's `totalSleepMin` (today's row) < 360 min or < 70 % of the need (need = `sleepNeedMin`
//           ?? 480): one level down (push -> maintain -> easy), reason `.shortSleep`. Added even when the level
//           is already easy.
//       (b) load ratio >= 1.5 (`TrainingLoad.Band.sharpRise`; Gabbett 2016 with the limit of Impellizzeri et al.
//           2020, see TrainingLoad.swift): cap at maintain; `.loadSharpRise` is added when the level before the
//           cap was push (changed) or maintain (the cap applies), not when it was already easy.
//       (c) hard streak: a "hard" day has Effort (`strain`) >= the 75th percentile (linear interpolation
//           between order statistics, "type 7") of the Efforts in the 28 days before today (needs >= 14 such
//           days with an Effort, otherwise the rule is off). Consecutive hard days ending yesterday are counted
//           (a missing day or one without Effort ends the streak); >= 3 -> cap at easy, `.hardStreak`.
//     The first reason is always the Charge one.
//  2. Sleep target. minutes = need + min(max(debt, 0), 60), rounded to 5 (need = `sleepNeedMin` ?? 480).
//     bedtime = wake - minutes - 15, wrapped into 0 ..< 1440, where wake is the user's `wakeTargetMinutes` when
//     set (used even with no recorded nights), else the median of the last 14 `wakeMinutes`; nil with no target
//     and fewer than 5 wake times. Wake times are morning times of day, so a plain (not circular) median is used; a person
//     waking around midnight would break that assumption, which does not occur for real night sleep.
//  3. Nutrition (nil when age, weight or height is <= 0).
//     Resting energy, Mifflin-St Jeor (Mifflin et al. 1990, Am J Clin Nutr 51:241): 10·kg + 6.25·cm − 5·age + 5
//     (male), −161 (female), −78 (other, the mean of the two). Day factor easy 1.4 / maintain 1.6 / push 1.8,
//     goal factor fatLoss 0.85 / strength 1.07 / others 1.0. Energy range = centre·0.95 … centre·1.05 rounded to
//     50 kcal, the lower bound never under the resting energy (rounded up to 50).
//     Protein, g/kg/day (ISSN position stand, Jäger et al. 2017; Morton et al. 2018): health 1.2–1.6,
//     performance and endurance 1.4–2.0, strength 1.6–2.2, fatLoss 1.6–2.4; × kg, rounded to 5.
//     Carbohydrate, g/kg/day (Burke et al. 2011; ACSM/AND/DC joint position 2016): easy 3–5, maintain and push
//     5–7, endurance goal on a push day 6–10, fatLoss goal 3–5 every day; × kg, rounded to 5, then the upper
//     bound is lowered (rounded down to 5) so that carbs·4 + protein(low)·4 + 0.8 g/kg fat·9 stays within the
//     upper energy bound, keeping lower <= upper.
//     Fluids (EFSA 2010 adequate intake): 2500 ml male, 2000 female, 2250 other; +500 on maintain and push.
//  4. Focus, at most 3, in this priority: sleepDebt (debt >= 60 min); lowSleepAverage (mean `totalSleepMin`
//     of the 7 days ending today, >= 4 values, more than 45 min under the need); irregularWake (population
//     standard deviation of the last 14 wake times, >= 7 values, > 60 min); loadHigh (ratio >= 1.5) or loadLow
//     (ratio < 0.8); hrvDown (7-day mean `avgHrv`, >= 4 values, more than 10 % under the mean of the 30 days
//     before those 7, >= 10 values); restingHrUp (7-day mean `restingHr` >= 5 bpm above the same 30-day
//     reference, same value counts).
//  5. Schedule (all optional inputs; nil = no schedule known, behaviour as before).
//     `trainsToday == false`: the level is still computed but `isRestDay = true`, the level reads "if you train
//     anyway", and the nutrition ranges use the easy-day factor (nobody eats for a hard session on a rest day).
//     `trainsToday == true` with `sessionStartMinutes`: `preSession` = main meal from 3 h to 2.5 h before the start
//     (general sports-nutrition guidance on a meal 3-4 h before; carbohydrate amounts stay the daily range, never
//     insulin).
//     `trainsTomorrow == true`, today's Charge known and below the athlete's own median of the 90 days before
//     (`PersonalThresholds.medianCharge`, needs >= 14 days): the sleep target adds 30 min, so that debt part and
//     this part together never exceed 60 min; reason `.trainingTomorrow(addedMinutes:)` only when something was
//     really added.
//  6. Personal thresholds (`Inputs.thresholds`, nil = the fixed rules above). With personal Charge cut-offs push
//     is Charge > `pushAbove`, easy is Charge < `easyBelow`, else maintain; with personal short-night minutes the
//     rule (a) uses them instead of 360 (the 70 %-of-need part stays). `Plan.thresholds` records which were used
//     and how many days of Charge they rest on.
public enum DayPlan {

    // MARK: - Types

    public enum Goal: String, CaseIterable, Sendable, Equatable {
        case performance, strength, fatLoss, endurance, health
    }

    public enum Sex: Sendable, Equatable {
        case male, female, other
        /// "male" / "female" (case-insensitive) as stored in the profile; anything else is `.other`.
        public init(profileString: String) {
            switch profileString.trimmingCharacters(in: .whitespaces).lowercased() {
            case "male": self = .male
            case "female": self = .female
            default: self = .other
            }
        }
    }

    public enum Training: Int, Sendable, Equatable {
        case easy = 0, maintain = 1, push = 2
    }

    public enum Reason: Sendable, Equatable {
        case chargeHigh(Int)
        case chargeMid(Int)
        case chargeLow(Int)
        case noCharge
        case shortSleep(minutes: Int, needMinutes: Int)
        case loadSharpRise(ratio: Double)
        case hardStreak(days: Int)
    }

    /// Why tonight's sleep target is what it is, beyond the need and the debt.
    public enum SleepReason: Sendable, Equatable {
        /// A session is planned tomorrow and today's Charge is under the athlete's own median: this many minutes were added.
        case trainingTomorrow(addedMinutes: Int)
    }

    /// The pre-session meal window for today's session. Minutes after local midnight, wrapped into 0 ..< 1440.
    public struct PreSession: Sendable, Equatable {
        public let startMinutes: Int
        /// 3 h before the start.
        public let mealFromMinutes: Int
        /// 2.5 h before the start.
        public let mealToMinutes: Int
        public init(startMinutes: Int, mealFromMinutes: Int, mealToMinutes: Int) {
            self.startMinutes = startMinutes; self.mealFromMinutes = mealFromMinutes
            self.mealToMinutes = mealToMinutes
        }
    }

    /// Which thresholds the plan was made with.
    public struct ThresholdInfo: Sendable, Equatable {
        /// True when the Charge cut-offs are the athlete's own (push above the 67th percentile, easy below the 33rd).
        public let isPersonal: Bool
        /// Days with a Charge that the personal cut-offs rest on (or would rest on).
        public let chargeDays: Int
        /// The athlete's own Charge cut-offs when personal.
        public let pushAbove: Double?
        public let easyBelow: Double?
        /// The athlete's own short-night minutes when `PlanLearning` found one; nil = the standard 6 h.
        public let shortNightMinutes: Int?
        public init(isPersonal: Bool, chargeDays: Int, pushAbove: Double? = nil, easyBelow: Double? = nil,
                    shortNightMinutes: Int? = nil) {
            self.isPersonal = isPersonal; self.chargeDays = chargeDays
            self.pushAbove = pushAbove; self.easyBelow = easyBelow; self.shortNightMinutes = shortNightMinutes
        }
        /// Days still to wait for personal Charge cut-offs: 30 minus the days available, at least 1.
        public var daysUntilPersonal: Int { max(1, PersonalThresholds.minChargeDays - chargeDays) }
    }

    public enum Focus: Sendable, Equatable {
        case sleepDebt(minutes: Int)
        case lowSleepAverage(avgMinutes: Int, needMinutes: Int)
        case irregularWake(sdMinutes: Int)
        case loadHigh(ratio: Double)
        case loadLow(ratio: Double)
        case hrvDown(pct: Int, recent: Double, usual: Double)
        case restingHrUp(bpm: Double, recent: Double, usual: Double)
    }

    public struct SleepTarget: Sendable, Equatable {
        public let minutes: Int
        /// Minutes after local midnight, 0 ..< 1440; nil with fewer than 5 wake times.
        public let bedtimeMinutes: Int?
        /// The wake time (minutes after local midnight) the bedtime was computed for: the user's target, or the
        /// median of the recorded wake times; nil when neither exists.
        public let wakeMinutes: Int?
        /// True when `wakeMinutes` is the user's own target rather than the median of recorded nights.
        public let wakeIsUserSet: Bool
        /// Extra reasons for the target (empty = need plus debt only).
        public let reasons: [SleepReason]
        public init(minutes: Int, bedtimeMinutes: Int?, wakeMinutes: Int? = nil, wakeIsUserSet: Bool = false,
                    reasons: [SleepReason] = []) {
            self.minutes = minutes; self.bedtimeMinutes = bedtimeMinutes
            self.wakeMinutes = wakeMinutes; self.wakeIsUserSet = wakeIsUserSet
            self.reasons = reasons
        }
    }

    public struct Nutrition: Sendable, Equatable {
        public let restingKcal: Int
        public let energyKcal: ClosedRange<Int>
        public let proteinG: ClosedRange<Int>
        public let carbsG: ClosedRange<Int>
        public let fluidMl: Int
        public init(restingKcal: Int, energyKcal: ClosedRange<Int>, proteinG: ClosedRange<Int>,
                    carbsG: ClosedRange<Int>, fluidMl: Int) {
            self.restingKcal = restingKcal; self.energyKcal = energyKcal; self.proteinG = proteinG
            self.carbsG = carbsG; self.fluidMl = fluidMl
        }
    }

    public struct Inputs: Equatable {
        public var days: [DailyMetric]
        public var today: String
        public var sleepNeedMin: Double?
        public var sleepDebtMin: Double?
        public var wakeMinutes: [Int]
        public var load: TrainingLoad.Summary?
        public var age: Int
        public var sex: Sex
        public var weightKg: Double
        public var heightCm: Double
        public var goal: Goal
        /// The wake-up time the user wants, minutes after local midnight (0 ..< 1440); nil = derive it from the
        /// recorded wake times.
        public var wakeTargetMinutes: Int?
        /// Whether the athlete trains today / tomorrow by his schedule; nil = unknown.
        public var trainsToday: Bool?
        public var trainsTomorrow: Bool?
        /// His usual session start, minutes after local midnight; nil = unknown.
        public var sessionStartMinutes: Int?
        /// His own thresholds (`PersonalThresholds.compute`); nil = the fixed standard rules.
        public var thresholds: PersonalThresholds.Result?
        /// The schedule the flags above came from (learned or the profile's); only carried through to the plan so
        /// the Coach can quote it. Does not change any rule.
        public var schedule: TrainingPattern.Schedule?
        public init(days: [DailyMetric], today: String, sleepNeedMin: Double?, sleepDebtMin: Double?,
                    wakeMinutes: [Int], load: TrainingLoad.Summary?, age: Int, sex: Sex,
                    weightKg: Double, heightCm: Double, goal: Goal, wakeTargetMinutes: Int? = nil,
                    trainsToday: Bool? = nil, trainsTomorrow: Bool? = nil, sessionStartMinutes: Int? = nil,
                    thresholds: PersonalThresholds.Result? = nil, schedule: TrainingPattern.Schedule? = nil) {
            self.schedule = schedule
            self.trainsToday = trainsToday; self.trainsTomorrow = trainsTomorrow
            self.sessionStartMinutes = sessionStartMinutes; self.thresholds = thresholds
            self.wakeTargetMinutes = wakeTargetMinutes
            self.days = days; self.today = today; self.sleepNeedMin = sleepNeedMin
            self.sleepDebtMin = sleepDebtMin; self.wakeMinutes = wakeMinutes; self.load = load
            self.age = age; self.sex = sex; self.weightKg = weightKg; self.heightCm = heightCm
            self.goal = goal
        }
    }

    public struct Plan: Sendable, Equatable {
        public let training: Training
        public let reasons: [Reason]
        public let sleep: SleepTarget
        public let nutrition: Nutrition?
        public let focus: [Focus]
        /// True when the schedule says today is not a training day; `training` then reads "if you train anyway".
        public let isRestDay: Bool
        /// Whether a session is planned tomorrow; nil = unknown.
        public let trainsTomorrow: Bool?
        /// His usual session start, when known.
        public let sessionStartMinutes: Int?
        /// The meal window before today's session; only when he trains today and the start is known.
        public let preSession: PreSession?
        /// nil when the plan was made without thresholds input (the fixed rules).
        public let thresholds: ThresholdInfo?
        /// The training schedule the plan was made with (for the Coach); nil when none was given.
        public let schedule: TrainingPattern.Schedule?
        public init(training: Training, reasons: [Reason], sleep: SleepTarget,
                    nutrition: Nutrition?, focus: [Focus], isRestDay: Bool = false, trainsTomorrow: Bool? = nil,
                    sessionStartMinutes: Int? = nil, preSession: PreSession? = nil,
                    thresholds: ThresholdInfo? = nil, schedule: TrainingPattern.Schedule? = nil) {
            self.schedule = schedule
            self.training = training; self.reasons = reasons; self.sleep = sleep
            self.nutrition = nutrition; self.focus = focus; self.isRestDay = isRestDay
            self.trainsTomorrow = trainsTomorrow; self.sessionStartMinutes = sessionStartMinutes
            self.preSession = preSession; self.thresholds = thresholds
        }
    }

    // MARK: - Constants

    static let defaultNeedMin = 480.0
    static let maxFocus = 3
    /// Extra sleep when a session is planned tomorrow and today's Charge is under the athlete's own median.
    static let trainingTomorrowMinutes = 30.0

    // MARK: - Entry point

    public static func make(_ inputs: Inputs) -> Plan {
        let need = inputs.sleepNeedMin ?? defaultNeedMin
        let (training, reasons) = trainingDecision(inputs, need: need)
        let sleep = sleepTarget(inputs, need: need)
        let isRestDay = inputs.trainsToday == false
        // A rest day is fed as an easy day whatever the level would read "if you train anyway".
        let nutrition = nutrition(inputs, training: isRestDay ? .easy : training)
        let focus = focusList(inputs, need: need)
        return Plan(training: training, reasons: reasons, sleep: sleep, nutrition: nutrition, focus: focus,
                    isRestDay: isRestDay, trainsTomorrow: inputs.trainsTomorrow,
                    sessionStartMinutes: inputs.sessionStartMinutes,
                    preSession: preSession(inputs), thresholds: thresholdInfo(inputs),
                    schedule: inputs.schedule)
    }

    // MARK: - Schedule and thresholds

    static func preSession(_ i: Inputs) -> PreSession? {
        guard i.trainsToday == true, let start = i.sessionStartMinutes, (0..<1440).contains(start) else { return nil }
        func wrap(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }
        return PreSession(startMinutes: start, mealFromMinutes: wrap(start - 180), mealToMinutes: wrap(start - 150))
    }

    static func thresholdInfo(_ i: Inputs) -> ThresholdInfo? {
        guard let t = i.thresholds else { return nil }
        return ThresholdInfo(isPersonal: t.hasPersonalCharge, chargeDays: t.chargeDays,
                             pushAbove: t.pushAbove, easyBelow: t.easyBelow, shortNightMinutes: t.shortNightMinutes)
    }

    // MARK: - 1. Training

    static func trainingDecision(_ i: Inputs, need: Double) -> (Training, [Reason]) {
        let todayRow = i.days.last { $0.day == i.today }
        var level: Training
        var reasons: [Reason] = []
        if let c = todayRow?.recovery, c.isFinite {
            let shown = Int(c.rounded())
            let isPush: Bool, isEasy: Bool
            if let push = i.thresholds?.pushAbove, let easy = i.thresholds?.easyBelow {
                isPush = c > push; isEasy = c < easy
            } else {
                isPush = c >= 67; isEasy = c < 34
            }
            if isPush { level = .push; reasons.append(.chargeHigh(shown)) }
            else if !isEasy { level = .maintain; reasons.append(.chargeMid(shown)) }
            else { level = .easy; reasons.append(.chargeLow(shown)) }
        } else {
            level = .maintain
            reasons.append(.noCharge)
        }

        // (a) short night
        let shortCut = Double(i.thresholds?.shortNightMinutes ?? 360)
        if let sleep = todayRow?.totalSleepMin, sleep.isFinite, sleep < shortCut || sleep < 0.7 * need {
            level = stepDown(level)
            reasons.append(.shortSleep(minutes: Int(sleep.rounded()), needMinutes: Int(need.rounded())))
        }

        // (b) sharp load rise
        if let ratio = i.load?.ratio, ratio.isFinite, ratio >= 1.5 {
            if level != .easy { reasons.append(.loadSharpRise(ratio: ratio)) }
            if level == .push { level = .maintain }
        }

        // (c) hard streak
        let streak = hardStreak(i)
        if streak >= 3 {
            level = .easy
            reasons.append(.hardStreak(days: streak))
        }
        return (level, reasons)
    }

    private static func stepDown(_ t: Training) -> Training {
        switch t {
        case .push: return .maintain
        case .maintain, .easy: return .easy
        }
    }

    /// Consecutive hard days ending yesterday; 0 when the rule is off (fewer than 14 Effort days in the 28 before today).
    static func hardStreak(_ i: Inputs) -> Int {
        var strainByDay: [String: Double] = [:]
        for d in i.days { if let s = d.strain, s.isFinite { strainByDay[d.day] = s } }
        var window: [Double] = []
        for k in 1...28 {
            guard let key = FitnessAgeEngine.shiftDay(i.today, by: -k) else { return 0 }
            if let s = strainByDay[key] { window.append(s) }
        }
        guard window.count >= 14, let threshold = percentile(window, 0.75) else { return 0 }
        var streak = 0
        var k = 1
        while let key = FitnessAgeEngine.shiftDay(i.today, by: -k), let s = strainByDay[key], s >= threshold {
            streak += 1
            k += 1
        }
        return streak
    }

    /// Linear-interpolation percentile ("type 7"); nil for an empty list.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let pos = p * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    // MARK: - 2. Sleep

    static func roundTo(_ x: Double, _ step: Double) -> Int { Int((x / step).rounded() * step) }

    static func sleepTarget(_ i: Inputs, need: Double) -> SleepTarget {
        let debtExtra = min(max(i.sleepDebtMin ?? 0, 0), 60)
        // A session tomorrow after a below-median Charge today: +30 min, the debt part and this one together <= 60.
        var extra = debtExtra
        var reasons: [SleepReason] = []
        if i.trainsTomorrow == true,
           let c = i.days.last(where: { $0.day == i.today })?.recovery, c.isFinite,
           let median = PersonalThresholds.medianCharge(days: i.days, today: i.today), c < median {
            extra = min(debtExtra + trainingTomorrowMinutes, 60)
            if extra > debtExtra { reasons.append(.trainingTomorrow(addedMinutes: Int(extra - debtExtra))) }
        }
        let minutes = roundTo(need + extra, 5)
        let wakes = Array(i.wakeMinutes.suffix(14))
        if let target = i.wakeTargetMinutes {
            let wake = ((target % 1440) + 1440) % 1440
            let raw = wake - minutes - 15
            return SleepTarget(minutes: minutes, bedtimeMinutes: ((raw % 1440) + 1440) % 1440,
                               wakeMinutes: wake, wakeIsUserSet: true, reasons: reasons)
        }
        var bed: Int?
        var wake: Int?
        if wakes.count >= 5 {
            let med = median(wakes.map(Double.init))
            wake = Int(med.rounded())
            let raw = Int(med.rounded()) - minutes - 15
            bed = ((raw % 1440) + 1440) % 1440
        }
        return SleepTarget(minutes: minutes, bedtimeMinutes: bed, wakeMinutes: wake, wakeIsUserSet: false,
                           reasons: reasons)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    // MARK: - 3. Nutrition

    static func nutrition(_ i: Inputs, training: Training) -> Nutrition? {
        guard i.age > 0, i.weightKg > 0, i.heightCm > 0 else { return nil }
        let kg = i.weightKg
        let sexTerm: Double
        switch i.sex {
        case .male: sexTerm = 5
        case .female: sexTerm = -161
        case .other: sexTerm = -78
        }
        let resting = 10 * kg + 6.25 * i.heightCm - 5 * Double(i.age) + sexTerm

        let dayFactor: Double
        switch training {
        case .easy: dayFactor = 1.4
        case .maintain: dayFactor = 1.6
        case .push: dayFactor = 1.8
        }
        let goalFactor: Double
        switch i.goal {
        case .fatLoss: goalFactor = 0.85
        case .strength: goalFactor = 1.07
        default: goalFactor = 1.0
        }
        let centre = resting * dayFactor * goalFactor
        let restingCeil = Int((resting / 50).rounded(.up)) * 50
        let eLo = max(roundTo(centre * 0.95, 50), restingCeil)
        let eHi = max(roundTo(centre * 1.05, 50), eLo)

        let p: (Double, Double)
        switch i.goal {
        case .health: p = (1.2, 1.6)
        case .performance, .endurance: p = (1.4, 2.0)
        case .strength: p = (1.6, 2.2)
        case .fatLoss: p = (1.6, 2.4)
        }
        let pLo = roundTo(p.0 * kg, 5), pHi = max(roundTo(p.1 * kg, 5), pLo)

        let c: (Double, Double)
        if i.goal == .fatLoss { c = (3, 5) }
        else if i.goal == .endurance && training == .push { c = (6, 10) }
        else {
            switch training {
            case .easy: c = (3, 5)
            case .maintain, .push: c = (5, 7)
            }
        }
        var cLo = roundTo(c.0 * kg, 5)
        var cHi = roundTo(c.1 * kg, 5)
        let fatKcal = 0.8 * kg * 9
        let room = (Double(eHi) - Double(pLo) * 4 - fatKcal) / 4
        let cap = max(0, Int((room / 5).rounded(.down)) * 5)
        cHi = min(cHi, cap)
        cLo = min(cLo, cHi)

        var fluid: Int
        switch i.sex {
        case .male: fluid = 2500
        case .female: fluid = 2000
        case .other: fluid = 2250
        }
        if training != .easy { fluid += 500 }

        return Nutrition(restingKcal: Int(resting.rounded()), energyKcal: eLo...eHi,
                         proteinG: pLo...pHi, carbsG: cLo...cHi, fluidMl: fluid)
    }

    // MARK: - 4. Focus

    static func focusList(_ i: Inputs, need: Double) -> [Focus] {
        var out: [Focus] = []

        if let debt = i.sleepDebtMin, debt.isFinite, debt >= 60 {
            out.append(.sleepDebt(minutes: Int(debt.rounded())))
        }

        let byDay = Dictionary(i.days.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        func series(_ from: Int, _ to: Int, _ f: (DailyMetric) -> Double?) -> [Double] {
            // days `from`...`to` back from today (0 = today), inclusive
            var vals: [Double] = []
            for k in from...to {
                if let key = FitnessAgeEngine.shiftDay(i.today, by: -k), let d = byDay[key],
                   let v = f(d), v.isFinite { vals.append(v) }
            }
            return vals
        }
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

        let sleep7 = series(0, 6) { $0.totalSleepMin }
        if sleep7.count >= 4 {
            let avg = mean(sleep7)
            if need - avg > 45 {
                out.append(.lowSleepAverage(avgMinutes: Int(avg.rounded()), needMinutes: Int(need.rounded())))
            }
        }

        let wakes = Array(i.wakeMinutes.suffix(14)).map(Double.init)
        if wakes.count >= 7 {
            let m = mean(wakes)
            let sd = (wakes.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(wakes.count)).squareRoot()
            if sd > 60 { out.append(.irregularWake(sdMinutes: Int(sd.rounded()))) }
        }

        if let r = i.load?.ratio, r.isFinite {
            if r >= 1.5 { out.append(.loadHigh(ratio: r)) }
            else if r < 0.8 { out.append(.loadLow(ratio: r)) }
        }

        let hrv7 = series(0, 6) { $0.avgHrv }
        let hrvRef = series(7, 36) { $0.avgHrv }
        if hrv7.count >= 4, hrvRef.count >= 10 {
            let recent = mean(hrv7), usual = mean(hrvRef)
            if usual > 0, recent < usual * 0.9 {
                out.append(.hrvDown(pct: Int(((usual - recent) / usual * 100).rounded()),
                                    recent: recent, usual: usual))
            }
        }

        let rhr7 = series(0, 6) { $0.restingHr.map(Double.init) }
        let rhrRef = series(7, 36) { $0.restingHr.map(Double.init) }
        if rhr7.count >= 4, rhrRef.count >= 10 {
            let recent = mean(rhr7), usual = mean(rhrRef)
            if recent - usual >= 5 { out.append(.restingHrUp(bpm: recent - usual, recent: recent, usual: usual)) }
        }

        return Array(out.prefix(maxFocus))
    }
}
