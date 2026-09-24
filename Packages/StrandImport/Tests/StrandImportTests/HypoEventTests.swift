import XCTest
@testable import StrandImport

/// Consensus CGM hypoglycaemia events (Battelino et al., Lancet Diabetes Endocrinol 2023): ≥ 15 consecutive
/// minutes below 70 mg/dL, ended by ≥ 15 consecutive minutes at or above 70; Level 2 below 54; extended
/// beyond 120 minutes; nocturnal 00:00–05:59.
final class HypoEventTests: XCTestCase {

    private let t0 = 1_714_521_600.0   // 2024-05-01 00:00 UTC

    /// A trace sampled every `every` minutes from `startMin` (minutes after t0).
    private func trace(_ v: [Double], every: Double = 5, startMin: Double = 0) -> [GlucoseReading] {
        v.enumerated().map { i, x in
            let ts = t0 + (startMin + Double(i) * every) * 60
            return GlucoseReading(ts: ts, day: "2024-05-01", minutesLocal: Int(startMin) + i * Int(every), mgdl: x)
        }
    }

    private func events(_ r: [GlucoseReading], tz: Int? = 0) -> [HypoEvent] {
        DiabetesMetrics.hypoEvents(r, tzOffsetSeconds: tz)
    }

    func testTenMinutesLowIsNotAnEvent() {
        XCTAssertTrue(events(trace([100, 90, 68, 66, 100, 110, 120])).isEmpty)
    }

    func testFifteenMinutesLowIsALevel1Event() {
        let e = events(trace([100, 68, 65, 63, 80, 90, 100, 110]))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].level, 1)
        XCTAssertEqual(e[0].start, t0 + 5 * 60)
        XCTAssertEqual(e[0].end, t0 + 20 * 60, "ends where the 15-minute recovery starts")
        XCTAssertEqual(e[0].durationMin, 15)
        XCTAssertEqual(e[0].nadir, 63)
        XCTAssertFalse(e[0].extended)
        XCTAssertFalse(e[0].censored)
    }

    func testShortRecoveryDoesNotEndTheEvent() {
        // 15 min low, 10 min back in range, 15 min low again, then a real recovery: ONE event.
        let e = events(trace([68, 65, 63, 75, 80, 66, 64, 62, 90, 95, 100, 105]))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].durationMin, 40)
        XCTAssertEqual(e[0].nadir, 62)
    }

    func testTwoEventsWhenTheRecoveryLastsFifteenMinutes() {
        let e = events(trace([68, 65, 63, 75, 80, 85, 66, 64, 62, 90, 95, 100]))
        XCTAssertEqual(e.count, 2)
    }

    func testLevel2NeedsFifteenMinutesBelow54() {
        let l2 = events(trace([80, 60, 52, 50, 49, 58, 65, 80, 85, 90]))
        XCTAssertEqual(l2.count, 1)
        XCTAssertEqual(l2[0].level, 2)
        XCTAssertEqual(l2[0].nadir, 49)
        let brief = events(trace([80, 60, 52, 50, 58, 60, 80, 85, 90]))
        XCTAssertEqual(brief[0].level, 1, "10 minutes below 54 is not Level 2")
    }

    func testExtendedNeedsMoreThan120ConsecutiveMinutes() {
        // 24 low samples × 5 min = 120 min: not extended. 25 → 125 min: extended.
        XCTAssertFalse(events(trace([90] + Array(repeating: 65, count: 24) + [90, 95, 100]))[0].extended)
        XCTAssertTrue(events(trace([90] + Array(repeating: 65, count: 25) + [90, 95, 100]))[0].extended)
    }

    func testInterpolatesAcrossShortGaps() {
        // A 20-minute gap inside the low stretch is bridged (≤ 45 min): one 25-minute event.
        let r = trace([100, 65], startMin: 0) + trace([63, 100, 105, 110], startMin: 25)
        let e = events(r)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].durationMin, 25)
    }

    func testLongGapCensorsTheEvent() {
        // Low for 20 min, then the sensor drops out for an hour: the event closes at its last known low.
        let r = trace([100, 66, 64, 62, 61], startMin: 0) + trace([120, 125, 130], startMin: 80)
        let e = events(r)
        XCTAssertEqual(e.count, 1)
        XCTAssertTrue(e[0].censored)
        XCTAssertEqual(e[0].end, t0 + 25 * 60)
    }

    func testEventsAfterAGapAreStillFound() {
        // A low cut short by a 2-hour sensor gap, then a separate low later the same day: both are events.
        let first = trace([100, 66, 64, 62])                                   // 00:00–00:15, then data stops
        let second = trace([100, 95, 67, 65, 63, 90, 95, 100, 105], startMin: 135)   // resumes at 02:15
        let e = events(first + second)
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e[0].censored)
        XCTAssertFalse(e[1].censored)
        XCTAssertEqual(e[1].start, t0 + (135 + 10) * 60)
        XCTAssertEqual(e[1].nadir, 63)
    }

    func testFifteenMinuteSensorsNeedTwoLowReadings() {
        // A lone low reading between normal ones (15-min sampling) never spans 15 minutes below 70.
        XCTAssertTrue(events(trace([100, 65, 100, 110], every: 15)).isEmpty)
        XCTAssertEqual(events(trace([100, 65, 64, 100, 110, 115], every: 15)).count, 1)
    }

    func testNocturnalWindowIsLocalMidnightToSix() {
        // 02:30 local (UTC+2 → 00:30 UTC) is nocturnal; 06:30 local is not.
        let night = trace([100, 66, 64, 62, 90, 95, 100], startMin: 30)
        XCTAssertTrue(events(night, tz: 7200)[0].nocturnal)
        let morning = trace([100, 66, 64, 62, 90, 95, 100], startMin: 270)
        XCTAssertFalse(events(morning, tz: 7200)[0].nocturnal)
        XCTAssertFalse(events(night, tz: nil)[0].nocturnal)
    }

    func testOvernightEventsIncludeTheSleepWindow() {
        // 23:30 local is outside 00:00–05:59 but inside the sleep window: counted as overnight.
        let late = trace([100, 66, 64, 62, 90, 95, 100], startMin: 23 * 60 + 30)
        let e = events(late, tz: 0)
        XCTAssertFalse(e[0].nocturnal)
        let sleepStart = t0 + 23 * 3600, sleepEnd = t0 + 31 * 3600
        XCTAssertEqual(DiabetesMetrics.overnightEvents(e, sleepStart: sleepStart, sleepEnd: sleepEnd).count, 1)
        XCTAssertTrue(DiabetesMetrics.overnightEvents(e, sleepStart: nil, sleepEnd: nil).isEmpty)
    }
}
