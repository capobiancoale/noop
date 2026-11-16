import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// `NightCoverage`: how much of a night the strap recorded, and whether it is enough for a nightly HRV.
final class NightCoverageTests: XCTestCase {

    private let start = 1_800_000_000
    private let hour = 3600

    /// One heart-rate timestamp per second over `[from, to)`.
    private func hrSeconds(_ from: Int, _ to: Int) -> [Int] { Array(from..<to) }

    /// Clean resting R-R beats starting at `from`, spanning at least `seconds`.
    private func beats(from: Int, seconds: Int, seed: UInt64 = 1) -> [RRInterval] {
        let count = Int(Double(seconds) / 0.9) + 2
        return RRFixtures.timed(RRFixtures.resting(count: count, seed: seed), start: from)
            .filter { $0.ts < from + seconds }
    }

    // MARK: summarize

    func testEmptyOrInvertedWindowIsNil() {
        XCTAssertNil(NightCoverage.summarize(hrTimestamps: [], rr: [], start: start, end: start))
        XCTAssertNil(NightCoverage.summarize(hrTimestamps: [], rr: [], start: start, end: start - 10))
    }

    func testFullyRecordedNightIsEnough() throws {
        let end = start + 2 * hour
        let s = try XCTUnwrap(NightCoverage.summarize(hrTimestamps: hrSeconds(start, end),
                                                      rr: beats(from: start, seconds: 2 * hour),
                                                      start: start, end: end))
        XCTAssertEqual(s.sleepSeconds, 2 * hour)
        XCTAssertEqual(s.hrSeconds, 2 * hour)
        XCTAssertEqual(s.hrHours, 2.0, accuracy: 1e-9)
        XCTAssertEqual(s.hrShare, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(s.rrShare, 0.99)
        XCTAssertEqual(s.totalWindows, 24)
        XCTAssertGreaterThanOrEqual(s.usableWindows, 22)   // clean synthetic beats: nearly every window passes
        XCTAssertEqual(s.verdict, .enough)
        XCTAssertEqual(NightCoverage.suggestedFixes(for: s), [])
    }

    func testHeartRateWithoutBeatsIsNoBeatToBeat() throws {
        let end = start + 6 * hour
        let s = try XCTUnwrap(NightCoverage.summarize(hrTimestamps: hrSeconds(start, end), rr: [],
                                                      start: start, end: end))
        XCTAssertEqual(s.rrBeats, 0)
        XCTAssertEqual(s.rrShare, 0)
        XCTAssertEqual(s.usableWindows, 0)
        XCTAssertEqual(s.verdict, .noBeatToBeat)
        XCTAssertEqual(NightCoverage.suggestedFixes(for: s), [.stayConnected, .wearSnug])
    }

    func testAlmostNoHeartRateIsNoHeartRate() throws {
        let end = start + 8 * hour
        // 10 minutes of heart rate in an 8-hour night: the strap did not record it.
        let s = try XCTUnwrap(NightCoverage.summarize(hrTimestamps: hrSeconds(start, start + 600), rr: [],
                                                      start: start, end: end))
        XCTAssertLessThan(s.hrShare, NightCoverage.minHeartRateShare)
        XCTAssertEqual(s.verdict, .noHeartRate)
        XCTAssertEqual(NightCoverage.suggestedFixes(for: s), [.stayConnected, .chargeStrap, .wearSnug])
    }

    func testAFewScatteredBeatsAreTooSparse() {
        let end = start + 4 * hour
        // 30 beats spread one per 7.5 minutes: enough intervals to count, never 120 s clean inside a window.
        let rr = (0..<30).map { RRInterval(ts: start + $0 * 450, rrMs: 900) }
        let s = NightCoverage.summarize(hrTimestamps: hrSeconds(start, end), rr: rr, start: start, end: end)
        XCTAssertEqual(s?.rrBeats, 30)
        XCTAssertEqual(s?.usableWindows, 0)
        XCTAssertEqual(s?.verdict, .tooSparse)
    }

    func testBeatsAreCountedOnlyInsideTheWindow() {
        let end = start + 1800
        let inside = beats(from: start, seconds: 1800)
        let outside = beats(from: start - 3600, seconds: 600, seed: 2) + beats(from: end + 60, seconds: 600, seed: 3)
        let s = NightCoverage.summarize(hrTimestamps: hrSeconds(start - 100, end + 100),
                                        rr: outside + inside, start: start, end: end)
        XCTAssertEqual(s?.rrBeats, inside.count)
        XCTAssertEqual(s?.hrSeconds, 1800)
    }

    func testRepeatedSecondsCountOnce() {
        let end = start + 600
        // Two heart-rate samples and three beats in the same second still cover one second.
        let s = NightCoverage.summarize(hrTimestamps: [start + 5, start + 5, start + 6],
                                        rr: [RRInterval(ts: start + 5, rrMs: 800),
                                             RRInterval(ts: start + 5, rrMs: 810),
                                             RRInterval(ts: start + 5, rrMs: 820)],
                                        start: start, end: end)
        XCTAssertEqual(s?.hrSeconds, 2)
        XCTAssertEqual(s?.rrBeats, 3)
        XCTAssertEqual(s?.rrSeconds, 1)
    }

    func testHalfTheNightWithBeatsGivesHalfTheShare() {
        let end = start + 2 * hour
        let s = NightCoverage.summarize(hrTimestamps: hrSeconds(start, end),
                                        rr: beats(from: start, seconds: hour), start: start, end: end)
        XCTAssertEqual(s?.rrShare ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(s?.verdict, .enough)
    }

    func testPartialLastWindowStillCounts() {
        let end = start + 5 * 60 + 100   // one full window plus 100 s
        let s = NightCoverage.summarize(hrTimestamps: [], rr: [], start: start, end: end)
        XCTAssertEqual(s?.totalWindows, 2)
    }

    // MARK: usableHrvNights

    func testUsableHrvNightsMatchesTheBaselinePredicate() {
        XCTAssertEqual(NightCoverage.usableHrvNights(nightlyHrv: [55, nil, 61, 4, 999]), 2)
        XCTAssertEqual(NightCoverage.usableHrvNights(nightlyHrv: []), 0)
        XCTAssertEqual(NightCoverage.usableHrvNights(nightlyHrv: [nil, nil]), 0)
    }

    func testUsableHrvNightsAgreesWithCalibrationNights() {
        let nights: [Double?] = [55, nil, 61, 4]
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: nights, hasRecovery: false),
                       NightCoverage.usableHrvNights(nightlyHrv: nights))
    }

    // MARK: suggestedFixes

    func testNoSleepSessionSuggestsEverything() {
        XCTAssertEqual(NightCoverage.suggestedFixes(for: nil), [.stayConnected, .chargeStrap, .wearSnug])
    }
}
