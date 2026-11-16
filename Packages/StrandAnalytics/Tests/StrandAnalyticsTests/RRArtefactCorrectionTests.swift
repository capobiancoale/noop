import XCTest
@testable import StrandAnalytics

/// Lipponen & Tarvainen (2019) artefact detection and correction. The simulations follow the paper's own
/// protocol (§3: missed / extra / misaligned beats at k = 100n) and the tolerances come from its Table 3,
/// where RMSSD after correction was within 0.4–1.2% of the original for missed, extra and misaligned
/// (q ≥ 4) beats. Two real excerpts from PhysioNet Fantasia pin the behaviour on genuine recordings.
final class RRArtefactCorrectionTests: XCTestCase {

    private typealias Fix = RRFixtures
    private func rmssd(_ x: [Double]) -> Double { HRVAnalyzer.rmssdRaw(x)! }
    private func relErr(_ a: Double, _ b: Double) -> Double { abs(a - b) / b }

    // MARK: - Normal beats stay untouched

    func testCleanRestingSeriesIsUntouched() {
        for seed in UInt64(1)...5 {
            let rr = Fix.resting(count: 300, seed: seed)
            let res = RRArtefactCorrection.correct(rr)
            XCTAssertEqual(res.corrected, 0, "seed \(seed): a clean resting series has no artefacts")
            XCTAssertEqual(res.nn, rr)
        }
    }

    func testHighVariabilityNightKeepsEveryGenuineBeat() {
        // RSA of ±120 ms (RMSSD ≈ 100 ms), typical of a fit young sleeper. The adaptive thresholds scale with
        // the person's own variability, so no genuine beat is flagged; the old fixed 20%-of-local-median rule
        // throws beats away on exactly these nights.
        let rr = Fix.resting(count: 300, meanMs: 800, rsaMs: 120, jitterMs: 25, seed: 1)
        XCTAssertGreaterThan(rmssd(rr), 90)
        XCTAssertEqual(RRArtefactCorrection.correct(rr).corrected, 0)
        XCTAssertLessThan(HRVAnalyzer.rejectEctopic(rr).count, 290, "the legacy rule deletes genuine beats here")
    }

    func testRealHighVariabilityRecordingKeepsEveryBeat() {
        // Fantasia f1y01: five minutes of abrupt, large sinus arrhythmia, every beat annotated normal.
        let rr = Fix.f1y01
        let res = RRArtefactCorrection.correct(rr)
        XCTAssertEqual(res.corrected, 0, "no genuine beat of the real high-HRV recording is flagged")
        XCTAssertEqual(rmssd(res.nn), rmssd(rr), accuracy: 1e-9)
        // The legacy rule would delete 22 of these 300 normal beats and cut RMSSD by more than a third.
        let malik = HRVAnalyzer.rejectEctopic(rr)
        XCTAssertEqual(rr.count - malik.count, 22)
        XCTAssertLessThan(rmssd(malik), 0.65 * rmssd(rr))
    }

    // MARK: - Simulated artefacts (paper §3 protocol)

    func testMissedBeatsAreDetectedAndSplitBack() {
        let truth = Fix.resting(count: 500, seed: 3)
        let bad = Fix.withMissedBeats(truth)
        XCTAssertEqual(bad.count, truth.count - 4)
        XCTAssertGreaterThan(rmssd(bad), 2 * rmssd(truth), "uncorrected, four missed beats inflate RMSSD")
        let res = RRArtefactCorrection.correct(bad)
        XCTAssertEqual(res.count(.missed), 4)
        XCTAssertEqual(res.corrected, 4)
        XCTAssertEqual(res.nn.count, truth.count, "each missed beat is added back")
        XCTAssertLessThan(relErr(rmssd(res.nn), rmssd(truth)), 0.02)
    }

    func testExtraDetectionsAreDetectedAndMerged() {
        let truth = Fix.resting(count: 500, seed: 4)
        let bad = Fix.withExtraBeats(truth)
        XCTAssertEqual(bad.count, truth.count + 4)
        XCTAssertGreaterThan(rmssd(bad), 1.5 * rmssd(truth))
        let res = RRArtefactCorrection.correct(bad)
        XCTAssertEqual(res.count(.extra), 4)
        XCTAssertEqual(res.corrected, 4, "the merged second half is part of the same artefact, not a second one")
        XCTAssertEqual(res.nn.count, truth.count, "each extra detection is removed")
        // Merging restores the original interval up to the ±1 ms rounding of the two halves.
        for (a, b) in zip(res.nn, truth) { XCTAssertEqual(a, b, accuracy: 1) }
        XCTAssertLessThan(relErr(rmssd(res.nn), rmssd(truth)), 0.005)
    }

