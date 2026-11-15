import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The pure steps of `WeeklyReviewBuilder` and the number logic of `WeeklyReviewView` (no store, no clock).
final class WeeklyReviewBuilderTests: XCTestCase {

    private let rome = TimeZone(identifier: "Europe/Rome")!
    private let monday = "2026-11-09"

    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, in tz: TimeZone) -> Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return Int(c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970)
    }

    private func night(endingOn d: Int, hour: Int, minute: Int, hours: Double = 7.5) -> CachedSleepSession {
        let end = ts(2026, 11, d, hour, minute, in: rome)
        return CachedSleepSession(startTs: end - Int(hours * 3600), endTs: end,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    private func row(_ day: String, charge: Double? = nil, strain: Double? = nil, sleep: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: charge, strain: strain, exerciseCount: nil)
    }

    private func key(_ k: Int) -> String { FitnessAgeEngine.shiftDay(monday, by: k)! }

    private func context(days: [DailyMetric], tir: [(day: String, value: Double)] = [], debt: Double? = nil,
                         today: String = "2026-11-15") -> WeeklyReviewBuilder.Context {
        WeeklyReviewBuilder.Context(
            todayKey: today, days: days, wods: [], wakeByDay: [:], tirSeries: tir, sleepNeedMin: 480,
            sleepDebtMin: debt, bedtimeMinutes: 22 * 60 + 30,
            profile: DayPlanBuilder.ProfileValues(age: 30, sex: "male", weightKg: 75, heightCm: 178, goal: .performance),
            findings: [], firstWeekStart: nil)
    }

    // MARK: - Pure steps

    func testWakeMinutesByDayUsesLocalDayAndTime() {
        let sleeps = [night(endingOn: 12, hour: 7, minute: 15), night(endingOn: 10, hour: 6, minute: 30),
                      night(endingOn: 11, hour: 8, minute: 0, hours: 2)] // a nap, not a night
        let out = WeeklyReviewBuilder.wakeMinutesByDay(sleeps: sleeps, timeZone: rome)
        XCTAssertEqual(out, ["2026-11-12": 7 * 60 + 15, "2026-11-10": 6 * 60 + 30])
    }

    func testWeeklyMeanNeedsThreeValuesInTheWeek() {
        let two = [(day: key(0), value: 70.0), (day: key(1), value: 80.0)]
        XCTAssertNil(WeeklyReviewBuilder.weeklyMean(two, from: monday))
        let three = two + [(day: key(2), value: 90.0), (day: key(8), value: 0.0)] // the last one is the next week
        XCTAssertEqual(WeeklyReviewBuilder.weeklyMean(three, from: monday) ?? 0, 80, accuracy: 1e-9)
        XCTAssertNil(WeeklyReviewBuilder.weeklyMean(three, from: "bad"))
    }

    func testReviewPassesTimeInRangeOfBothWeeks() {
        let days = (0..<5).map { row(key($0), charge: 60) }
        var tir: [(day: String, value: Double)] = []
        for k in 0..<4 { tir.append((key(k), 80)) }          // this week
        for k in 1...4 { tir.append((key(-k), 70)) }         // last week
        guard case .ready(let r) = WeeklyReviewBuilder.review(context: context(days: days, tir: tir), weekStart: monday) else {
            return XCTFail("expected a review")
        }
        let hasTir = r.improved.contains { if case .metric(let c) = $0 { return c.metric == .timeInRange } else { return false } }
        XCTAssertTrue(hasTir)
    }

    func testSleepDebtOnlyReachesTheCurrentWeek() {
        // sleep average fine (500 vs need 480), so only the debt can ask for an earlier bedtime
        let this = (0..<5).map { row(key($0), sleep: 500) }
        let last = (1...5).map { row(key(-$0), sleep: 500) }
        let ctx = context(days: this + last, debt: 90)
        guard case .ready(let now) = WeeklyReviewBuilder.review(context: ctx, weekStart: monday),
              case .ready(let before) = WeeklyReviewBuilder.review(context: ctx, weekStart: key(-7)) else {
            return XCTFail("expected reviews")
        }
        XCTAssertEqual(now.oneThing, .earlierBedtime(evenings: 3, bedtimeMinutes: 22 * 60 + 30))
        XCTAssertEqual(before.oneThing, .keepGoing)
    }

    func testPlanLevelsOnlyForPastDaysWithARow() {
        let days = [row(key(0), charge: 80), row(key(1), charge: 20), row(key(3), charge: 80)]
        let ctx = context(days: days, today: key(2))
        let levels = WeeklyReviewBuilder.planLevels(context: ctx, keys: WeeklyReview.weekKeys(monday)!)
        XCTAssertEqual(Set(levels.keys), [key(0), key(1)], "no row on day 2, and day 3 is in the future")
        XCTAssertEqual(levels[key(0)], .push)
        XCTAssertEqual(levels[key(1)], .easy)
    }

    // MARK: - View numbers

    func testRowsFromMetricChanges() {
        let up = WeeklyReview.Change(metric: .sleep, thisWeek: 450, lastWeek: 420, change: 30, changePct: 7.1)
        let down = WeeklyReview.Change(metric: .restingHr, thisWeek: 58, lastWeek: 55, change: 3, changePct: 5.5)
        let rows = WeeklyReviewView.rows([.metric(up), .metric(down)])
        XCTAssertEqual(rows.map(\.up), [true, true])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        let lower = WeeklyReviewView.metricRow(.init(metric: .charge, thisWeek: 50, lastWeek: 60, change: -10, changePct: -16.7), id: "x")
        XCTAssertFalse(lower.up)
        XCTAssertTrue(lower.spoken.contains(lower.value))
    }

    func testRecordAndBestRows() {
        let wod = WodLogRow(id: "a", ts: 1, day: monday, type: "wod", title: "Fran", resultKind: .time,
                            resultSeconds: 380, createdTs: 1)
        let rows = WeeklyReviewView.rows([.strengthRecord(name: "Back Squat", weightKg: 105),
                                          .wodBest(.init(title: "Fran", row: wod))])
        XCTAssertEqual(rows.map(\.label), ["Back Squat", "Fran"])
        XCTAssertTrue(rows[0].value.contains("105"))
        XCTAssertTrue(rows[1].value.contains("6") && rows[1].value.contains("20"), "6:20")
        XCTAssertEqual(rows.map(\.up), [true, true])
    }

    func testFindingSentenceCarriesTheNumbersAndDirection() {
        let f = PlanLearning.Finding(kind: .shortSleep, groupA: .init(n: 8, mean: 50), groupB: .init(n: 10, mean: 62),
                                     difference: -12, t: -3, isReliable: true)
        let text = WeeklyReviewView.findingText(f)
        XCTAssertTrue(text.contains("12"))
        XCTAssertTrue(text.contains("18"), "8 + 10 nights")
        let g = PlanLearning.Finding(kind: .shortSleep, groupA: .init(n: 8, mean: 62), groupB: .init(n: 10, mean: 50),
                                     difference: 12, t: 3, isReliable: true)
        XCTAssertNotEqual(WeeklyReviewView.findingText(g), text, "higher and lower read differently")
    }

    func testEveryHeadlineAndOneThingHasText() {
        for h in WeeklyReview.Headline.allCases { XCTAssertFalse(WeeklyReviewView.headlineText(h).isEmpty) }
        let ones: [WeeklyReview.OneThing] = [.earlierBedtime(evenings: 4, bedtimeMinutes: 1350),
                                             .earlierBedtime(evenings: 4, bedtimeMinutes: nil), .steadyWake(sdMinutes: 70),
                                             .oneEasierDay, .oneMoreSession, .keepGoing]
        for o in ones { XCTAssertFalse(WeeklyReviewView.oneThingText(o).isEmpty) }
        XCTAssertTrue(WeeklyReviewView.oneThingText(ones[0]).contains("4"))
    }

    func testDateKeyAndRange() {
        XCTAssertNotNil(WeeklyReviewView.date("2026-11-09"))
        XCTAssertNil(WeeklyReviewView.date("nope"))
        XCTAssertFalse(WeeklyReviewView.rangeText(start: "2026-11-09", end: "2026-11-15").isEmpty)
        XCTAssertEqual(WeeklyReviewView.rangeText(start: "bad", end: "2026-11-15"), "bad")
    }
}
