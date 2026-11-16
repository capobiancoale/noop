import Foundation
import StrandAnalytics
import WhoopStore

/// The ONE place that gathers the inputs of "Today's plan" (`DayPlan.make`). The Today card, the Coach and the
/// widgets all call `snapshot(repo:profile:now:)`, so they can never disagree.
enum DayPlanBuilder {

    /// UserDefaults key of the personal goal (`ProfileStore.goal`).
    static let goalKey = "profile.goal"

    /// UserDefaults key of the wake-up time the user wants (`ProfileStore.wakeTimeMinutes`): minutes after local
    /// midnight, or -1 for "automatic, from my usual wake time".
    static let wakeTimeKey = "profile.wakeTimeMinutes"

    /// UserDefaults keys of the training schedule (`ProfileStore.trainingDaysPerWeek`, `usualTrainingMinutes`,
    /// `usualSessionMinutes`): days a week (1...7), usual start (minutes after local midnight), usual length (minutes).
    static let trainingDaysKey = "profile.trainingDaysPerWeek"
    static let trainingTimeKey = "profile.usualTrainingMinutes"
    static let sessionMinutesKey = "profile.usualSessionMinutes"
    /// The user's own answers, pre-filled: 5 days a week, 19:00, 60 minutes.
    nonisolated static let defaultTrainingDays = 5
    nonisolated static let defaultTrainingMinutes = 19 * 60
    nonisolated static let defaultSessionMinutes = 60

    /// NOOP's own smart alarm keys. They MIRROR `BehaviorStore`'s private keys (`behavior.smartAlarmEnabled`,
    /// `behavior.smartAlarmMinutes`, `behavior.smartAlarmWeekdays`); keep them in step.
    nonisolated static let smartAlarmEnabledKey = "behavior.smartAlarmEnabled"
    nonisolated static let smartAlarmMinutesKey = "behavior.smartAlarmMinutes"
    nonisolated static let smartAlarmWeekdaysKey = "behavior.smartAlarmWeekdays"

    /// The profile fields the plan needs, read from the same UserDefaults keys `ProfileStore` writes.
    struct ProfileValues: Equatable, Sendable {
        var age: Int
        var sex: String
        var weightKg: Double
        var heightCm: Double
        var goal: DayPlan.Goal
        /// Minutes after local midnight, or -1 for automatic (see `ProfileStore.wakeTimeMinutes`).
        var wakeTimeMinutes: Int = -1
        /// The athlete's own schedule answers; the plan prefers what his workouts show (`TrainingPattern`).
        var trainingDaysPerWeek: Int = DayPlanBuilder.defaultTrainingDays
        var usualTrainingMinutes: Int = DayPlanBuilder.defaultTrainingMinutes
        var usualSessionMinutes: Int = DayPlanBuilder.defaultSessionMinutes

        /// Same defaults as `ProfileStore.init()`.
        nonisolated static func stored(defaults: UserDefaults = .standard) -> ProfileValues {
            ProfileValues(
                age: defaults.object(forKey: ProfileStore.ageKey) as? Int ?? 30,
                sex: defaults.string(forKey: ProfileStore.sexKey) ?? "male",
                weightKg: defaults.object(forKey: ProfileStore.weightKey) as? Double ?? 75,
                heightCm: defaults.object(forKey: ProfileStore.heightKey) as? Double ?? 178,
                goal: DayPlanBuilder.goal(from: defaults.string(forKey: DayPlanBuilder.goalKey)),
                wakeTimeMinutes: DayPlanBuilder.validWakeMinutes(defaults.object(forKey: DayPlanBuilder.wakeTimeKey) as? Int),
                trainingDaysPerWeek: DayPlanBuilder.validTrainingDays(defaults.object(forKey: DayPlanBuilder.trainingDaysKey) as? Int),
                usualTrainingMinutes: DayPlanBuilder.validTrainingMinutes(defaults.object(forKey: DayPlanBuilder.trainingTimeKey) as? Int),
                usualSessionMinutes: DayPlanBuilder.validSessionMinutes(defaults.object(forKey: DayPlanBuilder.sessionMinutesKey) as? Int))
        }
    }

    /// The plan plus the figures the card and the Coach quote next to it.
    struct Snapshot {
        let plan: DayPlan.Plan
        let inputs: DayPlan.Inputs
        let todayKey: String
        let todayRow: DailyMetric?
        let restScore: Double?
        let sleepNeedMin: Double?
        let sleepDebtMin: Double?
        let lastNight: CachedSleepSession?
        let load: TrainingLoad.Summary?
        /// The schedule the plan used: learned from the last 8 weeks where there was enough data, else the profile's.
        /// `schedule.daysLearned` / `startLearned` / `durationLearned` say which source each field came from.
        let schedule: TrainingPattern.Schedule
        /// What the learner found (weeks observed, training days in the window), for diagnostics and the card.
        let learnedPattern: TrainingPattern.Result
        let thresholds: PersonalThresholds.Result
    }

