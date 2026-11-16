import XCTest
import WhoopStore
@testable import StrandAnalytics

final class PlanLearningTests: XCTestCase {

    let today = "2026-11-13"

    typealias Spec = (charge: Double?, strain: Double?, sleep: Double?)

    func metric(back: Int, _ s: Spec) -> DailyMetric {
        DailyMetric(day: FitnessAgeEngine.shiftDay(today, by: -back)!, totalSleepMin: s.sleep, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: s.charge, strain: s.strain, exerciseCount: nil)
    }

    /// Specs laid on consecutive days, the LAST one on `today`.
    func seq(_ specs: [Spec]) -> [DailyMetric] {
        specs.enumerated().map { metric(back: specs.count - 1 - $0.offset, $0.element) }
    }

    /// n values around `mean`, alternating -k / +k (sample sd about 1.054 k for n = 10).
    func pattern(_ mean: Double, _ k: Double, _ n: Int) -> [Double] {
        (0..<n).map { mean + ($0 % 2 == 0 ? -k : k) }
    }

    // MARK: - Gates on the statistic

    func testGroupSizeGateNineVersusTen() {
        let a9 = PlanLearning.compare(kind: .shortSleep, a: pattern(50, 2, 9), b: pattern(62, 2, 10))
        XCTAssertFalse(a9.isReliable)
        let a10 = PlanLearning.compare(kind: .shortSleep, a: pattern(50, 2, 10), b: pattern(62, 2, 10))
        XCTAssertTrue(a10.isReliable)
        let b9 = PlanLearning.compare(kind: .shortSleep, a: pattern(50, 2, 10), b: pattern(62, 2, 9))
        XCTAssertFalse(b9.isReliable)
    }

    func testDifferenceGateJustUnderAndAtFivePoints() {
        let under = PlanLearning.compare(kind: .shortSleep, a: pattern(55, 1, 10), b: pattern(59.9, 1, 10))
        XCTAssertEqual(under.difference, -4.9, accuracy: 1e-9)
        XCTAssertFalse(under.isReliable)
        let at = PlanLearning.compare(kind: .shortSleep, a: pattern(55, 1, 10), b: pattern(60, 1, 10))
        XCTAssertEqual(at.difference, -5, accuracy: 1e-9)
        XCTAssertTrue(at.isReliable, "exactly 5 points passes")
        // the sign does not matter
        let positive = PlanLearning.compare(kind: .shortSleep, a: pattern(60, 1, 10), b: pattern(55, 1, 10))
        XCTAssertTrue(positive.isReliable)
    }

    func testWelchTGateJustUnderAndOverTwo() {
        // 10 points apart; the spread alone moves t across 2 (t = 10 / (s * sqrt(2/10)))
        let over = PlanLearning.compare(kind: .shortSleep, a: pattern(50, 10.5, 10), b: pattern(60, 10.5, 10))
        XCTAssertEqual(abs(over.t), 2.02, accuracy: 0.01)
        XCTAssertTrue(over.isReliable)
        let under = PlanLearning.compare(kind: .shortSleep, a: pattern(50, 10.7, 10), b: pattern(60, 10.7, 10))
        XCTAssertEqual(abs(under.t), 1.98, accuracy: 0.01)
        XCTAssertFalse(under.isReliable)
        XCTAssertEqual(abs(over.difference), 10, accuracy: 1e-9)
        XCTAssertEqual(abs(under.difference), 10, accuracy: 1e-9)
    }

    func testWelchTValues() {
        XCTAssertNil(PlanLearning.welchT([1], [1, 2, 3]))
        XCTAssertEqual(PlanLearning.welchT([5, 5, 5], [5, 5, 5]), 0)
        XCTAssertEqual(PlanLearning.welchT([6, 6], [5, 5]), .infinity)
        XCTAssertEqual(PlanLearning.welchT([4, 4], [5, 5]), -.infinity)
        // textbook: a = 1,2,3,4,5 (mean 3, var 2.5), b = 3,4,5,6,7 (mean 5, var 2.5): t = -2 / sqrt(1) = -2
        XCTAssertEqual(PlanLearning.welchT([1, 2, 3, 4, 5], [3, 4, 5, 6, 7])!, -2, accuracy: 1e-12)
    }

    // MARK: - Rule 1: short sleep

