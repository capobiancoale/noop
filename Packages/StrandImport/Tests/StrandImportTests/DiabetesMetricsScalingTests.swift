import XCTest
@testable import StrandImport

/// The glucose reducers run over a year of CGM data in one go (the Apple Health history import), so their
/// per-event and per-workout lookups use binary search. These tests pin them to the straightforward linear
/// scans they replaced, on shuffled pseudo-random traces, so the speed-up cannot change a result.
final class DiabetesMetricsScalingTests: XCTestCase {

    /// Deterministic linear congruential generator: the same trace on every run and platform.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// A 5-minute CGM trace over `days` days with dips below 70 (and some below 54) that straddle
    /// midnight now and then, plus the occasional sensor gap.
    private func trace(days: Int, seed: UInt64) -> [GlucoseReading] {
        var rng = LCG(state: seed)
        var out: [GlucoseReading] = []
        let start = 1_760_000_000.0 - 1_760_000_000.0.truncatingRemainder(dividingBy: 86_400)
        var mg = 140.0
        var t = start
        while t < start + Double(days) * 86_400 {
            if rng.next() < 0.004 { t += (rng.next() * 3 + 1) * 3_600; continue }     // sensor gap 1–4 h
            if rng.next() < 0.01 { mg = 45 + rng.next() * 20 }                        // a dip
            mg += (rng.next() - 0.45) * 12
            mg = min(max(mg, 40), 380)
            let secOfDay = Int(t.truncatingRemainder(dividingBy: 86_400))
            let day = Int((t - start) / 86_400)
            out.append(GlucoseReading(ts: t, day: String(format: "d%03d", day),
                                      minutesLocal: secOfDay / 60, mgdl: mg))
            t += 300
        }
        return out
    }

    private func shuffled(_ v: [GlucoseReading], seed: UInt64) -> [GlucoseReading] {
        var rng = LCG(state: seed)
        var a = v
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() * Double(i + 1))
            a.swapAt(i, j)
        }
        return a
    }

    func testFirstIndexAtOrAfter() {
        let r = [10.0, 20, 20, 30].map { GlucoseReading(ts: $0, day: "d", minutesLocal: 0, mgdl: 100) }
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: [], atOrAfter: 5), 0)
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: r, atOrAfter: 5), 0)
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: r, atOrAfter: 10), 0)
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: r, atOrAfter: 15), 1)
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: r, atOrAfter: 20), 1)   // first of the duplicates
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: r, atOrAfter: 30), 3)
        XCTAssertEqual(DiabetesMetrics.firstIndex(in: r, atOrAfter: 31), 4)   // none: count
    }

    func testPostWorkoutGlucoseMatchesTheLinearScanOnShuffledInput() {
        let readings = trace(days: 40, seed: 7)
        var rng = LCG(state: 99)
        let t0 = readings.first!.ts
        var workouts: [WorkoutWindow] = []
        for k in 0..<60 {
            let s = t0 + rng.next() * 42 * 86_400                  // a few land after the trace ends
            let e = s + (20 + rng.next() * 70) * 60
            workouts.append(WorkoutWindow(start: s, end: e, day: "w\(k % 25)"))  // shared days merge
        }
        // The previous implementation, verbatim: every reading checked against every workout.
        func reference() -> [String: PostWorkoutGlucose] {
            let pad = 120 * 60.0
            var byDay: [String: (min: Double?, lows: Int)] = [:]
            for w in workouts {
                for r in readings where r.ts >= w.start && r.ts <= w.end + pad {
                    var a = byDay[w.day] ?? (nil, 0)
                    a.min = a.min.map { Swift.min($0, r.mgdl) } ?? r.mgdl
                    if r.mgdl < GlucoseThresholds.standard.low { a.lows += 1 }
                    byDay[w.day] = a
                }
            }
            return byDay.reduce(into: [:]) { $0[$1.key] = PostWorkoutGlucose(day: $1.key, minMgdl: $1.value.min, lows: $1.value.lows) }
        }
        let expected = reference()
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(DiabetesMetrics.postWorkoutGlucose(readings: readings, workouts: workouts), expected)
        XCTAssertEqual(DiabetesMetrics.postWorkoutGlucose(readings: shuffled(readings, seed: 3), workouts: workouts),
                       expected)
    }

    func testHypoEventDayAttributionMatchesTheLinearScan() {
        let readings = trace(days: 30, seed: 11)
        let sorted = readings.sorted { $0.ts < $1.ts }
        var expected: [String: Int] = [:]
        for e in DiabetesMetrics.hypoEvents(sorted, low: 70, severeLow: 54, tzOffsetSeconds: nil) {
            if let r = sorted.first(where: { $0.ts >= e.start }) ?? sorted.last { expected[r.day, default: 0] += 1 }
        }
        XCTAssertGreaterThan(expected.values.reduce(0, +), 5, "the trace should contain several events")
        let daily = DiabetesMetrics.glucoseDaily(readings)
        for (day, stats) in daily {
            XCTAssertEqual(stats.hypoEvents, expected[day] ?? 0, day)
        }
        // Every event lands on a day that has readings, so none is lost.
        XCTAssertEqual(daily.values.reduce(0) { $0 + $1.hypoEvents }, expected.values.reduce(0, +))
    }
}
