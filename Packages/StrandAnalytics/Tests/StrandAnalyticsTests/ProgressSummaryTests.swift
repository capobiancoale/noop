import XCTest
@testable import StrandAnalytics

final class ProgressSummaryTests: XCTestCase {
    private let today = "2026-11-16"

    /// `n` consecutive days ending `endOffset` days before today, all with `value`.
    private func points(n: Int, endOffset: Int, value: Double) -> [ProgressSummary.Point] {
        let t = ProgressSummary.dayNumber(today)!
        return (0..<n).map { i in
            ProgressSummary.Point(day: Self.key(t - endOffset - i), value: value)
        }
    }

    private static func key(_ n: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(n) * 86_400)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func testDayNumberMatchesCalendar() {
        XCTAssertEqual(ProgressSummary.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(ProgressSummary.dayNumber("2026-11-16"), 20_773)
        XCTAssertEqual(ProgressSummary.dayNumber("2024-03-01")! - ProgressSummary.dayNumber("2024-02-28")!, 2)
        XCTAssertNil(ProgressSummary.dayNumber("nope"))
    }

    func testBetterWorseStable() {
        let up = points(n: 28, endOffset: 0, value: 70) + points(n: 28, endOffset: 28, value: 60)
        let r = ProgressSummary.row(metric: .recovery, points: up, today: today, windowDays: 28)
        XCTAssertEqual(r?.value ?? 0, 70, accuracy: 1e-9)
        XCTAssertEqual(r?.change ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(r?.direction, .better)

        let down = points(n: 28, endOffset: 0, value: 400) + points(n: 28, endOffset: 28, value: 430)
        XCTAssertEqual(ProgressSummary.row(metric: .sleep, points: down, today: today, windowDays: 28)?.direction, .worse)

        let flat = points(n: 28, endOffset: 0, value: 64) + points(n: 28, endOffset: 28, value: 62)
        XCTAssertEqual(ProgressSummary.row(metric: .recovery, points: flat, today: today, windowDays: 28)?.direction, .stable)
    }

    func testBandBoundaries() {
        XCTAssertEqual(ProgressSummary.direction(metric: .sleep, change: 9.9), .stable)
        XCTAssertEqual(ProgressSummary.direction(metric: .sleep, change: 10), .better)
        XCTAssertEqual(ProgressSummary.direction(metric: .sleep, change: -10), .worse)
        XCTAssertEqual(ProgressSummary.direction(metric: .engine, change: 0.4), .stable)
        XCTAssertEqual(ProgressSummary.direction(metric: .glucose, change: 2), .better)
        XCTAssertEqual(ProgressSummary.direction(metric: .strength, change: -2.5), .worse)
        XCTAssertEqual(ProgressSummary.direction(metric: .recovery, change: 2.9), .stable)
    }

    func testTooLittleDataIsNil() {
        // 6 values in the current window, 28 in the previous: below the 7-value minimum.
        let p = points(n: 6, endOffset: 0, value: 60) + points(n: 28, endOffset: 28, value: 60)
        XCTAssertNil(ProgressSummary.row(metric: .recovery, points: p, today: today, windowDays: 28))
        // Nothing in the previous window.
        XCTAssertNil(ProgressSummary.row(metric: .recovery, points: points(n: 28, endOffset: 0, value: 60),
                                         today: today, windowDays: 28))
        XCTAssertNil(ProgressSummary.row(metric: .recovery, points: [], today: today, windowDays: 28))
    }

    func testStrengthNeedsTwoEntriesPerWindow() {
        let one = [ProgressSummary.Point(day: "2026-11-10", value: 100),
                   ProgressSummary.Point(day: "2026-08-20", value: 90)]
        XCTAssertNil(ProgressSummary.row(metric: .strength, points: one, today: today, windowDays: 84))
        let two = one + [ProgressSummary.Point(day: "2026-11-01", value: 110),
                         ProgressSummary.Point(day: "2026-08-10", value: 90)]
        let r = ProgressSummary.row(metric: .strength, points: two, today: today, windowDays: 84)
        XCTAssertEqual(r?.value ?? 0, 105, accuracy: 1e-9)
        XCTAssertEqual(r?.previous ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(r?.direction, .better)
    }

    func testWindowEdges() {
        // A value exactly windowDays ago belongs to the previous window, not the current one.
        let t = ProgressSummary.dayNumber(today)!
        var p = points(n: 7, endOffset: 0, value: 50)
        p += (0..<7).map { ProgressSummary.Point(day: Self.key(t - 28 - $0), value: 50) }
        let r = ProgressSummary.row(metric: .recovery, points: p, today: today, windowDays: 28)
        XCTAssertEqual(r?.currentCount, 7)
        XCTAssertEqual(r?.previousCount, 7)
    }

    func testSeriesIsThinned() {
        let p = points(n: 365, endOffset: 0, value: 60) + points(n: 365, endOffset: 365, value: 60)
        let r = ProgressSummary.row(metric: .recovery, points: p, today: today, windowDays: 365)
        XCTAssertEqual(r?.series.count, ProgressSummary.maxSeriesPoints)
    }

    private func row(_ m: ProgressSummary.Metric, _ d: ProgressSummary.Direction) -> ProgressSummary.Row {
        ProgressSummary.Row(metric: m, value: 1, previous: 1, change: 0, direction: d, series: [],
                            currentCount: 7, previousCount: 7)
    }

    func testSummaryKeys() {
        XCTAssertEqual(ProgressSummary.summaryKey([]), .notEnoughData)
        XCTAssertEqual(ProgressSummary.summaryKey([row(.sleep, .better), row(.engine, .better)]), .allBetter)
        XCTAssertEqual(ProgressSummary.summaryKey([row(.sleep, .worse)]), .allWorse)
        XCTAssertEqual(ProgressSummary.summaryKey([row(.sleep, .stable), row(.engine, .stable)]), .allStable)
        XCTAssertEqual(ProgressSummary.summaryKey([row(.sleep, .stable), row(.engine, .better)]), .betterOnly([.engine]))
        XCTAssertEqual(ProgressSummary.summaryKey([row(.sleep, .worse), row(.engine, .stable)]), .worseOnly([.sleep]))
        XCTAssertEqual(ProgressSummary.summaryKey([row(.sleep, .worse), row(.strength, .better), row(.engine, .better)]),
                       .mixed(better: [.strength, .engine], worse: [.sleep]))
    }

    func testCurrentOnlyWhenThePeriodBeforeIsEmpty() {
        // Two strength entries in the last 28 days, nothing before: no comparison, but a value.
        let pts = [ProgressSummary.Point(day: "2026-11-01", value: 100),
                   ProgressSummary.Point(day: "2026-11-10", value: 110)]
        XCTAssertNil(ProgressSummary.row(metric: .strength, points: pts, today: "2026-11-16", windowDays: 28))
        let c = ProgressSummary.currentOnly(metric: .strength, points: pts, today: "2026-11-16", windowDays: 28)
        XCTAssertEqual(c?.value, 105)
        // One entry is below the strength minimum of two: nothing.
        XCTAssertNil(ProgressSummary.currentOnly(metric: .strength, points: [pts[0]], today: "2026-11-16",
                                                 windowDays: 28))
    }
}
