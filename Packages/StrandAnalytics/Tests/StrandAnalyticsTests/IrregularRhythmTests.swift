import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// `IrregularRhythm`: the quality gates, the three Dash et al. (2009) features plus the repeating-pattern check
/// and the AND of their thresholds, the 30-minute episode rule and the nightly numbers. The series are synthetic
/// and seeded; the thresholds themselves were measured on PhysioNet ECG databases (see the engine's header).
final class IrregularRhythmTests: XCTestCase {

    private let start = 1_800_000_000

    // MARK: - Builders

    /// A continuous clock that emits strap-style rows: the timestamp is the whole second of the beat that ends
    /// the interval. A beat can be advanced over without being listed (a dropped beat), and a hole can be skipped.
    private struct Strap {
        let start: Int
        var elapsedMs = 0
        var rows: [RRInterval] = []

        init(start: Int) { self.start = start }

        mutating func add(_ rrMs: Int, listed: Bool = true) {
            elapsedMs += rrMs
            if listed { rows.append(RRInterval(ts: start + elapsedMs / 1000, rrMs: rrMs)) }
        }

        mutating func addBlock(_ block: [Int]) { for v in block { add(v) } }

        mutating func skip(seconds: Int) { elapsedMs += seconds * 1000 }
    }

    /// 128 beats of a resting rhythm with respiratory sinus arrhythmia whose intervals add up to EXACTLY
    /// 120 000 ms, so blocks tile into whole 2-minute segments.
    private func regularBlock(seed: UInt64, rsaMs: Double = 40) -> [Int] {
        let raw = RRFixtures.resting(count: 128, meanMs: 937.5, rsaMs: rsaMs, jitterMs: 8, seed: seed)
        return exactly120s(raw.map { Int($0) })
    }

    /// 128 intervals drawn without replacement from a wide spread (918...666 below, 957...1209 above 937.5), in
    /// a seeded random order: an irregularly irregular series that also adds up to exactly 120 000 ms.
    private func irregularBlock(seed: UInt64) -> [Int] {
        var values: [Int] = []
        for i in 0..<64 {
            let d = 20 + 4 * i
            values.append(938 - d)
            values.append(937 + d)
        }
        var rng = RRFixtures.SplitMix64(state: seed)
        var i = values.count - 1
        while i > 0 {
            let j = Int(rng.next() % UInt64(i + 1))
            values.swapAt(i, j)
            i -= 1
        }
        return values
    }

    /// Spread the rounding error over the block so its intervals add up to 120 000 ms.
    private func exactly120s(_ v: [Int]) -> [Int] {
        var out = v
        let diff = 120_000 - out.reduce(0, +)
        let each = diff / out.count
        for k in out.indices { out[k] += each }
        var rest = diff - each * out.count
        var k = 0
        while rest != 0 {
            out[k] += rest > 0 ? 1 : -1
            rest += rest > 0 ? -1 : 1
            k += 1
        }
        return out
    }

    /// `n` regular 2-minute blocks.
    private func regularBlocks(_ n: Int, seed: UInt64 = 100) -> [[Int]] {
        (0..<n).map { regularBlock(seed: seed + UInt64($0)) }
    }

    /// `n` irregular 2-minute blocks.
    private func irregularBlocks(_ n: Int, seed: UInt64 = 500) -> [[Int]] {
        (0..<n).map { irregularBlock(seed: seed + UInt64($0)) }
    }

    /// A night of `parts` back to back, as rows plus the window that covers them.
    private func night(_ parts: [[[Int]]]) -> (rows: [RRInterval], window: IrregularRhythm.Window) {
        var strap = Strap(start: start)
        for part in parts { for block in part { strap.addBlock(block) } }
        return (strap.rows, IrregularRhythm.Window(start: start - 10, end: start + strap.elapsedMs / 1000 + 10))
    }

    // MARK: - Features

