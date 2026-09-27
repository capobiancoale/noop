import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRVAnalyzerTests: XCTestCase {

    func testRMSSDRawHandComputed() {
        // NN = [800, 810, 800, 810] → diffs 10, -10, 10 → sqrt(300/3) = 10.
        let nn = [800.0, 810, 800, 810]
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(nn)!, 10.0, accuracy: 1e-9)
    }

    func testSDNNRawSampleStdDev() {
        // Sample SD (ddof=1) of [800, 810, 800, 810] = 5.7735026919...
        let nn = [800.0, 810, 800, 810]
        XCTAssertEqual(HRVAnalyzer.sdnnRaw(nn)!, 5.773502691896258, accuracy: 1e-9)
    }

    func testRMSSDRawTooFewReturnsNil() {
        XCTAssertNil(HRVAnalyzer.rmssdRaw([800]))
        XCTAssertNil(HRVAnalyzer.sdnnRaw([]))
    }

    func testRangeFilterDropsOutOfRange() {
        let rr = [250.0, 300, 800, 2000, 2100, 1500]
        // 250 (<300) and 2100 (>2000) dropped; 300 and 2000 kept (inclusive).
        XCTAssertEqual(HRVAnalyzer.rangeFilter(rr), [300, 800, 2000, 1500])
    }

    func testAnalyzeRequiresMinBeats() {
        // 19 clean intervals → below minBeats(20) → empty result.
        let rr = Array(repeating: 800.0, count: 19)
        let result = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertNil(result.rmssd)
        XCTAssertNil(result.sdnn)
        XCTAssertEqual(result.nInput, 19)
        XCTAssertEqual(result.nClean, 0)
    }

    func testAnalyzeGoldenSeries() {
        // 22 intervals oscillating near 800 ms; matches Python golden values.
        let nn: [Double] = [800, 810, 805, 815, 800, 820, 810, 800, 815, 805, 810,
                            800, 820, 815, 805, 810, 800, 815, 810, 805, 800, 820]
        let result = HRVAnalyzer.analyze(rawRR: nn)
        XCTAssertEqual(result.nClean, 22)  // none ectopic (all near local median)
        XCTAssertEqual(result.rmssd!, 11.649647450214351, accuracy: 1e-9)
        XCTAssertEqual(result.sdnn!, 7.101612523427368, accuracy: 1e-9)
        XCTAssertEqual(result.meanNN!, nn.reduce(0,+)/22, accuracy: 1e-9)
    }

    func testArtefactCorrectionReplacesSpikeWithoutLosingBeats() {
        // A realistic resting series with one impossible 1400 ms interval. Lipponen–Tarvainen re-estimates
        // it from its neighbours instead of deleting it: no beat is lost, so every successive difference is
        // still taken between truly adjacent beats.
        let truth = RRFixtures.resting(count: 120, seed: 11)
        var rr = truth
        rr[60] = 1400
        let cleaned = HRVAnalyzer.clean(rr)
        XCTAssertEqual(cleaned.nn.count, rr.count)
        XCTAssertEqual(cleaned.corrected, 1)
        XCTAssertEqual(cleaned.nDropped, 0)
        XCTAssertEqual(cleaned.nn[60], truth[60], accuracy: 40)
        let truthRmssd = HRVAnalyzer.rmssdRaw(truth)!
        XCTAssertGreaterThan(HRVAnalyzer.rmssdRaw(rr)!, 2 * truthRmssd, "uncorrected, the spike dominates RMSSD")
        XCTAssertEqual(HRVAnalyzer.analyze(rawRR: rr).rmssd!, truthRmssd, accuracy: 0.05 * truthRmssd)
    }

    func testEctopicKeepsModerateVariation() {
        // ±15% variation is within the 20% Malik threshold → all kept.
        let nn = [800.0, 900, 800, 900, 800, 900, 800, 900]  // 900/800 = +12.5%
        let clean = HRVAnalyzer.rejectEctopic(nn)
        XCTAssertEqual(clean.count, nn.count)
    }

    // MARK: - #585 spot honesty gate (maxRejectedFraction)

    func testSpotGateRefusesWhenTooManyBeatsRejected() {
        // 40 input beats: 24 valid 800 ms + 16 out-of-range 100 ms (dropped by the range filter).
        // 24 clean survive (>= minBeats 20), but 16/40 = 0.40 rejected > 0.35 gate → refused (empty).
        var rr = Array(repeating: 800.0, count: 24)
        rr.append(contentsOf: Array(repeating: 100.0, count: 16))   // 100 ms < rrMinMs(300) → range-dropped
        let gated = HRVAnalyzer.analyze(rawRR: rr, maxRejectedFraction: 0.35)
        XCTAssertNil(gated.rmssd, "0.40 rejected > 0.35 gate must refuse the spot reading")
        XCTAssertNil(gated.sdnn)
        XCTAssertEqual(gated.nInput, 40)
        XCTAssertEqual(gated.nClean, 0)   // empty() reports no clean beats on refusal

        // SAME beats with NO gate (nil) still produce a value , 24 clean ≥ minBeats. Proves the gate is
        // the only thing rejecting it, not the beat count.
        let ungated = HRVAnalyzer.analyze(rawRR: rr)
        XCTAssertEqual(ungated.nClean, 24)
        XCTAssertEqual(ungated.rmssd!, 0.0, accuracy: 1e-9)   // all-800 survivors → no successive diffs
    }

    func testSpotGateAllowsWhenRejectionUnderCeiling() {
        // 40 input: 30 valid 800 ms + 10 out-of-range → 10/40 = 0.25 rejected < 0.35 gate → allowed.
        var rr = Array(repeating: 800.0, count: 30)
        rr.append(contentsOf: Array(repeating: 100.0, count: 10))
        let gated = HRVAnalyzer.analyze(rawRR: rr, maxRejectedFraction: 0.35)
        XCTAssertEqual(gated.nClean, 30)
        XCTAssertEqual(gated.rmssd!, 0.0, accuracy: 1e-9)
    }

    func testNightlyWindowedRMSSDUnchangedWithDefaultedGate() {
        // The nightly windowed analyze(_:windowStart:windowEnd:) passes NO maxRejectedFraction, so the
        // gate is skipped and the result is byte-identical to analyze(rawRR:) on the same beats , even
        // when the series WOULD trip a spot gate (here 0.40 rejected). Overnight HRV must not move (#585).
        var rr: [RRInterval] = []
        for t in 0..<24 { rr.append(RRInterval(ts: 1000 + t, rrMs: 800)) }   // 24 valid 800 ms
        for t in 0..<16 { rr.append(RRInterval(ts: 1100 + t, rrMs: 100)) }   // 16 range-dropped
        let windowed = HRVAnalyzer.analyze(rr, windowStart: 1000, windowEnd: 2000)
        // The spot gate WOULD refuse this (0.40 > 0.35); the nightly path must NOT.
        XCTAssertEqual(windowed.nClean, 24)
        XCTAssertNotNil(windowed.rmssd)
        // Identical to the un-gated raw analysis on the same values.
        let raw = HRVAnalyzer.analyze(rawRR: rr.map { Double($0.rrMs) })
        XCTAssertEqual(windowed.rmssd!, raw.rmssd!, accuracy: 1e-12)
        XCTAssertEqual(windowed.sdnn ?? .nan, raw.sdnn ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(windowed.nClean, raw.nClean)
    }

    // MARK: - #803 rolling / windowed rMSSD timeline

    func testRollingRmssdEmitsWindowedTimelineWithKnownValue() {
        // A clean 1 Hz R-R series oscillating 800/810 ms. Over any trailing window the successive diffs
        // alternate ±10, so rMSSD = sqrt(mean(10^2)) = 10 ms. We build 60 beats (1 s apart) and ask for a
        // 30 s trailing window; every emitted point must read ~10 ms.
        var rr: [RRInterval] = []
        for t in 0..<60 { rr.append(RRInterval(ts: 1000 + t, rrMs: t.isMultiple(of: 2) ? 800 : 810)) }
        let pts = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        XCTAssertFalse(pts.isEmpty, "a dense clean stream must yield a windowed timeline")
        // The first ~7 beats can't fill minBeatsPerWindow(8); once the window holds >= 8 beats every point
        // is the steady ±10 oscillation → 10 ms rMSSD.
        for p in pts { XCTAssertEqual(p.rmssd, 10.0, accuracy: 1e-9) }
        // Right edge of each point is a real interval timestamp inside the series, and points are time-ordered.
        XCTAssertTrue(pts.allSatisfy { $0.ts >= 1000 && $0.ts <= 1059 })
        XCTAssertEqual(pts.map { $0.ts }, pts.map { $0.ts }.sorted())
    }

    func testRollingRmssdStepThinsEmission() {
        // Same 60-beat 1 Hz stream, but a 10 s stride: points must be at least 10 s apart, so far fewer
        // than one-per-beat are emitted while the value stays the steady 10 ms.
        var rr: [RRInterval] = []
        for t in 0..<60 { rr.append(RRInterval(ts: 1000 + t, rrMs: t.isMultiple(of: 2) ? 800 : 810)) }
        let dense = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        let thinned = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 10, minBeatsPerWindow: 8)
        XCTAssertLessThan(thinned.count, dense.count, "a stride must emit fewer points than every-beat")
        // Adjacent emitted points are >= stepSec apart.
        for i in 1..<thinned.count { XCTAssertGreaterThanOrEqual(thinned[i].ts - thinned[i - 1].ts, 10) }
    }

    func testRollingRmssdCleansArtifactWindows() {
        // A realistic resting stream with one impossible 1400 ms value reported at the right time. Every
        // window holding it has it re-estimated, so no point spikes: each stays close to the same window of
        // the artefact-free stream, while the raw window would more than double.
        let truth = RRFixtures.timed(RRFixtures.resting(count: 90, seed: 12))
        var bad = truth
        bad[45] = RRInterval(ts: truth[45].ts, rrMs: 1400)
        let ref = HRVAnalyzer.rollingRmssd(rr: truth, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        let pts = HRVAnalyzer.rollingRmssd(rr: bad, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertEqual(pts.map(\.ts), ref.map(\.ts))
        for (p, r) in zip(pts, ref) {
            XCTAssertEqual(p.rmssd, r.rmssd, accuracy: 0.15 * r.rmssd, "the 1400 ms artefact must never spike a window")
        }
        let spiked = bad.filter { $0.ts > truth[45].ts - 30 && $0.ts <= truth[45].ts }.map { Double($0.rrMs) }
        let spikedRef = truth.filter { $0.ts > truth[45].ts - 30 && $0.ts <= truth[45].ts }.map { Double($0.rrMs) }
        XCTAssertGreaterThan(HRVAnalyzer.rmssdRaw(spiked)!, 2 * HRVAnalyzer.rmssdRaw(spikedRef)!)
    }

    func testRollingRmssdSparseSeriesEmitsNothing() {
        // Fewer beats than minBeatsPerWindow → no point at all (honest absence, no fabricated value).
        let rr = (0..<5).map { RRInterval(ts: 3000 + $0, rrMs: 800) }
        XCTAssertTrue(HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30).isEmpty)
        // Zero / negative window width is rejected.
        XCTAssertTrue(HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 0).isEmpty)
    }

    func testRollingRmssdSortsUnorderedInput() {
        // Input shuffled in time; the function sorts internally so the trailing window is well-defined and
        // the emitted points are time-ordered with the same steady 10 ms value.
        var rr: [RRInterval] = []
        for t in 0..<40 { rr.append(RRInterval(ts: 4000 + t, rrMs: t.isMultiple(of: 2) ? 800 : 810)) }
        rr.shuffle()
        let pts = HRVAnalyzer.rollingRmssd(rr: rr, windowSec: 30, stepSec: 0, minBeatsPerWindow: 8)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertEqual(pts.map { $0.ts }, pts.map { $0.ts }.sorted())
        for p in pts { XCTAssertEqual(p.rmssd, 10.0, accuracy: 1e-9) }
    }

    func testAnalyzeWindowFiltersByTimestamp() {
        // RR rows across two windows; only [1000,1010] should be analyzed.
        var rr: [RRInterval] = []
        for t in 1000...1030 { rr.append(RRInterval(ts: t, rrMs: 800)) }   // 31 in window A
        for t in 5000...5030 { rr.append(RRInterval(ts: t, rrMs: 600)) }   // window B
        let result = HRVAnalyzer.analyze(rr, windowStart: 1000, windowEnd: 1030)
        XCTAssertEqual(result.nInput, 31)
        XCTAssertEqual(result.nClean, 31)
        XCTAssertEqual(result.rmssd!, 0.0, accuracy: 1e-9)  // all 800 → no successive diffs
    }

    // MARK: - Timestamps, gaps and nightly window quality

    func testCleanTimedCarriesTimestampsThroughCorrections() {
        // One missed beat (the detection at k = 100 removed): the merged interval is split back in two and the
        // inserted beat is stamped half an interval before the beat that ends it.
        let truth = RRFixtures.resting(count: 200, seed: 13)
        let bad = RRFixtures.withMissedBeats(truth)
        let timed = RRFixtures.timed(bad)
        let c = HRVAnalyzer.cleanTimed(timed)
        XCTAssertEqual(c.missed, 1)
        XCTAssertEqual(c.beats.count, truth.count)
        XCTAssertEqual(c.beats[100].ts, timed[99].ts)
        XCTAssertEqual(c.beats[99].ts, timed[99].ts - Int((bad[99] / 2 / 1000).rounded()))
        XCTAssertEqual(c.beats.map(\.ts), c.beats.map(\.ts).sorted())
    }

    func testTimeGapSplitsSuccessiveDifferences() {
        // Two clean stretches a minute apart: the beats either side of the gap are not adjacent, so no
        // successive difference is taken across it.
        let a = RRFixtures.timed(RRFixtures.resting(count: 40, seed: 14), start: 1_000_000)
        let b = RRFixtures.timed(RRFixtures.resting(count: 40, seed: 15), start: 1_000_100)
        let c = HRVAnalyzer.cleanTimed(a + b)
        XCTAssertEqual(c.segments.count, 2)
        let pooled = HRVAnalyzer.rmssd(segments: [a.map { Double($0.rrMs) }, b.map { Double($0.rrMs) }])!
        XCTAssertEqual(HRVAnalyzer.analyze(a + b).rmssd!, pooled, accuracy: 1e-9)
    }

    func testWindowQualityAcceptsCleanFiveMinutes() {
        let w = HRVAnalyzer.windowQuality(RRFixtures.timed(RRFixtures.resting(count: 330, seed: 16)))
        XCTAssertTrue(w.accepted)
        XCTAssertGreaterThan(w.coverageSeconds, 290)
        XCTAssertEqual(w.nCorrected, 0)
        XCTAssertEqual(w.nDropped, 0)
    }

    func testWindowQualityRejectsShortCoverage() {
        // ~90 s of clean beats: below the 120 s that still tracks a 5-min RMSSD (Munoz 2015).
        let w = HRVAnalyzer.windowQuality(RRFixtures.timed(RRFixtures.resting(count: 100, seed: 17)))
        XCTAssertNotNil(w.rmssd)
        XCTAssertLessThan(w.coverageSeconds, HRVAnalyzer.minWindowCoverageSeconds)
        XCTAssertFalse(w.accepted)
    }

    func testWindowQualityRejectsTooManyCorrections() {
        // A displaced detection every 10 beats: far above Kubios' 5% corrected-beat acceptance threshold.
        var b = RRFixtures.beats(RRFixtures.resting(count: 330, seed: 18))
        let dt = 8 * HRVAnalyzer.rmssdRaw(RRFixtures.resting(count: 330, seed: 18))!
        for (n, k) in stride(from: 10, to: b.count - 3, by: 10).enumerated() { b[k] += n.isMultiple(of: 2) ? dt : -dt }
        let w = HRVAnalyzer.windowQuality(RRFixtures.timed(RRFixtures.intervals(b)))
        XCTAssertGreaterThan(Double(w.nCorrected) / Double(w.nInput), HRVAnalyzer.maxCorrectedFraction)
        XCTAssertGreaterThan(w.coverageSeconds, HRVAnalyzer.minWindowCoverageSeconds)
        XCTAssertFalse(w.accepted)
    }

    func testWindowQualityRejectsHeavyDropout() {
        // Two of every five intervals are dropouts (100 ms, not heartbeats): 40% lost, above the 36% at which
        // RMSSD stays within 5% (Sheridan 2020), even though the rest still covers more than 120 s.
        var rr = RRFixtures.timed(RRFixtures.resting(count: 330, seed: 19))
        for i in rr.indices where i % 5 < 2 { rr[i] = RRInterval(ts: rr[i].ts, rrMs: 100) }
        let w = HRVAnalyzer.windowQuality(rr)
        XCTAssertGreaterThan(Double(w.nDropped) / Double(w.nInput), HRVAnalyzer.maxDroppedFraction)
        XCTAssertGreaterThan(w.coverageSeconds, HRVAnalyzer.minWindowCoverageSeconds)
        XCTAssertFalse(w.accepted)
    }
}
