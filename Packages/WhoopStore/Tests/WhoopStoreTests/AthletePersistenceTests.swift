import XCTest
@testable import WhoopStore

final class AthletePersistenceTests: XCTestCase {
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
