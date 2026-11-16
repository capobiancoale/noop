import XCTest
import WhoopStore
@testable import StrandAnalytics

final class PersonalThresholdsTests: XCTestCase {

    let today = "2026-11-13"

    func day(_ back: Int) -> String { FitnessAgeEngine.shiftDay(today, by: -back)! }

    func row(_ back: Int, charge: Double?, sleep: Double? = nil) -> DailyMetric {
        DailyMetric(day: day(back), totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: charge,
                    strain: nil, exerciseCount: nil)
    }

    func testPercentilesOfTheOwnCharge() {
        // Charge 1 ... 40 on the 40 days before today: type-7 p67 = 1 + 0.67*39 = 27.13, p33 = 13.87
        let days = (1...40).map { row($0, charge: Double(41 - $0)) }
        let t = PersonalThresholds.compute(days: days, today: today)
        XCTAssertEqual(t.chargeDays, 40)
        XCTAssertEqual(t.pushAbove!, 27.13, accuracy: 1e-9)
        XCTAssertEqual(t.easyBelow!, 13.87, accuracy: 1e-9)
        XCTAssertTrue(t.hasPersonalCharge)
        XCTAssertEqual(t.daysUntilPersonal, 1)
    }

    func testNeedsThirtyDays() {
        let d29 = (1...29).map { row($0, charge: Double($0)) }
        let t29 = PersonalThresholds.compute(days: d29, today: today)
        XCTAssertNil(t29.pushAbove); XCTAssertNil(t29.easyBelow)
        XCTAssertFalse(t29.hasPersonalCharge)
        XCTAssertEqual(t29.chargeDays, 29)
        XCTAssertEqual(t29.daysUntilPersonal, 1)
        let t30 = PersonalThresholds.compute(days: (1...30).map { row($0, charge: Double($0)) }, today: today)
        XCTAssertTrue(t30.hasPersonalCharge)
        XCTAssertEqual(PersonalThresholds.compute(days: [], today: today).daysUntilPersonal, 30)
        XCTAssertEqual(PersonalThresholds.compute(days: (1...10).map { row($0, charge: 50) }, today: today).daysUntilPersonal, 20)
    }

    func testWindowIs90DaysBeforeTodayAndTodayIsLeftOut() {
        // 30 days in the window at 50, plus today at 100 and a day 91 back at 0: neither counts
        var days = (1...30).map { row($0, charge: 50) }
        days.append(row(0, charge: 100))
        days.append(row(91, charge: 0))
        let t = PersonalThresholds.compute(days: days, today: today)
        XCTAssertEqual(t.chargeDays, 30)
        XCTAssertEqual(t.pushAbove!, 50, accuracy: 1e-9)
        // day 90 back is inside
        XCTAssertEqual(PersonalThresholds.compute(days: [row(90, charge: 1)], today: today).chargeDays, 1)
    }

    func testDaysWithoutChargeAreSkipped() {
        var days = (1...30).map { row($0, charge: 50) }
        days += (31...60).map { row($0, charge: nil) }
        days.append(row(61, charge: .nan))
        XCTAssertEqual(PersonalThresholds.compute(days: days, today: today).chargeDays, 30)
    }

    func testMedianCharge() {
        XCTAssertNil(PersonalThresholds.medianCharge(days: (1...13).map { row($0, charge: 60) }, today: today))
        XCTAssertEqual(PersonalThresholds.medianCharge(days: (1...14).map { row($0, charge: Double($0)) }, today: today)!,
                       7.5, accuracy: 1e-9)
    }

    func testShortNightThresholdComesFromPlanLearning() {
        // 120 days: nights under 7 h pair with Charge 40, 7 h and more with Charge 70 -> the best cut is 420
        let days = (1...60).map { k in
            row(k, charge: k % 2 == 0 ? 40 : 70, sleep: k % 2 == 0 ? 400 : 480)
        }
        let expected = PlanLearning.personalSleepThresholdMinutes(days: days, today: today)
        XCTAssertNotNil(expected)
        let t = PersonalThresholds.compute(days: days, today: today)
        XCTAssertEqual(t.shortNightMinutes, expected)
        // no sleep data: no personal cut
        XCTAssertNil(PersonalThresholds.compute(days: (1...40).map { row($0, charge: 50) }, today: today).shortNightMinutes)
    }
}
