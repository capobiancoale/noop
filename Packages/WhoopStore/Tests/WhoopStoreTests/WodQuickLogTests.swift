import XCTest
@testable import WhoopStore

final class WodQuickLogTests: XCTestCase {
    func testTime() {
        XCTAssertEqual(WodResultParser.parse("4:32"), WodQuickResult(kind: .time, seconds: 272))
        XCTAssertEqual(WodResultParser.parse(" 12:05 "), WodQuickResult(kind: .time, seconds: 725))
        XCTAssertNil(WodResultParser.parse("4:75"))
        XCTAssertNil(WodResultParser.parse("0:00"))
        XCTAssertNil(WodResultParser.parse("1:02:03"))
        XCTAssertNil(WodResultParser.parse("4:"))
    }

    func testRoundsReps() {
        XCTAssertEqual(WodResultParser.parse("12+5"), WodQuickResult(kind: .roundsReps, rounds: 12, reps: 5))
        XCTAssertEqual(WodResultParser.parse("12 + 5"), WodQuickResult(kind: .roundsReps, rounds: 12, reps: 5))
        XCTAssertEqual(WodResultParser.parse("0+7"), WodQuickResult(kind: .roundsReps, rounds: 0, reps: 7))
        XCTAssertNil(WodResultParser.parse("0+0"))
        XCTAssertNil(WodResultParser.parse("12+"))
        XCTAssertNil(WodResultParser.parse("1+2+3"))
    }

    func testWeight() {
        XCTAssertEqual(WodResultParser.parse("100 kg"), WodQuickResult(kind: .weight, weightKg: 100))
        XCTAssertEqual(WodResultParser.parse("62,5kg"), WodQuickResult(kind: .weight, weightKg: 62.5))
        XCTAssertEqual(WodResultParser.parse("62.5 KG"), WodQuickResult(kind: .weight, weightKg: 62.5))
        XCTAssertNil(WodResultParser.parse("kg"))
        XCTAssertNil(WodResultParser.parse("0 kg"))
        XCTAssertNil(WodResultParser.parse("-5 kg"))
    }

    func testReps() {
        XCTAssertEqual(WodResultParser.parse("150"), WodQuickResult(kind: .reps, reps: 150))
        XCTAssertNil(WodResultParser.parse("0"))
        XCTAssertNil(WodResultParser.parse("12.5"))
        XCTAssertNil(WodResultParser.parse("99999999"))
    }

    func testGarbageIsNoResult() {
        XCTAssertNil(WodResultParser.parse(nil))
        XCTAssertNil(WodResultParser.parse(""))
        XCTAssertNil(WodResultParser.parse("   "))
        XCTAssertNil(WodResultParser.parse("fast"))
        XCTAssertNil(WodResultParser.parse("100 lb"))
    }

    private func wod(_ id: String, ts: Int, title: String = "Back Squat", type: String = "Weightlifting",
                     format: String? = "Strength", movements: [WodMovement]) -> WodLogRow {
        WodLogRow(id: id, ts: ts, day: "2026-11-05", type: type, title: title, format: format,
                  movements: movements, createdTs: ts)
    }

    func testMovementLookupNewestAndNormalised() {
        let old = wod("a", ts: 100, movements: [WodMovement(name: "Back Squat", scheme: "5x5", weightKg: 80)])
        let new = wod("b", ts: 200, movements: [WodMovement(name: "  back   SQUAT ", scheme: "5x5", weightKg: 90)])
        let e = WodMovementHistory.latest(named: "Back squat", in: [old, new])
        XCTAssertEqual(e?.movement.weightKg, 90)
        XCTAssertEqual(e?.ts, 200)
        XCTAssertNil(WodMovementHistory.latest(named: "Deadlift", in: [old, new]))
        XCTAssertNil(WodMovementHistory.latest(named: "  ", in: [old, new]))
        // the WOD being edited is skipped
        XCTAssertEqual(WodMovementHistory.latest(named: "Back squat", in: [old, new], excluding: "b")?.movement.weightKg, 80)
    }

    func testMovementLookupFoldsAccentsAndSkipsEmptyEntries() {
        let bare = wod("a", ts: 300, movements: [WodMovement(name: "Thruster")])
        let full = wod("b", ts: 200, movements: [WodMovement(name: "Thruster", reps: 21, weightKg: 43)])
        XCTAssertEqual(WodMovementHistory.latest(named: "thruster", in: [bare, full])?.ts, 200)
        let acc = wod("c", ts: 100, movements: [WodMovement(name: "Sumo Déadlift", reps: 10)])
        XCTAssertNotNil(WodMovementHistory.latest(named: "sumo deadlift", in: [acc]))
    }

    func testMakeRowCopiesPreviousWod() {
        let prev = WodLogRow(id: "p", ts: 100, day: "2026-11-01", type: "CrossFit", title: "Fran", format: "For Time",
                             timeCapS: 600, resultKind: .time, resultSeconds: 300, rpe: 9, rx: true, notes: "n",
                             movements: [WodMovement(name: "Thruster", scheme: "21-15-9", repsDone: 45, weightKg: 43)],
                             createdTs: 100)
        let r = WodQuickLog.makeRow(title: "  fran ", resultText: "4:32", rpe: 8, scaled: true, history: [prev],
                                    id: "new", now: 500, dayKey: "2026-11-14")
        XCTAssertEqual(r.id, "new")
        XCTAssertEqual(r.title, "fran")
        XCTAssertEqual(r.type, "CrossFit")
        XCTAssertEqual(r.format, "For Time")
        XCTAssertEqual(r.resultKind, .time)
        XCTAssertEqual(r.resultSeconds, 272)
        XCTAssertEqual(r.rpe, 8)
        XCTAssertEqual(r.rx, false)
        XCTAssertNil(r.notes)
        XCTAssertEqual(r.ts, 500)
        XCTAssertEqual(r.day, "2026-11-14")
        XCTAssertEqual(r.movements, [WodMovement(name: "Thruster", scheme: "21-15-9", weightKg: 43)])
    }

    func testMakeRowWithoutHistoryOrResult() {
        let r = WodQuickLog.makeRow(title: "Cindy", resultText: "banana", rpe: 11, scaled: false, history: [],
                                    id: "x", now: 10, dayKey: "2026-11-14")
        XCTAssertEqual(r.type, "CrossFit")
        XCTAssertNil(r.format)
        XCTAssertEqual(r.resultKind, .none)
        XCTAssertNil(r.resultSeconds)
        XCTAssertNil(r.rpe)
        XCTAssertNil(r.rx)
        XCTAssertTrue(r.movements.isEmpty)
    }
}
