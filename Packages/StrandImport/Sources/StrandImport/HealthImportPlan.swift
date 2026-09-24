import Foundation

// MARK: - Apple Health import plan
//
// The first Apple Health import reads about 14 months of history. Read in one go, a year of CGM readings
// and insulin doses sits in memory at once, nothing lands until everything is read, and an interruption
// (the iPhone locking, the app being closed) throws the whole run away. So the import is planned as
// day-aligned windows of at most 30 days, newest first: each window is read and saved on its own, the
// most recent data shows up first, progress can be reported per window, and an interrupted history import
// resumes from the oldest window already saved. The routine update is the same machinery with one window.
// Pure (Foundation only): the iOS HealthKit bridge executes the plan.

/// One slice of an Apple Health import: whole local days from `start` (a local midnight) up to `end`
/// (exclusive; the next newer window's start, or the moment the plan was made for the newest window).
public struct HealthImportWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// Part of the one-time history import (as opposed to the routine update of recent days).
    public let isHistory: Bool

    public init(start: Date, end: Date, isHistory: Bool) {
        self.start = start; self.end = end; self.isHistory = isHistory
    }
}

public enum HealthImportPlan {

    /// How far back the one-time history import reaches, in days (about 14 months, enough history for
    /// every range chip of the Apple Health screens to unlock).
    public static let historyDays = 430
    /// The recent period every full refresh re-reads, in days: the minimum depth of Apple Health data NOOP
    /// always holds, read first so three months are complete before the older history arrives.
    public static let recentDays = 90
    /// Days an automatic refresh re-reads when the last full `recentDays` refresh is under
    /// `fullRefreshInterval` old: opening the app repeatedly shouldn't re-read three months each time.
    public static let catchUpDays = 7
    /// How old the last full refresh may be before an automatic refresh reads all `recentDays` again.
    public static let fullRefreshInterval: TimeInterval = 6 * 3_600
    /// Longest window, in days.
    public static let windowDays = 30

    /// Day-aligned windows covering `[from, to)`, newest first, each at most `windowDays` local days.
    /// `from` is snapped back to its local midnight; the newest window ends at `to` itself, so it covers
    /// the current partial day. Empty when there is nothing between the two.
    public static func windows(from: Date, to: Date, isHistory: Bool,
                               windowDays: Int = windowDays, calendar: Calendar = .current) -> [HealthImportWindow] {
        let floor = calendar.startOfDay(for: from)
        guard windowDays > 0, to > floor else { return [] }
        var out: [HealthImportWindow] = []
        var end = to
        var anchor = calendar.startOfDay(for: to)
        // The newest window holds the partial day `to` falls in plus the whole days before it.
        var span = anchor == to ? windowDays : windowDays - 1
        while end > floor {
            guard let back = calendar.date(byAdding: .day, value: -span, to: anchor) else { break }
            let start = max(back, floor)
            out.append(HealthImportWindow(start: start, end: end, isHistory: isHistory))
            end = start
            anchor = start
            span = windowDays
        }
        return out
    }

    /// What one sync reads: the routine window of the last `routineDays` calendar days (today included),
    /// then, while the history import is unfinished and `includeHistory` is set, the history still missing
    /// down to `historyDays` before today, newest first. `historySavedFrom` is the start of the oldest
    /// history window already saved (nil when none yet), so an interrupted import resumes below it instead
    /// of starting over.
    public static func plan(now: Date, routineDays: Int, includeHistory: Bool, historyDone: Bool,
                            historySavedFrom: Date?, calendar: Calendar = .current) -> [HealthImportWindow] {
        let today = calendar.startOfDay(for: now)
        guard let routineFrom = calendar.date(byAdding: .day, value: -(max(routineDays, 1) - 1), to: today)
        else { return [] }
        var out = windows(from: routineFrom, to: now, isHistory: false, calendar: calendar)
        guard includeHistory, !historyDone,
              let target = historyTarget(now: now, calendar: calendar) else { return out }
        let upper = min(historySavedFrom ?? routineFrom, routineFrom)
        out += windows(from: target, to: upper, isHistory: true, calendar: calendar)
        return out
    }

    /// Days an automatic (not user-started) refresh should re-read: all `recentDays` when the last full
    /// refresh is missing or older than `fullRefreshInterval`, else only `catchUpDays`.
    public static func automaticRefreshDays(lastFullRefresh: Date?, now: Date) -> Int {
        guard let last = lastFullRefresh, now.timeIntervalSince(last) < fullRefreshInterval, last <= now else {
            return recentDays
        }
        return catchUpDays
    }

