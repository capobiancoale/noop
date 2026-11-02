import XCTest
@testable import StrandImport

final class GlucoseNowTests: XCTestCase {

    private let t0 = 1_790_000_000.0

    /// Readings at (minutes from t0, mg/dL).
    private func readings(_ pairs: [(Double, Double)]) -> [GlucoseReading] {
        pairs.map { GlucoseReading(ts: t0 + $0.0 * 60, day: "d", minutesLocal: 0, mgdl: $0.1) }
    }

    // MARK: Latest reading and rate

    func testNoReadingsNoGlucose() {
        XCTAssertNil(GlucoseNow.latest([]))
    }

    func testTheLatestReadingIsTakenWhateverTheOrder() {
        let now = GlucoseNow.latest(readings([(10, 130), (0, 120), (5, 125)]))
        XCTAssertEqual(now?.ts, t0 + 600)
        XCTAssertEqual(now?.mgdl, 130)
    }

    func testAFlatTraceIsSteady() {
        let now = GlucoseNow.latest(readings([(0, 120), (5, 121), (10, 119), (15, 120)]))
        XCTAssertEqual(now?.ratePerMinute ?? 99, 0, accuracy: 0.1)
        XCTAssertEqual(now?.trend, .steady)
    }

    func testTheRateIsTheSlopeInMgdlPerMinute() {
        // +2.5 mg/dL per minute over 15 minutes of 5-minute readings.
        let now = GlucoseNow.latest(readings([(0, 100), (5, 112.5), (10, 125), (15, 137.5)]))
        XCTAssertEqual(now?.ratePerMinute ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(now?.trend, .rising)
    }

    func testOnlyTheLastFifteenMinutesCount() {
        // Rising for half an hour, then falling 1.5 per minute for the last 15 minutes.
        let now = GlucoseNow.latest(readings([(0, 100), (10, 130), (20, 160), (25, 152.5), (30, 145), (35, 137.5)]))
        XCTAssertEqual(now?.ratePerMinute ?? 0, -1.5, accuracy: 1e-9)
        XCTAssertEqual(now?.trend, .fallingSlowly)
    }

    func testOneNoisyReadingDoesNotFlipTheArrow() {
        // Steadily falling 2.5 per minute on a 1-minute sensor, with one reading 12 mg/dL off.
        var pairs = (0...15).map { (Double($0), 200 - 2.5 * Double($0)) }
        pairs[8].1 += 12
        XCTAssertEqual(GlucoseNow.latest(readings(pairs))?.trend, .falling)
    }

    func testTwoReadingsAreTooFewForARate() {
        let now = GlucoseNow.latest(readings([(0, 100), (10, 140)]))
        XCTAssertEqual(now?.mgdl, 140)
        XCTAssertNil(now?.ratePerMinute)
        XCTAssertNil(now?.trend)
    }

    func testReadingsTooCloseTogetherGiveNoRate() {
        XCTAssertNil(GlucoseNow.latest(readings([(0, 100), (2, 104), (4, 108)]))?.ratePerMinute)
    }

    func testTheSameReadingFromTwoSourcesCountsOnce() {
        // Two distinct times only, each written twice: still too few for a rate.
        let now = GlucoseNow.latest(readings([(0, 100), (0, 100), (10, 120), (10, 120)]))
        XCTAssertNil(now?.ratePerMinute)
    }

    func testTheArrowSteps() {
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: 1), .steady)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: -1), .steady)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: 1.5), .risingSlowly)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: -2), .fallingSlowly)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: 3), .rising)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: -2.5), .falling)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: 3.2), .risingFast)
        XCTAssertEqual(GlucoseNow.trend(ratePerMinute: -4), .fallingFast)
    }

    func testAnOldReadingIsNotNow() {
        let now = GlucoseNow(ts: t0, mgdl: 120, ratePerMinute: 0)
        XCTAssertFalse(now.isStale(now: t0 + 15 * 60))
        XCTAssertTrue(now.isStale(now: t0 + 15 * 60 + 1))
    }

    // MARK: Around a workout

    func testGlucoseAtTheStartAndEndOfAWorkout() {
        // Workout from minute 30 to minute 90; readings every 5 minutes, dropping from 180 to 120, then 110.
        var pairs: [(Double, Double)] = []
        for i in 0...18 {
            let minute = Double(i * 5)
            pairs.append((minute, 180 - max(0, minute - 30)))
        }
        pairs.append((100, 110))
        let trace = GlucoseTrace(readings: readings(pairs))
        let g = WorkoutGlucose.around(trace, start: t0 + 30 * 60, end: t0 + 90 * 60)
        XCTAssertEqual(g?.startMgdl, 180)
        XCTAssertEqual(g?.endMgdl, 120)
        XCTAssertEqual(g?.lowestMgdl, 110)          // after the end, inside the hour
        XCTAssertEqual(g?.wentLow, false)
    }

    func testALowInTheHourAfterIsCaught() {
        let trace = GlucoseTrace(readings: readings([(0, 140), (30, 110), (60, 90), (75, 64), (90, 80), (150, 50)]))
        let g = WorkoutGlucose.around(trace, start: t0, end: t0 + 30 * 60)
        XCTAssertEqual(g?.lowestMgdl, 64)           // the 50 at minute 150 is more than an hour after the end
        XCTAssertEqual(g?.wentLow, true)
    }

    func testAReadingTooFarFromAnEdgeIsNotTakenForIt() {
        // Nothing within 10 minutes of the start; the end has one 4 minutes after it.
        let trace = GlucoseTrace(readings: readings([(-30, 150), (64, 120)]))
        let g = WorkoutGlucose.around(trace, start: t0, end: t0 + 60 * 60)
        XCTAssertNil(g?.startMgdl)
        XCTAssertEqual(g?.endMgdl, 120)
    }

    func testNoReadingsAroundTheWorkout() {
        let trace = GlucoseTrace(readings: readings([(-300, 150)]))
        XCTAssertNil(WorkoutGlucose.around(trace, start: t0, end: t0 + 3_600))
        XCTAssertNil(WorkoutGlucose.around(GlucoseTrace(readings: []), start: t0, end: t0 + 3_600))
    }
}