    func testSinusRhythmWithRespiratoryArrhythmiaIsRegular() throws {
        let rr = RRFixtures.resting(count: 128 * 40, meanMs: 900, rsaMs: 35, jitterMs: 10, seed: 3)
        let rows = RRFixtures.timed(rr, start: start)
        let segs = IrregularRhythm.segments(rr: rows)
        XCTAssertEqual(segs.count, 40)
        XCTAssertTrue(segs.allSatisfy { !$0.isIrregular })
        // Smooth breathing waves give fewer turning points than chance: a strongly negative z.
        let f = try XCTUnwrap(segs.first?.features)
        XCTAssertLessThan(f.turningPointZ, -4)
        XCTAssertLessThan(f.normalizedRMSSD, IrregularRhythm.minNormalizedRMSSD)
    }

    func testStrongRespiratoryArrhythmiaIsStillRegular() {
        // A young, fit sleeper: a 0.2 Hz wave of +-70 ms on a 1 s beat. High RMSSD, but a smooth wave.
        let rr = RRFixtures.resting(count: 128 * 30, meanMs: 1000, rsaMs: 70, jitterMs: 8, seed: 11)
        let segs = IrregularRhythm.segments(rr: RRFixtures.timed(rr, start: start))
        XCTAssertEqual(segs.count, 30)
        XCTAssertTrue(segs.allSatisfy { !$0.isIrregular })
    }

    func testIndependentRandomIntervalsAreIrregular() {
        var rng = RRFixtures.SplitMix64(state: 42)
        let rr = (0..<(128 * 30)).map { _ in 600.0 + 600.0 * rng.uniform() }
        let segs = IrregularRhythm.segments(rr: RRFixtures.timed(rr, start: start))
        XCTAssertEqual(segs.count, 30)
        // i.i.d. intervals are what AF looks like to this screen: nearly every segment is called irregular.
        XCTAssertGreaterThanOrEqual(segs.filter(\.isIrregular).count, 28)
        if let f = segs.first?.features {
            XCTAssertGreaterThan(f.entropy, IrregularRhythm.minEntropy)
            XCTAssertGreaterThan(f.normalizedRMSSD, IrregularRhythm.minNormalizedRMSSD)
            XCTAssertTrue(IrregularRhythm.turningPointZRange.contains(f.turningPointZ))
        }
    }

    func testBigeminyIsNotIrregular() throws {
        // Long-short-long-short: every interval a turning point, only two clusters of values.
        var rng = RRFixtures.SplitMix64(state: 7)
        var strap = Strap(start: start)
        for i in 0..<(128 * 40) {
            let base = i % 2 == 0 ? 1000.0 : 600.0
            strap.add(Int(base + 15 * rng.gaussian()))
        }
        let segs = IrregularRhythm.segments(rr: strap.rows)
        XCTAssertEqual(segs.count, 40)
        XCTAssertTrue(segs.allSatisfy { !$0.isIrregular })
        let f = try XCTUnwrap(segs.first?.features)
        XCTAssertGreaterThan(f.normalizedRMSSD, 0.3)      // lots of beat-to-beat change ...
        XCTAssertLessThan(f.entropy, 0.6)                 // ... but only two interval values
        XCTAssertGreaterThan(f.turningPointZ, IrregularRhythm.turningPointZRange.upperBound)
        let result = IrregularRhythm.screen(rr: strap.rows, windows: [.init(start: start, end: start + strap.elapsedMs / 1000 + 1)])
        XCTAssertEqual(result.verdict, .regular)
    }

    func testTrigeminyIsNotIrregular() throws {
        // Normal beat, premature beat, compensatory pause, repeated.
        var rng = RRFixtures.SplitMix64(state: 9)
        var strap = Strap(start: start)
        let pattern = [800.0, 500.0, 1100.0]
        for i in 0..<(128 * 40) {
            strap.add(Int(pattern[i % 3] + 15 * rng.gaussian()))
        }
        let segs = IrregularRhythm.segments(rr: strap.rows)
        XCTAssertGreaterThanOrEqual(segs.count, 30)
        XCTAssertTrue(segs.allSatisfy { !$0.isIrregular })
        let f = try XCTUnwrap(segs.first?.features)
        XCTAssertGreaterThan(f.normalizedRMSSD, 0.1)      // the RMSSD criterion alone WOULD call it irregular
        XCTAssertLessThan(f.entropy, IrregularRhythm.minEntropy)
    }

