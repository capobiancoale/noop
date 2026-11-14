import XCTest
import WhoopStore
@testable import StrandAnalytics

final class DayPlanTests: XCTestCase {

    let today = "2026-11-13"

    func day(_ back: Int) -> String { FitnessAgeEngine.shiftDay(today, by: -back)! }

    func row(_ back: Int, charge: Double? = nil, strain: Double? = nil, sleep: Double? = nil,
             hrv: Double? = nil, rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: day(back), totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: charge,
                    strain: strain, exerciseCount: nil)
    }

    func summary(ratio: Double?) -> TrainingLoad.Summary {
        TrainingLoad.Summary(acute: 100, acuteDays: 7, chronicWeekly: 100, chronicDays: 28, ratio: ratio,
                             band: ratio.map { TrainingLoad.band(ratio: $0) }, weeks: [])
    }

    func inputs(days: [DailyMetric], need: Double? = 480, debt: Double? = 0, wakes: [Int] = [],
                load: TrainingLoad.Summary? = nil, age: Int = 35, sex: DayPlan.Sex = .male,
                kg: Double = 80, cm: Double = 180, goal: DayPlan.Goal = .performance) -> DayPlan.Inputs {
        DayPlan.Inputs(days: days, today: today, sleepNeedMin: need, sleepDebtMin: debt, wakeMinutes: wakes,
                       load: load, age: age, sex: sex, weightKg: kg, heightCm: cm, goal: goal)
    }

    func plan(charge: Double?, sleep: Double? = 480, load: Double? = nil, extra: [DailyMetric] = [],
              goal: DayPlan.Goal = .performance) -> DayPlan.Plan {
        DayPlan.make(inputs(days: extra + [row(0, charge: charge, sleep: sleep)],
                            load: load.map { summary(ratio: $0) }, goal: goal))
    }

    // MARK: Charge boundaries

    func testChargeBoundaries() {
        XCTAssertEqual(plan(charge: 33).training, .easy)
        XCTAssertEqual(plan(charge: 34).training, .maintain)
        XCTAssertEqual(plan(charge: 66).training, .maintain)
        XCTAssertEqual(plan(charge: 67).training, .push)
        XCTAssertEqual(plan(charge: 33).reasons, [.chargeLow(33)])
        XCTAssertEqual(plan(charge: 66).reasons, [.chargeMid(66)])
        XCTAssertEqual(plan(charge: 67).reasons, [.chargeHigh(67)])
    }

    func testNoCharge() {
        let p = plan(charge: nil)
        XCTAssertEqual(p.training, .maintain)
        XCTAssertEqual(p.reasons, [.noCharge])
        let none = DayPlan.make(inputs(days: []))
        XCTAssertEqual(none.training, .maintain)
        XCTAssertEqual(none.reasons, [.noCharge])
    }

    // MARK: Downgrade rules

    func testShortSleepAbsoluteAndRelative() {
        let a = plan(charge: 80, sleep: 359)
        XCTAssertEqual(a.training, .maintain)
        XCTAssertEqual(a.reasons, [.chargeHigh(80), .shortSleep(minutes: 359, needMinutes: 480)])
        XCTAssertEqual(plan(charge: 80, sleep: 360).training, .push)   // not under 6 h, 75 % of need
        // 70 % of a 9 h need is 378 min
        let rel = DayPlan.make(inputs(days: [row(0, charge: 80, sleep: 377)], need: 540))
        XCTAssertEqual(rel.training, .maintain)
        let ok = DayPlan.make(inputs(days: [row(0, charge: 80, sleep: 380)], need: 540))
        XCTAssertEqual(ok.training, .push)
        XCTAssertEqual(plan(charge: 50, sleep: 300).training, .easy)
        XCTAssertEqual(plan(charge: 20, sleep: 300).training, .easy)
    }

    func testShortSleepIgnoredWithoutSleep() {
        XCTAssertEqual(plan(charge: 80, sleep: nil).training, .push)
    }

    func testLoadSharpRise() {
        let a = plan(charge: 80, load: 1.5)
        XCTAssertEqual(a.training, .maintain)
        XCTAssertEqual(a.reasons, [.chargeHigh(80), .loadSharpRise(ratio: 1.5)])
        XCTAssertEqual(plan(charge: 80, load: 1.49).training, .push)
        // already maintain: reason still added
        XCTAssertEqual(plan(charge: 50, load: 1.6).reasons, [.chargeMid(50), .loadSharpRise(ratio: 1.6)])
        // already easy: nothing to cap
        XCTAssertEqual(plan(charge: 10, load: 1.6).reasons, [.chargeLow(10)])
    }

    /// Days before today with a varied base Effort (30...39, so the 75th percentile is not a tie); days
    /// 1...hardDays are set to 90.
    func streakDays(hardDays: Int, withEffortDays: Int = 28) -> [DailyMetric] {
        (1...withEffortDays).map { k in row(k, strain: k <= hardDays ? 90 : Double(30 + k % 10)) }
    }

    func testHardStreak() {
        let three = plan(charge: 80, extra: streakDays(hardDays: 3))
        XCTAssertEqual(three.training, .easy)
        XCTAssertEqual(three.reasons.last, .hardStreak(days: 3))
        let two = plan(charge: 80, extra: streakDays(hardDays: 2))
        XCTAssertEqual(two.training, .push)
        // streak must end yesterday: hard on days 2,3,4 only
        let gap = (1...28).map { k in row(k, strain: (2...4).contains(k) ? 90 : Double(30 + k % 10)) }
        XCTAssertEqual(plan(charge: 80, extra: gap).training, .push)
    }

    func testHardStreakNeedsFourteenEffortDays() {
        // 13 days with Effort: rule off even with 3 hard days
        let few = streakDays(hardDays: 3, withEffortDays: 13)
        XCTAssertEqual(plan(charge: 80, extra: few).training, .push)
        let enough = streakDays(hardDays: 3, withEffortDays: 14)
        XCTAssertEqual(plan(charge: 80, extra: enough).training, .easy)
    }

    func testCombinedRules() {
        let p = plan(charge: 80, sleep: 300, load: 1.7, extra: streakDays(hardDays: 3))
        XCTAssertEqual(p.training, .easy)
        XCTAssertEqual(p.reasons, [.chargeHigh(80), .shortSleep(minutes: 300, needMinutes: 480),
                                   .loadSharpRise(ratio: 1.7), .hardStreak(days: 3)])
    }

    // MARK: Sleep target

    func testSleepTargetMinutes() {
        func target(need: Double?, debt: Double?) -> Int {
            DayPlan.make(inputs(days: [], need: need, debt: debt)).sleep.minutes
        }
        XCTAssertEqual(target(need: nil, debt: nil), 480)
        XCTAssertEqual(target(need: 462, debt: 0), 460)
        XCTAssertEqual(target(need: 480, debt: 30), 510)
        XCTAssertEqual(target(need: 480, debt: 200), 540)
        XCTAssertEqual(target(need: 480, debt: -50), 480)
    }

    func testBedtimeWrapsAcrossMidnight() {
        // wake 06:30 = 390; 9 h = 540; 390 - 540 - 15 = -165 -> 1275 = 21:15
        let p = DayPlan.make(inputs(days: [], need: 540, debt: 0, wakes: Array(repeating: 390, count: 14)))
        XCTAssertEqual(p.sleep.minutes, 540)
        XCTAssertEqual(p.sleep.bedtimeMinutes, 1275)
        // no wrap
        let q = DayPlan.make(inputs(days: [], need: 360, debt: 0, wakes: Array(repeating: 600, count: 5)))
        XCTAssertEqual(q.sleep.bedtimeMinutes, 225)
    }

    func testBedtimeNeedsFiveWakes() {
        XCTAssertNil(DayPlan.make(inputs(days: [], wakes: [400, 400, 400, 400])).sleep.bedtimeMinutes)
        XCTAssertNotNil(DayPlan.make(inputs(days: [], wakes: [400, 400, 400, 400, 400])).sleep.bedtimeMinutes)
    }

    func testBedtimeUsesMedianOfLast14() {
        // 20 old wakes at 300 then 14 at 420: only the last 14 count
        let wakes = Array(repeating: 300, count: 20) + Array(repeating: 420, count: 14)
        let p = DayPlan.make(inputs(days: [], need: 480, debt: 0, wakes: wakes))
        XCTAssertEqual(p.sleep.bedtimeMinutes, 420 - 480 - 15 + 1440)
    }

    // MARK: Nutrition

    func testIncompleteProfileHasNoNutrition() {
        XCTAssertNil(DayPlan.make(inputs(days: [], age: 0)).nutrition)
        XCTAssertNil(DayPlan.make(inputs(days: [], kg: 0)).nutrition)
        XCTAssertNil(DayPlan.make(inputs(days: [], cm: 0)).nutrition)
        XCTAssertNotNil(DayPlan.make(inputs(days: [])).nutrition)
    }

    func testNutritionNumbersMaintainPerformance() throws {
        // male 80 kg 180 cm 35 y: 800 + 1125 - 175 + 5 = 1755; maintain x1.6 = 2808
        let n = try XCTUnwrap(plan(charge: 50).nutrition)
        XCTAssertEqual(n.restingKcal, 1755)
        XCTAssertEqual(n.energyKcal, 2650...2950)       // 2667.6 -> 2650, 2948.4 -> 2950
        XCTAssertEqual(n.proteinG, 110...160)           // 112 -> 110, 160
        // 5-7 g/kg = 400-560 g, but (2950 - 4*110 - 0.8*80*9)/4 = 483 g -> upper bound 480
        XCTAssertEqual(n.carbsG, 400...480)
        XCTAssertEqual(n.fluidMl, 3000)
    }

    func testRestingEnergyBySex() throws {
        let f = try XCTUnwrap(DayPlan.make(inputs(days: [], sex: .female)).nutrition)
        let o = try XCTUnwrap(DayPlan.make(inputs(days: [], sex: .other)).nutrition)
        XCTAssertEqual(f.restingKcal, 1589)
        XCTAssertEqual(o.restingKcal, 1672)
        XCTAssertEqual(f.fluidMl, 2500)                 // 2000 + 500 (maintain, no Charge)
        XCTAssertEqual(o.fluidMl, 2750)
    }

    func testFluidsEasyDay() throws {
        let n = try XCTUnwrap(plan(charge: 10).nutrition)
        XCTAssertEqual(n.fluidMl, 2500)
    }

    func testEnergyLowerBoundNeverUnderResting() throws {
        // easy x1.4 x0.85 fat loss: 1755 * 1.19 = 2088 > resting; make the factor drop under resting is
        // impossible with these factors, so check the invariant over a sweep.
        for goal in DayPlan.Goal.allCases {
            for c in [10.0, 50, 80] {
                let n = try XCTUnwrap(plan(charge: c, goal: goal).nutrition)
                XCTAssertGreaterThanOrEqual(n.energyKcal.lowerBound, n.restingKcal)
                XCTAssertGreaterThanOrEqual(n.energyKcal.upperBound, n.energyKcal.lowerBound)
            }
        }
        // direct check of the floor: a tiny person where centre*0.95 rounds under resting
        let n = try XCTUnwrap(DayPlan.nutrition(inputs(days: [], age: 80, sex: .female, kg: 40, cm: 150,
                                                      goal: .fatLoss), training: .easy))
        XCTAssertGreaterThanOrEqual(n.energyKcal.lowerBound, n.restingKcal)
    }

    func testCarbsClampedByEnergy() throws {
        // endurance push: 6-10 g/kg x 80 = 480-800 g; energy upper bound is far smaller
        let n = try XCTUnwrap(plan(charge: 80, goal: .endurance).nutrition)
        let eHi = n.energyKcal.upperBound
        let pLo = n.proteinG.lowerBound
        XCTAssertLessThan(n.carbsG.upperBound, 800)
        XCTAssertLessThanOrEqual(Double(n.carbsG.upperBound * 4 + pLo * 4) + 0.8 * 80 * 9, Double(eHi))
        XCTAssertLessThanOrEqual(n.carbsG.lowerBound, n.carbsG.upperBound)
        XCTAssertEqual(n.carbsG.upperBound % 5, 0)
    }

    func testCarbsByGoalAndDay() throws {
        let fat = try XCTUnwrap(plan(charge: 80, goal: .fatLoss).nutrition)
        XCTAssertEqual(fat.carbsG, 240...400)
        let easy = try XCTUnwrap(plan(charge: 10, goal: .performance).nutrition)
        XCTAssertEqual(easy.carbsG, 240...395)          // clamp: (2600 - 440 - 576)/4 = 396
        let strength = try XCTUnwrap(plan(charge: 10, goal: .strength).nutrition)
        XCTAssertEqual(strength.proteinG, 130...175)
    }

    func testSexInit() {
        XCTAssertEqual(DayPlan.Sex(profileString: "male"), .male)
        XCTAssertEqual(DayPlan.Sex(profileString: "Female"), .female)
        XCTAssertEqual(DayPlan.Sex(profileString: ""), .other)
        XCTAssertEqual(DayPlan.Sex(profileString: "x"), .other)
    }

    // MARK: Focus

    /// Rows for the last `n` days (0 = today) with the given HRV / RHR, plus 30 reference days before.
    func vitals(recentHrv: Double, usualHrv: Double, recentRhr: Int, usualRhr: Int) -> [DailyMetric] {
        (0...6).map { row($0, hrv: recentHrv, rhr: recentRhr) } + (7...36).map { row($0, hrv: usualHrv, rhr: usualRhr) }
    }

    func focus(_ days: [DailyMetric], debt: Double? = 0, wakes: [Int] = [], load: Double? = nil) -> [DayPlan.Focus] {
        DayPlan.make(inputs(days: days, debt: debt, wakes: wakes, load: load.map { summary(ratio: $0) })).focus
    }

    func testHrvDownThreshold() {
        // 10 % under 60 = 54: exactly 54 is NOT more than 10 % under
        XCTAssertEqual(focus(vitals(recentHrv: 54, usualHrv: 60, recentRhr: 50, usualRhr: 50)), [])
        let f = focus(vitals(recentHrv: 53.9, usualHrv: 60, recentRhr: 50, usualRhr: 50))
        guard case .hrvDown(let pct, let recent, let usual)? = f.first else { return XCTFail("\(f)") }
        XCTAssertEqual(pct, 10)
        XCTAssertEqual(recent, 53.9, accuracy: 1e-9)
        XCTAssertEqual(usual, 60, accuracy: 1e-9)
    }

    func testRestingHrUpThreshold() {
        XCTAssertEqual(focus(vitals(recentHrv: 60, usualHrv: 60, recentRhr: 54, usualRhr: 50)), [])
        let f = focus(vitals(recentHrv: 60, usualHrv: 60, recentRhr: 55, usualRhr: 50))
        XCTAssertEqual(f, [.restingHrUp(bpm: 5, recent: 55, usual: 50)])
    }

    func testVitalsNeedEnoughValues() {
        // only 3 recent values
        let days = (0...2).map { row($0, hrv: 10) } + (7...36).map { row($0, hrv: 60) }
        XCTAssertEqual(focus(days), [])
        // only 9 reference values
        let d2 = (0...6).map { row($0, hrv: 10) } + (7...15).map { row($0, hrv: 60) }
        XCTAssertEqual(focus(d2), [])
    }

    func testSleepDebtAndAverage() {
        XCTAssertEqual(focus([], debt: 59), [])
        XCTAssertEqual(focus([], debt: 60), [.sleepDebt(minutes: 60)])
        // mean 420 vs 480: 60 under -> flagged; 440 -> 40 under, not flagged; needs 4 values
        let low = (0...3).map { row($0, sleep: 420) }
        XCTAssertEqual(focus(low), [.lowSleepAverage(avgMinutes: 420, needMinutes: 480)])
        XCTAssertEqual(focus((0...3).map { row($0, sleep: 440) }), [])
        XCTAssertEqual(focus((0...2).map { row($0, sleep: 300) }), [])
    }

    func testIrregularWake() {
        let steady = Array(repeating: 400, count: 14)
        XCTAssertEqual(focus([], wakes: steady), [])
        // alternate 300 / 480: SD 90
        let wild = (0..<14).map { $0 % 2 == 0 ? 300 : 480 }
        XCTAssertEqual(focus([], wakes: wild), [.irregularWake(sdMinutes: 90)])
        // fewer than 7 values
        XCTAssertEqual(focus([], wakes: Array(wild.prefix(6))), [])
    }

    func testLoadFocus() {
        XCTAssertEqual(focus([], load: 1.5), [.loadHigh(ratio: 1.5)])
        XCTAssertEqual(focus([], load: 0.79), [.loadLow(ratio: 0.79)])
        XCTAssertEqual(focus([], load: 0.8), [])
        XCTAssertEqual(focus([], load: 1.2), [])
    }

    func testFocusOrderAndCap() {
        var days = vitals(recentHrv: 40, usualHrv: 60, recentRhr: 60, usualRhr: 50)
        days = days.map { d in
            DailyMetric(day: d.day, totalSleepMin: 360, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: d.restingHr, avgHrv: d.avgHrv,
                        recovery: nil, strain: nil, exerciseCount: nil)
        }
        let wild = (0..<14).map { $0 % 2 == 0 ? 300 : 480 }
        let all = focus(days, debt: 90, wakes: wild, load: 1.6)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all, [.sleepDebt(minutes: 90), .lowSleepAverage(avgMinutes: 360, needMinutes: 480),
                             .irregularWake(sdMinutes: 90)])
        // without the first three, the rest show in order
        let rest = focus(vitals(recentHrv: 40, usualHrv: 60, recentRhr: 60, usualRhr: 50), load: 1.6)
        XCTAssertEqual(rest.count, 3)
        XCTAssertEqual(rest[0], .loadHigh(ratio: 1.6))
        if case .hrvDown = rest[1] {} else { XCTFail("\(rest)") }
        if case .restingHrUp = rest[2] {} else { XCTFail("\(rest)") }
    }
}
