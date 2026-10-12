import XCTest
@testable import StrandAnalytics

/// The daily HUNT VO₂max series: one Nes 2011 estimate per day on the 7 calendar days ending on it.
final class DailyVO2maxSeriesTests: XCTestCase {

    private typealias Row = (day: String, restingHR: Double?, strain: Double?)

    /// `n` consecutive days from 2026-03-01 with the same resting HR and strain.
    private func constantRows(_ n: Int, rhr: Double? = 60, strain: Double? = 50) -> [Row] {
        (0..<n).compactMap { i in
            FitnessAgeEngine.shiftDay("2026-03-01", by: i).map { (day: $0, restingHR: rhr, strain: strain) }
        }
    }

    // MARK: - The series

    func testConstantInputsGiveConstantSeriesEqualToTheNesEstimate() {
        // 10 days, RHR 60, strain 50 every day: 7 active days → frequency 5, mean strain 50 → PAI 5 × 50/30.
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: constantRows(10), age: 40, sex: "male", waistCm: 90)
        let pa = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 50)
        let expected = FitnessAgeEngine.estimateVO2max(age: 40, sex: "male", waistCm: 90, restingHR: 60, paIndex: pa)
        // Days 1–3 have fewer than 4 nights; days 4…10 have a point.
        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series.first?.day, "2026-03-04")
        XCTAssertEqual(series.last?.day, "2026-03-10")
        // From day 5 on at least 5 days are active, so the frequency factor is at its ceiling (5) and the series is
        // constant. Day 4 has only 4 active days (frequency 2.5): the same evidence, a smaller activity index.
        for p in series.dropFirst() { XCTAssertEqual(p.vo2max, expected, accuracy: 1e-9) }
        XCTAssertLessThan(series[0].vo2max, expected)
    }

    func testFullWindowMatchesComputeForTheSameWeek() {
        // A full 7-day window must give exactly what the weekly Fitness Age pass computes from the same week.
        let rows = constantRows(7, rhr: 58, strain: 45)
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 35, sex: "female", waistCm: 78)
        let pa = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 45)
        let weekly = FitnessAgeEngine.compute(age: 35, sex: "female", restingHR: 58, paIndex: pa, waistCm: 78)
        XCTAssertEqual(series.last?.vo2max ?? 0, weekly?.vo2max ?? -1, accuracy: 1e-9)
    }

    func testFallingRestingHeartRateRaisesTheEstimate() {
        let rhrs: [Double] = [66, 66, 66, 66, 66, 66, 66, 60, 60, 60, 60, 60, 60, 60]
        let rows: [Row] = rhrs.enumerated().compactMap { i, r in
            FitnessAgeEngine.shiftDay("2026-03-01", by: i).map { (day: $0, restingHR: r, strain: 40) }
        }
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90)
        XCTAssertGreaterThan(series.last?.vo2max ?? 0, (series.first?.vo2max ?? 0) + 0.5)
        // Monotone: once the median RHR starts falling it never rises again with constant activity.
        let values = series.map(\.vo2max)
        XCTAssertEqual(values, values.sorted())
    }

    func testFewerThanFourNightsGivesNoPoint() {
        // Three nights of resting HR in the week → nothing, however many days are listed.
        var rows = constantRows(7, rhr: nil, strain: 50)
        rows[0].restingHR = 60; rows[2].restingHR = 61; rows[4].restingHR = 59
        XCTAssertTrue(FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90).isEmpty)
        // A fourth night makes the last day computable.
        rows[6].restingHR = 60
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90)
        XCTAssertEqual(series.map(\.day), ["2026-03-07"])
    }

    func testGapsAreHandledByCalendarWindowNotArrayIndex() {
        // Nights on days 1, 2, 3, 4 then nothing until day 12: by array position the 5th row would still see
        // the four old nights; by calendar the week ending on day 12 (days 6–12) has only one night.
        var rows: [Row] = (1...4).map { (day: "2026-03-0\($0)", restingHR: 60, strain: 50) }
        rows.append((day: "2026-03-12", restingHR: 60, strain: 50))
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90)
        XCTAssertEqual(series.map(\.day), ["2026-03-04"])
        // And a day inside the gap that IS listed reads only the nights that fall in its own week.
        rows.append((day: "2026-03-07", restingHR: nil, strain: nil))   // week 1–7: nights 1,2,3,4 → counts
        rows.append((day: "2026-03-09", restingHR: nil, strain: nil))   // week 3–9: nights 3,4 → no point
        let more = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90)
        XCTAssertEqual(more.map(\.day), ["2026-03-04", "2026-03-07"])
    }

    func testUnorderedAndDuplicatedRowsAreNormalised() {
        var rows = constantRows(8)
        rows.shuffle()
        rows.append((day: "2026-03-05", restingHR: nil, strain: nil))   // duplicate without data keeps the real one
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90)
        XCTAssertEqual(series.map(\.day), series.map(\.day).sorted())
        XCTAssertEqual(series.count, 5)   // days 4…8
    }

    func testTodayWithoutItsOwnNightReadsTheSixDaysBefore() {
        // Six scored days, today listed empty: today's window = 6 nights, so it has a point.
        var rows = constantRows(6)
        rows.append((day: "2026-03-07", restingHR: nil, strain: nil))
        let series = FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90)
        XCTAssertEqual(series.last?.day, "2026-03-07")
    }

    func testActiveDayRuleIsStrainAtLeast30() {
        // Same nights; one week trains at strain 30, the other at 29.9 (not an active day → PA-index 0).
        let at30 = FitnessAgeEngine.dailyVO2maxSeries(days: constantRows(7, strain: 30),
                                                     age: 40, sex: "male", waistCm: 90)
        let below = FitnessAgeEngine.dailyVO2maxSeries(days: constantRows(7, strain: 29.9),
                                                      age: 40, sex: "male", waistCm: 90)
        let pa30 = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 30)
        XCTAssertEqual(pa30, 5.0, accuracy: 1e-9)
        let expected30 = FitnessAgeEngine.estimateVO2max(age: 40, sex: "male", waistCm: 90, restingHR: 60, paIndex: 5)
        let expectedBelow = FitnessAgeEngine.estimateVO2max(age: 40, sex: "male", waistCm: 90, restingHR: 60, paIndex: 0)
        XCTAssertEqual(at30.last?.vo2max ?? 0, expected30, accuracy: 1e-9)
        XCTAssertEqual(below.last?.vo2max ?? 0, expectedBelow, accuracy: 1e-9)
    }

    func testMedianIgnoresOneOutlierNight() {
        var rows = constantRows(7, rhr: 60, strain: 50)
        rows[3].restingHR = 95   // one feverish night
        let w = FitnessAgeEngine.vo2maxWindow(days: rows, endingOn: "2026-03-07")
        XCTAssertEqual(w?.restingHR ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(w?.nights, 7)
        XCTAssertEqual(w?.activeDays, 7)
    }

    func testNoPointWithoutAgeOrWaist() {
        let rows = constantRows(10)
        XCTAssertTrue(FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 0).isEmpty)
        XCTAssertTrue(FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 0, sex: "male", waistCm: 90).isEmpty)
        XCTAssertTrue(FitnessAgeEngine.dailyVO2maxSeries(days: [], age: 40, sex: "male", waistCm: 90).isEmpty)
    }

    func testZeroOrMissingRestingHeartRateDoesNotCountAsANight() {
        var rows = constantRows(7)
        rows[0].restingHR = 0
        rows[1].restingHR = 0
        rows[2].restingHR = nil
        // 4 real nights left (days 4–7) → still a point; a fifth zero removes it.
        XCTAssertEqual(FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90).count, 1)
        rows[3].restingHR = 0
        XCTAssertTrue(FitnessAgeEngine.dailyVO2maxSeries(days: rows, age: 40, sex: "male", waistCm: 90).isEmpty)
    }

    // MARK: - Standard error

    func testStandardErrorBySex() {
        XCTAssertEqual(FitnessAgeEngine.vo2maxStandardError(sex: "male"), 5.70, accuracy: 1e-9)
        XCTAssertEqual(FitnessAgeEngine.vo2maxStandardError(sex: "female"), 5.14, accuracy: 1e-9)
        XCTAssertEqual(FitnessAgeEngine.vo2maxStandardError(sex: "other"), 5.70, accuracy: 1e-9)
    }

    // MARK: - Rolling mean

    func testRollingMeanUsesCalendarDays() {
        let series: [(day: String, value: Double)] = [
            (day: "2026-03-01", value: 40), (day: "2026-03-02", value: 42),
            (day: "2026-03-03", value: 44), (day: "2026-03-20", value: 50),
        ]
        let mean = FitnessAgeEngine.rollingMean(series)
        XCTAssertEqual(mean.map(\.day), ["2026-03-01", "2026-03-02", "2026-03-03", "2026-03-20"])
        XCTAssertEqual(mean[0].value, 40, accuracy: 1e-9)
        XCTAssertEqual(mean[1].value, 41, accuracy: 1e-9)
        XCTAssertEqual(mean[2].value, 42, accuracy: 1e-9)
        XCTAssertEqual(mean[3].value, 50, accuracy: 1e-9)   // the old points are outside its week
    }

    func testRollingMeanWindowEdges() {
        let series: [(day: String, value: Double)] = (1...8).map { (day: "2026-03-0\($0)", value: Double($0)) }
        let mean = FitnessAgeEngine.rollingMean(series, windowDays: 7)
        // Day 8's week is days 2…8: (2+…+8)/7 = 5; day 1 has dropped out.
        XCTAssertEqual(mean.last?.value ?? 0, 5, accuracy: 1e-9)
        XCTAssertTrue(FitnessAgeEngine.rollingMean(series, windowDays: 0).isEmpty)
    }

    // MARK: - Calendar arithmetic

    func testShiftDayAcrossMonthsAndLeapYears() {
        XCTAssertEqual(FitnessAgeEngine.shiftDay("2026-03-01", by: -1), "2026-02-28")
        XCTAssertEqual(FitnessAgeEngine.shiftDay("2028-03-01", by: -1), "2028-02-29")
        XCTAssertEqual(FitnessAgeEngine.shiftDay("2026-12-31", by: 1), "2027-01-01")
        XCTAssertEqual(FitnessAgeEngine.shiftDay("2026-10-12", by: -119), "2026-06-15")
        XCTAssertEqual(FitnessAgeEngine.shiftDay("2026-10-12", by: 0), "2026-10-12")
        XCTAssertEqual(FitnessAgeEngine.shiftDay("1999-01-31", by: 400), "2000-03-06")
        XCTAssertNil(FitnessAgeEngine.shiftDay("not-a-day", by: 1))
        XCTAssertNil(FitnessAgeEngine.shiftDay("2026-13-01", by: 1))
    }
}
