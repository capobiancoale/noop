import Foundation
import StrandAnalytics
import WhoopStore

/// The ONE place that gathers the inputs of the weekly review (`WeeklyReview.make`) and of "What the plan has
/// learned about you" (`PlanLearning.findings`). The screen loads a `Context` once, then turns any week into a
/// review with the pure `review(context:weekStart:)`, so paging between weeks never touches the store again.
enum WeeklyReviewBuilder {

    /// Everything the review needs that does not depend on which week is shown.
    struct Context {
        let todayKey: String
        let days: [DailyMetric]
        let wods: [WodLogRow]
        /// Local morning wake-up (minutes after midnight) by day, nights of at least 3 h.
        let wakeByDay: [String: Int]
        /// Daily glucose time in range (%), by day; empty without a glucose source.
        let tirSeries: [(day: String, value: Double)]
        let sleepNeedMin: Double?
        let sleepDebtMin: Double?
        /// The plan's bedtime for tonight (minutes after midnight), when known.
        let bedtimeMinutes: Int?
        let profile: DayPlanBuilder.ProfileValues
        let findings: [PlanLearning.Finding]
        /// The Monday of the oldest week with any data, so the screen can stop paging back.
        let firstWeekStart: String?
    }

    // MARK: - Gathering

    @MainActor
    static func context(repo: Repository, profile: DayPlanBuilder.ProfileValues = .stored(),
                        now: Date = Date()) async -> Context {
        // The plan snapshot already resolves today, the sleep need and debt and the bedtime.
        let snap = await DayPlanBuilder.snapshot(repo: repo, profile: profile, now: now)
        let wods = await repo.allWods()
        let tir = await repo.series(key: "glucose_tir", source: "apple-health")
        let days = repo.days
        let first = days.first(where: { $0.recovery != nil || $0.strain != nil || $0.totalSleepMin != nil })
            .flatMap { WeeklyReview.mondayKey(of: $0.day) }
        return Context(
            todayKey: snap.todayKey, days: days, wods: wods,
            wakeByDay: wakeMinutesByDay(sleeps: repo.sleeps, timeZone: .current),
            tirSeries: tir, sleepNeedMin: snap.sleepNeedMin, sleepDebtMin: snap.sleepDebtMin,
            bedtimeMinutes: snap.plan.sleep.bedtimeMinutes, profile: profile,
            findings: PlanLearning.findings(days: days, today: snap.todayKey),
            firstWeekStart: first)
    }

    // MARK: - Pure steps

    /// The review of the week starting on `weekStart`. The sleep debt is today's figure, so it is passed only to
    /// the week that contains today.
    nonisolated static func review(context c: Context, weekStart: String) -> WeeklyReview.Outcome {
        let keys = WeeklyReview.weekKeys(weekStart) ?? []
        let isCurrent = keys.contains(c.todayKey)
        let last = FitnessAgeEngine.shiftDay(weekStart, by: -7) ?? weekStart
        let inputs = WeeklyReview.Inputs(
            days: c.days, weekStart: weekStart, wakeMinutesByDay: c.wakeByDay, wods: c.wods,
            planLevelByDay: planLevels(context: c, keys: keys),
            timeInRangeThisWeek: weeklyMean(c.tirSeries, from: weekStart),
            timeInRangeLastWeek: weeklyMean(c.tirSeries, from: last),
            sleepNeedMin: c.sleepNeedMin, sleepDebtMin: isCurrent ? c.sleepDebtMin : nil,
            bedtimeMinutes: c.bedtimeMinutes)
        return WeeklyReview.make(inputs)
    }

    /// The training level the plan gave on each day of the week that has a row and is not in the future,
    /// rebuilt with the same engine from the history up to that day.
    nonisolated static func planLevels(context c: Context, keys: [String]) -> [String: DayPlan.Training] {
        var out: [String: DayPlan.Training] = [:]
        for k in keys where k <= c.todayKey && c.days.contains(where: { $0.day == k }) {
            let upTo = c.days.filter { $0.day <= k }
            let efforts: [(day: String, effort: Double?)] = upTo.map { (day: $0.day, effort: $0.strain) }
            let inputs = DayPlan.Inputs(
                days: upTo, today: k, sleepNeedMin: c.sleepNeedMin, sleepDebtMin: nil, wakeMinutes: [],
                load: TrainingLoad.summary(days: efforts, today: k), age: c.profile.age,
                sex: DayPlan.Sex(profileString: c.profile.sex), weightKg: c.profile.weightKg,
                heightCm: c.profile.heightCm, goal: c.profile.goal)
            out[k] = DayPlan.make(inputs).training
        }
        return out
    }

    /// Mean of the series over the 7 days from `start`; nil with fewer than 3 values.
    nonisolated static func weeklyMean(_ series: [(day: String, value: Double)], from start: String) -> Double? {
        guard let keys = WeeklyReview.weekKeys(start) else { return nil }
        let set = Set(keys)
        let v = series.filter { set.contains($0.day) && $0.value.isFinite }.map(\.value)
        return v.count >= WeeklyReview.minDaysPerMetric ? v.reduce(0, +) / Double(v.count) : nil
    }

    /// Local wake-up time (minutes after midnight in `timeZone`) of each night of at least 3 h, by the local day
    /// it ended on. When two sessions end on one day the later one wins.
    nonisolated static func wakeMinutesByDay(sleeps: [CachedSleepSession], timeZone: TimeZone) -> [String: Int] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var out: [String: Int] = [:]
        for s in sleeps.sorted(by: { $0.endTs < $1.endTs })
        where s.endTs - s.effectiveStartTs >= DayPlanBuilder.minNightSeconds {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                       from: Date(timeIntervalSince1970: Double(s.endTs)))
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let key = String(format: "%04d-%02d-%02d", y, m, d)
            out[key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        return out
    }
}
