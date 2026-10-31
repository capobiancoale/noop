import XCTest
@testable import StrandImport

final class HealthImportPlanTests: XCTestCase {

    private var rome: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        rome.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Windows are newest first, contiguous (each ends where the next newer one starts), start at local
    /// midnight, and together cover exactly [floor, to).
    private func assertTiles(_ w: [HealthImportWindow], from: Date, to: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(w.isEmpty, file: file, line: line)
        XCTAssertEqual(w.first?.end, to, file: file, line: line)
        XCTAssertEqual(w.last?.start, rome.startOfDay(for: from), file: file, line: line)
        for (a, b) in zip(w, w.dropFirst()) { XCTAssertEqual(b.end, a.start, file: file, line: line) }
        for x in w {
            XCTAssertEqual(rome.startOfDay(for: x.start), x.start, "window starts at local midnight", file: file, line: line)
            XCTAssertLessThan(x.start, x.end, file: file, line: line)
            let days = rome.dateComponents([.day], from: x.start, to: rome.startOfDay(for: x.end.addingTimeInterval(-1))).day! + 1
            XCTAssertLessThanOrEqual(days, HealthImportPlan.windowDays, file: file, line: line)
        }
    }

    func testNewestWindowHoldsTodayPlusTheWholeDaysBefore() {
        let now = date(2026, 9, 24, 15, 30)
        let w = HealthImportPlan.windows(from: date(2026, 1, 1), to: now, isHistory: false, calendar: rome)
        assertTiles(w, from: date(2026, 1, 1), to: now)
        XCTAssertEqual(w[0].start, date(2026, 8, 26))            // 29 whole days + today = 30 days
        XCTAssertEqual(w[1].start, date(2026, 7, 27))
        XCTAssertEqual(w[1].end, date(2026, 8, 26))
    }

    func testWindowsAcrossDaylightSavingStayMidnightAligned() {
        // Europe/Rome leaves summer time on 25 Oct 2026 (a 25-hour day).
        let now = date(2026, 11, 20, 9)
        let w = HealthImportPlan.windows(from: date(2026, 9, 1), to: now, isHistory: true, calendar: rome)
        assertTiles(w, from: date(2026, 9, 1), to: now)
        XCTAssertTrue(w.allSatisfy(\.isHistory))
    }

    func testNothingToPlanWhenTheRangeIsEmpty() {
        let now = date(2026, 9, 24, 10)
        XCTAssertTrue(HealthImportPlan.windows(from: now, to: date(2026, 9, 24), isHistory: false, calendar: rome).isEmpty)
    }

    func testFirstImportReadsTheLastNinetyDaysFirstThenTheHistory() {
        let now = date(2026, 9, 24, 15)
        let plan = HealthImportPlan.plan(now: now, routineDays: HealthImportPlan.recentDays, includeHistory: true,
                                         historyDone: false, historySavedFrom: nil, calendar: rome)
        let recent = plan.filter { !$0.isHistory }, history = plan.filter(\.isHistory)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.last?.start, date(2026, 6, 27))    // 90 calendar days, today included
        XCTAssertEqual(history.first?.end, recent.last?.start)   // history continues right below
        XCTAssertEqual(history.last?.start, HealthImportPlan.historyTarget(now: now, calendar: rome))
        XCTAssertEqual(Array(plan.prefix(3)), recent, "recent windows come first")
    }

    func testAnInterruptedHistoryImportResumesBelowWhatWasSaved() {
        let now = date(2026, 9, 24, 15)
        let saved = date(2026, 3, 1)
        let plan = HealthImportPlan.plan(now: now, routineDays: HealthImportPlan.recentDays, includeHistory: true,
                                         historyDone: false, historySavedFrom: saved, calendar: rome)
        let history = plan.filter(\.isHistory)
        XCTAssertEqual(history.first?.end, saved)
        XCTAssertEqual(history.last?.start, HealthImportPlan.historyTarget(now: now, calendar: rome))
    }

    func testNoHistoryWindowsWhenDoneOrExcluded() {
        let now = date(2026, 9, 24, 15)
        for (done, include) in [(true, true), (false, false)] {
            let plan = HealthImportPlan.plan(now: now, routineDays: 7, includeHistory: include, historyDone: done,
                                             historySavedFrom: nil, calendar: rome)
            XCTAssertEqual(plan.count, 1)
            XCTAssertFalse(plan[0].isHistory)
            XCTAssertEqual(plan[0].start, date(2026, 9, 18))       // 7 calendar days, today included
        }
    }

    func testAutomaticRefreshReadsNinetyDaysUnlessARecentFullRefreshExists() {
        let now = date(2026, 9, 24, 15)
        XCTAssertEqual(HealthImportPlan.automaticRefreshDays(lastFullRefresh: nil, now: now), 90)
        XCTAssertEqual(HealthImportPlan.automaticRefreshDays(lastFullRefresh: now.addingTimeInterval(-3_600), now: now), 7)
        // Once a day: seven hours after a full refresh is still a catch-up, a day later a full one.
        XCTAssertEqual(HealthImportPlan.automaticRefreshDays(lastFullRefresh: now.addingTimeInterval(-7 * 3_600), now: now), 7)
        XCTAssertEqual(HealthImportPlan.automaticRefreshDays(lastFullRefresh: now.addingTimeInterval(-25 * 3_600), now: now), 90)
        // A timestamp in the future (clock changed) doesn't suppress the full refresh.
        XCTAssertEqual(HealthImportPlan.automaticRefreshDays(lastFullRefresh: now.addingTimeInterval(3_600), now: now), 90)
    }

    func testOpeningNOOPAgainSoonAfterAnUpdateDoesNotReadAppleHealthAgain() {
        let now = date(2026, 9, 24, 15)
        // Nothing finished since launch: update.
        XCTAssertTrue(HealthImportPlan.foregroundSyncDue(now: now, lastFinished: nil, historyDone: true))
        // Two minutes after the last one: skip; ten minutes after: update.
        XCTAssertFalse(HealthImportPlan.foregroundSyncDue(now: now, lastFinished: now.addingTimeInterval(-120), historyDone: true))
        XCTAssertTrue(HealthImportPlan.foregroundSyncDue(now: now, lastFinished: now.addingTimeInterval(-600), historyDone: true))
        // The history import carries on at every opening until it is complete.
        XCTAssertTrue(HealthImportPlan.foregroundSyncDue(now: now, lastFinished: now.addingTimeInterval(-120), historyDone: false))
        // A finish time in the future (clock changed) doesn't hold updates back.
        XCTAssertTrue(HealthImportPlan.foregroundSyncDue(now: now, lastFinished: now.addingTimeInterval(3_600), historyDone: true))
    }

    func testHistoryProgressAndCompletion() {
        let now = date(2026, 9, 24, 15)
        let target = HealthImportPlan.historyTarget(now: now, calendar: rome)!
        XCTAssertEqual(HealthImportPlan.historyFraction(savedFrom: nil, now: now, calendar: rome), 0)
        XCTAssertEqual(HealthImportPlan.historyFraction(savedFrom: target, now: now, calendar: rome), 1, accuracy: 1e-9)
        let half = rome.date(byAdding: .day, value: -215, to: rome.startOfDay(for: now))!
        XCTAssertEqual(HealthImportPlan.historyFraction(savedFrom: half, now: now, calendar: rome), 0.5, accuracy: 0.01)
        XCTAssertTrue(HealthImportPlan.historyComplete(savedFrom: target, now: now, calendar: rome))
        XCTAssertFalse(HealthImportPlan.historyComplete(savedFrom: half, now: now, calendar: rome))
    }
}
