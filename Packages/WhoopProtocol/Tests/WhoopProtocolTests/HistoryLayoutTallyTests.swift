import XCTest
@testable import WhoopProtocol

final class HistoryLayoutTallyTests: XCTestCase {

    private func t(_ x: Double) -> String { "t\(Int(x))" }

    func testEmptyTallySaysNothingCounted() {
        XCTAssertEqual(HistoryLayoutTally().summaryLine(formatTime: t), "History layouts: none counted yet.")
    }

    func testCountsEveryRecordAndFlagsMissingOpticalLayouts() {
        var tally = HistoryLayoutTally()
        tally.record(versions: [18, 18, 26], at: 100)
        tally.record(versions: [], at: 150)
        tally.record(versions: [18], at: 200)
        XCTAssertEqual(tally.counts, [18: 3, 26: 1])
        XCTAssertEqual(tally.since, 100)
        XCTAssertEqual(tally.summaryLine(formatTime: t),
                       "History layouts since t100: v18 3 (last t200), v26 1 (last t100). No v20/v21 optical records yet.")
    }

    func testOpticalLayoutDropsTheWarning() {
        var tally = HistoryLayoutTally()
        tally.record(versions: [18, 21], at: 100)
        XCTAssertEqual(tally.summaryLine(formatTime: t),
                       "History layouts since t100: v18 1 (last t100), v21 1 (last t100).")
    }

    func testSurvivesAJsonRoundTrip() throws {
        var tally = HistoryLayoutTally()
        tally.record(versions: [18, 20, 20], at: 42)
        let back = try JSONDecoder().decode(HistoryLayoutTally.self, from: JSONEncoder().encode(tally))
        XCTAssertEqual(back, tally)
    }
}
