import XCTest
@testable import StrandImport

/// Unit tests for the pure diabetes reductions. These run on any platform (no HealthKit), so the
/// clinical arithmetic that `HealthKitBridge` relies on is validated in CI even though the bridge
/// itself is iOS-only.
final class DiabetesMetricsTests: XCTestCase {

    // MARK: Glucose

    func testGlucoseDailyBandsVariabilityHypoOvernight() throws {
        // One day, ascending by time. minutesLocal < 360 == overnight (00:00–06:00).
        let day = "2024-05-01"
        let r: [GlucoseReading] = [
            .init(ts: 1, day: day, minutesLocal: 300, mgdl: 60),   // overnight, <70 -> hypo event #1
            .init(ts: 2, day: day, minutesLocal: 390, mgdl: 75),   // in range (recovered)
            .init(ts: 3, day: day, minutesLocal: 480, mgdl: 100),  // in range
            .init(ts: 4, day: day, minutesLocal: 720, mgdl: 200),  // > 180
            .init(ts: 5, day: day, minutesLocal: 840, mgdl: 260),  // > 250
            .init(ts: 6, day: day, minutesLocal: 1200, mgdl: 50),  // <54 -> hypo event #2 (severe)
        ]
        let d = try XCTUnwrap(DiabetesMetrics.glucoseDaily(r)[day])

        XCTAssertEqual(d.readings, 6)
        XCTAssertEqual(d.mean, 745.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(d.min, 50, accuracy: 1e-9)
        XCTAssertEqual(d.max, 260, accuracy: 1e-9)
        // 2 in range, 2 below (<70), 1 severe (<54), 2 above (>180), 1 very high (>250) — of 6.
        XCTAssertEqual(d.tirPct, 2.0 / 6.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(d.tbrPct, 2.0 / 6.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(d.tbrSeverePct, 1.0 / 6.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(d.tarPct, 2.0 / 6.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(d.tarHighPct, 1.0 / 6.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(d.hypoEvents, 2)
        // Only the 05:00 (minutesLocal 300) reading is overnight.
        XCTAssertEqual(try XCTUnwrap(d.overnightMean), 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(d.overnightMin), 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(d.cvPct), 69.1, accuracy: 0.5)
    }

    func testGlucoseDailyStableDayNoHypoNoOvernight() throws {
        let day = "2024-05-02"
        let r: [GlucoseReading] = [
            .init(ts: 1, day: day, minutesLocal: 600, mgdl: 110),
            .init(ts: 2, day: day, minutesLocal: 700, mgdl: 120),
            .init(ts: 3, day: day, minutesLocal: 800, mgdl: 130),
        ]
        let d = try XCTUnwrap(DiabetesMetrics.glucoseDaily(r)[day])
        XCTAssertEqual(d.tirPct, 100, accuracy: 1e-9)
        XCTAssertEqual(d.tbrPct, 0, accuracy: 1e-9)
        XCTAssertEqual(d.tarPct, 0, accuracy: 1e-9)
        XCTAssertEqual(d.hypoEvents, 0)
        XCTAssertNil(d.overnightMean)   // no readings before 06:00
        XCTAssertNil(d.overnightMin)
        XCTAssertNotNil(d.cvPct)        // 3 readings -> CV computable
    }

    func testGlucoseDailySingleReadingHasNilCV() throws {
        let day = "2024-05-03"
        let d = try XCTUnwrap(DiabetesMetrics.glucoseDaily([
            .init(ts: 1, day: day, minutesLocal: 500, mgdl: 100)
        ])[day])
        XCTAssertNil(d.cvPct)           // variability undefined with a single reading
        XCTAssertEqual(d.tirPct, 100, accuracy: 1e-9)
    }

    func testGlucoseDailyEmptyIsEmpty() {
        XCTAssertTrue(DiabetesMetrics.glucoseDaily([]).isEmpty)
    }

    func testGlucoseDayOpeningBelowRangeCountsAsOneHypo() throws {
        let day = "2024-05-04"
        let r: [GlucoseReading] = [
            .init(ts: 1, day: day, minutesLocal: 60, mgdl: 65),   // opens below -> event #1
            .init(ts: 2, day: day, minutesLocal: 120, mgdl: 66),  // still below -> same event
            .init(ts: 3, day: day, minutesLocal: 180, mgdl: 90),  // recovered
        ]
        XCTAssertEqual(try XCTUnwrap(DiabetesMetrics.glucoseDaily(r)[day]).hypoEvents, 1)
    }

    // MARK: GMI

    func testGmiPercent() throws {
        // mean 154 mg/dL is the classic ~7.0% anchor.
        XCTAssertEqual(try XCTUnwrap(DiabetesMetrics.gmiPercent(meanMgdl: 154)), 6.99, accuracy: 0.02)
        XCTAssertNil(DiabetesMetrics.gmiPercent(meanMgdl: 0))
        XCTAssertNil(DiabetesMetrics.gmiPercent(meanMgdl: -5))
    }

    // MARK: Insulin

    func testInsulinDailySplitAndTotal() throws {
        let doses: [InsulinDose] = [
            .init(day: "2024-05-01", units: 0.5, kind: .basal),
            .init(day: "2024-05-01", units: 0.5, kind: .basal),
            .init(day: "2024-05-01", units: 4.0, kind: .bolus),
            .init(day: "2024-05-01", units: 1.0, kind: .unknown),
            .init(day: "2024-05-02", units: 3.0, kind: .bolus),
        ]
        let stats = DiabetesMetrics.insulinDaily(doses)
        let d1 = try XCTUnwrap(stats["2024-05-01"])
        XCTAssertEqual(d1.basal, 1.0, accuracy: 1e-9)
        XCTAssertEqual(d1.bolus, 4.0, accuracy: 1e-9)
        XCTAssertEqual(d1.unknown, 1.0, accuracy: 1e-9)
        XCTAssertEqual(d1.total, 6.0, accuracy: 1e-9)   // basal + bolus + unknown
        let d2 = try XCTUnwrap(stats["2024-05-02"])
        XCTAssertEqual(d2.total, 3.0, accuracy: 1e-9)
    }

    // MARK: Post-workout glucose

    func testPostWorkoutGlucoseMinAndLows() throws {
        let day = "2024-05-01"
        // Workout [1000, 2000]; window extends +120min (7200s) -> [1000, 9200].
        let workouts = [WorkoutWindow(start: 1000, end: 2000, day: day)]
        let readings: [GlucoseReading] = [
            .init(ts: 500,  day: day, minutesLocal: 10, mgdl: 120),  // before window -> ignored
            .init(ts: 1500, day: day, minutesLocal: 20, mgdl: 90),   // in window
            .init(ts: 5000, day: day, minutesLocal: 90, mgdl: 65),   // in window, <70 -> low, min
            .init(ts: 9300, day: day, minutesLocal: 99, mgdl: 60),   // after window -> ignored
        ]
        let d = try XCTUnwrap(DiabetesMetrics.postWorkoutGlucose(readings: readings, workouts: workouts)[day])
        XCTAssertEqual(try XCTUnwrap(d.minMgdl), 65, accuracy: 1e-9)
        XCTAssertEqual(d.lows, 1)
    }

    func testPostWorkoutGlucoseEmptyWithoutWorkouts() {
        let readings = [GlucoseReading(ts: 1, day: "d", minutesLocal: 1, mgdl: 100)]
        XCTAssertTrue(DiabetesMetrics.postWorkoutGlucose(readings: readings, workouts: []).isEmpty)
    }
}
