import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

final class AthleteReliabilityTests: XCTestCase {
    func testIrregularDurationsAndDuplicates() {
        let rows = [HRSample(ts: 0, bpm: 185), HRSample(ts: 10, bpm: 185),
                    HRSample(ts: 30, bpm: 185), HRSample(ts: 60, bpm: 185)]
        // 10 + 20 + 30 measured seconds, plus median terminal interval 20 s.
        XCTAssertEqual(StrainScorer.coverage(rows).observedSeconds, 80)
        XCTAssertEqual(StrainScorer.edwardsTRIMP(rows, restingHR: 60, hrReserve: 130,
                                               sampleDurationMin: 999), 80.0 / 60 * 5, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.coverage(rows + rows.reversed()), StrainScorer.coverage(rows))
    }

    func testLongGapsDoNotCreateLoadOrQualifySparseData() {
        let rows = (0..<30).map { HRSample(ts: $0 * 3600, bpm: 185) }
        XCTAssertNil(StrainScorer.strain(rows, maxHR: 190))
        XCTAssertEqual(StrainScorer.coverage(rows).observedSeconds, 0)
        XCTAssertEqual(StrainScorer.coverage(rows).gapSeconds, 29 * 3600)
    }

    func testTwoDenseSegmentsExcludeGap() {
        let first = (0..<600).map { HRSample(ts: $0, bpm: 185) }
        let second = (0..<600).map { HRSample(ts: 7200 + $0, bpm: 185) }
        XCTAssertEqual(StrainScorer.coverage(first + second).observedSeconds, 1199)
        XCTAssertEqual(StrainScorer.coverage(first + second).gapSeconds, 6601)
    }

    private func row(_ day: String, strain: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: 55,
                    avgHrv: 60, recovery: nil, strain: strain, exerciseCount: nil)
    }

    func testFutureRowsCannotChangeHistoricalReadiness() {
        let rows = (0..<28).map { row(ReadinessEngine.dayKey("2024-03-31", adding: -$0)!, strain: 10) }
        let past = ReadinessEngine.evaluate(days: rows, today: "2024-03-31")
        let future = ReadinessEngine.evaluate(days: rows + [row("2024-04-01", strain: 100)], today: "2024-03-31")
        XCTAssertEqual(past, future)
        XCTAssertEqual(past.acwr, 1)
    }

    func testMissingDayIsUnknownButExplicitZeroIsRecorded() {
        var rows = (0..<28).map { row(ReadinessEngine.dayKey("2024-03-31", adding: -$0)!, strain: 10) }
        rows.removeLast()
        XCTAssertNil(ReadinessEngine.evaluate(days: rows, today: "2024-03-31").acwr)
        rows.append(row("2024-03-04", strain: 0))
        XCTAssertNotNil(ReadinessEngine.evaluate(days: rows, today: "2024-03-31").acwr)
    }

    func testCivilDayArithmeticAcrossDSTAndLeapDay() {
        XCTAssertEqual(ReadinessEngine.dayKey("2024-03-31", adding: -1), "2024-03-30")
        XCTAssertEqual(ReadinessEngine.dayKey("2024-03-01", adding: -1), "2024-02-29")
        XCTAssertNil(ReadinessEngine.dayKey("2024-02-31", adding: 1))
    }

    func testExplicitDurationOverridesTimeCap() {
        let w = WodLogRow(id: "a", ts: 0, day: "2024-01-01", type: "Strength", title: "Squat",
                          timeCapS: 600, rpe: 8, createdTs: 0, durationS: 1800)
        let session = StrainScorer.LoggedSession(wod: w, tzOffsetSeconds: 0)
        XCTAssertEqual(session?.load, 240)
    }
}
