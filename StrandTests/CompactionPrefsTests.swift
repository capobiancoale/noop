import XCTest
@testable import Strand

final class CompactionPrefsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "compaction-prefs-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultIsNeverAndRejectsUnknownValues() {
        let d = freshDefaults()
        XCTAssertEqual(CompactionPrefs.keepFullResolutionDays(defaults: d), 0)
        CompactionPrefs.setKeepFullResolutionDays(90, defaults: d)
        XCTAssertEqual(CompactionPrefs.keepFullResolutionDays(defaults: d), 90)
        CompactionPrefs.setKeepFullResolutionDays(7, defaults: d)
        XCTAssertEqual(CompactionPrefs.keepFullResolutionDays(defaults: d), 0)
    }

    func testCutoffIsLocalMidnightKeepDaysAgo() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 15, minute: 30))!
        let cutoff = CompactionPrefs.cutoff(now: now, keepDays: 30, calendar: cal)
        let expected = cal.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        XCTAssertEqual(cutoff, Int(expected.timeIntervalSince1970))
        XCTAssertNil(CompactionPrefs.cutoff(now: now, keepDays: 0, calendar: cal))
        XCTAssertNil(CompactionPrefs.cutoff(now: now, keepDays: 7, calendar: cal))
    }

    func testRecordFinishedRunNeverMovesBackwards() {
        let d = freshDefaults()
        XCTAssertNil(CompactionPrefs.lastCompactedCutoff(defaults: d))
        CompactionPrefs.recordFinishedRun(cutoff: 2_000, defaults: d)
        CompactionPrefs.recordFinishedRun(cutoff: 1_000, defaults: d)
        XCTAssertEqual(CompactionPrefs.lastCompactedCutoff(defaults: d), 2_000)
        XCTAssertTrue(CompactionPrefs.userRanOnce(defaults: d))
    }

    func testAutoRunNeverDueWhileEngineGuardMissingOrWithoutManualRun() {
        let d = freshDefaults()
        CompactionPrefs.setKeepFullResolutionDays(30, defaults: d)
        XCTAssertFalse(CompactionPrefs.autoRunDue(now: Date(), defaults: d))   // no manual run yet
        CompactionPrefs.recordFinishedRun(cutoff: 1_000, defaults: d)
        // Due only when the engine guard is installed.
        XCTAssertEqual(CompactionPrefs.autoRunDue(now: Date(), defaults: d), CompactionPrefs.engineGuardInstalled)
        CompactionPrefs.markAutoRunAttempt(now: Date(), defaults: d)
        XCTAssertFalse(CompactionPrefs.autoRunDue(now: Date(), defaults: d))   // attempted < 24 h ago
    }

    func testClampedMaxDays() {
        let day = 86_400
        let nowMid = 100 * day
        XCTAssertEqual(CompactionPrefs.clampedMaxDays(4000, nowLocalMidnight: nowMid, lastCutoff: nil), 4000)
        XCTAssertEqual(CompactionPrefs.clampedMaxDays(4000, nowLocalMidnight: nowMid, lastCutoff: nowMid - 30 * day), 30)
        XCTAssertEqual(CompactionPrefs.clampedMaxDays(21, nowLocalMidnight: nowMid, lastCutoff: nowMid - 30 * day), 21)
        XCTAssertEqual(CompactionPrefs.clampedMaxDays(21, nowLocalMidnight: nowMid, lastCutoff: nowMid + day), 0)
    }
}