    /// Never older than this many nights of wake times feed the bedtime and the wake-regularity focus.
    nonisolated static let wakeNights = 14
    /// A session shorter than this is a nap, not a night.
    nonisolated static let minNightSeconds = 3 * 3_600

    // MARK: - Snapshot

    @MainActor
    static func snapshot(repo: Repository, profile: ProfileValues = .stored(), now: Date = Date(),
                         defaults: UserDefaults = .standard) async -> Snapshot {
        let days = repo.days
        // Same resolution as the liquid Today at offset 0 (`selectedDayKey` / `resolveDisplayDay`).
        let todayKey = repo.today?.day ?? Repository.localDayKey(Repository.logicalDay(now))
        let todayRow = repo.today ?? days.last(where: { $0.day == todayKey })

        let needSeries = await repo.exploreSeries(key: "sleep_need_min", source: "my-whoop")
        let debtSeries = await repo.exploreSeries(key: "sleep_debt_min", source: "my-whoop")
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let need = latest(needSeries, todayKey: todayKey)
        let debt = latest(debtSeries, todayKey: todayKey)
        let rest = latest(restSeries, todayKey: todayKey)

        let sleeps = repo.sleeps
        let tz = TimeZone.current
        let wakes = wakeMinutes(sleeps: sleeps, timeZone: tz)
        let night = lastNight(sleeps: sleeps, now: now, timeZone: tz)

        // The same mapping the Workouts screen uses for its Training load card.
        let efforts: [(day: String, effort: Double?)] = days.map { (day: $0.day, effort: $0.strain) }
        let load = TrainingLoad.summary(days: efforts, today: Repository.logicalDayKey(now))

        // The schedule: learned from the last 8 weeks of strap / imported workouts and logged WODs, else the profile's.
        let workouts = await repo.workoutRows(days: TrainingPattern.maxWeeks * 7 + 7, reconcileHr: false)
        let wods = await repo.allWods()
        let sessions = trainingSessions(workouts: workouts, wods: wods, timeZone: tz)
        let learned = TrainingPattern.learn(sessions: sessions, today: todayKey, dataSince: days.map(\.day).min())
        // The schedule answers are read from the store itself: the Today views build `ProfileValues` from the live
        // profile without them, and `ProfileStore` persists every change at once, so this is always current.
        let answers = ProfileValues.stored(defaults: defaults)
        let schedule = TrainingPattern.resolve(
            learned: learned, profileDaysPerWeek: answers.trainingDaysPerWeek,
            profileStartMinutes: answers.usualTrainingMinutes, profileSessionMinutes: answers.usualSessionMinutes)
        let thresholds = PersonalThresholds.compute(days: days, today: todayKey)
        let todayWeekday = TrainingPattern.weekday(ofDayKey: todayKey)

        let inputs = DayPlan.Inputs(
            days: days, today: todayKey, sleepNeedMin: need, sleepDebtMin: debt,
            wakeMinutes: wakes, load: load, age: profile.age,
            sex: DayPlan.Sex(profileString: profile.sex),
            weightKg: profile.weightKg, heightCm: profile.heightCm, goal: profile.goal,
            wakeTargetMinutes: wakeTarget(userMinutes: profile.wakeTimeMinutes, now: now, timeZone: tz),
            trainsToday: todayWeekday.flatMap { schedule.trains(on: $0) },
            trainsTomorrow: todayWeekday.flatMap { schedule.trains(on: TrainingPattern.nextWeekday($0)) },
            sessionStartMinutes: schedule.startMinutes, thresholds: thresholds, schedule: schedule)
        return Snapshot(plan: DayPlan.make(inputs), inputs: inputs, todayKey: todayKey, todayRow: todayRow,
                        restScore: rest, sleepNeedMin: need, sleepDebtMin: debt, lastNight: night, load: load,
                        schedule: schedule, learnedPattern: learned, thresholds: thresholds)
    }

    /// That day's value, else the newest one while it is still fresh (same carry rule as Today's Rest).
    @MainActor
    private static func latest(_ series: [(day: String, value: Double)], todayKey: String) -> Double? {
        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        return TodayView.freshRestScore(todayValue: byDay[todayKey], lastDay: series.last?.day,
                                        lastValue: series.last?.value, isTodaySelected: true, todayKey: todayKey)
    }

    // MARK: - Pure steps

    /// Days a week as stored: 1...7, else the default (5).
    nonisolated static func validTrainingDays(_ raw: Int?) -> Int {
        guard let raw, (1...7).contains(raw) else { return defaultTrainingDays }
        return raw
    }

    /// A stored usual start when it is a time of day (0 ..< 1440), else 19:00.
    nonisolated static func validTrainingMinutes(_ raw: Int?) -> Int {
        guard let raw, (0..<1440).contains(raw) else { return defaultTrainingMinutes }
        return raw
    }

