import XCTest
@testable import StrandImport

/// ESH 2023 classification boundaries, the daily merge of Apple Health and Lab Book readings, and the
/// latest/30-day summary behind the blood-pressure card.
final class BloodPressureTests: XCTestCase {

    private func cat(_ sys: Double, _ dia: Double) -> BloodPressure.Category? {
        BloodPressure.classify(systolic: sys, diastolic: dia)
    }

    // MARK: Systolic boundaries (diastolic held optimal, 70)

    func testSystolicBoundaries() {
        XCTAssertEqual(cat(119, 70), .optimal)
        XCTAssertEqual(cat(120, 70), .normal)
        XCTAssertEqual(cat(129, 70), .normal)
        XCTAssertEqual(cat(130, 70), .highNormal)
        XCTAssertEqual(cat(139, 70), .highNormal)
        // 140 and above with a diastolic under 90 is the separate isolated-systolic row.
        XCTAssertEqual(cat(140, 70), .isolatedSystolic)
        XCTAssertEqual(cat(159, 70), .isolatedSystolic)
        XCTAssertEqual(cat(179, 70), .isolatedSystolic)
        XCTAssertEqual(cat(180, 70), .isolatedSystolic)
    }

    // MARK: Diastolic boundaries (systolic held optimal, 110)

    func testDiastolicBoundaries() {
        XCTAssertEqual(cat(110, 79), .optimal)
        XCTAssertEqual(cat(110, 80), .normal)
        XCTAssertEqual(cat(110, 84), .normal)
        XCTAssertEqual(cat(110, 85), .highNormal)
        XCTAssertEqual(cat(110, 89), .highNormal)
        XCTAssertEqual(cat(110, 90), .grade1)
        XCTAssertEqual(cat(110, 99), .grade1)
        XCTAssertEqual(cat(110, 100), .grade2)
        XCTAssertEqual(cat(110, 109), .grade2)
        XCTAssertEqual(cat(110, 110), .grade3)
        XCTAssertEqual(cat(110, 130), .grade3)
    }

    // MARK: Systolic grades once the diastolic is raised out of the isolated row (>= 90)

    func testSystolicGradesWithRaisedDiastolic() {
        XCTAssertEqual(cat(140, 90), .grade1)
        XCTAssertEqual(cat(159, 90), .grade1)
        XCTAssertEqual(cat(160, 90), .grade2)
        XCTAssertEqual(cat(179, 90), .grade2)
        XCTAssertEqual(cat(180, 90), .grade3)
    }

    // MARK: The higher category of the two values wins

    func testHigherOfTheTwoWins() {
        XCTAssertEqual(cat(118, 86), .highNormal, "optimal systolic, high-normal diastolic")
        XCTAssertEqual(cat(125, 79), .normal, "normal systolic, optimal diastolic")
        XCTAssertEqual(cat(135, 82), .highNormal, "high-normal systolic, normal diastolic")
        XCTAssertEqual(cat(128, 92), .grade1, "normal systolic, grade 1 diastolic")
        XCTAssertEqual(cat(145, 95), .grade1, "grade 1 on both")
        XCTAssertEqual(cat(145, 102), .grade2, "grade 1 systolic, grade 2 diastolic")
        XCTAssertEqual(cat(165, 95), .grade2, "grade 2 systolic, grade 1 diastolic")
        XCTAssertEqual(cat(150, 112), .grade3, "grade 1 systolic, grade 3 diastolic")
        XCTAssertEqual(cat(185, 100), .grade3, "grade 3 systolic, grade 2 diastolic")
        XCTAssertEqual(cat(120, 80), .normal, "both at the lower edge of normal")
        XCTAssertEqual(cat(119, 79), .optimal, "both just under it")
    }

    // MARK: Isolated systolic hypertension: >= 140 and < 90

    func testIsolatedSystolicBoundaries() {
        XCTAssertEqual(cat(140, 89), .isolatedSystolic)
        XCTAssertEqual(cat(140, 90), .grade1, "diastolic 90 leaves the isolated row")
        XCTAssertEqual(cat(139, 89), .highNormal, "systolic 139 is not yet hypertension")
        XCTAssertEqual(cat(170, 60), .isolatedSystolic)
    }

    // MARK: Whole-mmHg rounding (the displayed value is the classified value)

    func testValuesAreClassifiedAsTheyAreDisplayed() {
        XCTAssertEqual(cat(119.4, 79.4), .optimal)
        XCTAssertEqual(cat(119.5, 70), .normal, "119.5 shows as 120")
        XCTAssertEqual(cat(129.5, 70), .highNormal, "129.5 shows as 130")
        XCTAssertEqual(cat(110, 79.5), .normal, "79.5 shows as 80")
        XCTAssertEqual(cat(139.5, 70), .isolatedSystolic, "139.5 shows as 140")
    }

    // MARK: Invalid input never gets a category

    func testInvalidInputIsNil() {
        XCTAssertNil(cat(0, 80))
        XCTAssertNil(cat(120, 0))
        XCTAssertNil(cat(-120, 80))
        XCTAssertNil(cat(.nan, 80))
        XCTAssertNil(cat(120, .infinity))
    }

    func testEveryCategoryIsReachable() {
        let reached = Set([cat(110, 70), cat(125, 70), cat(135, 70), cat(150, 95),
                           cat(150, 105), cat(190, 120), cat(150, 70)].compactMap { $0 })
        XCTAssertEqual(reached, Set(BloodPressure.Category.allCases))
    }

    // MARK: Pairing

