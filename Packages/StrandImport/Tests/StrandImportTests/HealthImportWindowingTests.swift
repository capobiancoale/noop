import XCTest
@testable import StrandImport

/// The Apple Health import reads a long history in 30-day windows. These tests prove that, with the
/// windows' margins (`glucoseLeadIn`/`glucoseLeadOut`, `leadInDays`) and each window keeping only its own
/// days, the per-day results are exactly those of one read over the whole period: no hypo counted twice
/// or lost at a window's edge, no post-exercise low cut short, no night of sleep split.
final class HealthImportWindowingTests: XCTestCase {

    private var rome: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    private lazy var dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = rome.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func day(_ d: Date) -> String { dayFormatter.string(from: d) }

    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// 75 days of 5-minute CGM from 1 Aug 2026 (crossing the 25 Oct change of time), with dips from
    /// 23:40 to 00:35 every third night, a 5½-hour low from 20:00 every seventh, and sensor gaps.
    private func glucoseTrace() -> [GlucoseReading] {
        var rng = LCG(state: 42)
        let start = rome.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        var out: [GlucoseReading] = []
        var t = start
        var mg = 130.0
        while t < rome.date(byAdding: .day, value: 75, to: start)! {
            let c = rome.dateComponents([.hour, .minute], from: t)
            let minute = c.hour! * 60 + c.minute!
            let dayIndex = rome.dateComponents([.day], from: start, to: rome.startOfDay(for: t)).day!
            if dayIndex % 11 == 5, (120..<240).contains(minute) { t += 300; continue }        // gap 02:00–04:00
            mg = min(max(mg + (rng.next() - 0.5) * 10, 75), 300)
            var value = mg
            let nearMidnight = minute >= 23 * 60 + 40 || minute < 35
            let nightIndex = minute < 35 ? dayIndex - 1 : dayIndex                             // the night it belongs to
            if nearMidnight, nightIndex % 3 == 0 { value = 55 + rng.next() * 10 }
            if nightIndex % 7 == 0, minute >= 20 * 60 || minute < 90 { value = 58 + rng.next() * 8 }
            if rng.next() < 0.004 { mg = 50 }                                                  // random dip start
            out.append(GlucoseReading(ts: t.timeIntervalSince1970, day: day(t), minutesLocal: minute, mgdl: value))
            t += 300
        }
        return out
    }

    private func workouts(over readings: [GlucoseReading]) -> [WorkoutWindow] {
        let start = Date(timeIntervalSince1970: readings.first!.ts)
        var out: [WorkoutWindow] = []
        for d in 0..<75 {
            let base = rome.startOfDay(for: rome.date(byAdding: .day, value: d, to: start)!)
            func add(_ h: Int, _ m: Int, minutes: Double) {
                let s = rome.date(byAdding: .minute, value: h * 60 + m, to: base)!
                out.append(WorkoutWindow(start: s.timeIntervalSince1970, end: s.timeIntervalSince1970 + minutes * 60,
                                         day: day(s)))
            }
            if d % 2 == 0 { add(18, 0, minutes: 75) }
            if d % 5 == 0 { add(22, 30, minutes: 120) }                                      // ends after midnight
            if d % 13 == 0 { add(17, 0, minutes: 300) }                                      // a 5-hour hike
        }
        return out
    }

    func testGlucoseReadInWindowsMatchesOneWholePeriodRead() {
        let readings = glucoseTrace()
        let workouts = workouts(over: readings)
        let whole = (daily: DiabetesMetrics.glucoseDaily(readings),
                     post: DiabetesMetrics.postWorkoutGlucose(readings: readings, workouts: workouts))
        XCTAssertGreaterThan(whole.daily.values.reduce(0) { $0 + $1.hypoEvents }, 30)

        let first = Date(timeIntervalSince1970: readings.first!.ts)
        let last = Date(timeIntervalSince1970: readings.last!.ts + 1)
        let windows = HealthImportPlan.windows(from: first, to: last, isHistory: true, calendar: rome)
        XCTAssertGreaterThan(windows.count, 2)

        var daily: [String: GlucoseDayStats] = [:], post: [String: PostWorkoutGlucose] = [:]
        for w in windows {
            let lo = w.start.timeIntervalSince1970 - HealthImportPlan.glucoseLeadIn
            let hi = w.end.timeIntervalSince1970 + HealthImportPlan.glucoseLeadOut
            let rs = readings.filter { $0.ts >= lo && $0.ts < hi }
            let ws = workouts.filter { $0.start >= w.start.timeIntervalSince1970 && $0.start < w.end.timeIntervalSince1970 }
            let part = HealthImportPlan.glucose(forDays: Set(HealthImportPlan.days(of: w, calendar: rome)),
                                                readings: rs, workouts: ws)
            for (k, v) in part.daily { XCTAssertNil(daily.updateValue(v, forKey: k), "day \(k) in two windows") }
            for (k, v) in part.postWorkout { XCTAssertNil(post.updateValue(v, forKey: k), "day \(k) in two windows") }
        }
        XCTAssertEqual(daily, whole.daily)
        XCTAssertEqual(post, whole.post)
    }

