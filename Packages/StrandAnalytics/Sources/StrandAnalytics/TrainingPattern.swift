import Foundation

// TrainingPattern.swift — when THIS athlete usually trains, learned from his own last 8 weeks of workouts and
// logged WODs. Pure and deterministic: no clock, no Calendar.current, no UserDefaults. The caller converts each
// session's start into a local "yyyy-MM-dd" day key, a weekday (Calendar numbering, 1 = Sunday ... 7 = Saturday)
// and the minute of the local day, and says what "today" is.
//
// Rules
//  1. Window. N = whole weeks observed = min(8, floor(days from the first day with data to today, both
//     included / 7)). The first day with data is `dataSince` when given, else the oldest session day. The window
//     is the 7·N days ending on `today`, so every weekday occurs exactly N times in it. N < 4 -> no weekdays.
//  2. A session counts when its duration is unknown (a WOD logged with only a time) or at least 20 minutes
//     (shorter bouts are walks, warm-ups or detector noise). Several sessions on one day (a strap workout and
//     the WOD logged for it) are ONE training day: the longest one gives the start time and the duration.
//  3. Weekdays. A weekday counts as "usual" when it had a training day in at least half of the N weeks
//     (2·days >= N). No weekday passing leaves the result nil (the pattern is too loose to name days).
//  4. Start time and duration: the median over the training days in the window, rounded to 5 minutes, needing
//     at least 6 training days (6 with a known duration for the duration). Plain median: the usual start is an
//     afternoon / evening time, so wrap-around at midnight is not handled.
// An association in one person's log, not a plan he committed to.
public enum TrainingPattern {

    // MARK: - Constants

    public static let maxWeeks = 8
    public static let minWeeks = 4
    /// A weekday is "usual" when trained in at least this share of the weeks observed.
    public static let usualShare = 0.5
    /// Fewest training days before a median start time (or duration) is given.
    public static let minSessions = 6
    /// Sessions known to be shorter than this are not training.
    public static let minDurationMinutes = 20

    // MARK: - Types

    public struct Session: Equatable, Sendable {
        /// Local day of the session's start, "yyyy-MM-dd".
        public let day: String
        /// 1 = Sunday ... 7 = Saturday (Calendar's numbering), local.
        public let weekday: Int
        /// Minutes after local midnight of the session's start.
        public let startMinutes: Int
        /// nil when unknown.
        public let durationMinutes: Int?
        public init(day: String, weekday: Int, startMinutes: Int, durationMinutes: Int?) {
            self.day = day; self.weekday = weekday; self.startMinutes = startMinutes
            self.durationMinutes = durationMinutes
        }
    }

    public struct Result: Equatable, Sendable {
        /// Usual training weekdays (1 = Sunday ... 7 = Saturday), nil with too little data.
        public let weekdays: Set<Int>?
        public let startMinutes: Int?
        public let durationMinutes: Int?
        public let weeksObserved: Int
        /// Training days in the window.
        public let sessionDays: Int
        public init(weekdays: Set<Int>?, startMinutes: Int?, durationMinutes: Int?,
                    weeksObserved: Int, sessionDays: Int) {
            self.weekdays = weekdays; self.startMinutes = startMinutes; self.durationMinutes = durationMinutes
            self.weeksObserved = weeksObserved; self.sessionDays = sessionDays
        }
        public static let empty = Result(weekdays: nil, startMinutes: nil, durationMinutes: nil,
                                         weeksObserved: 0, sessionDays: 0)
    }

    /// The schedule the plan works with: the learned values where there are any, the profile's otherwise.
    public struct Schedule: Equatable, Sendable {
        /// nil when the weekdays are not known (the profile only holds how many days a week).
        public let weekdays: Set<Int>?
        public let daysPerWeek: Int
        public let startMinutes: Int?
        public let sessionMinutes: Int?
        public let daysLearned: Bool
        public let startLearned: Bool
        public let durationLearned: Bool
        public init(weekdays: Set<Int>?, daysPerWeek: Int, startMinutes: Int?, sessionMinutes: Int?,
                    daysLearned: Bool, startLearned: Bool, durationLearned: Bool) {
            self.weekdays = weekdays; self.daysPerWeek = daysPerWeek; self.startMinutes = startMinutes
            self.sessionMinutes = sessionMinutes; self.daysLearned = daysLearned
            self.startLearned = startLearned; self.durationLearned = durationLearned
        }

