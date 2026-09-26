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

    func testRunsBetweenDeepOnesLookBackTwoHoursOnly() throws {
        let newest = now - 3_600
        let w = try XCTUnwrap(HealthWritePlan.heartRateWindow(now: now, newestWritten: newest, deep: false))
        XCTAssertEqual(w.from, ((newest - 2 * 3_600) / 60).rounded(.down) * 60)
        XCTAssertEqual(w.to, try XCTUnwrap(HealthWritePlan.heartRateWindow(now: now, newestWritten: newest)).to)
        // The first run is the two weeks' backfill either way.
        let first = try XCTUnwrap(HealthWritePlan.heartRateWindow(now: now, newestWritten: nil, deep: false))
        XCTAssertEqual(first.to - first.from, 14 * 86_400)
    }

    func testADeepRunComesEverySixHours() {
        XCTAssertTrue(HealthWritePlan.deepHeartRateRunDue(now: now, lastDeep: nil))
        XCTAssertFalse(HealthWritePlan.deepHeartRateRunDue(now: now, lastDeep: now - 3_600))
        XCTAssertTrue(HealthWritePlan.deepHeartRateRunDue(now: now, lastDeep: now - 6 * 3_600))
        XCTAssertTrue(HealthWritePlan.deepHeartRateRunDue(now: now, lastDeep: now + 60))        // clock moved back
    }

    // MARK: When to write

    func testAutomaticWritesRunAtMostEveryQuarterOfAnHour() {
        XCTAssertTrue(HealthWritePlan.writeDue(now: now, lastWrite: nil))
        XCTAssertFalse(HealthWritePlan.writeDue(now: now, lastWrite: now - 60))
        XCTAssertFalse(HealthWritePlan.writeDue(now: now, lastWrite: now - 14 * 60))
        XCTAssertTrue(HealthWritePlan.writeDue(now: now, lastWrite: now - 15 * 60))
        XCTAssertTrue(HealthWritePlan.writeDue(now: now, lastWrite: now + 600))              // clock moved back
    }

    // MARK: Daily values

    func testOnlyNewOrChangedDailyValuesAreWrittenAgain() {
        let candidates: [(key: String, value: Double)] = [
            (key: "noop:my-whoop:rhr:2026-09-24", value: 52),
            (key: "noop:my-whoop:rhr:2026-09-25", value: 51),
            (key: "noop:my-whoop:hrv:2026-09-25", value: 61.25),
            (key: "noop:my-whoop:hrv:2026-09-26", value: 58),
        ]
        let written: [String: Double] = [
            "noop:my-whoop:rhr:2026-09-24": 52,              // same
            "noop:my-whoop:rhr:2026-09-25": 53,              // changed
            "noop:my-whoop:hrv:2026-09-25": 61.25 + 1e-12,   // same, to rounding
        ]
        XCTAssertEqual(HealthWritePlan.changedDailyValues(candidates, written: written),
                       ["noop:my-whoop:rhr:2026-09-25", "noop:my-whoop:hrv:2026-09-26"])
        XCTAssertEqual(HealthWritePlan.changedDailyValues(candidates, written: [:]).count, 4)
        XCTAssertTrue(HealthWritePlan.changedDailyValues([], written: written).isEmpty)
    }

    func testTheRecordOfWrittenValuesForgetsOldDays() {
        let written: [String: Double] = [
            "noop:my-whoop:rhr:2026-05-01": 50,
            "noop:my-whoop:rhr:2026-06-01": 51,
            "noop:my-whoop:vo2:2026-09-25": 44,
            "garbage": 1,
        ]
        XCTAssertEqual(Set(HealthWritePlan.prunedDailyWritten(written, oldestDay: "2026-06-01").keys),
                       ["noop:my-whoop:rhr:2026-06-01", "noop:my-whoop:vo2:2026-09-25"])
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

final class HealthWritePlanWorkoutTests: XCTestCase {

    private let now = 1_790_000_000.0
    private func span(_ startH: Double, _ minutes: Double) -> HealthWritePlan.WorkoutSpan {
        let s = now - startH * 3_600
        return .init(start: s, end: s + minutes * 60)
    }

    func testAWodMatchingAStrapWorkoutBecomesThatWorkout() {
        let own = [span(5, 40), span(30, 60)]
        let wod = HealthWritePlan.WodEntry(id: "fran", loggedTs: own[0].start + 300, durationS: 600)
        let plan = HealthWritePlan.workouts(own: own, others: [], wods: [wod], now: now)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.first(where: { $0.ownIndex == 0 })?.wodIds, ["fran"])
        XCTAssertEqual(plan.first(where: { $0.ownIndex == 1 })?.wodIds, [])
        XCTAssertEqual(plan.map(\.start), plan.map(\.start).sorted())
    }

    func testAWodWithNoRecordedWorkoutIsWrittenOverItsLoggedTime() {
        let wod = HealthWritePlan.WodEntry(id: "cindy", loggedTs: now - 3 * 3_600, durationS: 1_200)
        let plan = HealthWritePlan.workouts(own: [], others: [], wods: [wod], now: now)
        XCTAssertEqual(plan, [.init(start: now - 3 * 3_600, end: now - 3 * 3_600 + 1_200, ownIndex: nil, wodIds: ["cindy"])])
    }

    func testSessionsAppleHealthAlreadyHasAreLeftOut() {
        let watch = span(5, 45)
        let own = [span(5, 40)]                                   // the same session, from the strap
        let wod = HealthWritePlan.WodEntry(id: "murph", loggedTs: watch.start + 60, durationS: 2_400)
        let plan = HealthWritePlan.workouts(own: own, others: [watch], wods: [wod], now: now)
        XCTAssertTrue(plan.isEmpty, "\(plan)")
    }

    func testShortRunningOrOldBoutsAreNotWritten() {
        let short = span(5, 3)
        let running = HealthWritePlan.WorkoutSpan(start: now - 1_200, end: now - 60)   // ended a minute ago
        let old = span(24 * 20, 60)
        let plan = HealthWritePlan.workouts(own: [short, running, old], others: [], wods: [], now: now)
        XCTAssertTrue(plan.isEmpty)
    }

    func testTwoWodsInOneSessionShareTheWorkout() {
        let own = [span(5, 60)]
        let a = HealthWritePlan.WodEntry(id: "a", loggedTs: own[0].start + 600, durationS: 600)
        let b = HealthWritePlan.WodEntry(id: "b", loggedTs: own[0].start + 2_400, durationS: 600)
        let plan = HealthWritePlan.workouts(own: own, others: [], wods: [b, a], now: now)
        XCTAssertEqual(plan.map(\.wodIds), [["a", "b"]])
    }

    func testZoneMinutesCountEachMinuteInItsZone() {
        // Floors for a max of 200: 100, 120, 140, 160, 180.
        let floors = [100.0, 120, 140, 160, 180]
        XCTAssertEqual(HealthWritePlan.zoneMinutes(bpm: [90, 100, 125, 139, 150, 170, 185, 199], zoneFloors: floors),
                       [1, 1, 2, 1, 1, 2])
    }

    func testFingerprintsDifferWhenAPartChanges() {
        XCTAssertEqual(HealthWritePlan.fingerprint(["a", "b"]), HealthWritePlan.fingerprint(["a", "b"]))
        XCTAssertNotEqual(HealthWritePlan.fingerprint(["a", "b"]), HealthWritePlan.fingerprint(["a", "c"]))
    }
}

final class HealthWritePlanZoneTests: XCTestCase {
    func testZoneFloorsAreTenthsOfTheMaxFromHalf() {
        XCTAssertEqual(HealthWritePlan.zoneFloors(maxHR: 200), [100, 120, 140, 160, 180])
        XCTAssertTrue(HealthWritePlan.zoneFloors(maxHR: 0).isEmpty)
    }
}
