import XCTest
@testable import WhoopStore

final class WodRankingTests: XCTestCase {
    private func row(_ id: String, ts: Int = 1_000, title: String = "Fran", kind: WodResultKind = .time,
                     secs: Int? = nil, rounds: Int? = nil, reps: Int? = nil, kg: Double? = nil,
                     rx: Bool? = nil) -> WodLogRow {
        WodLogRow(id: id, ts: ts, day: "2026-01-01", type: "CrossFit", title: title, resultKind: kind,
                  resultSeconds: secs, resultRounds: rounds, resultReps: reps, resultWeightKg: kg,
                  rx: rx, createdTs: ts)
    }

    func testZeroTimeIsNoResult() {
        let r = row("a", secs: 0)
        XCTAssertEqual(r.effectiveResultKind, .none)
        XCTAssertFalse(r.hasResult)
        XCTAssertFalse(row("b", secs: nil).hasResult)
        XCTAssertTrue(row("c", secs: 185).hasResult)
    }

    func testOtherKindsWithBlankOrZeroAreNoResult() {
        XCTAssertFalse(row("a", kind: .roundsReps).hasResult)
        XCTAssertFalse(row("b", kind: .roundsReps, rounds: 0, reps: 0).hasResult)
        XCTAssertTrue(row("c", kind: .roundsReps, rounds: 0, reps: 12).hasResult)
        XCTAssertFalse(row("d", kind: .reps, reps: 0).hasResult)
        XCTAssertFalse(row("e", kind: .weight, kg: 0).hasResult)
        XCTAssertTrue(row("f", kind: .weight, kg: 60).hasResult)
        XCTAssertFalse(row("g", kind: .none).hasResult)
    }

    func testZeroTimeNeverBecomesTheRecord() {
        let rows = [row("old", ts: 1, secs: 300), row("blank", ts: 2, secs: 0), row("new", ts: 3, secs: 280)]
        let b = WodRanking.bests(of: rows)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].row.id, "new")
    }

    func testRxAndScaledRankedApart() {
        let rows = [row("rx", ts: 1, secs: 400, rx: true),
                    row("sc", ts: 2, secs: 200, rx: false),
                    row("unset", ts: 3, secs: 250)]
        let b = WodRanking.bests(of: rows)
        XCTAssertEqual(b.map(\.group), [.rx, .scaled])
        XCTAssertEqual(b[0].row.id, "rx")
        // The unflagged attempt is grouped with the scaled ones because RX is set elsewhere.
        XCTAssertEqual(b[1].row.id, "sc")
    }

    func testUnspecifiedOnlyWhenNoRowHasRx() {
        let b = WodRanking.bests(of: [row("a", ts: 1, secs: 300), row("b", ts: 2, secs: 250)])
        XCTAssertEqual(b.map(\.group), [.unspecified])
        XCTAssertEqual(b[0].row.id, "b")
    }

    func testOnlyScaledAttemptsGiveOneScaledBest() {
        let b = WodRanking.bests(of: [row("a", ts: 1, secs: 300, rx: false), row("b", ts: 2, secs: 350, rx: false)])
        XCTAssertEqual(b.map(\.group), [.scaled])
        XCTAssertEqual(b[0].row.id, "a")
    }

    func testRoundsRepsCompareAsATuple() {
        // 5 rounds + 120 reps used to outrank 6 rounds + 0 with the rounds*100+reps encoding.
        let rows = [row("a", ts: 1, kind: .roundsReps, rounds: 5, reps: 120),
                    row("b", ts: 2, kind: .roundsReps, rounds: 6, reps: 0),
                    row("c", ts: 3, kind: .roundsReps, rounds: 6, reps: 3)]
        XCTAssertEqual(WodRanking.bests(of: rows)[0].row.id, "c")
        XCTAssertTrue(WodRanking.isBetter(rows[1], than: rows[0]))
    }

    func testRepsAndWeightMax() {
        XCTAssertEqual(WodRanking.bests(of: [row("a", ts: 1, kind: .reps, reps: 50),
                                             row("b", ts: 2, kind: .reps, reps: 70)])[0].row.id, "b")
        XCTAssertEqual(WodRanking.bests(of: [row("a", ts: 1, kind: .weight, kg: 100),
                                             row("b", ts: 2, kind: .weight, kg: 90)])[0].row.id, "a")
    }

    func testTieKeepsEarlierAttempt() {
        let b = WodRanking.bests(of: [row("a", ts: 1, secs: 300), row("b", ts: 2, secs: 300)])
        XCTAssertEqual(b[0].row.id, "a")
    }

    func testNoResultsNoBest() {
        XCTAssertTrue(WodRanking.bests(of: [row("a", secs: 0), row("b", secs: nil)]).isEmpty)
        XCTAssertEqual(WodRanking.primaryKind(of: []), .none)
    }

    func testGroupByTitleIsCaseAndWhitespaceInsensitiveAndShowsLatestSpelling() {
        let rows = [row("a", ts: 1, title: "Fran"), row("b", ts: 3, title: " fran "),
                    row("c", ts: 2, title: "FRAN"), row("d", ts: 4, title: "Cindy")]
        let g = WodRanking.groupByTitle(rows)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].title, "Cindy")
        XCTAssertEqual(g[1].title, "fran")
        XCTAssertEqual(g[1].rows.map(\.id), ["b", "c", "a"])
    }
}
