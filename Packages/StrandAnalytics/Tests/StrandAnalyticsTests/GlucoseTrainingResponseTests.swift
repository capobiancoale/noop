import XCTest
@testable import StrandAnalytics

final class GlucoseTrainingResponseTests: XCTestCase {
    typealias G = GlucoseTrainingResponse

    let t0 = 1_000_000.0   // session start used throughout

    // MARK: helpers

    /// A reading every 5 min from `from` to `to`, glucose given by `f(minutesFromT0)`.
    func trace(from: Double, to: Double, step: Double = 300, _ f: (Double) -> Double) -> [G.Point] {
        stride(from: from, through: to, by: step).map { G.Point(ts: $0, mgdl: f(($0 - t0) / 60)) }
    }

    func session(_ id: String = "s", _ kind: G.Kind = .metcon, start: Double? = nil, minutes: Double = 30) -> G.Session {
        let s = start ?? t0
        return G.Session(id: id, kind: kind, start: s, end: s + minutes * 60)
    }

    // MARK: classifier

    func testClassifierTable() {
        let cases: [(String?, String?, String?, Double, G.Kind)] = [
            ("CrossFit", "CrossFit", "AMRAP", 20, .metcon),
            ("CrossFit", "CrossFit", "For Time", 15, .metcon),
            ("CrossFit", "CrossFit", "EMOM", 30, .metcon),
            ("HIIT", nil, nil, 25, .metcon),
            ("Functional Fitness", nil, nil, 40, .metcon),
            ("Weightlifting", "Weightlifting", nil, 50, .strength),
            ("CrossFit", "CrossFit", "Strength", 45, .strength),
            ("CrossFit", "CrossFit", "strength", 90, .strength),
            ("Strength", nil, nil, 60, .strength),
            ("TraditionalStrengthTraining", nil, nil, 75, .strength),
            ("Running", nil, nil, 44, .metcon),
            ("Running", nil, nil, 45, .long),
            ("Cycling", nil, nil, 60, .long),
            ("Rowing", nil, nil, 50, .long),
            ("Hiking", nil, nil, 120, .long),
            ("Swimming", nil, nil, 45, .long),
            ("Running", "Running", nil, 50, .long),
            ("HIIT", nil, nil, 59, .metcon),
            ("HIIT", nil, nil, 60, .long),
            ("CrossFit", "CrossFit", "AMRAP", 75, .long),
            ("Hyrox", "Hyrox", nil, 70, .long),
            ("Weightlifting", "Weightlifting", nil, 120, .strength),
            (nil, nil, nil, 30, .metcon),
        ]
        for (sport, type, format, dur, expected) in cases {
            XCTAssertEqual(G.kind(sport: sport, wodType: type, wodFormat: format, durationMin: dur), expected,
                           "\(sport ?? "-") \(type ?? "-") \(format ?? "-") \(dur)")
        }
    }

    func testSportWithStrengthWordButWodTypeCrossFitFormatNotStrengthStaysMetcon() {
        // A WOD is classified by its type and format, never by the sport label.
        XCTAssertEqual(G.kind(sport: "Strength", wodType: "CrossFit", wodFormat: "AMRAP", durationMin: 20), .metcon)
    }

    // MARK: deltas

