import XCTest
@testable import StrandAnalytics

final class DayFreshnessTests: XCTestCase {

    func testSameDayIsZero() {
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2026-11-15", referenceKey: "2026-11-15"), 0)
        XCTAssertEqual(DayFreshness.label(dayKey: "2026-11-15", referenceKey: "2026-11-15"), .sameDay)
    }

    func testYesterdayAcrossMonthAndYearBoundaries() {
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2026-10-31", referenceKey: "2026-11-01"), 1)
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2025-12-31", referenceKey: "2026-01-01"), 1)
        XCTAssertEqual(DayFreshness.label(dayKey: "2026-10-31", referenceKey: "2026-11-01"), .yesterday)
    }

    func testLeapDayCountsAsACalendarDay() {
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2024-02-28", referenceKey: "2024-03-01"), 2)
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2025-02-28", referenceKey: "2025-03-01"), 1)
        XCTAssertNil(DayFreshness.ageInDays(dayKey: "2025-02-29", referenceKey: "2025-03-01"))
    }

    func testDaysAgoThenDate() {
        XCTAssertEqual(DayFreshness.label(dayKey: "2026-11-13", referenceKey: "2026-11-15"), .daysAgo(2))
        XCTAssertEqual(DayFreshness.label(dayKey: "2026-11-09", referenceKey: "2026-11-15"), .daysAgo(6))
        XCTAssertEqual(DayFreshness.label(dayKey: "2026-11-08", referenceKey: "2026-11-15"), .onDate)
    }

    func testFutureAndGarbage() {
        XCTAssertEqual(DayFreshness.label(dayKey: "2026-11-16", referenceKey: "2026-11-15"), .future)
        XCTAssertEqual(DayFreshness.label(dayKey: "nope", referenceKey: "2026-11-15"), .unknown)
        XCTAssertNil(DayFreshness.ageInDays(dayKey: "2026-13-01", referenceKey: "2026-11-15"))
        XCTAssertNil(DayFreshness.ageInDays(dayKey: "2026-1-01", referenceKey: "2026-11-15"))
    }

    func testDaylightSavingDoesNotShiftTheCount() {
        // Calendar-day arithmetic, so the 23 h / 25 h days around a clock change still count as one day.
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2026-03-28", referenceKey: "2026-03-30"), 2)
        XCTAssertEqual(DayFreshness.ageInDays(dayKey: "2026-10-24", referenceKey: "2026-10-26"), 2)
    }
}
