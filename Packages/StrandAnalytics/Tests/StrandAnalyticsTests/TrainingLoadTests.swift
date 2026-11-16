import XCTest
@testable import StrandAnalytics

final class TrainingLoadTests: XCTestCase {

    private let today = "2026-10-20"

    /// The day `back` days before `today` ("yyyy-MM-dd").
    private func day(_ back: Int) -> String {
        FitnessAgeEngine.shiftDay(today, by: -back) ?? "invalid"
    }

    /// One Effort per listed offset (0 = today, 6 = six days back, …).
    private func series(_ offsets: [Int], effort: Double) -> [(day: String, effort: Double?)] {
        offsets.map { (day: day($0), effort: Optional(effort)) }
    }

    // MARK: - Effort → TRIMP

    func testTrimpInvertsTheEffortScale() {
        // Effort is stored to 2 dp, so the round trip is only as exact as that rounding: ±0.005 of Effort is
        // ±0.005 · ln(D) / 100 of relative TRIMP.
        for trimp in [1.0, 10.0, 50.0, 100.0, 500.0, 2_000.0, 7_200.0] {
            let effort = StrainScorer.trimpToStrain(trimp)
            let back = TrainingLoad.trimp(fromEffort: effort)
            XCTAssertEqual(back, trimp, accuracy: (trimp + 1) * 0.0005, "TRIMP \(trimp) via Effort \(effort)")
        }
    }

    func testTrimpAtTheScaleEnds() {
        XCTAssertEqual(TrainingLoad.trimp(fromEffort: 0), 0)
        XCTAssertEqual(TrainingLoad.trimp(fromEffort: -5), 0)
        XCTAssertEqual(TrainingLoad.trimp(fromEffort: .nan), 0)
        XCTAssertEqual(TrainingLoad.trimp(fromEffort: .infinity), 0)
        // The Edwards daily ceiling (5 × 1440 min) is Effort 100.
        XCTAssertEqual(TrainingLoad.trimp(fromEffort: 100), 7_200, accuracy: 1e-6)
    }

    func testTrimpGrowsFasterThanEffort() {
        // Logarithmic scale: the same step in Effort is a bigger step in load higher up.
        let low = TrainingLoad.trimp(fromEffort: 40) - TrainingLoad.trimp(fromEffort: 30)
        let high = TrainingLoad.trimp(fromEffort: 80) - TrainingLoad.trimp(fromEffort: 70)
        XCTAssertGreaterThan(high, low * 10)
    }

    // MARK: - Summing is done in TRIMP, not Effort

    func testTwoEffort50DaysAreNotOneEffort100Day() {
        let two = TrainingLoad.summary(days: series([0, 1], effort: 50), today: today, weeks: 1)
        let one = TrainingLoad.summary(days: series([0], effort: 100), today: today, weeks: 1)
        XCTAssertEqual(two.acute, 2 * TrainingLoad.trimp(fromEffort: 50), accuracy: 1e-9)
        XCTAssertEqual(one.acute, TrainingLoad.trimp(fromEffort: 100), accuracy: 1e-9)
        // Summing Effort would give 100 = 100; in load the single hard day is far bigger.
        XCTAssertGreaterThan(one.acute, two.acute * 10)
    }

    // MARK: - Windows

    func testAcuteIsTodayAndTheSixDaysBefore() {
        let t = TrainingLoad.trimp(fromEffort: 60)
        // Offsets 0…6 are the acute week; 7 is not.
        let inside = TrainingLoad.summary(days: series([0, 6], effort: 60), today: today)
        XCTAssertEqual(inside.acute, 2 * t, accuracy: 1e-9)
        XCTAssertEqual(inside.acuteDays, 2)
        XCTAssertEqual(inside.chronicDays, 0)

        let outside = TrainingLoad.summary(days: series([7], effort: 60), today: today)
        XCTAssertEqual(outside.acute, 0)
        XCTAssertEqual(outside.acuteDays, 0)
        XCTAssertEqual(outside.chronicDays, 1)
    }

