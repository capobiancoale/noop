import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// `HeartRateAccuracy`: the strap against its own beat-to-beat timing, a manual pulse count, and the
/// person's own sleeping / waking baseline.
final class HeartRateAccuracyTests: XCTestCase {

    private let t0 = 1_800_000_000

    /// One heart-rate sample per second, all at `bpm`.
    private func steadyHR(seconds: Int, bpm: Double) -> [(ts: Int, bpm: Double)] {
        (0..<seconds).map { (ts: t0 + $0, bpm: bpm) }
    }

    /// R-R intervals at exactly `bpm` (one beat every 60000 / bpm ms), stamped with the whole second.
    private func steadyRR(seconds: Int, bpm: Double) -> [(ts: Int, rrMs: Double)] {
        let rr = 60_000 / bpm
        var out: [(ts: Int, rrMs: Double)] = []
        var t = 0.0
        while t < Double(seconds) {
            t += rr / 1000
            out.append((ts: t0 + Int(t), rrMs: rr.rounded()))
        }
        return out
    }

    // MARK: rrConsistency

    func testAgreementWhenTheStrapMatchesItsBeatTiming() throws {
        let a = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 120, bpm: 70),
                                                              rr: steadyRR(seconds: 120, bpm: 70)))
        XCTAssertGreaterThanOrEqual(a.n, 100)
        XCTAssertEqual(a.meanBias, 0, accuracy: 0.2)
        XCTAssertEqual(a.meanAbsError, 0, accuracy: 0.2)
        XCTAssertEqual(a.shareWithin5Bpm, 1.0, accuracy: 1e-9)
    }

    func testStrapReadingHighShowsAPositiveBias() throws {
        // The strap says 80 while the beats arrive at 70: +10 bpm, never within 5.
        let a = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 120, bpm: 80),
                                                              rr: steadyRR(seconds: 120, bpm: 70)))
        XCTAssertEqual(a.meanBias, 10, accuracy: 0.3)
        XCTAssertEqual(a.meanAbsError, 10, accuracy: 0.3)
        XCTAssertEqual(a.shareWithin5Bpm, 0, accuracy: 1e-9)
    }

    func testStrapReadingLowShowsANegativeBias() throws {
        let a = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 120, bpm: 60),
                                                              rr: steadyRR(seconds: 120, bpm: 70)))
        XCTAssertEqual(a.meanBias, -10, accuracy: 0.3)
        XCTAssertEqual(a.meanAbsError, 10, accuracy: 0.3)
    }

    func testShareWithinFiveCountsTheBoundaryInclusive() throws {
        // Half the seconds read 5 bpm high (inside), half 12 bpm high (outside).
        let hr = (0..<120).map { (ts: t0 + $0, bpm: $0 < 60 ? 75.0 : 82.0) }
        let a = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: hr, rr: steadyRR(seconds: 120, bpm: 70)))
        XCTAssertEqual(a.shareWithin5Bpm, 0.5, accuracy: 0.05)
    }

    func testTooFewComparisonsIsNil() {
        // 20 seconds can give at most 20 comparisons: below the 30 a statement needs.
        XCTAssertNil(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 20, bpm: 70),
                                                     rr: steadyRR(seconds: 20, bpm: 70)))
    }

    func testNoIntervalsOrNoHeartRateIsNil() {
        XCTAssertNil(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 120, bpm: 70), rr: []))
        XCTAssertNil(HeartRateAccuracy.rrConsistency(hr: [], rr: steadyRR(seconds: 120, bpm: 70)))
    }

    func testIntervalsOutsideThePhysiologicalRangeAreIgnored() {
        // 250 ms (240 bpm) and 2500 ms are not heartbeats: nothing is left to compare.
        let rr = (0..<200).map { (ts: t0 + $0 / 2, rrMs: $0 % 2 == 0 ? 250.0 : 2500.0) }
        XCTAssertNil(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 100, bpm: 70), rr: rr))
    }

    func testErraticIntervalsAreDroppedByTheArtefactRule() {
        // Windows of three wildly different beats (857, 400, 1700 ms): the 20 % rule leaves one, below the
        // three needed, so the second is not compared rather than compared on garbage.
        var rr: [(ts: Int, rrMs: Double)] = []
        for s in 0..<120 { rr += [(ts: t0 + s, rrMs: 857), (ts: t0 + s, rrMs: 400), (ts: t0 + s, rrMs: 1700)] }
        // Each window holds 33 values here, so thin it to exactly three per window by spacing seconds 11 apart.
        let sparse = rr.filter { ($0.ts - t0) % 11 == 0 }
        XCTAssertNil(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 120, bpm: 70), rr: sparse))
    }

    func testIntervalsBeyondFiveSecondsDoNotCount() {
        // Beats only 8 to 20 s after each heart-rate second: outside the +-5 s window for the first 120 s of
        // samples that have no beat nearby, so far fewer than 30 comparisons survive.
        let hr = steadyHR(seconds: 60, bpm: 70)
        let rr = steadyRR(seconds: 400, bpm: 70).filter { $0.ts - t0 >= 70 }
        XCTAssertNil(HeartRateAccuracy.rrConsistency(hr: hr, rr: rr))
    }

    func testSingleOutlierBeatDoesNotMoveTheMedian() throws {
        var rr = steadyRR(seconds: 120, bpm: 70)
        // A missed-beat style artefact every ~10 s (a doubled interval) must not shift the agreement.
        for i in stride(from: 5, to: rr.count, by: 12) { rr[i] = (ts: rr[i].ts, rrMs: rr[i].rrMs * 2) }
        let a = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: steadyHR(seconds: 120, bpm: 70), rr: rr))
        XCTAssertEqual(a.meanBias, 0, accuracy: 1.0)
        XCTAssertGreaterThan(a.shareWithin5Bpm, 0.95)
    }

    func testUnsortedInputGivesTheSameAnswer() throws {
        let hr = steadyHR(seconds: 120, bpm: 74)
        let rr = steadyRR(seconds: 120, bpm: 70)
        let a = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: hr, rr: rr))
        let b = try XCTUnwrap(HeartRateAccuracy.rrConsistency(hr: hr.reversed(), rr: rr.reversed()))
        XCTAssertEqual(a, b)
    }

    // MARK: palpation

    func testCountedPulseAgainstTheStrap() throws {
        // 36 beats in 30 s = 72 bpm; the strap said 74 the whole time.
        let r = try XCTUnwrap(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 30, bpm: 74),
                                                          start: t0, seconds: 30, countedBeats: 36))
        XCTAssertEqual(r.countedBpm, 72, accuracy: 1e-9)
        XCTAssertEqual(r.strapBpm, 74, accuracy: 1e-9)
        XCTAssertEqual(r.differenceBpm, 2, accuracy: 1e-9)
        XCTAssertEqual(r.percent, 2.0 / 72 * 100, accuracy: 1e-9)
        XCTAssertEqual(r.samples, 30)
        XCTAssertTrue(r.matches)
    }

    func testAStrapMoreThanFiveBpmAwayDoesNotMatch() throws {
        let r = try XCTUnwrap(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 30, bpm: 90),
                                                          start: t0, seconds: 30, countedBeats: 36))
        XCTAssertEqual(r.differenceBpm, 18, accuracy: 1e-9)
        XCTAssertFalse(r.matches)
    }

    func testFiveBpmExactlyStillMatches() throws {
        let r = try XCTUnwrap(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 30, bpm: 77),
                                                          start: t0, seconds: 30, countedBeats: 36))
        XCTAssertEqual(r.differenceBpm, 5, accuracy: 1e-9)
        XCTAssertTrue(r.matches)
    }

    func testStrapBelowTheCountIsANegativeDifference() throws {
        let r = try XCTUnwrap(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 30, bpm: 60),
                                                          start: t0, seconds: 30, countedBeats: 36))
        XCTAssertEqual(r.differenceBpm, -12, accuracy: 1e-9)
        XCTAssertLessThan(r.percent, 0)
    }

    func testWindowIsStartInclusiveEndExclusive() throws {
        // Samples at t0-1 and t0+30 are outside [t0, t0+30) and must not enter the mean.
        var strap = steadyHR(seconds: 30, bpm: 70)
        strap.append((ts: t0 - 1, bpm: 200))
        strap.append((ts: t0 + 30, bpm: 200))
        let r = try XCTUnwrap(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 30, countedBeats: 35))
        XCTAssertEqual(r.strapBpm, 70, accuracy: 1e-9)
        XCTAssertEqual(r.samples, 30)
    }

    func testStrapCoverageBelowHalfTheWindowIsNil() {
        // 14 of 30 seconds (47 %): too little of the count was seen by the strap.
        XCTAssertNil(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 14, bpm: 70),
                                                 start: t0, seconds: 30, countedBeats: 35))
    }

    func testStrapCoverageOfExactlyHalfIsEnough() {
        XCTAssertNotNil(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 15, bpm: 70),
                                                    start: t0, seconds: 30, countedBeats: 35))
    }

    func testRepeatedSamplesInOneSecondCountOnceForCoverage() {
        // 30 samples, all in the same second: one second of coverage, not thirty.
        let strap = (0..<30).map { _ in (ts: t0 + 3, bpm: 70.0) }
        XCTAssertNil(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 30, countedBeats: 35))
    }

    func testImplausibleCountsAndWindowsAreRejected() {
        let strap = steadyHR(seconds: 30, bpm: 70)
        XCTAssertNil(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 30, countedBeats: 0))
        XCTAssertNil(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 30, countedBeats: -4))
        XCTAssertNil(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 0, countedBeats: 35))
        // 5 beats in 30 s is 10 bpm and 200 beats is 400 bpm: mis-counts, not pulses.
        XCTAssertNil(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 30, countedBeats: 5))
        XCTAssertNil(HeartRateAccuracy.palpation(strap: strap, start: t0, seconds: 30, countedBeats: 200))
    }

    func testOtherCountingWindowsScaleTheRate() throws {
        // 15 s: 18 beats = 72 bpm; a 60 s window: 72 beats = 72 bpm.
        let r15 = try XCTUnwrap(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 15, bpm: 72),
                                                            start: t0, seconds: 15, countedBeats: 18))
        XCTAssertEqual(r15.countedBpm, 72, accuracy: 1e-9)
        let r60 = try XCTUnwrap(HeartRateAccuracy.palpation(strap: steadyHR(seconds: 60, bpm: 72),
                                                            start: t0, seconds: 60, countedBeats: 72))
        XCTAssertEqual(r60.countedBpm, 72, accuracy: 1e-9)
    }

    // MARK: sleeping

    func testSleepingFloorAndMean() throws {
        // 8 h at 1 Hz: the first 4 h at 60 bpm, the last 4 h at 52. Floor = the lowest 5-minute mean.
        let hr = (0..<(8 * 3600)).map { HRSample(ts: t0 + $0, bpm: $0 < 4 * 3600 ? 60 : 52) }
        let s = try XCTUnwrap(HeartRateAccuracy.sleeping(hr: hr, start: t0, end: t0 + 8 * 3600))
        XCTAssertEqual(s.floorBpm, 52)
        XCTAssertEqual(s.meanBpm, 56, accuracy: 1e-9)
        XCTAssertEqual(s.samples, 8 * 3600)
    }

    func testSleepingNeedsFiveMinutesOfSamples() {
        let hr = (0..<299).map { HRSample(ts: t0 + $0, bpm: 55) }
        XCTAssertNil(HeartRateAccuracy.sleeping(hr: hr, start: t0, end: t0 + 3600))
    }

    func testSleepingIgnoresSamplesOutsideTheNight() throws {
        var hr = (0..<3600).map { HRSample(ts: t0 + $0, bpm: 50) }
        hr += (0..<3600).map { HRSample(ts: t0 + 7200 + $0, bpm: 120) }   // later, awake
        let s = try XCTUnwrap(HeartRateAccuracy.sleeping(hr: hr, start: t0, end: t0 + 3599))
        XCTAssertEqual(s.meanBpm, 50, accuracy: 1e-9)
    }

    // MARK: waking

    func testWakingPercentiles() throws {
        // 50 awake windows at 60, 61 ... 109 bpm: type-7 percentiles are 64.9 / 84.5 / 104.1.
        let w = (0..<50).map { (ts: t0 + $0 * 300, bpm: 60.0 + Double($0)) }
        let r = try XCTUnwrap(HeartRateAccuracy.waking(windows: w, excluding: []))
        XCTAssertEqual(r.restingBpm, 64.9, accuracy: 1e-9)
        XCTAssertEqual(r.typicalBpm, 84.5, accuracy: 1e-9)
        XCTAssertEqual(r.highBpm, 104.1, accuracy: 1e-9)
        XCTAssertEqual(r.windows, 50)
    }

    func testWakingLeavesOutSleepWindows() throws {
        // 30 awake windows at 70 and 100 sleeping windows at 48 that a session covers: only the 70s count.
        var w = (0..<30).map { (ts: t0 + $0 * 300, bpm: 70.0) }
        let sleepStart = t0 + 30 * 300
        w += (0..<100).map { (ts: sleepStart + $0 * 300, bpm: 48.0) }
        let r = try XCTUnwrap(HeartRateAccuracy.waking(
            windows: w, excluding: [(start: sleepStart, end: sleepStart + 100 * 300)]))
        XCTAssertEqual(r.restingBpm, 70, accuracy: 1e-9)
        XCTAssertEqual(r.windows, 30)
    }

    func testWakingNeedsTwoHoursOfWindows() {
        let w = (0..<23).map { (ts: t0 + $0 * 300, bpm: 70.0) }
        XCTAssertNil(HeartRateAccuracy.waking(windows: w, excluding: []))
    }

    func testWakingIgnoresZeroWindows() {
        let w = (0..<40).map { (ts: t0 + $0 * 300, bpm: 0.0) }
        XCTAssertNil(HeartRateAccuracy.waking(windows: w, excluding: []))
    }
}