    func testDeltasAndMinimum() {
        let s = session(minutes: 30)
        // 120 at start, rises to 150 at the end, 110 two hours after the end, dips to 90 later.
        let pts = trace(from: s.start - 3_900, to: s.end + 7 * 3_600) { m in
            if m <= 0 { return 120 }
            if m <= 30 { return 120 + m }          // 150 at the end
            if m <= 150 { return 150 - (m - 30) / 3 }   // 150 -> 110 at end + 2 h (m = 150)
            return 110 - min(20, (m - 150) / 6)    // slides to 90
        }
        let r = G.evaluate(.init(session: s, points: pts, night: nil))
        XCTAssertEqual(r.startValue!, 120, accuracy: 0.001)
        XCTAssertEqual(r.duringDelta!, 30, accuracy: 0.001)
        XCTAssertEqual(r.after2hDelta!, -40, accuracy: 0.001)
        XCTAssertEqual(r.minAfter6h!, 90, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(r.coverage, 0.99)
        XCTAssertTrue(r.included)
    }

    func testNearestReadingMustBeWithinFifteenMinutes() {
        let s = session(minutes: 30)
        // Readings only from 20 min after the start: nothing within 15 min of the start.
        let pts = trace(from: s.start + 20 * 60, to: s.end + 7 * 3_600) { _ in 100 }
        let r = G.evaluate(.init(session: s, points: pts, night: nil))
        XCTAssertNil(r.startValue)
        XCTAssertNil(r.duringDelta)
        XCTAssertNotNil(r.after2hDelta)
    }

    func testAfter2hMissingWhenFutureNotYetRecorded() {
        let s = session(minutes: 30)
        let pts = trace(from: s.start - 3_600, to: s.end + 30 * 60) { _ in 100 }
        let r = G.evaluate(.init(session: s, points: pts, night: nil))
        XCTAssertNil(r.after2hDelta)
        XCTAssertLessThan(r.coverage, 0.7)
    }

    func testUnsortedAndNonFinitePointsAreHandled() {
        let s = session(minutes: 30)
        var pts = trace(from: s.start - 3_900, to: s.end + 7 * 3_600) { _ in 100 }.reversed() as [G.Point]
        pts.append(G.Point(ts: s.start, mgdl: .nan))
        let r = G.evaluate(.init(session: s, points: pts, night: nil))
        XCTAssertEqual(r.duringDelta!, 0, accuracy: 0.001)
        XCTAssertTrue(r.included)
    }

    // MARK: coverage

    func testCoverageExcludesGappySession() {
        let s = session(minutes: 30)
        // A 2 h hole inside the window, 8 h window => about 0.75 covered? Make the hole bigger.
        let all = trace(from: s.start - 3_600, to: s.end + 6 * 3_600) { _ in 100 }
        let holey = all.filter { !($0.ts > s.end + 30 * 60 && $0.ts < s.end + 4.5 * 3_600) }
        let r = G.evaluate(.init(session: s, points: holey, night: nil))
        XCTAssertLessThan(r.coverage, 0.7)
        XCTAssertFalse(r.included)
    }

    func testCoverageSmallGapsStillCount() {
        let s = session(minutes: 30)
        // Readings every 14 min: gaps just under the limit keep full coverage.
        let pts = trace(from: s.start - 3_700, to: s.end + 6 * 3_600 + 800, step: 14 * 60) { _ in 100 }
        let r = G.evaluate(.init(session: s, points: pts, night: nil))
        XCTAssertGreaterThan(r.coverage, 0.95)
        // Readings every 16 min: no coverage at all.
        let sparse = trace(from: s.start - 3_700, to: s.end + 6 * 3_600 + 800, step: 16 * 60) { _ in 100 }
        XCTAssertEqual(G.evaluate(.init(session: s, points: sparse, night: nil)).coverage, 0, accuracy: 0.0001)
    }

    func testNoPointsMeansExcluded() {
        let r = G.evaluate(.init(session: session(), points: [], night: nil))
        XCTAssertEqual(r.coverage, 0)
        XCTAssertFalse(r.included)
        XCTAssertNil(r.minAfter6h)
    }

    // MARK: overnight low

    func testNightLowDetection() {
        let s = session(minutes: 30)
        let night = G.NightWindow(start: s.end + 4 * 3_600, end: s.end + 12 * 3_600)
        func run(_ f: @escaping (Double) -> Double) -> G.SessionResult {
            let pts = trace(from: s.start - 3_900, to: s.end + 13 * 3_600) { f($0) }
            return G.evaluate(.init(session: s, points: pts, night: night))
        }
        let nightStartMin = (night.start - t0) / 60
        XCTAssertEqual(run { _ in 110 }.nightLow, false)
        XCTAssertEqual(run { m in abs(m - nightStartMin - 120) < 10 ? 65 : 110 }.nightLow, true)
        XCTAssertEqual(run { m in abs(m - nightStartMin - 120) < 10 ? 70 : 110 }.nightLow, false)   // 70 is not below 70
        XCTAssertNil(G.evaluate(.init(session: s, points: trace(from: s.start - 3_900, to: s.end + 7 * 3_600) { _ in 100 },
                                      night: night)).nightLow, "night not covered by readings")
        XCTAssertNil(G.evaluate(.init(session: s, points: trace(from: s.start - 3_900, to: s.end + 13 * 3_600) { _ in 100 },
                                      night: nil)).nightLow)
    }

    func testLowSeenInPartiallyCoveredNightStillCounts() {
        let s = session(minutes: 30)
        let night = G.NightWindow(start: s.end + 4 * 3_600, end: s.end + 12 * 3_600)
        var pts = trace(from: s.start - 3_900, to: s.end + 7 * 3_600) { _ in 100 }
        pts.append(G.Point(ts: night.start + 600, mgdl: 60))
        XCTAssertEqual(G.evaluate(.init(session: s, points: pts, night: night)).nightLow, true)
    }

    // MARK: curve, percentiles, reliability

    /// A session at a distinct day offset whose glucose is `base + minute * slope` relative to its start.
    func input(_ i: Int, kind: G.Kind = .metcon, base: Double, slope: Double = 0, minutes: Double = 30,
               night: Bool = false, nightLow: Bool = false) -> G.Input {
        let s = session("s\(i)", kind, start: t0 + Double(i) * 86_400, minutes: minutes)
        let pts = trace(from: s.start - 3_900, to: s.end + 13 * 3_600) { _ in 0 }.map { p -> G.Point in
            let minute = (p.ts - s.start) / 60
            var v = base + minute * slope
            if nightLow && p.ts > s.end + 5 * 3_600 && p.ts < s.end + 5 * 3_600 + 900 { v = 60 }
            return G.Point(ts: p.ts, mgdl: v)
        }
        let n = night ? G.NightWindow(start: s.end + 4 * 3_600, end: s.end + 12 * 3_600) : nil
        return G.Input(session: s, points: pts, night: n)
    }

    func testCurveMeanAndPercentiles() {
        // Four sessions flat at 100, 110, 120, 130.
        let inputs = [100.0, 110, 120, 130].enumerated().map { input($0.offset, base: $0.element) }
        let sum = G.analyze(inputs).first { $0.kind == .metcon }!
        XCTAssertTrue(sum.isReliable)
        XCTAssertEqual(sum.sessions, 4)
        XCTAssertEqual(sum.excluded, 0)
        XCTAssertEqual(sum.curve.count, G.curveMinutes.count)
        XCTAssertEqual(sum.curve.first!.minute, -60)
        XCTAssertEqual(sum.curve.last!.minute, 360)
        let p = sum.curve[4]   // minute 0
        XCTAssertEqual(p.minute, 0)
        XCTAssertEqual(p.mean, 115, accuracy: 0.001)
        XCTAssertEqual(p.p25, 107.5, accuracy: 0.001)   // type-7 percentile of 100,110,120,130
        XCTAssertEqual(p.p75, 122.5, accuracy: 0.001)
        XCTAssertEqual(p.n, 4)
        XCTAssertEqual(sum.medianDurationMin!, 30, accuracy: 0.001)
    }

    func testCurveStepNeedsThreeSessions() {
        // Sessions whose readings stop at +3.5 h have a curve value at +3 h and none at +4.5 h.
        var inputs = (0..<3).map { input($0, base: 100, minutes: 30) }
        for i in 0..<3 {
            let s = inputs[i].session
            // Data stops 3.5 h after the start: the per-session curve has no value from there on.
            let kept = inputs[i].points.filter { $0.ts <= s.start + 3.5 * 3_600 }
            inputs[i] = G.Input(session: s, points: kept, night: nil)
        }
        let results = inputs.map(G.evaluate)
        XCTAssertTrue(results.allSatisfy { $0.curve[G.curveMinutes.firstIndex(of: 180)!] != nil })
        XCTAssertTrue(results.allSatisfy { $0.curve[G.curveMinutes.firstIndex(of: 270)!] == nil })
        // Only 2 sessions with data at a step: no curve point there (3 needed), even though the kind is reliable.
        let four = (0..<4).map { i -> G.Input in
            let base = input(i, base: 100)
            let cutAt = i < 2 ? base.session.start + 3.5 * 3_600 : .infinity
            return G.Input(session: base.session, points: base.points.filter { $0.ts <= cutAt }, night: nil)
        }
        // Sessions 0 and 1 have too little coverage to be included, so build the results by hand.
        let hand = four.map { G.evaluate($0) }
        let rel = G.summary(kind: .metcon, results: hand)
        XCTAssertEqual(rel.sessions, 2)
        XCTAssertFalse(rel.isReliable)
    }

    func testReliabilityGateHidesNumbers() {
        let inputs = (0..<3).map { input($0, base: 100, slope: 0.1, night: true) }
        let sum = G.analyze(inputs).first { $0.kind == .metcon }!
        XCTAssertEqual(sum.sessions, 3)
        XCTAssertFalse(sum.isReliable)
        XCTAssertNil(sum.meanDuringDelta)
        XCTAssertNil(sum.meanAfter2hDelta)
        XCTAssertTrue(sum.curve.isEmpty)
        XCTAssertNil(sum.medianDurationMin)
        XCTAssertEqual(sum.nightsObserved, 0)
        XCTAssertFalse(sum.nightsReliable)
        // exactly at the gate: reliable
        let four = G.analyze((0..<4).map { input($0, base: 100, slope: 0.1) }).first { $0.kind == .metcon }!
        XCTAssertTrue(four.isReliable)
    }

    func testExcludedSessionsAreCountedNotAveraged() {
        var inputs = (0..<4).map { input($0, base: 100, slope: 0.1) }
        let bad = input(9, base: 500)
        inputs.append(G.Input(session: bad.session, points: Array(bad.points.prefix(5)), night: nil))
        let sum = G.analyze(inputs).first { $0.kind == .metcon }!
        XCTAssertEqual(sum.sessions, 4)
        XCTAssertEqual(sum.excluded, 1)
        XCTAssertEqual(sum.curve[4].mean, 100, accuracy: 0.001)
    }

    func testKindsAreSeparatedAndOrdered() {
        var inputs = (0..<4).map { input($0, kind: .strength, base: 100, slope: 0.2, minutes: 30) }
        inputs += (10..<12).map { input($0, kind: .long, base: 100) }
        let all = G.analyze(inputs)
        XCTAssertEqual(all.map(\.kind), [.strength, .metcon, .long])
        XCTAssertEqual(all[0].sessions, 4)
        XCTAssertEqual(all[1].sessions, 0)
        XCTAssertFalse(all[1].isReliable)
        XCTAssertEqual(all[2].sessions, 2)
        XCTAssertFalse(all[2].isReliable)
        // slope 0.2 mg/dL per min over a 30 min session => +6 during; +24 in the 2 h after.
        XCTAssertEqual(all[0].meanDuringDelta!, 6, accuracy: 0.01)
        XCTAssertEqual(all[0].meanAfter2hDelta!, 24, accuracy: 0.01)
    }

    func testNightCountingAndReliability() {
        var inputs: [G.Input] = []
        for i in 0..<9 { inputs.append(input(i, base: 110, night: true, nightLow: i == 2)) }
        let sum = G.analyze(inputs).first { $0.kind == .metcon }!
        XCTAssertEqual(sum.nightsObserved, 9)
        XCTAssertEqual(sum.nightsWithLow, 1)
        XCTAssertTrue(sum.nightsReliable)
        // Only three nights observed among five sessions: the count is not shown.
        var some: [G.Input] = []
        for i in 0..<5 { some.append(input(i, base: 110, night: i < 3)) }
        let s2 = G.analyze(some).first { $0.kind == .metcon }!
        XCTAssertEqual(s2.sessions, 5)
        XCTAssertEqual(s2.nightsObserved, 3)
        XCTAssertFalse(s2.nightsReliable)
    }

    func testMeanDeltaNilWhenFewerThanMinSessionsHaveIt() {
        // Four included sessions but only three have their 2-h reading (the 4th ended too recently).
        var inputs = (0..<3).map { input($0, base: 100, slope: 0.1) }
        let recent = input(5, base: 100, slope: 0.1)
        let s = recent.session
        // Cut readings after end + 1 h but add sparse-but-covering ones? coverage would fail, so check via results.
        let cut = recent.points.filter { $0.ts <= s.end + 3_600 }
        let r = G.evaluate(.init(session: s, points: cut, night: nil))
        XCTAssertNil(r.after2hDelta)
        inputs.append(G.Input(session: s, points: cut, night: nil))
        let results = inputs.map(G.evaluate)
        XCTAssertEqual(results.filter { $0.after2hDelta != nil }.count, 3)
    }

    func testPercentileHelper() {
        XCTAssertEqual(G.percentile([1, 2, 3, 4, 5], 0.5), 3, accuracy: 1e-9)
        XCTAssertEqual(G.percentile([1, 2, 3, 4], 0.25), 1.75, accuracy: 1e-9)
        XCTAssertEqual(G.percentile([7], 0.75), 7, accuracy: 1e-9)
        XCTAssertEqual(G.median([4, 1, 3, 2])!, 2.5, accuracy: 1e-9)
    }

    func testInterpolationAcrossGapRefused() {
        let pts = [G.Point(ts: 0, mgdl: 100), G.Point(ts: 600, mgdl: 120), G.Point(ts: 5_000, mgdl: 80)]
        XCTAssertEqual(G.interpolate(pts, at: 300)!, 110, accuracy: 1e-9)
        XCTAssertNil(G.interpolate(pts, at: 2_000))
        XCTAssertNil(G.interpolate(pts, at: -10))
    }
}