    func testSleepReadInWindowsMatchesOneWholePeriodRead() {
        var rng = LCG(state: 7)
        let start = rome.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        var samples: [SleepStageSample] = []
        let stages: [SleepStage] = [.asleepCore, .asleepDeep, .asleepREM, .awake, .asleepUnspecified]
        for n in 0..<60 {
            let night = rome.date(byAdding: .day, value: n, to: start)!
            var t = rome.date(bySettingHour: 22, minute: 30, second: 0, of: night)!
                .addingTimeInterval(rng.next() * 3_600)
            let wake = rome.date(byAdding: .hour, value: 9, to: t)!
            samples.append(SleepStageSample(start: t, end: wake, stage: .inBed))
            if n % 4 == 0 {                                                                   // a block ending exactly at midnight
                let midnight = rome.startOfDay(for: rome.date(byAdding: .day, value: 1, to: night)!)
                samples.append(SleepStageSample(start: midnight.addingTimeInterval(-3_600), end: midnight, stage: .asleepCore))
                t = midnight
            }
            while t < wake {
                let e = min(wake, t.addingTimeInterval((20 + rng.next() * 70) * 60))
                samples.append(SleepStageSample(start: t, end: e, stage: stages[Int(rng.next() * Double(stages.count))]))
                t = e
            }
        }
        samples.sort { $0.start < $1.start }
        let whole = AppleSleepStages.minutesByDay(samples, dayOf: day)

        let last = samples.map(\.end).max()!.addingTimeInterval(1)
        var merged: [String: SleepDayMinutes] = [:]
        for w in HealthImportPlan.windows(from: start, to: last, isHistory: true, calendar: rome) {
            // HealthKit's overlap predicate over the window plus its lead-in day.
            let lo = rome.date(byAdding: .day, value: -HealthImportPlan.leadInDays, to: w.start)!
            let inRange = samples.filter { $0.end > lo && $0.start < w.end }
            let own = Set(HealthImportPlan.days(of: w, calendar: rome))
            for (k, v) in AppleSleepStages.minutesByDay(inRange, dayOf: day) where own.contains(k) {
                XCTAssertNil(merged.updateValue(v, forKey: k), "day \(k) in two windows")
            }
        }
        XCTAssertEqual(merged, whole)
    }

    func testSleepStagesCountAsleepTimeOnTheDayEachSampleEnds() {
        let t0 = rome.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 23))!
        let samples = [
            SleepStageSample(start: t0, end: t0 + 1_800, stage: .asleepDeep),                  // 23:00–23:30 → 1 Sep
            SleepStageSample(start: t0 + 1_800, end: t0 + 5_400, stage: .asleepREM),           // 23:30–00:30 → 2 Sep
            SleepStageSample(start: t0 + 5_400, end: t0 + 7_200, stage: .asleepUnspecified),   // counts as core
            SleepStageSample(start: t0, end: t0 + 7_200, stage: .inBed),                       // ignored
            SleepStageSample(start: t0 + 7_200, end: t0 + 7_800, stage: .awake),               // ignored
        ]
        let m = AppleSleepStages.minutesByDay(samples, dayOf: day)
        XCTAssertEqual(m["2026-09-01"], SleepDayMinutes(asleep: 30, deep: 30))
        XCTAssertEqual(m["2026-09-02"], SleepDayMinutes(asleep: 90, rem: 60, core: 30))
        XCTAssertEqual(m.count, 2)
    }

    func testWindowDaysAreDisjointAndCoverTheWholePeriod() {
        let now = rome.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 8))!
        let plan = HealthImportPlan.plan(now: now, routineDays: HealthImportPlan.recentDays, includeHistory: true,
                                         historyDone: false, historySavedFrom: nil, calendar: rome)
        let days = plan.flatMap { HealthImportPlan.days(of: $0, calendar: rome) }
        XCTAssertEqual(days.count, Set(days).count, "no day belongs to two windows")
        XCTAssertEqual(days.count, HealthImportPlan.historyDays + 1)    // target day … today
        XCTAssertEqual(days.max(), "2026-11-03")                         // today
        XCTAssertEqual(days.min(), day(HealthImportPlan.historyTarget(now: now, calendar: rome)!))
    }
}
