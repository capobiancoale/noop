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

        /// Same defaults as `ProfileStore.init()`.
        nonisolated static func stored(defaults: UserDefaults = .standard) -> ProfileValues {
            ProfileValues(
                age: defaults.object(forKey: ProfileStore.ageKey) as? Int ?? 30,
                sex: defaults.string(forKey: ProfileStore.sexKey) ?? "male",
                weightKg: defaults.object(forKey: ProfileStore.weightKey) as? Double ?? 75,
                heightCm: defaults.object(forKey: ProfileStore.heightKey) as? Double ?? 178,
                goal: DayPlanBuilder.goal(from: defaults.string(forKey: DayPlanBuilder.goalKey)),
                wakeTimeMinutes: DayPlanBuilder.validWakeMinutes(defaults.object(forKey: DayPlanBuilder.wakeTimeKey) as? Int))
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
    }

    /// Never older than this many nights of wake times feed the bedtime and the wake-regularity focus.
    nonisolated static let wakeNights = 14
    /// A session shorter than this is a nap, not a night.
    nonisolated static let minNightSeconds = 3 * 3_600

    // MARK: - Snapshot

    @MainActor
    static func snapshot(repo: Repository, profile: ProfileValues = .stored(), now: Date = Date()) async -> Snapshot {
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

        let inputs = DayPlan.Inputs(
            days: days, today: todayKey, sleepNeedMin: need, sleepDebtMin: debt,
            wakeMinutes: wakes, load: load, age: profile.age,
            sex: DayPlan.Sex(profileString: profile.sex),
            weightKg: profile.weightKg, heightCm: profile.heightCm, goal: profile.goal,
            wakeTargetMinutes: wakeTarget(userMinutes: profile.wakeTimeMinutes, now: now, timeZone: tz))
        return Snapshot(plan: DayPlan.make(inputs), inputs: inputs, todayKey: todayKey, todayRow: todayRow,
                        restScore: rest, sleepNeedMin: need, sleepDebtMin: debt, lastNight: night, load: load)
    }

    /// That day's value, else the newest one while it is still fresh (same carry rule as Today's Rest).
    @MainActor
    private static func latest(_ series: [(day: String, value: Double)], todayKey: String) -> Double? {
        let byDay = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        return TodayView.freshRestScore(todayValue: byDay[todayKey], lastDay: series.last?.day,
                                        lastValue: series.last?.value, isTodaySelected: true, todayKey: todayKey)
    }

    // MARK: - Pure steps

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
