import XCTest
import GRDB
@testable import WhoopStore

final class WodStoreTests: XCTestCase {

    // MARK: - v23 migration

    func testV23CreatesWodLogTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("wodLog"))

        let pk = try await store.primaryKeyColumns("wodLog")
        XCTAssertEqual(pk, ["id"])

        let cols = try await store.columnNamesForTest(table: "wodLog")
        for c in ["id", "ts", "day", "type", "title", "format", "timeCapS", "resultKind",
                  "resultSeconds", "resultRounds", "resultReps", "resultWeightKg", "rpe",
                  "notes", "movementsJSON", "createdTs"] {
            XCTAssertTrue(cols.contains(c), "wodLog missing column \(c)")
        }
    }

    /// Additive: v23 must not drop tables that existed before it.
    func testV23IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["dailyMetric", "workout", "metricSeries", "labMarker", "liveSession"] {
            XCTAssertTrue(tables.contains(t), "v23 must not drop \(t)")
        }
    }

    // MARK: - Movements JSON codec (pure)

    func testMovementCodecRoundTrip() {
        let movs = [WodMovement(name: "Thruster", reps: 21, weightKg: 43),
                    WodMovement(name: "Pull-up", reps: 21, weightKg: nil, notes: "kipping")]
        let json = WodMovementCodec.encode(movs)
        XCTAssertEqual(WodMovementCodec.decode(json), movs)
    }

    func testMovementCodecBadInputDegradesToEmpty() {
        XCTAssertEqual(WodMovementCodec.decode(nil), [])
        XCTAssertEqual(WodMovementCodec.decode(""), [])
        XCTAssertEqual(WodMovementCodec.decode("not json"), [])
        XCTAssertEqual(WodMovementCodec.encode([]), "[]")
    }

    // MARK: - CRUD

    func testUpsertFetchDeleteRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let r = WodLogRow(
            id: "w1", ts: 1_000_000, day: "2026-09-20", type: "CrossFit", title: "Fran",
            format: "For Time", timeCapS: nil, resultKind: .time, resultSeconds: 245,
            movements: [WodMovement(name: "Thruster", reps: 21, weightKg: 43),
                        WodMovement(name: "Pull-up", reps: 21)],
            createdTs: 1_000_000)
        try await store.upsertWod(r)

        let all = try await store.allWods()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, r)   // full round-trip, movements included

        // Editing the same id replaces rather than inserts.
        var edited = r
        edited.resultSeconds = 230
        try await store.upsertWod(edited)
        XCTAssertEqual(try await store.allWods().count, 1)

        // Title query is case-insensitive.
        XCTAssertEqual(try await store.wods(title: "fran").first?.resultSeconds, 230)

        try await store.deleteWod(id: "w1")
        XCTAssertTrue(try await store.allWods().isEmpty)
    }

    func testAllWodsNewestFirst() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWod(WodLogRow(id: "a", ts: 100, day: "d", type: "CrossFit", title: "A", createdTs: 0))
        try await store.upsertWod(WodLogRow(id: "b", ts: 200, day: "d", type: "CrossFit", title: "B", createdTs: 0))
        XCTAssertEqual(try await store.allWods().map(\.id), ["b", "a"])
    }
}
