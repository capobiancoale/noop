import XCTest
@testable import StrandImport

final class HealthWritePlanTests: XCTestCase {

    private let now = 1_790_000_000.0 + 37            // mid-minute on purpose

    // MARK: Heart rate

    func testTheFirstRunReachesBackTwoWeeksUpToTheLastSettledMinute() throws {
        let w = try XCTUnwrap(HealthWritePlan.heartRateWindow(now: now, newestWritten: nil))
        XCTAssertEqual(w.to.truncatingRemainder(dividingBy: 60), 0)
        XCTAssertLessThanOrEqual(w.to, now - HealthWritePlan.settleSeconds)
        XCTAssertGreaterThan(w.to, now - HealthWritePlan.settleSeconds - 60)
        XCTAssertEqual(w.to - w.from, 14 * 86_400)
    }

    func testLaterRunsLookBackThreeDaysBehindTheNewestMinuteWritten() throws {
        let newest = now - 3_600
        let w = try XCTUnwrap(HealthWritePlan.heartRateWindow(now: now, newestWritten: newest))
        XCTAssertEqual(w.from, ((newest - 72 * 3_600) / 60).rounded(.down) * 60)
        // Written long ago: never further back than the first run's two weeks.
        let old = try XCTUnwrap(HealthWritePlan.heartRateWindow(now: now, newestWritten: now - 60 * 86_400))
        XCTAssertEqual(old.to - old.from, 14 * 86_400)
    }

    func testChunksCoverTheWindowWithoutGapsOrOverlaps() {
        let c = HealthWritePlan.chunks(from: 0, to: 2.5 * 86_400)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.first?.from, 0)
        XCTAssertEqual(c.last?.to, 2.5 * 86_400)
        for (a, b) in zip(c, c.dropFirst()) { XCTAssertEqual(a.to, b.from) }
        XCTAssertTrue(HealthWritePlan.chunks(from: 10, to: 10).isEmpty)
    }

    func testOnlyMinutesNotYetInHealthAndPlausibleAreWritten() {
        let strap: [(ts: Double, bpm: Double)] = [(180, 62), (0, 60), (60, 61), (120, 300), (240, 20), (300, 64)]
        let missing = HealthWritePlan.missingMinutes(strap, alreadyWritten: [1])      // minute 1 = ts 60..119
        XCTAssertEqual(missing.map(\.ts), [0, 180, 300])
        XCTAssertEqual(missing.map(\.bpm), [60, 62, 64])
    }

    // MARK: Sleep

    func testANightIsInBedPlusItsStagesClippedToItsSpan() {
        let json = """
        [{"start":900,"end":1500,"stage":"light"},{"start":1500,"end":2100,"stage":"deep"},
         {"start":2100,"end":2400,"stage":"rem"},{"start":2400,"end":2700,"stage":"wake"},
         {"start":2700,"end":3300,"stage":"light"},{"start":3300,"end":3400,"stage":"unknown"}]
        """
        // The onset was corrected to 1000 and the night ends at 3000.
        let segs = HealthWritePlan.sleepSegments(start: 1_000, end: 3_000, stagesJSON: json)
        XCTAssertEqual(segs.first, .init(start: 1_000, end: 3_000, kind: .inBed))
        XCTAssertEqual(Array(segs.dropFirst()), [
            .init(start: 1_000, end: 1_500, kind: .core), .init(start: 1_500, end: 2_100, kind: .deep),
            .init(start: 2_100, end: 2_400, kind: .rem), .init(start: 2_400, end: 2_700, kind: .awake),
            .init(start: 2_700, end: 3_000, kind: .core),
        ])
    }

    func testANightKnownOnlyByItsTotalsIsInBedOnly() {
        let totals = #"{"light":200,"deep":80,"rem":90,"awake":30}"#
        XCTAssertEqual(HealthWritePlan.sleepSegments(start: 0, end: 28_800, stagesJSON: totals),
                       [.init(start: 0, end: 28_800, kind: .inBed)])
        XCTAssertEqual(HealthWritePlan.sleepSegments(start: 0, end: 100, stagesJSON: nil).count, 1)
        XCTAssertTrue(HealthWritePlan.sleepSegments(start: 100, end: 100, stagesJSON: nil).isEmpty)
    }

    func testTheFingerprintChangesWhenTheNightChangesAndIsStable() {
        let a = HealthWritePlan.sleepFingerprint(start: 1_000, end: 3_000, stagesJSON: "[1]")
        XCTAssertEqual(a, HealthWritePlan.sleepFingerprint(start: 1_000, end: 3_000, stagesJSON: "[1]"))
        XCTAssertNotEqual(a, HealthWritePlan.sleepFingerprint(start: 1_000, end: 3_600, stagesJSON: "[1]"))
        XCTAssertNotEqual(a, HealthWritePlan.sleepFingerprint(start: 1_000, end: 3_000, stagesJSON: "[2]"))
        XCTAssertEqual(HealthWritePlan.fnv1a(""), "cbf29ce484222325")          // the FNV-1a offset basis
        XCTAssertEqual(HealthWritePlan.fnv1a("a"), "af63dc4c8601ec8c")         // published FNV-1a 64 vector
        let span = HealthWritePlan.span(ofFingerprint: a)
        XCTAssertEqual(span?.start, 1_000)
        XCTAssertEqual(span?.end, 3_000)
        XCTAssertNil(HealthWritePlan.span(ofFingerprint: "nonsense"))
    }

    // MARK: Daily values

    func testADailyValueIsNeverDatedInTheFuture() {
        XCTAssertEqual(HealthWritePlan.sampleDate(noon: now - 3_600, now: now), now - 3_600)
        XCTAssertEqual(HealthWritePlan.sampleDate(noon: now + 3_600, now: now), now - 60)
    }
}