        /// True when every field came from the data.
        public var isFullyLearned: Bool { daysLearned && startLearned && durationLearned }

        /// Whether the athlete trains on `weekday`; nil when the weekdays are unknown.
        public func trains(on weekday: Int) -> Bool? { weekdays.map { $0.contains(weekday) } }
    }

    // MARK: - Learn

    /// The usual weekdays, start time and duration from `sessions`, which may reach back further than the window.
    public static func learn(sessions: [Session], today: String, dataSince: String? = nil) -> Result {
        let valid = sessions.filter {
            (1...7).contains($0.weekday) && (0..<1440).contains($0.startMinutes)
                && ($0.durationMinutes.map { $0 >= minDurationMinutes } ?? true)
        }
        guard let first = [dataSince, valid.map(\.day).min()].compactMap({ $0 }).min(),
              let span = dayDifference(from: first, to: today), span >= 0 else { return .empty }
        let weeks = min(maxWeeks, (span + 1) / 7)
        guard weeks >= minWeeks, let from = FitnessAgeEngine.shiftDay(today, by: -(7 * weeks - 1)) else {
            return Result(weekdays: nil, startMinutes: nil, durationMinutes: nil,
                          weeksObserved: max(0, weeks), sessionDays: 0)
        }

        // One training day = the longest session of that day (unknown duration counts as shortest).
        var perDay: [String: Session] = [:]
        for s in valid where s.day >= from && s.day <= today {
            if let cur = perDay[s.day], (cur.durationMinutes ?? -1) >= (s.durationMinutes ?? -1) { continue }
            perDay[s.day] = s
        }
        let days = Array(perDay.values)

        var daysByWeekday: [Int: Int] = [:]
        for s in days { daysByWeekday[s.weekday, default: 0] += 1 }
        let usual = Set(daysByWeekday.filter { Double($0.value) >= usualShare * Double(weeks) }.keys)

        let starts = days.map { Double($0.startMinutes) }
        let durations = days.compactMap { $0.durationMinutes }.map(Double.init)
        return Result(weekdays: usual.isEmpty ? nil : usual,
                      startMinutes: starts.count >= minSessions ? roundTo5(DayPlan.median(starts)) : nil,
                      durationMinutes: durations.count >= minSessions ? roundTo5(DayPlan.median(durations)) : nil,
                      weeksObserved: weeks, sessionDays: days.count)
    }

    /// Learned values first, the profile's otherwise. The profile has no weekdays, only a count.
    public static func resolve(learned: Result, profileDaysPerWeek: Int, profileStartMinutes: Int,
                               profileSessionMinutes: Int) -> Schedule {
        let start = (0..<1440).contains(profileStartMinutes) ? profileStartMinutes : nil
        let length = profileSessionMinutes > 0 ? profileSessionMinutes : nil
        return Schedule(
            weekdays: learned.weekdays,
            daysPerWeek: learned.weekdays?.count ?? min(max(profileDaysPerWeek, 1), 7),
            startMinutes: learned.startMinutes ?? start,
            sessionMinutes: learned.durationMinutes ?? length,
            daysLearned: learned.weekdays != nil,
            startLearned: learned.startMinutes != nil,
            durationLearned: learned.durationMinutes != nil)
    }

    // MARK: - Day keys

    /// Weekday (1 = Sunday ... 7 = Saturday) of a "yyyy-MM-dd" key; nil when it is not one.
    public static func weekday(ofDayKey key: String) -> Int? {
        guard let date = utcDate(key) else { return nil }
        return utcCalendar.component(.weekday, from: date)
    }

    /// The weekday after `weekday` (7 -> 1).
    public static func nextWeekday(_ weekday: Int) -> Int { weekday % 7 + 1 }

    // MARK: - Helpers

    static func roundTo5(_ x: Double) -> Int { Int((x / 5).rounded() * 5) }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private static func utcDate(_ s: String) -> Date? {
        let p = s.split(separator: "-")
        guard p.count == 3, p[0].count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return utcCalendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// Whole days from `a` to `b`; positive when `b` is later.
    static func dayDifference(from a: String, to b: String) -> Int? {
        guard let da = utcDate(a), let db = utcDate(b) else { return nil }
        return utcCalendar.dateComponents([.day], from: da, to: db).day
    }
}