    func testPairKeepsOnlyDaysWithBothHalves() {
        let pairs = BloodPressure.pair(
            systolic: [(day: "2026-03-01", value: 120), (day: "2026-03-02", value: 130), (day: "2026-03-03", value: 140)],
            diastolic: [(day: "2026-03-03", value: 90), (day: "2026-03-01", value: 80)])
        XCTAssertEqual(pairs, [
            BloodPressure.DayReading(day: "2026-03-01", systolic: 120, diastolic: 80),
            BloodPressure.DayReading(day: "2026-03-03", systolic: 140, diastolic: 90),
        ])
        XCTAssertEqual(pairs.last?.category, .grade1)
    }

    // MARK: Merge of Apple Health and Lab Book

    func testMergeAppleOnlyKeepsAppleValue() {
        let m = BloodPressure.mergeDaily(appleDaily: [(day: "2026-03-01", value: 124)], labReadings: [])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].day, "2026-03-01")
        XCTAssertEqual(m[0].value, 124, accuracy: 1e-9)
    }

    func testMergeLabOnlyIsTheMeanOfTheDaysReadings() {
        let m = BloodPressure.mergeDaily(appleDaily: [], labReadings: [
            (day: "2026-03-01", value: 120), (day: "2026-03-01", value: 130), (day: "2026-03-01", value: 125),
            (day: "2026-03-02", value: 118),
        ])
        XCTAssertEqual(m.map { $0.day }, ["2026-03-01", "2026-03-02"])
        XCTAssertEqual(m[0].value, 125, accuracy: 1e-9)
        XCTAssertEqual(m[1].value, 118, accuracy: 1e-9)
    }

    func testMergeBothSourcesIsTheMeanOfAllReadingsOfTheDay() {
        // Apple Health contributes its daily value as one reading; each Lab Book reading is one more.
        let m = BloodPressure.mergeDaily(
            appleDaily: [(day: "2026-03-01", value: 126), (day: "2026-03-03", value: 140)],
            labReadings: [(day: "2026-03-01", value: 120), (day: "2026-03-01", value: 132),
                          (day: "2026-03-02", value: 110)])
        XCTAssertEqual(m.map { $0.day }, ["2026-03-01", "2026-03-02", "2026-03-03"])
        XCTAssertEqual(m[0].value, (126 + 120 + 132) / 3.0, accuracy: 1e-9)
        XCTAssertEqual(m[1].value, 110, accuracy: 1e-9)
        XCTAssertEqual(m[2].value, 140, accuracy: 1e-9)
    }

    func testMergeIgnoresNonFiniteValues() {
        let m = BloodPressure.mergeDaily(appleDaily: [(day: "2026-03-01", value: .nan)],
                                         labReadings: [(day: "2026-03-01", value: 121)])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].value, 121, accuracy: 1e-9)
        XCTAssertTrue(BloodPressure.mergeDaily(appleDaily: [], labReadings: []).isEmpty)
    }

    // MARK: Summary

    func testSummaryLatestAndThirtyDayAverages() {
        let days = [
            BloodPressure.DayReading(day: "2026-01-02", systolic: 150, diastolic: 95),   // outside the window
            BloodPressure.DayReading(day: "2026-03-01", systolic: 120, diastolic: 80),
            BloodPressure.DayReading(day: "2026-03-10", systolic: 130, diastolic: 84),
            BloodPressure.DayReading(day: "2026-03-20", systolic: 128, diastolic: 82),
        ]
        let s = BloodPressure.summary(days, today: "2026-03-21")
        XCTAssertEqual(s?.latest.day, "2026-03-20")
        XCTAssertEqual(s?.latest.systolic, 128)
        XCTAssertEqual(s?.daysInWindow, 3)
        XCTAssertEqual(s?.avgSystolic ?? 0, (120 + 130 + 128) / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s?.avgDiastolic ?? 0, (80 + 84 + 82) / 3.0, accuracy: 1e-9)
    }

    func testSummaryWindowIsInclusiveOfThirtyDays() {
        // today = 2026-03-31, a 30-day window starts on 2026-03-02.
        let days = [
            BloodPressure.DayReading(day: "2026-03-01", systolic: 200, diastolic: 120),  // 31 days back
            BloodPressure.DayReading(day: "2026-03-02", systolic: 120, diastolic: 80),   // first day in
            BloodPressure.DayReading(day: "2026-03-31", systolic: 130, diastolic: 84),   // today
        ]
        let s = BloodPressure.summary(days, today: "2026-03-31")
        XCTAssertEqual(s?.daysInWindow, 2)
        XCTAssertEqual(s?.avgSystolic ?? 0, 125, accuracy: 1e-9)
    }

    func testSummaryWithNothingInTheWindowKeepsTheLatestButNoAverage() {
        let days = [BloodPressure.DayReading(day: "2025-12-01", systolic: 118, diastolic: 76)]
        let s = BloodPressure.summary(days, today: "2026-03-21")
        XCTAssertEqual(s?.latest.day, "2025-12-01")
        XCTAssertEqual(s?.daysInWindow, 0)
        XCTAssertNil(s?.avgSystolic)
        XCTAssertNil(s?.avgDiastolic)
    }

    func testSummaryOfNoDaysIsNil() {
        XCTAssertNil(BloodPressure.summary([], today: "2026-03-21"))
    }

    func testDayShiftCrossesMonthAndYear() {
        XCTAssertEqual(BloodPressure.shift(day: "2026-03-01", by: -1), "2026-02-28")
        XCTAssertEqual(BloodPressure.shift(day: "2026-01-01", by: -1), "2025-12-31")
        XCTAssertEqual(BloodPressure.shift(day: "2024-03-01", by: -1), "2024-02-29")
        XCTAssertNil(BloodPressure.shift(day: "not-a-day", by: -1))
    }
}