    func testChronicIsTheFourWeeksBeforeTheAcuteWeek() throws {
        let t = TrainingLoad.trimp(fromEffort: 60)
        // 8 days back counting today as day 1 is offset 7; 35 days back is offset 34. Offset 35 is outside.
        // 14 days with data is the minimum for a "usual week": offsets 7…20.
        let inWindow = series(Array(7...20), effort: 60)
        let s = TrainingLoad.summary(days: inWindow, today: today)
        XCTAssertEqual(s.chronicDays, 14)
        XCTAssertEqual(try XCTUnwrap(s.chronicWeekly), 7 * t, accuracy: 1e-9, "mean daily load × 7")

        let edge = TrainingLoad.summary(days: series(Array(7...19) + [34], effort: 60), today: today)
        XCTAssertEqual(edge.chronicDays, 14, "the 35th day back (offset 34) is the last chronic day")

        let tooOld = TrainingLoad.summary(days: series(Array(7...19) + [35], effort: 60), today: today)
        XCTAssertEqual(tooOld.chronicDays, 13, "offset 35 is outside the window")
        XCTAssertNil(tooOld.chronicWeekly)
    }

    func testChronicDoesNotShareDaysWithTheAcuteWeek() throws {
        // An enormous acute week must not move the usual week at all (uncoupled windows).
        var days = series(Array(7...34), effort: 50)
        let calm = TrainingLoad.summary(days: days, today: today)
        days += series(Array(0...6), effort: 100)
        let spike = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(try XCTUnwrap(spike.chronicWeekly), try XCTUnwrap(calm.chronicWeekly), accuracy: 1e-9)
        XCTAssertEqual(spike.chronicDays, 28)
    }

    func testSteadyTrainingReadsAsOne() throws {
        let s = TrainingLoad.summary(days: series(Array(0...34), effort: 55), today: today)
        let ratio = try XCTUnwrap(s.ratio)
        XCTAssertEqual(ratio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.band, .steady)
        XCTAssertEqual(s.acuteDays, 7)
        XCTAssertEqual(s.chronicDays, 28)
    }