    func testStrictAlternationHasTheTurningPointZOfTheNormalApproximation() throws {
        let rr = (0..<128).map { $0 % 2 == 0 ? 1000.0 : 600.0 }
        let f = try XCTUnwrap(IrregularRhythm.features(rr: rr))
        // 126 turning points out of 126; expected 2 x 126 / 3 = 84, SD sqrt((16 x 128 - 29) / 90).
        XCTAssertEqual(f.turningPointRatio, 1.0, accuracy: 1e-12)
        XCTAssertEqual(f.turningPointZ, 42.0 / ((16.0 * 128 - 29) / 90).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(f.entropy, log(2.0) / log(16.0), accuracy: 1e-9)
    }

    func testFeaturesRejectTooShortInput() {
        XCTAssertNil(IrregularRhythm.features(rr: Array(repeating: 900, count: 18)))
        XCTAssertNotNil(IrregularRhythm.features(rr: (0..<19).map { 900 + Double($0 % 7) * 10 }))
    }

    func testAllFourCriteriaAreNeeded() {
        typealias F = IrregularRhythm.Features
        let ok = F(normalizedRMSSD: 0.2, entropy: 0.95, turningPointZ: 0, turningPointRatio: 0.66, autocorrelation: 0.1)
        XCTAssertTrue(IrregularRhythm.isIrregular(ok))
        XCTAssertFalse(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.0999, entropy: 0.95, turningPointZ: 0, turningPointRatio: 0.66, autocorrelation: 0.1)))
        XCTAssertFalse(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.2, entropy: 0.8699, turningPointZ: 0, turningPointRatio: 0.66, autocorrelation: 0.1)))
        XCTAssertFalse(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.2, entropy: 0.95, turningPointZ: -5.01, turningPointRatio: 0.48, autocorrelation: 0.1)))
        XCTAssertFalse(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.2, entropy: 0.95, turningPointZ: 6.01, turningPointRatio: 0.9, autocorrelation: 0.1)))
        XCTAssertFalse(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.2, entropy: 0.95, turningPointZ: 0, turningPointRatio: 0.66, autocorrelation: 0.3501)))
        // Every threshold is inclusive.
        XCTAssertTrue(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.10, entropy: 0.87, turningPointZ: -5.0, turningPointRatio: 0.48, autocorrelation: 0.35)))
        XCTAssertTrue(IrregularRhythm.isIrregular(F(normalizedRMSSD: 0.10, entropy: 0.87, turningPointZ: 6.0, turningPointRatio: 0.89, autocorrelation: 0.0)))
    }

    func testRepeatingRespiratoryOscillationIsNotIrregular() throws {
        // A very fit sleeper: heart rate 50, breathing 15 a minute, +-130 ms of respiratory sinus arrhythmia.
        // About 3.3 beats per breath is where a smooth wave has as many turning points as a random series, and
        // its RMSSD and entropy are high, so the three Dash et al. criteria alone call it irregular. It repeats,
        // which an irregularly irregular rhythm does not: the autocorrelation gate rejects it.
        let rr = RRFixtures.resting(count: 128 * 30, meanMs: 1200, rsaMs: 130, jitterMs: 8, seed: 21)
        let segs = IrregularRhythm.segments(rr: RRFixtures.timed(rr, start: start))
        XCTAssertEqual(segs.count, 30)
        XCTAssertTrue(segs.allSatisfy { !$0.isIrregular })
        let f = try XCTUnwrap(segs.first?.features)
        XCTAssertGreaterThanOrEqual(f.normalizedRMSSD, IrregularRhythm.minNormalizedRMSSD)
        XCTAssertGreaterThanOrEqual(f.entropy, IrregularRhythm.minEntropy)
        XCTAssertTrue(IrregularRhythm.turningPointZRange.contains(f.turningPointZ))
        XCTAssertGreaterThan(f.autocorrelation, IrregularRhythm.maxAutocorrelation)
    }

    func testAutocorrelationPeak() {
        // A period-4 wave over 128 beats: at lag 2 it is exactly opposite itself, so the product sum is -126/128 of
        // the variance (the sign does not matter, the size does).
        let wave = (0..<128).map { 1000 + 100 * sin(2 * Double.pi * Double($0) / 4 + 0.3) }
        XCTAssertEqual(IrregularRhythm.autocorrelationPeak(of: wave), 126.0 / 128.0, accuracy: 0.01)
        XCTAssertEqual(IrregularRhythm.autocorrelationPeak(of: Array(repeating: 900, count: 128)), 0)
        XCTAssertEqual(IrregularRhythm.autocorrelationPeak(of: [900]), 0)
        // Independent draws have no repeating pattern: far below the cap.
        var rng = RRFixtures.SplitMix64(state: 3)
        let noise = (0..<128).map { _ in 600 + 600 * rng.uniform() }
        XCTAssertLessThan(IrregularRhythm.autocorrelationPeak(of: noise), 0.3)
    }

    // MARK: - Quality gates

    func testNoSegmentFromFewerThan128Beats() {
        let rows = RRFixtures.timed(RRFixtures.resting(count: 127, seed: 1), start: start)
        XCTAssertTrue(IrregularRhythm.segments(rr: rows).isEmpty)
    }

    func testSegmentsAreWholeAndNonOverlapping() {
        let rows = RRFixtures.timed(RRFixtures.resting(count: 128 * 3 + 50, seed: 2), start: start)
        let segs = IrregularRhythm.segments(rr: rows)
        XCTAssertEqual(segs.count, 3)
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertLessThanOrEqual(a.endTs, b.startTs + 1.5) }
    }

    func testDroppedBeatsRejectTheSegment() {
        // Every 8th beat is missing from the list but its time passed: the 128 listed intervals cover only
        // 7/8 = 87.5 % of the clock, below the 90 % gate.
        var strap = Strap(start: start)
        let rr = RRFixtures.resting(count: 146, seed: 4).map { Int($0) }
        for (i, v) in rr.enumerated() { strap.add(v, listed: i % 8 != 7) }
        XCTAssertEqual(strap.rows.count, 128)
        XCTAssertTrue(IrregularRhythm.segments(rr: strap.rows).isEmpty)

        // The same recording with every 12th beat missing (91.7 % coverage) passes the gate.
        var lighter = Strap(start: start)
        let rr2 = RRFixtures.resting(count: 140, seed: 4).map { Int($0) }
        for (i, v) in rr2.enumerated() { lighter.add(v, listed: i % 12 != 11) }
        XCTAssertGreaterThanOrEqual(lighter.rows.count, 128)
        XCTAssertEqual(IrregularRhythm.segments(rr: lighter.rows).count, 1)
    }

    func testGapOverFiveSecondsSplitsTheStretch() {
        let rr = RRFixtures.resting(count: 200, seed: 5).map { Int($0) }
        var whole = Strap(start: start)
        for v in rr { whole.add(v) }
        XCTAssertEqual(IrregularRhythm.segments(rr: whole.rows).count, 1)

        // A 6-second hole after beat 100: two stretches of 100 beats, neither long enough for a segment.
        var gap = Strap(start: start)
        for (i, v) in rr.enumerated() {
            if i == 100 { gap.skip(seconds: 6) }
            gap.add(v)
        }
        XCTAssertTrue(IrregularRhythm.segments(rr: gap.rows).isEmpty)

        // A 4-second hole is tolerated by the gap gate (the coverage gate still sees it: 4 s of ~120 s).
        var small = Strap(start: start)
        for (i, v) in rr.enumerated() {
            if i == 100 { small.skip(seconds: 4) }
            small.add(v)
        }
        XCTAssertEqual(IrregularRhythm.segments(rr: small.rows).count, 1)
    }

    func testImplausibleIntervalEndsTheStretch() {
        var rr = RRFixtures.resting(count: 200, seed: 6).map { Int($0) }
        rr[100] = 250
        var strap = Strap(start: start)
        for v in rr { strap.add(v) }
        XCTAssertTrue(IrregularRhythm.segments(rr: strap.rows).isEmpty)
        rr[100] = 2100
        var long = Strap(start: start)
        for v in rr { long.add(v) }
        XCTAssertTrue(IrregularRhythm.segments(rr: long.rows).isEmpty)
    }

    func testOrderOfInputRowsDoesNotMatter() {
        let rows = RRFixtures.timed(RRFixtures.resting(count: 128 * 5, seed: 8), start: start)
        let expected = IrregularRhythm.segments(rr: rows)
        XCTAssertEqual(expected.count, 5)
        // Latest second first, but beats that share a second keep their delivery order.
        let byDescendingSecond = Dictionary(grouping: rows, by: \.ts).sorted { $0.key > $1.key }.flatMap(\.value)
        XCTAssertEqual(IrregularRhythm.segments(rr: byDescendingSecond), expected)
    }

    // MARK: - Episodes

    private func result(for parts: [[[Int]]]) -> IrregularRhythm.NightResult {
        let n = night(parts)
        return IrregularRhythm.screen(rr: n.rows, windows: [n.window])
    }

    func testEpisodeNeedsThirtyMinutes() {
        // 40 regular minutes, N irregular 2-minute blocks, 40 regular minutes.
        let before = regularBlocks(20, seed: 100)
        let after = regularBlocks(20, seed: 200)

        let short = result(for: [before, irregularBlocks(14), after])           // 28 minutes
        XCTAssertEqual(short.episodeCount, 0)
        XCTAssertEqual(short.longestEpisodeMinutes, 0)
        XCTAssertEqual(short.verdict, .someIrregularSegments)

        let exact = result(for: [before, irregularBlocks(15), after])           // 30 minutes
        XCTAssertEqual(exact.episodeCount, 1)
        XCTAssertEqual(exact.longestEpisodeMinutes, 30, accuracy: 0.01)
        XCTAssertEqual(exact.verdict, .irregularEpisode)

        let long = result(for: [before, irregularBlocks(16), after])            // 32 minutes
        XCTAssertEqual(long.episodeCount, 1)
        XCTAssertEqual(long.longestEpisodeMinutes, 32, accuracy: 0.01)
        XCTAssertEqual(long.verdict, .irregularEpisode)
    }

    func testARegularSegmentBreaksAnEpisode() {
        // 16 + 16 irregular minutes with one regular segment between them: two runs of 16 minutes.
        let r = result(for: [regularBlocks(20, seed: 100), irregularBlocks(8, seed: 500),
                             regularBlocks(1, seed: 300), irregularBlocks(8, seed: 600),
                             regularBlocks(20, seed: 200)])
        XCTAssertEqual(r.episodeCount, 0)
        XCTAssertEqual(r.verdict, .someIrregularSegments)
        XCTAssertEqual(r.irregularMinutes, 32, accuracy: 0.01)
    }

    func testRejectedSegmentNeitherBreaksNorExtendsAnEpisode() {
        // 20 irregular blocks, a stretch the quality gates reject (18 of 146 beats missing), 20 more.
        var strap = Strap(start: start)
        for block in regularBlocks(20, seed: 100) { strap.addBlock(block) }
        for block in irregularBlocks(10, seed: 500) { strap.addBlock(block) }
        let degraded = RRFixtures.resting(count: 146, meanMs: 937.5, seed: 9).map { Int($0) }
        for (i, v) in degraded.enumerated() { strap.add(v, listed: i % 8 != 7) }
        for block in irregularBlocks(10, seed: 600) { strap.addBlock(block) }
        for block in regularBlocks(20, seed: 200) { strap.addBlock(block) }
        let window = IrregularRhythm.Window(start: start - 10, end: start + strap.elapsedMs / 1000 + 10)
        let r = IrregularRhythm.screen(rr: strap.rows, windows: [window])

        XCTAssertEqual(r.irregularSegmentCount, 20)
        XCTAssertEqual(r.episodeCount, 1)
        // 40 irregular minutes plus the 2.3 minutes the rejected stretch took, and not a minute more.
        XCTAssertEqual(r.longestEpisodeMinutes, 40 + 146 * 0.9375 / 60, accuracy: 0.2)
        XCTAssertEqual(r.verdict, .irregularEpisode)
    }

    func testAnEpisodeNeedsEightyPercentOfItsSpanAnalysed() {
        // 16 irregular minutes, 20 minutes in which nothing was recorded, 16 irregular minutes: the 52-minute
        // span is only 61 % analysed, and neither half reaches 30 minutes.
        var strap = Strap(start: start)
        for block in regularBlocks(20, seed: 100) { strap.addBlock(block) }
        for block in irregularBlocks(8, seed: 500) { strap.addBlock(block) }
        strap.skip(seconds: 20 * 60)
        for block in irregularBlocks(8, seed: 600) { strap.addBlock(block) }
        for block in regularBlocks(20, seed: 200) { strap.addBlock(block) }
        let window = IrregularRhythm.Window(start: start - 10, end: start + strap.elapsedMs / 1000 + 10)
        let none = IrregularRhythm.screen(rr: strap.rows, windows: [window])
        XCTAssertEqual(none.episodeCount, 0)

        // A qualifying stretch is not lost because a shorter one sits far before it: the run is split at the
        // 20-minute hole and the second half (32 minutes) is an episode on its own.
        var strap2 = Strap(start: start)
        for block in regularBlocks(20, seed: 100) { strap2.addBlock(block) }
        for block in irregularBlocks(8, seed: 500) { strap2.addBlock(block) }
        strap2.skip(seconds: 20 * 60)
        for block in irregularBlocks(16, seed: 600) { strap2.addBlock(block) }
        for block in regularBlocks(20, seed: 200) { strap2.addBlock(block) }
        let window2 = IrregularRhythm.Window(start: start - 10, end: start + strap2.elapsedMs / 1000 + 10)
        let one = IrregularRhythm.screen(rr: strap2.rows, windows: [window2])
        XCTAssertEqual(one.episodeCount, 1)
        XCTAssertEqual(one.longestEpisodeMinutes, 32, accuracy: 0.05)
    }

    func testAnEpisodeNeverBridgesTwoWindows() {
        // 16 irregular minutes at the end of one sleep window and 16 at the start of the next.
        var strap = Strap(start: start)
        for block in regularBlocks(20, seed: 100) { strap.addBlock(block) }
        for block in irregularBlocks(8, seed: 500) { strap.addBlock(block) }
        strap.skip(seconds: 10)
        let firstEnd = start + strap.elapsedMs / 1000 - 7          // two separate windows with 4 s between them
        let secondStart = firstEnd + 4
        for block in irregularBlocks(8, seed: 600) { strap.addBlock(block) }
        for block in regularBlocks(20, seed: 200) { strap.addBlock(block) }
        let end = start + strap.elapsedMs / 1000 + 10
        let split = IrregularRhythm.screen(rr: strap.rows, windows: [.init(start: start - 10, end: firstEnd),
                                                                    .init(start: secondStart, end: end)])
        XCTAssertEqual(split.episodeCount, 0)
        XCTAssertEqual(split.verdict, .someIrregularSegments)

        let joined = IrregularRhythm.screen(rr: strap.rows, windows: [.init(start: start - 10, end: end)])
        XCTAssertEqual(joined.episodeCount, 1)
    }

    // MARK: - Night numbers

    func testBurdenArithmetic() {
        // 20 regular + 4 irregular + 20 regular blocks of 2 minutes: 88 analysed minutes, 8 of them irregular.
        let r = result(for: [regularBlocks(20, seed: 100), irregularBlocks(4), regularBlocks(20, seed: 200)])
        XCTAssertEqual(r.segmentCount, 44)
        XCTAssertEqual(r.irregularSegmentCount, 4)
        XCTAssertEqual(r.analysedMinutes, 88, accuracy: 1e-6)
        XCTAssertEqual(r.irregularMinutes, 8, accuracy: 1e-6)
        XCTAssertEqual(r.burdenPercent, 100.0 * 8.0 / 88.0, accuracy: 1e-6)
        XCTAssertEqual(r.longestEpisodeMinutes, 0)
        XCTAssertEqual(r.verdict, .someIrregularSegments)
        XCTAssertEqual(r.analysedShare, 1.0, accuracy: 0.01)
    }

    func testRegularNightHasZeroBurden() {
        let r = result(for: [regularBlocks(45, seed: 100)])
        XCTAssertEqual(r.verdict, .regular)
        XCTAssertEqual(r.burdenPercent, 0)
        XCTAssertEqual(r.irregularSegmentCount, 0)
        XCTAssertEqual(r.analysedMinutes, 90, accuracy: 1e-6)
    }

    func testUnderAnHourAnalysedIsNotEnoughData() {
        // 29 blocks = 58 minutes: even a fully irregular hour-less night says nothing.
        let regular = result(for: [regularBlocks(29, seed: 100)])
        XCTAssertEqual(regular.verdict, .notEnoughData)
        XCTAssertEqual(regular.analysedMinutes, 58, accuracy: 1e-6)
        let irregular = result(for: [irregularBlocks(29)])
        XCTAssertEqual(irregular.verdict, .notEnoughData)
        XCTAssertEqual(irregular.burdenPercent, 100, accuracy: 1e-9)
        // 30 blocks = exactly 60 minutes is enough.
        XCTAssertEqual(result(for: [regularBlocks(30, seed: 100)]).verdict, .regular)
    }

    func testNoBeatsAtAll() {
        let r = IrregularRhythm.screen(rr: [], windows: [.init(start: start, end: start + 8 * 3600)])
        XCTAssertEqual(r.verdict, .notEnoughData)
        XCTAssertEqual(r.analysedMinutes, 0)
        XCTAssertEqual(r.burdenPercent, 0)
        XCTAssertEqual(r.windowMinutes, 480, accuracy: 1e-9)
        XCTAssertEqual(r.analysedShare, 0)
        XCTAssertEqual(IrregularRhythm.screen(rr: [], windows: []).verdict, .notEnoughData)
    }

    func testOnlyBeatsInsideTheWindowAreUsed() {
        let n = night([regularBlocks(40, seed: 100)])
        // The window covers the middle 60 minutes of an 80-minute recording.
        let w = IrregularRhythm.Window(start: start + 10 * 60, end: start + 70 * 60)
        let r = IrregularRhythm.screen(rr: n.rows, windows: [w])
        XCTAssertEqual(r.windowMinutes, 60, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(r.analysedMinutes, 60.1)   // the first interval began just before the window
        XCTAssertGreaterThan(r.analysedMinutes, 54)
    }

    func testOverlappingWindowsAreMergedSoNothingIsCountedTwice() {
        let n = night([regularBlocks(40, seed: 100)])
        let a = IrregularRhythm.screen(rr: n.rows, windows: [n.window])
        let b = IrregularRhythm.screen(rr: n.rows, windows: [n.window, n.window,
                                                            .init(start: n.window.start + 100, end: n.window.end - 100)])
        XCTAssertEqual(a, b)
    }

    func testVerdictRawValuesAreStable() {
        // Stored or logged by name: renaming a case would silently orphan old values.
        XCTAssertEqual(IrregularRhythm.Verdict.notEnoughData.rawValue, "notEnoughData")
        XCTAssertEqual(IrregularRhythm.Verdict.regular.rawValue, "regular")
        XCTAssertEqual(IrregularRhythm.Verdict.someIrregularSegments.rawValue, "someIrregularSegments")
        XCTAssertEqual(IrregularRhythm.Verdict.irregularEpisode.rawValue, "irregularEpisode")
    }
}