    func testMisalignedBeatsAreDetectedAndReestimated() {
        for q in [4.0, 8.0] {
            let truth = Fix.resting(count: 500, seed: 5)
            let bad = Fix.withMisalignedBeats(truth, q: q)
            XCTAssertEqual(bad.count, truth.count)
            XCTAssertGreaterThan(rmssd(bad), 1.3 * rmssd(truth), "q=\(q): displacement inflates RMSSD")
            let res = RRArtefactCorrection.correct(bad)
            // Every displaced beat is caught on one of the two intervals it touches, as ectopic or long/short.
            for k in Fix.sites(beatCount: truth.count + 1) {
                XCTAssertTrue(res.labels[k - 1] != nil || res.labels[k] != nil, "q=\(q): beat \(k) missed")
            }
            XCTAssertEqual(res.count(.missed) + res.count(.extra), 0, "a displaced beat is never split or merged")
            XCTAssertEqual(res.nn.count, truth.count)
            XCTAssertLessThan(relErr(rmssd(res.nn), rmssd(truth)), 0.02, "q=\(q)")
        }
    }

    func testPrematureBeatWithCompensatoryPauseIsEctopic() {
        // A premature beat at 70% of the cycle and a full compensatory pause (the two intervals sum to 2T).
        var rr = Fix.resting(count: 200, seed: 6)
        let k = 100
        let t = (rr[k] + rr[k + 1]) / 2
        rr[k] = (0.7 * t).rounded()
        rr[k + 1] = (1.3 * t).rounded()
        let res = RRArtefactCorrection.correct(rr)
        XCTAssertEqual(res.labels[k + 1], .ectopic, "the NPN pattern centred on the compensatory pause")
        XCTAssertEqual(res.nn.count, rr.count)
        // Both corrupted intervals are re-estimated from their neighbours.
        let local = (rr[k - 3..<k] + rr[k + 2...k + 4]).reduce(0, +) / 6
        XCTAssertEqual(res.nn[k], local, accuracy: 60)
        XCTAssertEqual(res.nn[k + 1], local, accuracy: 60)
    }

    func testRealSupraventricularPrematureBeatIsCorrected() {
        // Fantasia f1o10: the database annotates a supraventricular premature beat (564 ms, then a 1020 ms
        // pause). The algorithm flags exactly those two intervals and nothing else in the two minutes.
        let rr = Fix.f1o10
        let res = RRArtefactCorrection.correct(rr)
        let flagged = res.labels.indices.filter { res.labels[$0] != nil }
        XCTAssertEqual(flagged, [60, 61])
        XCTAssertEqual(res.labels[61], .ectopic)
        XCTAssertEqual(res.nn.count, rr.count)
        for i in rr.indices where i != 60 && i != 61 { XCTAssertEqual(res.nn[i], rr[i]) }
        // Both intervals are re-estimated inside the sinus range of the surrounding two minutes...
        let sinus = rr.indices.filter { $0 != 60 && $0 != 61 }.map { rr[$0] }
        for i in [60, 61] { XCTAssertTrue((sinus.min()!...sinus.max()!).contains(res.nn[i])) }
        // ...so RMSSD matches the sinus beats alone (differences touching the premature beat left out), while
        // the uncorrected series nearly doubles it.
        let sinusOnly = HRVAnalyzer.rmssd(segments: [Array(rr[0..<60]), Array(rr[62...])])!
        XCTAssertEqual(rmssd(res.nn), sinusOnly, accuracy: 0.1 * sinusOnly)
        XCTAssertGreaterThan(rmssd(rr), 1.8 * sinusOnly)
    }

