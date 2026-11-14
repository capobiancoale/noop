#if WIDGET_SNAPSHOT_TESTS
// Compiles only when StrandiOSShared/WidgetSnapshot.swift and StrandiOS/Widgets/WidgetPublish.swift are part of
// the test bundle (and the flag WIDGET_SNAPSHOT_TESTS is set): StrandTests is a macOS bundle hosted by the
// macOS app, which does not contain those iOS files. Remove the `#if` once they are added to its sources.
import XCTest
import StrandAnalytics

final class WidgetPlanSnapshotTests: XCTestCase {

    private func plan(training: DayPlan.Training, reasons: [DayPlan.Reason],
                      bedtime: Int? = 1_365, nutrition: DayPlan.Nutrition? = nil,
                      focus: [DayPlan.Focus] = []) -> DayPlan.Plan {
        DayPlan.Plan(training: training, reasons: reasons,
                     sleep: DayPlan.SleepTarget(minutes: 480, bedtimeMinutes: bedtime),
                     nutrition: nutrition, focus: focus)
    }

    private func base() -> WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Codable

    func testOldSnapshotWithoutPlanKeysStillDecodes() throws {
        let json = #"{"recovery":70,"bpm":60,"batteryPct":80,"bonded":true,"updated":0,"effort":9,"rest":81}"#
        let snap = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.recovery, 70)
        XCTAssertEqual(snap.effort, 9)
        XCTAssertNil(snap.planTraining)
        XCTAssertNil(snap.planDay)
        XCTAssertFalse(snap.planIsCurrent(at: Date()))
    }

    func testPlanFieldsRoundTrip() throws {
        let snap = WidgetSnapshot.withPlan(base(), plan: plan(training: .push, reasons: [.chargeHigh(72)]), day: "2026-11-13")
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.planTraining, "push")
    }

    // MARK: - Day check

    func testPlanDayKeyRollsAtFourLocal() {
        let rome = TimeZone(identifier: "Europe/Rome")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = rome
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: h, minute: m))!
        }
        XCTAssertEqual(WidgetSnapshot.planDayKey(at: at(3, 59), timeZone: rome), "2026-11-12")
        XCTAssertEqual(WidgetSnapshot.planDayKey(at: at(4, 0), timeZone: rome), "2026-11-13")
        XCTAssertEqual(WidgetSnapshot.planDayKey(at: at(23, 59), timeZone: rome), "2026-11-13")
    }

    func testStalePlanIsNotCurrent() {
        let rome = TimeZone(identifier: "Europe/Rome")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = rome
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
        let today = WidgetSnapshot.withPlan(base(), plan: plan(training: .easy, reasons: [.chargeLow(20)]), day: "2026-11-13")
        let yesterday = WidgetSnapshot.withPlan(base(), plan: plan(training: .easy, reasons: [.chargeLow(20)]), day: "2026-11-12")
        XCTAssertTrue(today.planIsCurrent(at: noon, timeZone: rome))
        XCTAssertFalse(yesterday.planIsCurrent(at: noon, timeZone: rome))
    }

    // MARK: - Mapping

    func testTrainingKeys() {
        XCTAssertEqual(WidgetSnapshot.trainingKey(.push), "push")
        XCTAssertEqual(WidgetSnapshot.trainingKey(.maintain), "maintain")
        XCTAssertEqual(WidgetSnapshot.trainingKey(.easy), "easy")
    }

    func testChargeReasonWhenNothingLoweredTheLevel() {
        let s = WidgetSnapshot.withPlan(base(), plan: plan(training: .push, reasons: [.chargeHigh(72)]), day: "d")
        XCTAssertEqual(s.planReason, "chargeHigh")
        XCTAssertEqual(s.planReasonValue, 72)
    }

    func testShortSleepWhileAlreadyEasyKeepsTheChargeReason() {
        let p = plan(training: .easy, reasons: [.chargeLow(20), .shortSleep(minutes: 300, needMinutes: 480)])
        let s = WidgetSnapshot.withPlan(base(), plan: p, day: "d")
        XCTAssertEqual(s.planReason, "chargeLow")
    }

    func testShortSleepThatLoweredTheLevelWins() {
        let p = plan(training: .maintain, reasons: [.chargeHigh(80), .shortSleep(minutes: 300, needMinutes: 480)])
        let s = WidgetSnapshot.withPlan(base(), plan: p, day: "d")
        XCTAssertEqual(s.planReason, "shortSleep")
        XCTAssertNil(s.planReasonValue)
    }

    func testLoadCapAfterShortSleepKeepsShortSleep() {
        // push -> maintain (short night), then the load cap changes nothing: short sleep is the cause.
        let p = plan(training: .maintain, reasons: [.chargeHigh(80), .shortSleep(minutes: 300, needMinutes: 480),
                                                    .loadSharpRise(ratio: 1.6)])
        XCTAssertEqual(WidgetSnapshot.withPlan(base(), plan: p, day: "d").planReason, "shortSleep")
    }

    func testLoadCapThatLoweredPushWins() {
        let p = plan(training: .maintain, reasons: [.chargeHigh(80), .loadSharpRise(ratio: 1.6)])
        XCTAssertEqual(WidgetSnapshot.withPlan(base(), plan: p, day: "d").planReason, "loadSharpRise")
    }

    func testHardStreakWins() {
        let p = plan(training: .easy, reasons: [.chargeHigh(80), .loadSharpRise(ratio: 1.6), .hardStreak(days: 3)])
        XCTAssertEqual(WidgetSnapshot.withPlan(base(), plan: p, day: "d").planReason, "hardStreak")
    }

    func testNoChargeReason() {
        let s = WidgetSnapshot.withPlan(base(), plan: plan(training: .maintain, reasons: [.noCharge]), day: "d")
        XCTAssertEqual(s.planReason, "noCharge")
        XCTAssertNil(s.planReasonValue)
    }

    func testSleepNutritionFocusAndDay() {
        let n = DayPlan.Nutrition(restingKcal: 1_700, energyKcal: 2_700...3_000, proteinG: 130...180,
                                  carbsG: 380...520, fluidMl: 3_000)
        let p = plan(training: .push, reasons: [.chargeHigh(72)], bedtime: 1_365, nutrition: n,
                     focus: [.loadHigh(ratio: 1.54), .sleepDebt(minutes: 90)])
        let s = WidgetSnapshot.withPlan(base(), plan: p, day: "2026-11-13")
        XCTAssertEqual(s.planSleepMinutes, 480)
        XCTAssertEqual(s.planBedtimeMinutes, 1_365)
        XCTAssertEqual(s.planEnergyLow, 2_700); XCTAssertEqual(s.planEnergyHigh, 3_000)
        XCTAssertEqual(s.planProteinLow, 130); XCTAssertEqual(s.planProteinHigh, 180)
        XCTAssertEqual(s.planCarbsLow, 380); XCTAssertEqual(s.planCarbsHigh, 520)
        XCTAssertEqual(s.planFocus, "loadHigh")
        XCTAssertEqual(s.planFocusValue, 154)
        XCTAssertEqual(s.planDay, "2026-11-13")
        // The scores of the base snapshot are untouched.
        XCTAssertEqual(s.recovery, 72)
    }

    func testMissingNutritionBedtimeAndFocusStayNil() {
        let s = WidgetSnapshot.withPlan(base(), plan: plan(training: .maintain, reasons: [.noCharge], bedtime: nil), day: "d")
        XCTAssertNil(s.planBedtimeMinutes)
        XCTAssertNil(s.planEnergyLow)
        XCTAssertNil(s.planFocus)
        XCTAssertNil(s.planFocusValue)
    }

    func testFocusValues() {
        XCTAssertEqual(WidgetSnapshot.focusKeyAndValue(.sleepDebt(minutes: 75)).value, 75)
        XCTAssertEqual(WidgetSnapshot.focusKeyAndValue(.lowSleepAverage(avgMinutes: 400, needMinutes: 480)).key, "lowSleepAverage")
        XCTAssertEqual(WidgetSnapshot.focusKeyAndValue(.irregularWake(sdMinutes: 70)).value, 70)
        XCTAssertEqual(WidgetSnapshot.focusKeyAndValue(.loadLow(ratio: 0.7)).value, 70)
        XCTAssertEqual(WidgetSnapshot.focusKeyAndValue(.hrvDown(pct: 12, recent: 50, usual: 57)).value, 12)
        XCTAssertEqual(WidgetSnapshot.focusKeyAndValue(.restingHrUp(bpm: 5.6, recent: 60, usual: 54.4)).value, 6)
    }
}
#endif