    /// Unworn days in either window don't skew the ratio: steady training reads 1.0 with 20 of 28 chronic days
    /// and 5 of 7 acute days recorded (a sum ÷ 4 would have read the usual week 29 % low).
    func testPartialCoverageDoesNotSkewTheRatio() throws {
        let days = series([0, 1, 2, 4, 6], effort: 55) + series(Array(7...26), effort: 55)
        let s = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(s.acuteDays, 5)
        XCTAssertEqual(s.chronicDays, 20)
        XCTAssertEqual(try XCTUnwrap(s.ratio), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.chronicWeekly), 7 * TrainingLoad.trimp(fromEffort: 55), accuracy: 1e-9)
        XCTAssertEqual(s.acute, 5 * TrainingLoad.trimp(fromEffort: 55), accuracy: 1e-9, "the 7-day load stays a sum")
    }

    func testARisingWeekReadsAsHigher() throws {
        // Usual: Effort 50 every day. This week: Effort 60 every day → much more TRIMP, ratio well above 1.
        let days = series(Array(7...34), effort: 50) + series(Array(0...6), effort: 60)
        let s = TrainingLoad.summary(days: days, today: today)
        let expected = TrainingLoad.trimp(fromEffort: 60) / TrainingLoad.trimp(fromEffort: 50)
        XCTAssertEqual(try XCTUnwrap(s.ratio), expected, accuracy: 1e-9)
        XCTAssertEqual(s.band, TrainingLoad.band(ratio: expected))
    }

    // MARK: - Bands

    func testBandEdges() {
        XCTAssertEqual(TrainingLoad.band(ratio: 0), .below)
        XCTAssertEqual(TrainingLoad.band(ratio: 0.79), .below)
        XCTAssertEqual(TrainingLoad.band(ratio: 0.8), .steady)
        XCTAssertEqual(TrainingLoad.band(ratio: 1.0), .steady)
        XCTAssertEqual(TrainingLoad.band(ratio: 1.3), .steady)
        XCTAssertEqual(TrainingLoad.band(ratio: 1.31), .higher)
        XCTAssertEqual(TrainingLoad.band(ratio: 1.5), .higher)
        XCTAssertEqual(TrainingLoad.band(ratio: 1.51), .sharpRise)
        XCTAssertEqual(TrainingLoad.band(ratio: 4), .sharpRise)
    }

    // MARK: - Data coverage

    func testThreeAcuteDaysGiveNoRatio() {
        let days = series([0, 1, 2], effort: 60) + series(Array(7...34), effort: 60)
        let s = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(s.acuteDays, 3)
        XCTAssertGreaterThan(s.acute, 0, "the 7-day load is still reported")
        XCTAssertNotNil(s.chronicWeekly, "the usual week is known, only this week is too thin")
        XCTAssertNil(s.ratio)
        XCTAssertNil(s.band)

        let four = TrainingLoad.summary(days: series([0, 1, 2, 3], effort: 60) + series(Array(7...34), effort: 60),
                                        today: today)
        XCTAssertNotNil(four.ratio)
        XCTAssertNotNil(four.band)
    }

    func testThirteenChronicDaysGiveNoRatio() {
        let days = series(Array(0...6), effort: 60) + series(Array(7...19), effort: 60)
        let s = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(s.chronicDays, 13)
        XCTAssertNil(s.chronicWeekly)
        XCTAssertNil(s.ratio)
        XCTAssertNil(s.band)
        XCTAssertGreaterThan(s.acute, 0)

        let fourteen = TrainingLoad.summary(days: series(Array(0...6), effort: 60) + series(Array(7...20), effort: 60),
                                            today: today)
        XCTAssertEqual(fourteen.chronicDays, 14)
        XCTAssertNotNil(fourteen.ratio)
    }

    func testNoUsualLoadGivesNoRatio() {
        // 28 recorded easy days of Effort 0: the usual week is 0, and a ratio against 0 does not exist.
        let days = series(Array(0...6), effort: 40) + series(Array(7...34), effort: 0)
        let s = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(s.chronicWeekly, 0)
        XCTAssertNil(s.ratio)
        XCTAssertNil(s.band)
    }

    func testMissingDaysAreNotZeroDays() {
        // nil is unknown, 0 is a recorded easy day: only the second counts as data.
        var days = series([0, 1], effort: 60)
        days.append((day: day(2), effort: nil))
        days.append((day: day(3), effort: 0))
        let s = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(s.acuteDays, 3)
        XCTAssertEqual(s.weeks.last?.daysWithData, 3)
        XCTAssertEqual(s.acute, 2 * TrainingLoad.trimp(fromEffort: 60), accuracy: 1e-9)
    }

    func testNoDataAtAll() {
        let s = TrainingLoad.summary(days: [], today: today)
        XCTAssertEqual(s.acute, 0)
        XCTAssertEqual(s.acuteDays, 0)
        XCTAssertEqual(s.chronicDays, 0)
        XCTAssertNil(s.chronicWeekly)
        XCTAssertNil(s.ratio)
        XCTAssertNil(s.band)
        XCTAssertEqual(s.weeks.count, 8)
        XCTAssertTrue(s.weeks.allSatisfy { $0.daysWithData == 0 && $0.load == 0 })
    }

    // MARK: - Input hygiene

    func testUnusableEffortsAreIgnoredAndTheLastDuplicateWins() {
        let days: [(day: String, effort: Double?)] = [
            (day: day(0), effort: 30),
            (day: day(0), effort: 60),          // last usable entry for the day wins
            (day: day(1), effort: -10),         // negative: ignored
            (day: day(2), effort: .nan),        // not finite: ignored
            (day: day(3), effort: .infinity),   // not finite: ignored
            (day: day(4), effort: 40),
            (day: day(4), effort: nil),         // nil never replaces a usable value
            (day: "not a day", effort: 90),     // never inside any window
        ]
        let s = TrainingLoad.summary(days: days, today: today)
        XCTAssertEqual(s.acuteDays, 2)
        XCTAssertEqual(s.acute, TrainingLoad.trimp(fromEffort: 60) + TrainingLoad.trimp(fromEffort: 40), accuracy: 1e-9)
    }

    func testEffortAboveTheScaleIsCapped() {
        let s = TrainingLoad.summary(days: [(day: day(0), effort: 250)], today: today, weeks: 1)
        XCTAssertEqual(s.acute, TrainingLoad.trimp(fromEffort: 100), accuracy: 1e-9)
    }

    func testUnparseableTodayGivesAnEmptySummary() {
        let s = TrainingLoad.summary(days: series([0], effort: 60), today: "soon")
        XCTAssertTrue(s.weeks.isEmpty)
        XCTAssertEqual(s.acuteDays, 0)
        XCTAssertNil(s.ratio)
    }

    // MARK: - Weekly blocks

    func testWeeksRunOldestToNewestAndEndOnToday() {
        let s = TrainingLoad.summary(days: [], today: today)
        XCTAssertEqual(s.weeks.count, 8)
        XCTAssertEqual(s.weeks.last?.end, "2026-10-20")
        XCTAssertEqual(s.weeks.last?.start, "2026-10-14")
        XCTAssertEqual(s.weeks[6].end, "2026-10-13")
        XCTAssertEqual(s.weeks[6].start, "2026-10-07")
        XCTAssertEqual(s.weeks.first?.end, "2026-09-01")
        XCTAssertEqual(s.weeks.first?.start, "2026-08-26")
        // Consecutive blocks touch without a gap or an overlap.
        for (older, newer) in zip(s.weeks, s.weeks.dropFirst()) {
            XCTAssertEqual(FitnessAgeEngine.shiftDay(older.end, by: 1), newer.start)
        }
    }

    func testWeekLoadsAndDayCounts() {
        let t50 = TrainingLoad.trimp(fromEffort: 50)
        let t70 = TrainingLoad.trimp(fromEffort: 70)
        // Offsets 0–2 are this week, 7 and 13 the week before, 14 the one before that.
        let days: [(day: String, effort: Double?)] =
            series([0, 1, 2], effort: 50) + series([7, 13], effort: 70) + series([14], effort: 50)
        let s = TrainingLoad.summary(days: days, today: today, weeks: 3)
        XCTAssertEqual(s.weeks.count, 3)
        XCTAssertEqual(s.weeks[2].daysWithData, 3)
        XCTAssertEqual(s.weeks[2].load, 3 * t50, accuracy: 1e-9)
        XCTAssertEqual(s.weeks[1].daysWithData, 2)
        XCTAssertEqual(s.weeks[1].load, 2 * t70, accuracy: 1e-9)
        XCTAssertEqual(s.weeks[0].daysWithData, 1)
        XCTAssertEqual(s.weeks[0].load, t50, accuracy: 1e-9)
        // The newest block is the acute week.
        XCTAssertEqual(s.weeks[2].load, s.acute, accuracy: 1e-9)
        XCTAssertEqual(s.weeks[2].daysWithData, s.acuteDays)
    }

    func testWeeksParameterDoesNotChangeTheRatio() {
        let days = series(Array(0...40), effort: 55)
        let short = TrainingLoad.summary(days: days, today: today, weeks: 1)
        let long = TrainingLoad.summary(days: days, today: today, weeks: 12)
        XCTAssertEqual(short.weeks.count, 1)
        XCTAssertEqual(long.weeks.count, 12)
        XCTAssertEqual(short.ratio, long.ratio)
        XCTAssertEqual(short.chronicWeekly, long.chronicWeekly)
        XCTAssertEqual(TrainingLoad.summary(days: days, today: today, weeks: 0).weeks.count, 1)
    }

    func testWeeksAcrossAYearBoundary() {
        let s = TrainingLoad.summary(days: [], today: "2026-01-03", weeks: 2)
        XCTAssertEqual(s.weeks.last?.start, "2025-12-28")
        XCTAssertEqual(s.weeks.last?.end, "2026-01-03")
        XCTAssertEqual(s.weeks.first?.start, "2025-12-21")
        XCTAssertEqual(s.weeks.first?.end, "2025-12-27")
    }
}
