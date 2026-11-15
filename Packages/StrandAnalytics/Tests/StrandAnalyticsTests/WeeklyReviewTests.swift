import XCTest
import WhoopStore
@testable import StrandAnalytics

final class WeeklyReviewTests: XCTestCase {

    let thisMonday = "2026-11-09"   // a Monday
    let lastMonday = "2026-11-02"

    struct F {
        var sleep: Double?; var charge: Double?; var hrv: Double?; var rhr: Int?; var strain: Double?
        init(sleep: Double? = nil, charge: Double? = nil, hrv: Double? = nil, rhr: Int? = nil, strain: Double? = nil) {
            self.sleep = sleep; self.charge = charge; self.hrv = hrv; self.rhr = rhr; self.strain = strain
        }
    }

    func day(_ start: String, _ k: Int) -> String { FitnessAgeEngine.shiftDay(start, by: k)! }

    func row(_ d: String, _ f: F) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: f.sleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: f.rhr, avgHrv: f.hrv, recovery: f.charge, strain: f.strain,
                    exerciseCount: nil)
    }

    func week(_ start: String, _ n: Int, _ f: F) -> [DailyMetric] { (0..<n).map { row(day(start, $0), f) } }

    /// 28 days before last Monday... i.e. the days 35...8 back from this week's Sunday, all at one Effort.
    func baseline(strain: Double = 50) -> [DailyMetric] {
        (0..<28).map { row(day("2026-10-05", $0), F(strain: strain)) }
    }

    func ready(_ days: [DailyMetric], wods: [WodLogRow] = [], wake: [String: Int] = [:], plan: [String: DayPlan.Training] = [:],
               tir: (Double?, Double?) = (nil, nil), need: Double? = nil, debt: Double? = nil,
               bed: Int? = nil, file: StaticString = #filePath, line: UInt = #line) -> WeeklyReview.Review {
        let i = WeeklyReview.Inputs(days: days, weekStart: thisMonday, wakeMinutesByDay: wake, wods: wods,
                                    planLevelByDay: plan, timeInRangeThisWeek: tir.0, timeInRangeLastWeek: tir.1,
                                    sleepNeedMin: need, sleepDebtMin: debt, bedtimeMinutes: bed)
        guard case .ready(let r) = WeeklyReview.make(i) else {
            XCTFail("expected a review", file: file, line: line)
            return WeeklyReview.Review(weekStart: "", weekEnd: "", days: [], daysWithData: 0, improved: [], worsened: [],
                                       headline: .steady, oneThing: .keepGoing, adherence: nil, loadRatio: nil)
        }
        return r
    }

    func change(_ items: [WeeklyReview.Item], _ m: WeeklyReview.Metric) -> WeeklyReview.Change? {
        for case .metric(let c) in items where c.metric == m { return c }
        return nil
    }

    /// improved / worsened / neither for one metric.
    func verdict(_ m: WeeklyReview.Metric, this: F, last: F, nThis: Int = 5, nLast: Int = 5) -> String {
        var a = this, b = last
        if a.charge == nil { a.charge = 60 }   // a row with only an HRV or resting HR carries no "data"
        if b.charge == nil { b.charge = 60 }
        let r = ready(week(thisMonday, nThis, a) + week(lastMonday, nLast, b))
        if change(r.improved, m) != nil { return "improved" }
        if change(r.worsened, m) != nil { return "worsened" }
        return "none"
    }

    // MARK: - Week keys and the gate

    func testMondayKey() {
        XCTAssertEqual(WeeklyReview.mondayKey(of: "2026-11-15"), "2026-11-09") // Sunday
        XCTAssertEqual(WeeklyReview.mondayKey(of: "2026-11-09"), "2026-11-09")
        XCTAssertEqual(WeeklyReview.mondayKey(of: "2026-11-10"), "2026-11-09")
        XCTAssertEqual(WeeklyReview.mondayKey(of: "2026-01-01"), "2025-12-29")
        XCTAssertNil(WeeklyReview.mondayKey(of: "nope"))
    }

    func testNeedsFourDaysWithData() {
        let three = WeeklyReview.make(.init(days: week(thisMonday, 3, F(charge: 60)), weekStart: thisMonday))
        guard case .insufficient(let cells, let n) = three else { return XCTFail("3 days is not enough") }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(cells.count, 7)
        guard case .ready(let r) = WeeklyReview.make(.init(days: week(thisMonday, 4, F(charge: 60)), weekStart: thisMonday)) else {
            return XCTFail("4 days is enough")
        }
        XCTAssertEqual(r.daysWithData, 4)
        XCTAssertEqual(r.weekEnd, "2026-11-15")
    }

    func testAnyOfChargeEffortOrSleepCountsAsData() {
        let days = [row(day(thisMonday, 0), F(charge: 50)), row(day(thisMonday, 1), F(strain: 30)),
                    row(day(thisMonday, 2), F(sleep: 400)), row(day(thisMonday, 3), F(hrv: 50))]
        // the 4th row has only an HRV: not counted
        guard case .insufficient(_, let n) = WeeklyReview.make(.init(days: days, weekStart: thisMonday)) else {
            return XCTFail()
        }
        XCTAssertEqual(n, 3)
    }

    func testBadWeekStart() {
        XCTAssertEqual(WeeklyReview.make(.init(days: [], weekStart: "x")), .insufficient(days: [], daysWithData: 0))
    }

    // MARK: - Day strip

    func testLevelsAtTheEdges() {
        let charges: [Double] = [33.4, 34, 66.4, 66.9, 67, 100]
        let days = charges.enumerated().map { row(day(thisMonday, $0.offset), F(charge: $0.element)) }
        let r = ready(days)
        XCTAssertEqual(r.days.map(\.level), [.easy, .maintain, .maintain, .maintain, .push, .push, nil])
        XCTAssertEqual(r.days.map(\.charge), [33, 34, 66, 67, 67, 100, nil])
        XCTAssertEqual(r.days.map(\.day).first, thisMonday)
    }

    // MARK: - Metric thresholds (this week vs last week, just under and at/over)

    func testSleepThreshold() {
        XCTAssertEqual(verdict(.sleep, this: F(sleep: 435), last: F(sleep: 420)), "improved")
        XCTAssertEqual(verdict(.sleep, this: F(sleep: 434), last: F(sleep: 420)), "none")
        XCTAssertEqual(verdict(.sleep, this: F(sleep: 405), last: F(sleep: 420)), "worsened")
        XCTAssertEqual(verdict(.sleep, this: F(sleep: 406), last: F(sleep: 420)), "none")
    }

    func testChargeThreshold() {
        XCTAssertEqual(verdict(.charge, this: F(charge: 64), last: F(charge: 60)), "improved")
        XCTAssertEqual(verdict(.charge, this: F(charge: 63.9), last: F(charge: 60)), "none")
        XCTAssertEqual(verdict(.charge, this: F(charge: 56), last: F(charge: 60)), "worsened")
        XCTAssertEqual(verdict(.charge, this: F(charge: 56.1), last: F(charge: 60)), "none")
    }

    func testHrvThresholdIsPercent() {
        XCTAssertEqual(verdict(.hrv, this: F(hrv: 105), last: F(hrv: 100)), "improved")
        XCTAssertEqual(verdict(.hrv, this: F(hrv: 104.9), last: F(hrv: 100)), "none")
        XCTAssertEqual(verdict(.hrv, this: F(hrv: 95), last: F(hrv: 100)), "worsened")
        XCTAssertEqual(verdict(.hrv, this: F(hrv: 95.1), last: F(hrv: 100)), "none")
        // 5 ms on a base of 40 is 12 %, on a base of 200 it is 2.5 %
        XCTAssertEqual(verdict(.hrv, this: F(hrv: 45), last: F(hrv: 40)), "improved")
        XCTAssertEqual(verdict(.hrv, this: F(hrv: 205), last: F(hrv: 200)), "none")
    }

    func testRestingHrThresholdLowerIsBetter() {
        XCTAssertEqual(verdict(.restingHr, this: F(rhr: 53), last: F(rhr: 55)), "improved")
        XCTAssertEqual(verdict(.restingHr, this: F(rhr: 54), last: F(rhr: 55)), "none")
        XCTAssertEqual(verdict(.restingHr, this: F(rhr: 57), last: F(rhr: 55)), "worsened")
        XCTAssertEqual(verdict(.restingHr, this: F(rhr: 56), last: F(rhr: 55)), "none")
    }

    func wakes(_ start: String, sd k: Double, n: Int = 6) -> [String: Int] {
        var out: [String: Int] = [:]
        for j in 0..<n { out[day(start, j)] = Int(420 + (j % 2 == 0 ? -k : k)) }
        return out
    }

    func wakeVerdict(this: Double, last: Double) -> String {
        let days = week(thisMonday, 5, F(charge: 60)) + week(lastMonday, 5, F(charge: 60))
        let r = ready(days, wake: wakes(thisMonday, sd: this).merging(wakes(lastMonday, sd: last)) { a, _ in a })
        if change(r.improved, .wakeSpread) != nil { return "improved" }
        if change(r.worsened, .wakeSpread) != nil { return "worsened" }
        return "none"
    }

    func testWakeSpreadThresholdLowerIsBetter() {
        XCTAssertEqual(wakeVerdict(this: 30, last: 10), "worsened")
        XCTAssertEqual(wakeVerdict(this: 29, last: 10), "none")
        XCTAssertEqual(wakeVerdict(this: 10, last: 30), "improved")
        XCTAssertEqual(wakeVerdict(this: 10, last: 29), "none")
    }

    func testWakeSpreadNeedsFourWakeTimesInBothWeeks() {
        let days = week(thisMonday, 5, F(charge: 60)) + week(lastMonday, 5, F(charge: 60))
        let few = wakes(thisMonday, sd: 40, n: 6).merging(wakes(lastMonday, sd: 5, n: 3)) { a, _ in a }
        XCTAssertNil(change(ready(days, wake: few).worsened, .wakeSpread))
        let enough = wakes(thisMonday, sd: 40, n: 6).merging(wakes(lastMonday, sd: 5, n: 4)) { a, _ in a }
        XCTAssertNotNil(change(ready(days, wake: enough).worsened, .wakeSpread))
    }

    func testTimeInRangeThreshold() {
        let days = week(thisMonday, 5, F(charge: 60))
        XCTAssertNotNil(change(ready(days, tir: (73, 70)).improved, .timeInRange))
        XCTAssertNil(change(ready(days, tir: (72.9, 70)).improved, .timeInRange))
        XCTAssertNotNil(change(ready(days, tir: (70, 73)).worsened, .timeInRange))
        XCTAssertNil(change(ready(days, tir: (70, 72.9)).worsened, .timeInRange))
        XCTAssertNil(change(ready(days, tir: (73, nil)).improved, .timeInRange))
    }

    func testMetricNeedsThreeDaysInBothWeeks() {
        XCTAssertEqual(verdict(.sleep, this: F(sleep: 480), last: F(sleep: 400), nThis: 5, nLast: 2), "none")
        XCTAssertEqual(verdict(.sleep, this: F(sleep: 480), last: F(sleep: 400), nThis: 5, nLast: 3), "improved")
        // a week with 3 days is no review at all
        let three = WeeklyReview.make(.init(days: week(thisMonday, 3, F(sleep: 480)) + week(lastMonday, 5, F(sleep: 400)), weekStart: thisMonday))
        guard case .insufficient = three else { return XCTFail("3 days") }
    }

    func testChangeNumbers() {
        let r = ready(week(thisMonday, 5, F(charge: 60, hrv: 110)) + week(lastMonday, 5, F(charge: 60, hrv: 100)))
        let c = change(r.improved, .hrv)
        XCTAssertEqual(c?.thisWeek ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(c?.lastWeek ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(c?.change ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(c?.changePct ?? 0, 10, accuracy: 1e-9)
    }

    // MARK: - Records and bests

    func lift(_ id: String, _ d: String, kg: Double, name: String = "Back Squat") -> WodLogRow {
        WodLogRow(id: id, ts: ts(d), day: d, type: "strength", title: "Squat day",
                  movements: [WodMovement(name: name, scheme: "5x5", weightKg: kg)], createdTs: ts(d))
    }

    func ts(_ d: String, hour: Int = 10) -> Int {
        let p = d.split(separator: "-").map { Int($0)! }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return Int(cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!.timeIntervalSince1970)
    }

    func fran(_ id: String, _ d: String, seconds: Int) -> WodLogRow {
        WodLogRow(id: id, ts: ts(d), day: d, type: "wod", title: "Fran", resultKind: .time, resultSeconds: seconds,
                  createdTs: ts(d))
    }

    func testStrengthRecordThisWeek() {
        let wods = [lift("a", "2026-10-20", kg: 100), lift("b", day(thisMonday, 1), kg: 105)]
        let r = ready(week(thisMonday, 5, F(charge: 60)), wods: wods)
        XCTAssertEqual(r.improved, [.strengthRecord(name: "Back Squat", weightKg: 105)])
    }

    func testFirstEntryTieAndLastWeekAreNotRecords() {
        let first = ready(week(thisMonday, 5, F(charge: 60)), wods: [lift("a", day(thisMonday, 1), kg: 100)])
        XCTAssertTrue(first.improved.isEmpty, "the first entry of a movement is no record")
        let tie = ready(week(thisMonday, 5, F(charge: 60)),
                        wods: [lift("a", "2026-10-20", kg: 100), lift("b", day(thisMonday, 1), kg: 100)])
        XCTAssertTrue(tie.improved.isEmpty)
        let earlier = ready(week(thisMonday, 5, F(charge: 60)),
                            wods: [lift("a", "2026-10-20", kg: 100), lift("b", day(lastMonday, 1), kg: 105)])
        XCTAssertTrue(earlier.improved.isEmpty, "a record set last week is not this week's")
    }

    func testHeaviestRecordOfTheWeekPerMovement() {
        let wods = [lift("a", "2026-10-20", kg: 100), lift("b", day(thisMonday, 0), kg: 105), lift("c", day(thisMonday, 3), kg: 110)]
        let r = ready(week(thisMonday, 5, F(charge: 60)), wods: wods)
        XCTAssertEqual(r.improved, [.strengthRecord(name: "Back Squat", weightKg: 110)])
    }

    func testWodBest() {
        let days = week(thisMonday, 5, F(charge: 60))
        let better = ready(days, wods: [fran("a", "2026-10-20", seconds: 400), fran("b", day(thisMonday, 2), seconds: 380)])
        XCTAssertEqual(better.improved.count, 1)
        if case .wodBest(let b)? = better.improved.first { XCTAssertEqual(b.title, "Fran"); XCTAssertEqual(b.row.resultSeconds, 380) }
        else { XCTFail("expected a WOD best") }
        let slower = ready(days, wods: [fran("a", "2026-10-20", seconds: 400), fran("b", day(thisMonday, 2), seconds: 420)])
        XCTAssertTrue(slower.improved.isEmpty)
        let firstTime = ready(days, wods: [fran("b", day(thisMonday, 2), seconds: 380)])
        XCTAssertTrue(firstTime.improved.isEmpty)
        let tie = ready(days, wods: [fran("a", "2026-10-20", seconds: 400), fran("b", day(thisMonday, 2), seconds: 400)])
        XCTAssertTrue(tie.improved.isEmpty)
    }

    func testWodBestsNeverWorsen() {
        let r = ready(week(thisMonday, 5, F(charge: 60)),
                      wods: [fran("a", "2026-10-20", seconds: 300), fran("b", day(thisMonday, 2), seconds: 500)])
        XCTAssertTrue(r.worsened.isEmpty)
    }

    // MARK: - Headline

    func testBothBetter() {
        let days = week(thisMonday, 5, F(sleep: 440)) + week(lastMonday, 5, F(sleep: 420))
        let wods = [lift("a", "2026-10-20", kg: 100), lift("b", day(thisMonday, 1), kg: 105)]
        XCTAssertEqual(ready(days, wods: wods).headline, .bothBetter)
    }

    func testStrongerLessSleep() {
        let days = week(thisMonday, 5, F(sleep: 400)) + week(lastMonday, 5, F(sleep: 420))
        let wods = [lift("a", "2026-10-20", kg: 100), lift("b", day(thisMonday, 1), kg: 105)]
        XCTAssertEqual(ready(days, wods: wods).headline, .strongerLessSleep)
    }

    func testSleepBetterWithoutPerformanceIsNotBothBetter() {
        let days = week(thisMonday, 5, F(sleep: 440)) + week(lastMonday, 5, F(sleep: 420))
        XCTAssertEqual(ready(days).headline, .steady)
    }

    func testBetterRecovery() {
        XCTAssertEqual(ready(week(thisMonday, 5, F(charge: 65)) + week(lastMonday, 5, F(charge: 60))).headline, .betterRecovery)
        // one up, one down: no
        let mixed = week(thisMonday, 5, F(charge: 65, rhr: 58)) + week(lastMonday, 5, F(charge: 60, rhr: 55))
        XCTAssertEqual(ready(mixed).headline, .steady)
    }

    func loadWeek(effort: Double) -> [DailyMetric] { baseline() + week(lastMonday, 7, F(strain: 50)) + week(thisMonday, 7, F(strain: effort)) }

    func testHeavyAndQuietWeekFollowTheLoadRatio() {
        // baseline = 28 days at Effort 50 (days 8-35 back are all Effort 50)
        let heavy = ready(loadWeek(effort: 53.7))
        XCTAssertGreaterThan(heavy.loadRatio ?? 0, 1.3)
        XCTAssertLessThan(heavy.loadRatio ?? 9, 1.5)
        XCTAssertEqual(heavy.headline, .heavyWeek)
        XCTAssertEqual(ready(loadWeek(effort: 40)).headline, .quietWeek)
        XCTAssertEqual(ready(loadWeek(effort: 50)).headline, .steady)
    }

    func testHeadlineEdgesOfTheRatio() {
        // ratio just under 1.3 is steady, just over is heavy; just under 0.8 is quiet
        func ratio(_ e: Double) -> Double { ready(loadWeek(effort: e)).loadRatio ?? 0 }
        func effort(forRatio r: Double) -> Double { log(r * (pow(7201.0, 0.5) - 1) + 1) / log(7201.0) * 100 }
        let under = effort(forRatio: 1.29), over = effort(forRatio: 1.31)
        XCTAssertEqual(ratio(under), 1.29, accuracy: 0.005)
        XCTAssertEqual(ready(loadWeek(effort: under)).headline, .steady)
        XCTAssertEqual(ready(loadWeek(effort: over)).headline, .heavyWeek)
        XCTAssertEqual(ready(loadWeek(effort: effort(forRatio: 0.81))).headline, .steady)
        XCTAssertEqual(ready(loadWeek(effort: effort(forRatio: 0.79))).headline, .quietWeek)
    }

    func testHeadlinePriorityRecoveryBeforeLoad() {
        var days = loadWeek(effort: 70)
        days = days.map { d in
            d.day >= thisMonday ? row(d.day, F(charge: 70, strain: d.strain)) : row(d.day, F(charge: 60, strain: d.strain))
        }
        let r = ready(days)
        XCTAssertGreaterThan(r.loadRatio ?? 0, 1.5)
        XCTAssertEqual(r.headline, .betterRecovery)
    }

    // MARK: - One thing

    func sleepWeek(_ v: Double, n: Int = 5) -> [DailyMetric] { week(thisMonday, n, F(sleep: v)) }

    func testSleepAverageUnderNeedByMoreThan45() {
        // need 480: 435 is exactly 45 under, not more
        XCTAssertEqual(ready(sleepWeek(435)).oneThing, .keepGoing)
        XCTAssertEqual(ready(sleepWeek(434), bed: 22 * 60 + 30).oneThing, .earlierBedtime(evenings: 5, bedtimeMinutes: 1350))
    }

    func testSleepRuleNeedsFourNightsAndUsesTheNeed() {
        let days = week(thisMonday, 3, F(sleep: 300)) + [row(day(thisMonday, 3), F(charge: 50))]
        XCTAssertEqual(ready(days).oneThing, .keepGoing, "3 nights with a value is not enough")
        XCTAssertEqual(ready(sleepWeek(420), need: 540).oneThing, .earlierBedtime(evenings: 5, bedtimeMinutes: nil))
        XCTAssertEqual(ready(sleepWeek(420), need: 450).oneThing, .keepGoing)
    }

    func testSleepDebtTriggersAndEveningsAreClamped() {
        XCTAssertEqual(ready(sleepWeek(500), debt: 59).oneThing, .keepGoing)
        // no short night at all: still 3 evenings
        XCTAssertEqual(ready(sleepWeek(500), debt: 60).oneThing, .earlierBedtime(evenings: 3, bedtimeMinutes: nil))
        // 7 short nights: capped at 5
        XCTAssertEqual(ready(sleepWeek(300, n: 7)).oneThing, .earlierBedtime(evenings: 5, bedtimeMinutes: nil))
        // 4 short nights out of 5 with a low average -> 4
        let days = week(thisMonday, 4, F(sleep: 380)) + [row(day(thisMonday, 4), F(sleep: 600))]
        XCTAssertEqual(ready(days).oneThing, .earlierBedtime(evenings: 4, bedtimeMinutes: nil))
    }

    func testSteadyWakeAbove60() {
        let days = week(thisMonday, 5, F(sleep: 480, charge: 60))
        XCTAssertEqual(ready(days, wake: wakes(thisMonday, sd: 61)).oneThing, .steadyWake(sdMinutes: 61))
        XCTAssertEqual(ready(days, wake: wakes(thisMonday, sd: 60)).oneThing, .keepGoing)
        XCTAssertEqual(ready(days, wake: wakes(thisMonday, sd: 90, n: 3)).oneThing, .keepGoing, "3 wake times")
    }

    func testSleepOutranksWake() {
        let days = sleepWeek(400)
        XCTAssertEqual(ready(days, wake: wakes(thisMonday, sd: 90)).oneThing, .earlierBedtime(evenings: 5, bedtimeMinutes: nil))
    }

    func testLoadRules() {
        func effort(forRatio r: Double) -> Double { log(r * (pow(7201.0, 0.5) - 1) + 1) / log(7201.0) * 100 }
        XCTAssertEqual(ready(loadWeek(effort: effort(forRatio: 1.51))).oneThing, .oneEasierDay)
        XCTAssertEqual(ready(loadWeek(effort: effort(forRatio: 1.49))).oneThing, .keepGoing)
        XCTAssertEqual(ready(loadWeek(effort: effort(forRatio: 0.79))).oneThing, .oneMoreSession)
        XCTAssertEqual(ready(loadWeek(effort: effort(forRatio: 0.81))).oneThing, .keepGoing)
    }

    func testWakeOutranksLoad() {
        let days = loadWeek(effort: 70)
        XCTAssertEqual(ready(days, wake: wakes(thisMonday, sd: 80)).oneThing, .steadyWake(sdMinutes: 80))
    }

    func testNoLoadRatioWithoutHistory() {
        let r = ready(week(thisMonday, 5, F(strain: 60)))
        XCTAssertNil(r.loadRatio)
        XCTAssertEqual(r.oneThing, .keepGoing)
    }

    // MARK: - Adherence

    /// 21 prior days at Efforts 10 / 50 / 90 in turn, then the week.
    func adherenceDays(_ week: [(Double?, Double?)]) -> [DailyMetric] {
        let prior = (0..<21).map { row(day("2026-10-19", $0), F(strain: [10, 50, 90][$0 % 3])) }
        let wk = week.enumerated().map { row(day(thisMonday, $0.offset), F(charge: $0.element.0, strain: $0.element.1)) }
        return prior + wk
    }

    func testAdherenceCountsMatchedDays() {
        // push/maintain/easy from the Charge; Effort high / mid / low match, the last push day does not
        let w: [(Double?, Double?)] = [(80, 90), (50, 50), (20, 10), (80, 10), (20, 90)]
        let r = ready(adherenceDays(w))
        XCTAssertEqual(r.adherence, WeeklyReview.Adherence(judged: 5, matched: 3))
    }

    func testAdherenceNeedsFourJudgedDays() {
        XCTAssertNil(ready(adherenceDays([(80, 90), (50, 50), (20, 10), (nil, 90), (nil, 20)])).adherence)
        XCTAssertEqual(ready(adherenceDays([(80, 90), (50, 50), (20, 10), (80, 90), (nil, 20)])).adherence?.judged, 4)
    }

    func testAdherenceNeedsFourteenEffortDays() {
        let w = (0..<5).map { row(day(thisMonday, $0), F(charge: 80, strain: 90)) }
        func prior(_ n: Int) -> [DailyMetric] { (0..<n).map { row(day("2026-10-19", $0), F(strain: [10, 50, 90][$0 % 3])) } }
        XCTAssertNil(ready(prior(8) + w).adherence, "13 Effort days")
        XCTAssertNotNil(ready(prior(9) + w).adherence, "14 Effort days")
    }

    func testAdherenceUsesThePlanLevelWhenGiven() {
        let w: [(Double?, Double?)] = [(80, 90), (80, 90), (80, 90), (80, 90)]
        let days = adherenceDays(w)
        // by Charge all four are push days and all match
        XCTAssertEqual(ready(days).adherence, WeeklyReview.Adherence(judged: 4, matched: 4))
        // the plan said easy on two of them: Effort 90 does not match an easy day
        let planLevels: [String: DayPlan.Training] = [day(thisMonday, 0): .easy, day(thisMonday, 1): .easy]
        XCTAssertEqual(ready(days, plan: planLevels).adherence, WeeklyReview.Adherence(judged: 4, matched: 2))
    }
}