    func shortSleepDays(short: Int, long: Int, shortSleep: Double = 400, longSleep: Double = 440) -> [DailyMetric] {
        let sc = pattern(50, 2, short), lc = pattern(62, 2, long)
        var specs: [Spec] = []
        for i in 0..<max(short, long) {
            if i < short { specs.append((sc[i], nil, shortSleep)) }
            if i < long { specs.append((lc[i], nil, longSleep)) }
        }
        return seq(specs)
    }

    func testShortSleepFinding() {
        let f = PlanLearning.findings(days: shortSleepDays(short: 20, long: 20), today: today)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].kind, .shortSleep)
        XCTAssertEqual(f[0].groupA, PlanLearning.Group(n: 20, mean: 50))
        XCTAssertEqual(f[0].groupB, PlanLearning.Group(n: 20, mean: 62))
        XCTAssertEqual(f[0].difference, -12, accuracy: 1e-9)
        XCTAssertTrue(f[0].isReliable)
    }

    func testShortSleepNeedsTenNightsInEachGroup() {
        XCTAssertEqual(PlanLearning.findings(days: shortSleepDays(short: 10, long: 10), today: today).count, 1)
        XCTAssertTrue(PlanLearning.findings(days: shortSleepDays(short: 9, long: 10), today: today).isEmpty)
        XCTAssertTrue(PlanLearning.findings(days: shortSleepDays(short: 10, long: 9), today: today).isEmpty)
    }

    func testSevenHoursSharpIsNotShort() {
        // 419 min is a short night, 420 is not
        let f = PlanLearning.findings(days: shortSleepDays(short: 10, long: 10, shortSleep: 419, longSleep: 420), today: today)
        XCTAssertEqual(f.first?.groupA.n, 10)
        XCTAssertTrue(PlanLearning.findings(days: shortSleepDays(short: 10, long: 10, shortSleep: 420, longSleep: 420),
                                            today: today).isEmpty)
    }

    func testShortSleepUsesTheSameRowsCharge() {
        // the night stored on a row is paired with that row's Charge, not the next row's
        let days = shortSleepDays(short: 10, long: 10)
        let f = PlanLearning.findings(days: days, today: today)
        let shortCharges = days.filter { ($0.totalSleepMin ?? 999) < 420 }.compactMap(\.recovery)
        XCTAssertEqual(f.first?.groupA.mean ?? -1, shortCharges.reduce(0, +) / Double(shortCharges.count), accuracy: 1e-9)
    }

    func testWindowIsTheLast120Days() {
        func placed(shortBacks: [Int], longBacks: [Int]) -> [DailyMetric] {
            let sc = pattern(50, 2, shortBacks.count), lc = pattern(62, 2, longBacks.count)
            return shortBacks.enumerated().map { metric(back: $0.element, (sc[$0.offset], nil, 400)) }
                + longBacks.enumerated().map { metric(back: $0.element, (lc[$0.offset], nil, 440)) }
        }
        // oldest included day is 119 back
        let inside = placed(shortBacks: Array(stride(from: 119, to: 99, by: -2)), longBacks: Array(stride(from: 118, to: 98, by: -2)))
        XCTAssertEqual(PlanLearning.findings(days: inside, today: today).count, 1)
        // 120 back falls out: the short group drops to 9
        let outside = placed(shortBacks: Array(stride(from: 120, to: 100, by: -2)), longBacks: Array(stride(from: 119, to: 99, by: -2)))
        XCTAssertTrue(PlanLearning.findings(days: outside, today: today).isEmpty)
    }

    func testFutureDaysIgnored() {
        var days = shortSleepDays(short: 10, long: 10)
        days.append(metric(back: -1, (5, nil, 100)))
        XCTAssertEqual(PlanLearning.findings(days: days, today: today).first?.groupA.n, 10)
    }

    // MARK: - Rule 2: hard day after low Charge

    /// Cases of two days: an anchor (Charge `anchorCharge`, Effort 90 hard / 20 easy), then a next day
    /// (Effort 50, Charge >= 50 so it is no anchor itself).
    func lowChargeDays(nHard: Int, nEasy: Int, nextHard: Double = 56, nextEasy: Double = 72,
                       anchorCharge: Double = 30) -> [DailyMetric] {
        let h = pattern(nextHard, 2, nHard), e = pattern(nextEasy, 2, nEasy)
        var specs: [Spec] = []
        for i in 0..<max(nHard, nEasy) {
            if i < nHard { specs.append((anchorCharge, 90, nil)); specs.append((h[i], 50, nil)) }
            if i < nEasy { specs.append((anchorCharge, 20, nil)); specs.append((e[i], 50, nil)) }
        }
        return seq(specs)
    }

    func testHardDayAfterLowChargeFinding() {
        let f = PlanLearning.findings(days: lowChargeDays(nHard: 10, nEasy: 10), today: today)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].kind, .hardDayAfterLowCharge)
        XCTAssertEqual(f[0].groupA, PlanLearning.Group(n: 10, mean: 56))
        XCTAssertEqual(f[0].groupB, PlanLearning.Group(n: 10, mean: 72))
        XCTAssertEqual(f[0].difference, -16, accuracy: 1e-9)
    }

    func testHardDayAfterLowChargeGroupSizeGate() {
        XCTAssertTrue(PlanLearning.findings(days: lowChargeDays(nHard: 9, nEasy: 10), today: today).isEmpty)
        XCTAssertTrue(PlanLearning.findings(days: lowChargeDays(nHard: 10, nEasy: 9), today: today).isEmpty)
    }

    func testHardDayAfterLowChargeDifferenceGate() {
        // 4.9 apart: no; 5 apart: yes
        XCTAssertTrue(PlanLearning.findings(days: lowChargeDays(nHard: 10, nEasy: 10, nextHard: 67.1, nextEasy: 72), today: today).isEmpty)
        XCTAssertEqual(PlanLearning.findings(days: lowChargeDays(nHard: 10, nEasy: 10, nextHard: 67, nextEasy: 72), today: today).count, 1)
    }

    func testLowChargeMeansUnderFifty() {
        // an anchor at Charge 50 is not a low-Charge day
        XCTAssertTrue(PlanLearning.findings(days: lowChargeDays(nHard: 10, nEasy: 10, anchorCharge: 50), today: today).isEmpty)
        XCTAssertEqual(PlanLearning.findings(days: lowChargeDays(nHard: 10, nEasy: 10, anchorCharge: 49.9), today: today).count, 1)
    }

    func testHardIsTheUsersOwnTopQuartile() {
        // same shape, but every Effort is scaled down: "hard" is relative, the finding still holds
        let scaled = lowChargeDays(nHard: 10, nEasy: 10).map { d in
            DailyMetric(day: d.day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: nil, avgHrv: nil, recovery: d.recovery,
                        strain: d.strain.map { $0 / 10 }, exerciseCount: nil)
        }
        XCTAssertEqual(PlanLearning.findings(days: scaled, today: today).first?.kind, .hardDayAfterLowCharge)
    }

    // MARK: - Rule 3: consecutive hard days

    /// A case: easy day, hard, hard, then a next day at ~`nextRun`. B case: easy day, hard, next day at ~72.
    /// Hard days sit at Charge 72, so the first hard day of an A case reads as a "single" one for group B.
    func runDays(nRun: Int, nSingle: Int, nextRun: Double = 56) -> [DailyMetric] {
        let r = pattern(nextRun, 2, nRun), s = pattern(72, 2, nSingle)
        var specs: [Spec] = []
        for i in 0..<nRun {
            specs += [(72, 20, nil), (72, 90, nil), (72, 90, nil), (r[i], 20, nil)]
        }
        for i in 0..<nSingle {
            specs += [(72, 20, nil), (72, 90, nil), (s[i], 20, nil)]
        }
        return seq(specs)
    }

    func testConsecutiveHardDaysFinding() {
        let f = PlanLearning.findings(days: runDays(nRun: 10, nSingle: 4), today: today)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].kind, .consecutiveHardDays)
        XCTAssertEqual(f[0].groupA.n, 10)
        XCTAssertEqual(f[0].groupA.mean, 56, accuracy: 1e-9)
        XCTAssertEqual(f[0].groupB.n, 14) // 10 first-days of the runs + 4 true singles
        XCTAssertEqual(f[0].difference, f[0].groupA.mean - f[0].groupB.mean, accuracy: 1e-12)
        XCTAssertLessThan(f[0].difference, -5)
    }

    func testConsecutiveHardDaysGroupSizeGate() {
        XCTAssertEqual(PlanLearning.findings(days: runDays(nRun: 10, nSingle: 0), today: today).count, 1)
        XCTAssertTrue(PlanLearning.findings(days: runDays(nRun: 9, nSingle: 0), today: today).isEmpty)
        // B group under 10: 9 runs give 9 first-days, no singles
        XCTAssertTrue(PlanLearning.findings(days: runDays(nRun: 10, nSingle: 0).suffix(36), today: today).isEmpty)
    }

    func testConsecutiveHardDaysDifferenceGate() {
        XCTAssertTrue(PlanLearning.findings(days: runDays(nRun: 10, nSingle: 4, nextRun: 68), today: today).isEmpty)
        XCTAssertEqual(PlanLearning.findings(days: runDays(nRun: 10, nSingle: 4, nextRun: 67), today: today).count, 1)
    }

    // MARK: - Ordering and the sleep threshold

    func finding(_ kind: PlanLearning.Kind, diff: Double, t: Double) -> PlanLearning.Finding {
        PlanLearning.Finding(kind: kind, groupA: .init(n: 10, mean: 50), groupB: .init(n: 10, mean: 50 - diff),
                             difference: diff, t: t, isReliable: true)
    }

    func testStrongestFirst() {
        let a = finding(.shortSleep, diff: -20, t: -2.5)
        let b = finding(.hardDayAfterLowCharge, diff: -8, t: 4)
        let c = finding(.consecutiveHardDays, diff: -9, t: 3)
        XCTAssertEqual(PlanLearning.sortStrongestFirst([a, c, b]).map(\.kind),
                       [.hardDayAfterLowCharge, .consecutiveHardDays, .shortSleep])
        // equal |t|: bigger |difference| first; then rule order
        let d = finding(.hardDayAfterLowCharge, diff: 10, t: 3)
        let e = finding(.shortSleep, diff: -12, t: -3)
        let f = finding(.consecutiveHardDays, diff: 10, t: 3)
        XCTAssertEqual(PlanLearning.sortStrongestFirst([d, f, e]).map(\.kind),
                       [.shortSleep, .hardDayAfterLowCharge, .consecutiveHardDays])
    }

    func testFindingsAreOrderedStrongestFirst() {
        // two rules at once: the sleep series and the run series share no rows (different eras)
        let sleepEra = shortSleepDays(short: 20, long: 20).map { m in
            DailyMetric(day: FitnessAgeEngine.shiftDay(m.day, by: -45)!, totalSleepMin: m.totalSleepMin, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: m.recovery, strain: nil, exerciseCount: nil)
        }
        let f = PlanLearning.findings(days: sleepEra + runDays(nRun: 10, nSingle: 4), today: today)
        XCTAssertEqual(Set(f.map(\.kind)), [.shortSleep, .consecutiveHardDays])
        XCTAssertGreaterThanOrEqual(abs(f[0].t), abs(f[1].t))
    }

    func sleepCharge(_ rows: [(sleep: Double, charge: Double, n: Int)]) -> [DailyMetric] {
        var specs: [Spec] = []
        for r in rows {
            for c in pattern(r.charge, 1, r.n) { specs.append((c, nil, r.sleep)) }
        }
        return seq(specs)
    }

    func testPersonalThresholdPicksBiggestGap() {
        // 380 -> 50, 440 -> 50, 500 -> 64: the gap is 14 at 450 and at 480; the lower cut wins the tie
        let days = sleepCharge([(380, 50, 20), (440, 50, 20), (500, 64, 20)])
        XCTAssertEqual(PlanLearning.personalSleepThresholdMinutes(days: days), 450)
    }

    func testPersonalThresholdGates() {
        XCTAssertEqual(PlanLearning.personalSleepThresholdMinutes(days: sleepCharge([(400, 55, 10), (440, 60, 10)])), 420)
        XCTAssertNil(PlanLearning.personalSleepThresholdMinutes(days: sleepCharge([(400, 55, 10), (440, 59.9, 10)])),
                     "gap 4.9")
        XCTAssertNil(PlanLearning.personalSleepThresholdMinutes(days: sleepCharge([(400, 55, 9), (440, 62, 10)])),
                     "9 days below")
        XCTAssertNil(PlanLearning.personalSleepThresholdMinutes(days: sleepCharge([(400, 55, 10), (440, 62, 9)])),
                     "9 days above")
        XCTAssertNil(PlanLearning.personalSleepThresholdMinutes(days: []))
    }

    func testPersonalThresholdIgnoresOlderThan120Days() {
        let days = sleepCharge([(400, 55, 10), (440, 62, 10)])
        let old = days.map { m in
            DailyMetric(day: FitnessAgeEngine.shiftDay(m.day, by: -130)!, totalSleepMin: m.totalSleepMin, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                        recovery: m.recovery, strain: nil, exerciseCount: nil)
        }
        XCTAssertNil(PlanLearning.personalSleepThresholdMinutes(days: old, today: today))
        XCTAssertEqual(PlanLearning.personalSleepThresholdMinutes(days: old), 420, "anchored on the newest row")
    }
}