    /// A stored usual session length when it is 15...240 minutes, else 60.
    nonisolated static func validSessionMinutes(_ raw: Int?) -> Int {
        guard let raw, (15...240).contains(raw) else { return defaultSessionMinutes }
        return raw
    }

    /// Strap / imported workouts and logged WODs as `TrainingPattern` sessions: the local day key, weekday (1 = Sunday)
    /// and minute of the day of each start in `timeZone`, with the length in minutes when known. A WOD with a
    /// session end uses [ts, endTs]; one without has no length (its time may mark the start or the end).
    nonisolated static func trainingSessions(workouts: [WorkoutRow], wods: [WodLogRow],
                                             timeZone: TimeZone) -> [TrainingPattern.Session] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        func session(start: Int, durationS: Double?) -> TrainingPattern.Session? {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday],
                                       from: Date(timeIntervalSince1970: Double(start)))
            guard let y = c.year, let mo = c.month, let d = c.day, let w = c.weekday else { return nil }
            let key = String(format: "%04d-%02d-%02d", y, mo, d)
            let minutes = (durationS.flatMap { $0.isFinite && $0 > 0 ? Int(($0 / 60).rounded()) : nil })
            return TrainingPattern.Session(day: key, weekday: w, startMinutes: (c.hour ?? 0) * 60 + (c.minute ?? 0),
                                           durationMinutes: minutes)
        }
        var out: [TrainingPattern.Session] = []
        for w in workouts {
            let dur = w.durationS ?? (w.endTs > w.startTs ? Double(w.endTs - w.startTs) : nil)
            if let s = session(start: w.startTs, durationS: dur) { out.append(s) }
        }
        for w in wods {
            let dur = w.sessionSpan.map { Double($0.end - $0.start) }
            if let s = session(start: w.ts, durationS: dur) { out.append(s) }
        }
        return out
    }

    /// A stored wake time when it is a real time of day (0 ..< 1440), else -1 (automatic).
    nonisolated static func validWakeMinutes(_ raw: Int?) -> Int {
        guard let raw, (0..<1440).contains(raw) else { return -1 }
        return raw
    }

    /// The wake-up time the plan should aim for: the user's own setting when it is a time of day, else NOOP's
    /// smart alarm time when that alarm is on and rings tomorrow morning, else nil (the plan then uses the
    /// usual wake time).
    nonisolated static func wakeTarget(userMinutes: Int, defaults: UserDefaults = .standard, now: Date = Date(),
                                       timeZone: TimeZone = .current) -> Int? {
        if (0..<1440).contains(userMinutes) { return userMinutes }
        return smartAlarmWakeMinutes(defaults: defaults, now: now, timeZone: timeZone)
    }

    /// NOOP's smart alarm time (minutes after local midnight) for the morning after `now`, or nil when the alarm
    /// is off, its time is not a time of day, or its weekday selection leaves tomorrow out (an empty selection
    /// means every day, as in `AppModel.nextSmartAlarmDate`). Weekday numbers are Calendar's (1 = Sunday).
    nonisolated static func smartAlarmWakeMinutes(defaults: UserDefaults = .standard, now: Date = Date(),
                                                  timeZone: TimeZone = .current) -> Int? {
        guard defaults.object(forKey: smartAlarmEnabledKey) as? Bool == true else { return nil }
        let minutes = defaults.object(forKey: smartAlarmMinutesKey) as? Int ?? 7 * 60
        guard (0..<1440).contains(minutes) else { return nil }
        let days = Set((defaults.array(forKey: smartAlarmWeekdaysKey) as? [Int] ?? []).filter { (1...7).contains($0) })
        if days.isEmpty { return minutes }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now) else { return minutes }
        return days.contains(cal.component(.weekday, from: tomorrow)) ? minutes : nil
    }

    /// `DayPlan.Goal` from its stored raw value; anything unknown is `.performance`.
    nonisolated static func goal(from raw: String?) -> DayPlan.Goal {
        raw.flatMap { DayPlan.Goal(rawValue: $0) } ?? .performance
    }

    /// Local time of day (minutes after midnight, in `timeZone`) of the wake-up of the last `nights` nights
    /// lasting at least 3 h, oldest first.
    nonisolated static func wakeMinutes(sleeps: [CachedSleepSession], timeZone: TimeZone,
                                        nights: Int = wakeNights) -> [Int] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let nightsOnly = sleeps
            .filter { $0.endTs - $0.effectiveStartTs >= minNightSeconds }
            .sorted { $0.endTs < $1.endTs }
            .suffix(max(0, nights))
        return nightsOnly.map { s in
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(s.endTs)))
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }

    /// The session that ends on `now`'s local calendar day in `timeZone` (the longest when several).
    nonisolated static func lastNight(sleeps: [CachedSleepSession], now: Date, timeZone: TimeZone) -> CachedSleepSession? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        let lo = Int(start.timeIntervalSince1970), hi = Int(end.timeIntervalSince1970)
        return sleeps
            .filter { $0.endTs >= lo && $0.endTs < hi }
            .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
    }
}
