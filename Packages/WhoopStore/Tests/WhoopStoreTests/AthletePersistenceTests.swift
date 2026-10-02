import XCTest
import GRDB
@testable import WhoopStore

final class AthletePersistenceTests: XCTestCase {
    private func seedLegacyDatabase(_ path: String) throws {
        let db = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(db, upTo: "v24-wod-rx")
        try db.write { connection in
            try connection.execute(sql: """
                INSERT INTO wodLog (id, ts, day, type, title, resultKind, movementsJSON, createdTs)
                VALUES ('legacy', 1, '2026-10-02', 'Strength', 'Old squat', 'none',
                        '[{"name":"Squat","reps":5}]', 1)
                """)
            try connection.execute(sql: """
                INSERT INTO journal (deviceId, day, question, answeredYes, notes)
                VALUES ('noop-journal', '2026-10-02', 'Old journal', 1, 'keep')
                """)
        }
    }

    private func writeCheckIn(_ path: String) async throws {
        let store = try await WhoopStore(path: path)
        try await store.saveAthleteCheckIn(day: "2026-10-02", values: [.energy: 3, .sleepQuality: 4])
    }

    func testMigrationAndReopenPreserveExistingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("athlete.sqlite").path
        try seedLegacyDatabase(path)
        try await writeCheckIn(path)
        let reopened = try await WhoopStore(path: path)
        let wods = try await reopened.allWods()
        XCTAssertEqual(wods.first?.id, "legacy")
        XCTAssertEqual(wods.first?.movements.first?.reps, 5)
        XCTAssertNil(wods.first?.durationS)
        let journal = try await reopened.journalEntries(deviceId: "noop-journal", from: "2026-10-02", to: "2026-10-02")
        XCTAssertEqual(journal.count, 3)
        XCTAssertEqual(journal.first { $0.question == "Old journal" }?.notes, "keep")
        XCTAssertEqual(journal.first { $0.question == AthleteCheckInField.energy.journalKey }?.numericValue, 3)
    }

    func testCheckInPreservesOtherJournalAndCanClear() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-10-02"
        let old = JournalEntry(day: day, question: "Existing journal question", answeredYes: true, notes: "keep")
        try await store.upsertJournal([old], deviceId: "noop-journal")
        try await store.saveAthleteCheckIn(day: day, values: [.energy: 4, .stress: 2])
        var rows = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertTrue(rows.contains(old))
        XCTAssertEqual(rows.first { $0.question == AthleteCheckInField.energy.journalKey }?.numericValue, 4)
        try await store.saveAthleteCheckIn(day: day, values: [.energy: 1])
        rows = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.question == AthleteCheckInField.energy.journalKey }?.numericValue, 1)
        do {
            try await store.saveAthleteCheckIn(day: day, values: [.energy: 6])
            XCTFail("Invalid score accepted")
        } catch {}
        let unchanged = try await store.journalEntries(deviceId: "noop-journal", from: day, to: day)
        XCTAssertEqual(unchanged, rows)
    }

    func testNewFieldsRoundTripAndLegacyMovementDecode() async throws {
        let store = try await WhoopStore.inMemory()
        var w = WodLogRow(id: "a", ts: 1, day: "2026-10-02", type: "CrossFit", title: "Fran",
                          resultKind: .time, resultSeconds: 300, rx: true,
                          movements: [WodMovement(name: "Thruster", reps: 45, repsDone: 45,
                                                  weightKg: 43, sets: 3)],
                          createdTs: 1, durationS: 600, benchmarkVersion: "v1", scaling: "RX")
        try await store.upsertWod(w)
        var rows = try await store.allWods()
        XCTAssertEqual(rows, [w])
        w.durationS = 700
        try await store.upsertWod(w)
        rows = try await store.allWods()
        XCTAssertEqual(rows, [w])
        let legacy = WodMovementCodec.decode(#"[{"name":"Squat","reps":5}]"#)
        XCTAssertEqual(legacy.first?.name, "Squat")
        XCTAssertNil(legacy.first?.sets)
    }

    func testBenchmarksRequireMatchingProtocol() {
        let a = WodLogRow(id: "a", ts: 1, day: "2026-10-02", type: "CrossFit", title: "Fran",
                         resultKind: .time, resultSeconds: 300, rx: true,
                         movements: [WodMovement(name: "Thruster", reps: 45, weightKg: 43)],
                         createdTs: 1, benchmarkVersion: "v1", scaling: "RX")
        var b = a; b.id = "b"; b.resultSeconds = 270
        XCTAssertTrue(a.isComparable(to: b))
        b.rx = false; XCTAssertFalse(a.isComparable(to: b))
        b = a; b.benchmarkVersion = nil; XCTAssertFalse(a.isComparable(to: b))
        b = a; b.movements[0].weightKg = 30; XCTAssertFalse(a.isComparable(to: b))
        b = a; b.scaling = "banded"; XCTAssertFalse(a.isComparable(to: b))
    }
}
