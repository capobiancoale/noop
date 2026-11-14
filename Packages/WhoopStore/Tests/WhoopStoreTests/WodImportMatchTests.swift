import XCTest
@testable import WhoopStore

final class WodImportMatchTests: XCTestCase {
    private func row(_ id: String, day: String, title: String) -> WodLogRow {
        WodLogRow(id: id, ts: 1, day: day, type: "CrossFit", title: title, createdTs: 1)
    }

    func testSplitsByDayAndTitleIgnoringCaseAndSpaces() {
        let existing = [row("e1", day: "2026-03-01", title: "Fran")]
        let imported = [row("i1", day: "2026-03-01", title: "  fran "),
                        row("i2", day: "2026-03-02", title: "Fran"),
                        row("i3", day: "2026-03-01", title: "Cindy")]
        let s = WodImportMatch.split(imported: imported, existing: existing)
        XCTAssertEqual(s.duplicates.map(\.id), ["i1"])
        XCTAssertEqual(s.fresh.map(\.id), ["i2", "i3"])
    }

    func testEmptyExistingKeepsEverything() {
        let imported = [row("i1", day: "2026-03-01", title: "Fran")]
        let s = WodImportMatch.split(imported: imported, existing: [])
        XCTAssertEqual(s.fresh.count, 1)
        XCTAssertTrue(s.duplicates.isEmpty)
    }
}