    /// The local midnight the history import reaches back to.
    public static func historyTarget(now: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -historyDays, to: calendar.startOfDay(for: now))
    }

    /// True once history saved down to `savedFrom` covers everything back to the target.
    public static func historyComplete(savedFrom: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let target = historyTarget(now: now, calendar: calendar) else { return true }
        return savedFrom <= target
    }

    /// Share (0…1) of the history import already saved, for "History imported: 40%".
    public static func historyFraction(savedFrom: Date?, now: Date, calendar: Calendar = .current) -> Double {
        guard let savedFrom, let target = historyTarget(now: now, calendar: calendar) else { return 0 }
        let today = calendar.startOfDay(for: now)
        let total = today.timeIntervalSince(target)
        guard total > 0 else { return 1 }
        return min(1, max(0, today.timeIntervalSince(savedFrom) / total))
    }
}

// MARK: - Keeping windowed results identical to one whole-period read

extension HealthImportPlan {

    /// Statistics and sleep queries of a window start this many days before it; only the window's own
    /// days are kept. HealthKit splits a cumulative sample (steps, energy, insulin, carbs, water) that runs
    /// past midnight across both days' buckets, and the bridge credits a sleep sample to the day it ends,
    /// so a window's first day needs the samples that began the day before, as a whole-period read sees them.
    public static let leadInDays = 1
    /// Glucose is read from this long before a window: a hypo already under way at midnight is then seen
    /// starting on the previous day and left to that day's window, instead of being counted twice.
    public static let glucoseLeadIn: TimeInterval = 3 * 3_600
    /// …and until this long after it: an event that starts just before the window ends still gets its
    /// 15 minutes, and a late workout's post-exercise window (2 hours after it ends) is complete.
    public static let glucoseLeadOut: TimeInterval = 24 * 3_600

    /// The local days (`yyyy-MM-dd`, the store's day key) a window owns, oldest first.
    public static func days(of window: HealthImportWindow, calendar: Calendar = .current) -> [String] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        var out: [String] = []
        var d = calendar.startOfDay(for: window.start)
        while d < window.end {
            out.append(f.string(from: d))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    /// Per-day glucose KPIs and post-exercise lows for the `days` one window owns, from readings covering
    /// the window plus `glucoseLeadIn`/`glucoseLeadOut` and the workouts that start inside it.
    public static func glucose(forDays days: Set<String>, readings: [GlucoseReading], workouts: [WorkoutWindow])
        -> (daily: [String: GlucoseDayStats], postWorkout: [String: PostWorkoutGlucose]) {
        let daily = DiabetesMetrics.glucoseDaily(readings).filter { days.contains($0.key) }
        let post = DiabetesMetrics.postWorkoutGlucose(readings: readings, workouts: workouts)
            .filter { days.contains($0.key) }
        return (daily, post)
    }
}

// MARK: - Sleep minutes per day (the iOS HealthKit bridge's rule)

/// One Apple Health sleep-analysis sample.
public struct SleepStageSample: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let stage: SleepStage
    public init(start: Date, end: Date, stage: SleepStage) {
        self.start = start; self.end = end; self.stage = stage
    }
}

/// Minutes asleep credited to one day, and the part of them in each stage (nil when the day had none).
public struct SleepDayMinutes: Sendable, Equatable {
    public var asleep: Double = 0
    public var deep: Double?
    public var rem: Double?
    public var core: Double?
    public init(asleep: Double = 0, deep: Double? = nil, rem: Double? = nil, core: Double? = nil) {
        self.asleep = asleep; self.deep = deep; self.rem = rem; self.core = core
    }
}

public enum AppleSleepStages {
    /// Asleep minutes per day, each sample credited to the local day it ends (`dayOf`). Deep, REM and core
    /// (the legacy unspecified "asleep" counts as core) also add up on their own; in-bed, awake and unknown
    /// samples are ignored, and a day without any asleep sample is absent.
    public static func minutesByDay(_ samples: [SleepStageSample], dayOf: (Date) -> String) -> [String: SleepDayMinutes] {
        var out: [String: SleepDayMinutes] = [:]
        for s in samples {
            let mins = s.end.timeIntervalSince(s.start) / 60
            switch s.stage {
            case .asleepDeep:
                let day = dayOf(s.end)
                out[day, default: SleepDayMinutes()].asleep += mins
                out[day]!.deep = (out[day]!.deep ?? 0) + mins
            case .asleepREM:
                let day = dayOf(s.end)
                out[day, default: SleepDayMinutes()].asleep += mins
                out[day]!.rem = (out[day]!.rem ?? 0) + mins
            case .asleepCore, .asleepUnspecified:
                let day = dayOf(s.end)
                out[day, default: SleepDayMinutes()].asleep += mins
                out[day]!.core = (out[day]!.core ?? 0) + mins
            case .inBed, .awake, .unknown:
                continue
            }
        }
        return out
    }
}
