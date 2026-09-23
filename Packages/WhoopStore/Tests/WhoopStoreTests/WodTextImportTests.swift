import XCTest
@testable import WhoopStore

/// Pure-parser tests for `WodTextImport` — no database. A fixed `now`/UTC calendar keeps day keys and
/// the "no date" fallback deterministic.
final class WodTextImportTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2026-09-22T07:00:00Z
    private var now: Date { Date(timeIntervalSince1970: 1_790_060_400) }

    func testEmptyAndGarbage() {
        XCTAssertTrue(WodTextImport.parse("", now: now, calendar: cal).isEmpty)
        XCTAssertTrue(WodTextImport.parse("   \n \n", now: now, calendar: cal).isEmpty)
    }

    func testBasicWodWithMovementsAndLoads() throws {
        let text = """
        Data: 2026-09-20
        Tipo: CrossFit
        Nome: Fran
        Formato: For Time
        Time cap: 10
        RX: scaled
        Risultato: 6:32
        RPE: 8
        Movimenti:
        - Thruster; reps 21-15-9; rx 43; me 30
        - Pull-up; reps 21-15-9
        Note: felt strong
        """
        let rows = WodTextImport.parse(text, now: now, calendar: cal)
        XCTAssertEqual(rows.count, 1)
        let w = try XCTUnwrap(rows.first)
        XCTAssertEqual(w.title, "Fran")
        XCTAssertEqual(w.type, "CrossFit")
        XCTAssertEqual(w.format, "For Time")
        XCTAssertEqual(w.timeCapS, 600)
        XCTAssertEqual(w.rx, false)               // "scaled"
        XCTAssertEqual(w.resultKind, .time)
        XCTAssertEqual(w.resultSeconds, 6 * 60 + 32)
        XCTAssertEqual(w.rpe, 8)
        XCTAssertEqual(w.day, "2026-09-20")
        XCTAssertEqual(w.notes, "felt strong")
        XCTAssertEqual(w.movements.count, 2)
        XCTAssertEqual(w.movements[0].name, "Thruster")
        XCTAssertEqual(w.movements[0].scheme, "21-15-9")
        XCTAssertEqual(w.movements[0].rxWeightKg, 43)
        XCTAssertEqual(w.movements[0].weightKg, 30)
        XCTAssertNil(w.movements[1].weightKg)
        XCTAssertEqual(w.movements[1].scheme, "21-15-9")
    }

    func testMultipleWodsSeparated() {
        let text = """
        Nome: A
        - Squat; 5x5; rx 100
        ---
        Nome: B
        - Deadlift; 3x3; rx 140
        """
        let rows = WodTextImport.parse(text, now: now, calendar: cal)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].title, "A")
        XCTAssertEqual(rows[1].title, "B")
        XCTAssertEqual(rows[0].movements.first?.scheme, "5x5")
        XCTAssertEqual(rows[1].movements.first?.rxWeightKg, 140)
    }

    func testRxInferenceWhenLiftedBelowPrescribed() throws {
        let text = """
        Nome: Grace
        - Clean & Jerk; reps 30; rx 60; me 45
        """
        let w = try XCTUnwrap(WodTextImport.parse(text, now: now, calendar: cal).first)
        XCTAssertEqual(w.rx, false)   // 45 < 60 → scaled
        XCTAssertEqual(w.movements[0].reps, 30)   // plain integer count, not a scheme
        XCTAssertNil(w.movements[0].scheme)
    }

    func testRxInferenceAtOrAbovePrescribed() throws {
        let text = """
        Nome: Grace
        - Clean & Jerk; reps 30; rx 60; me 60
        """
        let w = try XCTUnwrap(WodTextImport.parse(text, now: now, calendar: cal).first)
        XCTAssertEqual(w.rx, true)
    }

    func testResultRoundsPlusReps() throws {
        let text = """
        Nome: Cindy
        Formato: AMRAP
        Risultato: 18 + 12
        - Pull-up; 5
        """
        let w = try XCTUnwrap(WodTextImport.parse(text, now: now, calendar: cal).first)
        XCTAssertEqual(w.resultKind, .roundsReps)
        XCTAssertEqual(w.resultRounds, 18)
        XCTAssertEqual(w.resultReps, 12)
    }

    func testResultWeightAndReps() throws {
        let w1 = try XCTUnwrap(WodTextImport.parse("Nome: 1RM\nRisultato: 102,5 kg", now: now, calendar: cal).first)
        XCTAssertEqual(w1.resultKind, .weight)
        XCTAssertEqual(w1.resultWeightKg, 102.5)

        let w2 = try XCTUnwrap(WodTextImport.parse("Nome: Max reps\nRisultato: 120 reps", now: now, calendar: cal).first)
        XCTAssertEqual(w2.resultKind, .reps)
        XCTAssertEqual(w2.resultReps, 120)
    }

    func testBareMovementTrailingWeightBecomesRx() throws {
        let w = try XCTUnwrap(WodTextImport.parse("- Back Squat 100 kg", now: now, calendar: cal).first)
        XCTAssertEqual(w.movements.count, 1)
        XCTAssertEqual(w.movements[0].name, "Back Squat")
        XCTAssertEqual(w.movements[0].rxWeightKg, 100)
        // No explicit title → falls back to the movement name.
        XCTAssertEqual(w.title, "Back Squat")
    }

    func testNoDateStampsNow() throws {
        let w = try XCTUnwrap(WodTextImport.parse("Nome: X\n- Row; 500", now: now, calendar: cal).first)
        XCTAssertEqual(w.ts, Int(now.timeIntervalSince1970))
        XCTAssertEqual(w.day, "2026-09-22")
    }

    func testEnglishLabelsAndMineKeyword() throws {
        let text = """
        Name: Diane
        Type: CrossFit
        Movements:
        - Deadlift; reps 21-15-9; rx 102; mine 80
        - HSPU; 21-15-9
        """
        let w = try XCTUnwrap(WodTextImport.parse(text, now: now, calendar: cal).first)
        XCTAssertEqual(w.title, "Diane")
        XCTAssertEqual(w.movements[0].weightKg, 80)
        XCTAssertEqual(w.movements[0].rxWeightKg, 102)
    }

    func testMovementsWithoutBullets() throws {
        // Some AIs drop the leading "-"; under a Movements: header we still read them as movements,
        // and a following Note: label ends the section.
        let text = """
        Nome: Helen
        Movimenti:
        Kettlebell Swing; reps 21; rx 24; me 20
        Run; 400 m
        Pull-up; reps 12
        Note: dura
        """
        let w = try XCTUnwrap(WodTextImport.parse(text, now: now, calendar: cal).first)
        XCTAssertEqual(w.movements.count, 3)
        XCTAssertEqual(w.movements[0].name, "Kettlebell Swing")
        XCTAssertEqual(w.movements[0].rxWeightKg, 24)
        XCTAssertEqual(w.movements[0].weightKg, 20)
        XCTAssertEqual(w.movements[2].reps, 12)
        XCTAssertEqual(w.notes, "dura")
    }

    func testNoNameMultiMovementBuildsCompositeTitle() throws {
        // No "Nome:" line, several movements, markdown "*" bullets — title from the movements,
        // not just the first.
        let text = """
        Tipo: CrossFit
        Formato: Intervals
        Movimenti:
        * Run; reps 400 m
        * Wall Ball; reps 30; me 9 kg
        * Double Under; reps 100
        Note: 5 rounds, every 6'
        """
        let w = try XCTUnwrap(WodTextImport.parse(text, now: now, calendar: cal).first)
        XCTAssertEqual(w.title, "Run / Wall Ball / Double Under")
        XCTAssertEqual(w.type, "CrossFit")
        XCTAssertEqual(w.format, "Intervals")
        XCTAssertEqual(w.movements.count, 3)
        XCTAssertEqual(w.movements[0].scheme, "400 m")
        XCTAssertEqual(w.movements[1].weightKg, 9)
        XCTAssertEqual(w.notes, "5 rounds, every 6'")
    }

    func testTimeValueNotMistakenForLabel() throws {
        // "6:32" as a bare result value line under a Result label must stay a time, and a stray
        // "21-15-9:" style leading-digit token must not be read as a label.
        let w = try XCTUnwrap(WodTextImport.parse("Nome: T\nRisultato: 6:32", now: now, calendar: cal).first)
        XCTAssertEqual(w.resultKind, .time)
        XCTAssertEqual(w.resultSeconds, 392)
    }
}