    func testArtefactAtTheEdgeOfARunIsCaught() {
        // The first and the last interval of a run have a neighbour on one side only; virtual median intervals
        // let their dRR pattern show, so a long or short artefact that opens or closes a window is corrected
        // like any other (from its nearest clean neighbour, the only side there is).
        let truth = Fix.resting(count: 40, seed: 8)
        for k in [0, truth.count - 1] {
            for bad in [1300.0, 450.0] {
                var rr = truth
                rr[k] = bad
                let res = RRArtefactCorrection.correct(rr)
                XCTAssertEqual(res.labels[k], .longShort, "\(bad) ms at index \(k)")
                XCTAssertEqual(res.corrected, 1)
                XCTAssertEqual(res.nn.count, rr.count)
                XCTAssertEqual(res.nn[k], truth[k], accuracy: 60)
            }
        }
    }

    // MARK: - Degenerate inputs

    func testZeroThresholdLeavesPerfectlyRegularSeriesUntouched() {
        // A perfectly regular synthetic stretch has a zero quartile deviation, so nothing can be normalised:
        // like NeuroKit2, the beat is left unflagged rather than every beat being called an artefact.
        var rr = Array(repeating: 800.0, count: 30)
        rr[15] = 1400
        let res = RRArtefactCorrection.correct(rr)
        XCTAssertEqual(res.corrected, 0)
        XCTAssertEqual(res.nn, rr)
    }

    func testShortRunIsNotClassified() {
        let rr: [Double] = [800, 810, 1600, 805, 800, 815, 790]
        XCTAssertLessThan(rr.count, RRArtefactCorrection.minIntervals)
        XCTAssertTrue(RRArtefactCorrection.classify(rr).allSatisfy { $0 == nil })
    }

    // MARK: - Building blocks

    func testThresholdUsesSignedQuartileDeviation() {
        // Signed [-2, -1, 0, 1, 2]: Q1 = -1, Q3 = 1, QD = 1 → Th = 5.2 at every position (window covers all).
        let th = RRArtefactCorrection.rollingThreshold([-2, -1, 0, 1, 2])
        for v in th { XCTAssertEqual(v, 5.2, accuracy: 1e-12) }
        // For normally distributed values 5.2 × QD ≈ 3.5σ, the 99.95% band the paper states.
        let z = 5.2 * 0.6744897501960817
        XCTAssertEqual(z, 3.507, accuracy: 0.001)
    }

    func testQuantileMatchesNumPyLinearInterpolation() {
        XCTAssertEqual(RRArtefactCorrection.quantile([1, 2, 3, 4], 0.25), 1.75, accuracy: 1e-12)
        XCTAssertEqual(RRArtefactCorrection.quantile([1, 2, 3, 4], 0.5), 2.5, accuracy: 1e-12)
        XCTAssertEqual(RRArtefactCorrection.quantile([1, 2, 3, 4], 0.75), 3.25, accuracy: 1e-12)
        XCTAssertEqual(RRArtefactCorrection.quantile([7], 0.25), 7)
    }

    func testNaturalCubicSplineReproducesKnotsAndLines() {
        let line = NaturalCubicSpline(x: [0, 1, 2, 5, 6], y: [1, 3, 5, 11, 13])
        XCTAssertEqual(line.value(at: 3.5), 8, accuracy: 1e-9, "a spline through collinear points is the line")
        let curve = NaturalCubicSpline(x: [0, 1, 2, 3], y: [0, 1, 0, 1])
        for (x, y) in [(0.0, 0.0), (1, 1), (2, 0), (3, 1)] { XCTAssertEqual(curve.value(at: x), y, accuracy: 1e-9) }
    }

    func testCorruptedRunIsFilledFromBothSides() {
        let values: [Double] = [800, 810, 820, 1500, 1500, 850, 860, 870]
        let corrupt = [false, false, false, true, true, false, false, false]
        let out = RRArtefactCorrection.fillCorrupted(values, corrupt: corrupt)
        XCTAssertEqual(out[3], 830, accuracy: 1e-6)
        XCTAssertEqual(out[4], 840, accuracy: 1e-6)
        XCTAssertEqual(Array(out[0...2]), [800, 810, 820])
        XCTAssertEqual(Array(out[5...7]), [850, 860, 870])
        // At an edge only one side exists: the nearest clean value is used.
        let edge = RRArtefactCorrection.fillCorrupted([1500, 800, 810, 820], corrupt: [true, false, false, false])
        XCTAssertEqual(edge[0], 800)
    }
}
