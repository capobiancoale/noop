import XCTest
@testable import StrandImport
import WhoopStore

/// Pure tests for `WodCsvImport`. Fixed now/UTC calendar keeps the "no date" fallback and day keys
/// deterministic.
final class WodCsvImportTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var now: Date { Date(timeIntervalSince1970: 1_790_060_400) } // 2026-09-22

    func testTemplateParsesTwoWodsWithCarriedRows() throws {
        let r = WodCsvImport.parse(text: WodCsvImport.template, now: now, calendar: cal)
        XCTAssertFalse(r.fileTooLarge)
        XCTAssertEqual(r.importedWods, 2)

        let fran = try XCTUnwrap(r.wods.first { $0.title == "Fran" })
        XCTAssertEqual(fran.type, "CrossFit")
        XCTAssertEqual(fran.format, "For Time")
        XCTAssertEqual(fran.timeCapS, 600)
        XCTAssertEqual(fran.rx, false)                 // "scaled"
        XCTAssertEqual(fran.resultKind, .time)
        XCTAssertEqual(fran.resultSeconds, 392)        // 6:32
        XCTAssertEqual(fran.day, "2026-09-20")
        XCTAssertEqual(fran.movements.count, 2)        // second row carried date+name
        XCTAssertEqual(fran.movements[0].name, "Thruster")
        XCTAssertEqual(fran.movements[0].scheme, "21-15-9")
        XCTAssertEqual(fran.movements[0].rxWeightKg, 43)
        XCTAssertEqual(fran.movements[0].weightKg, 30)
        XCTAssertEqual(fran.movements[1].name, "Pull-up")

        let bs = try XCTUnwrap(r.wods.first { $0.title == "Back Squat 5x5" })
        XCTAssertEqual(bs.type, "Weightlifting")
        XCTAssertEqual(bs.resultKind, .weight)
        XCTAssertEqual(bs.resultWeightKg, 100)         // "100 kg"
        XCTAssertEqual(bs.rx, true)
        XCTAssertEqual(bs.movements.first?.rxWeightKg, 100)
    }

    func testSemicolonDelimiterAndItalianHeaders() throws {
        // Italian Excel exports with ';'. Headers in Italian must resolve too.
        let text = """
        data;nome;tipo;risultato;movimento;ripetizioni;peso_rx;peso_mio
        2026-09-19;Grace;CrossFit;3:10;Clean & Jerk;30;60;45
        """
        let r = WodCsvImport.parse(text: text, now: now, calendar: cal)
        XCTAssertEqual(r.importedWods, 1)
        let w = try XCTUnwrap(r.wods.first)
        XCTAssertEqual(w.title, "Grace")
        XCTAssertEqual(w.day, "2026-09-19")
        XCTAssertEqual(w.resultKind, .time)
        XCTAssertEqual(w.resultSeconds, 190)
        XCTAssertEqual(w.movements.count, 1)
        XCTAssertEqual(w.movements[0].name, "Clean & Jerk")
        XCTAssertEqual(w.movements[0].reps, 30)         // plain count
        XCTAssertEqual(w.movements[0].rxWeightKg, 60)
        XCTAssertEqual(w.movements[0].weightKg, 45)
        XCTAssertEqual(w.rx, false)                     // inferred: 45 < 60 -> scaled
    }

    func testGroupingByDateAndName() throws {
        let text = """
        date,name,movement,reps
        2026-09-01,A,Squat,5
        2026-09-01,A,Bench,5
        2026-09-02,A,Deadlift,3
        """
        let r = WodCsvImport.parse(text: text, now: now, calendar: cal)
        // Same name on two different days = two WODs; two movements on day 1 fold into one.
        XCTAssertEqual(r.importedWods, 2)
        let day1 = try XCTUnwrap(r.wods.first { $0.day == "2026-09-01" })
        XCTAssertEqual(day1.movements.count, 2)
    }

    func testFileTooLarge() {
        let big = Data(count: WodCsvImport.maxBytes + 1)
        let r = WodCsvImport.parse(data: big)
        XCTAssertTrue(r.fileTooLarge)
        XCTAssertTrue(r.wods.isEmpty)
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(WodCsvImport.parse(text: "").importedWods, 0)
    }
}
