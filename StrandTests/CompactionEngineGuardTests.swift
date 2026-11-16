import XCTest
import WhoopProtocol
@testable import Strand

/// Pins the compaction guard of `IntelligenceEngine.analyzeRecent`: the scoring window it derives from
/// `maxDays` is clamped by `scanWindow` so a full-history rescore (`maxDays: 4000`) never reaches a day at or
/// before the last compaction cutoff, and is untouched when nothing was ever compacted. Pure (no store).
final class CompactionEngineGuardTests: XCTestCase {
    private let day = 86_400
    private let tz = 2 * 3_600                       // an arbitrary non-UTC offset
    private let now = 1_800_000_000 + 13 * 3_600     // mid-day, so `now` is not a local midnight

    private var nowMid: Int { IntelligenceEngine.midnightLocal(now, offsetSec: tz) }

    /// Local midnight `n` days before today's.
    private func midnight(daysAgo n: Int) -> Int { nowMid - n * day }

    func testNoCutoffLeavesWindowUnchanged() {
        for requested in [1, 21, 120, 4000] {
            let w = IntelligenceEngine.scanWindow(requested: requested, now: now, tzOffset: tz, lastCutoff: nil)
            XCTAssertEqual(w.maxDays, requested)
            XCTAssertFalse(w.clamped)
        }
    }

    func testFullRescoreNeverReachesCompactedDays() {
        for keep in CompactionPrefs.choices where keep > 0 {
            let cutoff = midnight(daysAgo: keep)
            let w = IntelligenceEngine.scanWindow(requested: 4000, now: now, tzOffset: tz, lastCutoff: cutoff)
            XCTAssertTrue(w.clamped)
            XCTAssertGreaterThan(w.maxDays, 0)
            // Oldest scanned day starts at nowMid - (maxDays - 1) days.
            let oldestDayStart = nowMid - (w.maxDays - 1) * day
            XCTAssertGreaterThan(oldestDayStart, cutoff + day - 1, "day start must be after the cutoff day")
            // Its 30 h look-back (the scan reads from dayStart - 30 h) must stay in uncompacted rows.
            XCTAssertGreaterThanOrEqual(oldestDayStart - 30 * 3_600, cutoff)
            // windowStart floor used by the reconciles is the oldest scanned midnight, also after the cutoff.
            XCTAssertGreaterThan(nowMid - (w.maxDays - 1) * day, cutoff)
        }
    }

    func testRegularWindowIsNotShortenedWhenCutoffIsOlder() {
        let cutoff = midnight(daysAgo: 30)
        let w = IntelligenceEngine.scanWindow(requested: 21, now: now, tzOffset: tz, lastCutoff: cutoff)
        XCTAssertEqual(w.maxDays, 21)
        XCTAssertFalse(w.clamped, "the normal 21-day pass must be byte-identical after a 30-day compaction")
    }

    func testCutoffTooCloseLeavesNothingToScan() {
        let w = IntelligenceEngine.scanWindow(requested: 21, now: now, tzOffset: tz, lastCutoff: nowMid)
        XCTAssertEqual(w.maxDays, 0)
        XCTAssertTrue(w.clamped)
        let future = IntelligenceEngine.scanWindow(requested: 21, now: now, tzOffset: tz, lastCutoff: nowMid + day)
        XCTAssertEqual(future.maxDays, 0)
    }

    func testClampNeverExceedsRequested() {
        let w = IntelligenceEngine.scanWindow(requested: 10, now: now, tzOffset: tz,
                                              lastCutoff: midnight(daysAgo: 180))
        XCTAssertEqual(w.maxDays, 10)
        XCTAssertFalse(w.clamped)
    }

    // MARK: - Timeline resolution label

    func testMedianSpacing() {
        XCTAssertNil(Repository.medianSpacingSeconds([]))
        XCTAssertNil(Repository.medianSpacingSeconds([5]))
        XCTAssertEqual(Repository.medianSpacingSeconds(Array(0..<100)), 1)
        XCTAssertEqual(Repository.medianSpacingSeconds((0..<100).map { $0 * 60 }), 60)
        // Mostly 1 Hz with one big gap: the median stays 1 s.
        XCTAssertEqual(Repository.medianSpacingSeconds(Array(0..<50) + Array(5_000..<5_050)), 1)
    }

    func testRawZoomOverMinuteHeartRateIsLabelledOneMinute() {
        let minute = Repository.rawTimelineResolution(
            medianSpacingSeconds: Repository.medianSpacingSeconds((0..<200).map { $0 * 60 }))
        XCTAssertFalse(minute.isRaw)
        XCTAssertEqual(minute.bucketSeconds, 60)

        let perSecond = Repository.rawTimelineResolution(
            medianSpacingSeconds: Repository.medianSpacingSeconds(Array(0..<200)))
        XCTAssertTrue(perSecond.isRaw)
        XCTAssertEqual(perSecond.bucketSeconds, 1)

        // Threshold: 50 s is minute-like, 49 s is not; no spacing keeps the raw label.
        XCTAssertFalse(Repository.rawTimelineResolution(medianSpacingSeconds: 50).isRaw)
        XCTAssertTrue(Repository.rawTimelineResolution(medianSpacingSeconds: 49).isRaw)
        XCTAssertTrue(Repository.rawTimelineResolution(medianSpacingSeconds: nil).isRaw)
    }
}
