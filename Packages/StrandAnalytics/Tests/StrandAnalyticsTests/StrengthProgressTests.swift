import XCTest
import WhoopStore
@testable import StrandAnalytics

final class StrengthProgressTests: XCTestCase {

    private func wod(_ id: String, _ day: String, ts: Int, kind: WodResultKind = .none,
                     _ movements: [WodMovement]) -> WodLogRow {
        WodLogRow(id: id, ts: ts, day: day, type: "strength", title: id, resultKind: kind,
                  movements: movements, createdTs: ts)
    }

    private func single(_ m: WodMovement) -> StrengthProgress.Entry? {
        StrengthProgress.movements(from: [wod("w", "2026-10-01", ts: 100, [m])]).first?.entries.first
    }

    func testNormalisationAndAliases() {
        XCTAssertEqual(StrengthProgress.normalizedName("  Back   SQUATS "), "back squat")
        XCTAssertEqual(StrengthProgress.normalizedName("Deadlifts"), "deadlift")
        XCTAssertEqual(StrengthProgress.normalizedName("Thrusters"), "thruster")
        XCTAssertEqual(StrengthProgress.normalizedName("Cleans"), "clean")
        XCTAssertEqual(StrengthProgress.normalizedName("Snatches"), "snatch")
        XCTAssertEqual(StrengthProgress.normalizedName("Presses"), "press")
        XCTAssertEqual(StrengthProgress.normalizedName("Push Presses"), "push press")
        // not in the table: left alone, no fuzzy matching
        XCTAssertEqual(StrengthProgress.normalizedName("Burpees"), "burpees")
        XCTAssertEqual(StrengthProgress.normalizedName("Bus"), "bus")
        XCTAssertNotEqual(StrengthProgress.normalizedName("front squat"), StrengthProgress.normalizedName("back squat"))
    }

    func testDisplayNameIsMostRecentSpelling() {
        let ms = StrengthProgress.movements(from: [
            wod("a", "2026-10-01", ts: 100, [WodMovement(name: "back squats", reps: 5, weightKg: 80)]),
            wod("b", "2026-10-05", ts: 200, [WodMovement(name: "Back  Squat", reps: 5, weightKg: 85)]),
        ])
        XCTAssertEqual(ms.count, 1)
        XCTAssertEqual(ms[0].displayName, "Back Squat")
        XCTAssertEqual(ms[0].key, "back squat")
    }

    func testSchemeForms() {
        for s in ["5x5", "5 x 5", "5×5", "5X5"] {
            let e = single(WodMovement(name: "x", scheme: s, weightKg: 100))
            XCTAssertEqual(e?.sets, 5, s); XCTAssertEqual(e?.reps, 5, s)
            XCTAssertEqual(e?.volumeKg, 2500, s)
        }
        let v = single(WodMovement(name: "x", scheme: "21-15-9", weightKg: 40))
        XCTAssertEqual(v?.sets, 3); XCTAssertNil(v?.reps); XCTAssertNil(v?.estimated1RM)
        XCTAssertEqual(v?.volumeKg, 45 * 40)
        let done = single(WodMovement(name: "x", reps: 10, scheme: "5x5", repsDone: 4, weightKg: 100))
        XCTAssertEqual(done?.reps, 4); XCTAssertEqual(done?.sets, 5); XCTAssertEqual(done?.volumeKg, 2000)
        let doneOnly = single(WodMovement(name: "x", repsDone: 3, weightKg: 100))
        XCTAssertEqual(doneOnly?.reps, 3); XCTAssertNil(doneOnly?.sets); XCTAssertEqual(doneOnly?.volumeKg, 300)
        let plain = single(WodMovement(name: "x", reps: 8, weightKg: 50))
        XCTAssertEqual(plain?.reps, 8); XCTAssertNil(plain?.sets); XCTAssertEqual(plain?.volumeKg, 400)
        let junk = single(WodMovement(name: "x", scheme: "heavy", weightKg: 50))
        XCTAssertNil(junk?.reps); XCTAssertNil(junk?.volumeKg); XCTAssertNil(junk?.estimated1RM)
        XCTAssertNil(single(WodMovement(name: "x", reps: 5, weightKg: 0)))
        XCTAssertNil(single(WodMovement(name: "x", reps: 5)))
    }

    func testEpley() {
        XCTAssertEqual(single(WodMovement(name: "x", reps: 1, weightKg: 100))?.estimated1RM, 100)
        XCTAssertEqual(single(WodMovement(name: "x", reps: 5, weightKg: 100))!.estimated1RM!, 100 * (1 + 5.0 / 30), accuracy: 1e-9)
        XCTAssertEqual(single(WodMovement(name: "x", reps: 10, weightKg: 90))!.estimated1RM!, 120, accuracy: 1e-9)
        XCTAssertNil(single(WodMovement(name: "x", reps: 11, weightKg: 100))?.estimated1RM)
        XCTAssertNotNil(single(WodMovement(name: "x", reps: 11, weightKg: 100)))
        XCTAssertNil(single(WodMovement(name: "x", scheme: "10-8-6", weightKg: 100))?.estimated1RM)
    }

    func testRecordFlags() {
        let ms = StrengthProgress.movements(from: [
            wod("c", "2026-10-10", ts: 300, [WodMovement(name: "deadlift", reps: 3, weightKg: 140)]),
            wod("a", "2026-10-01", ts: 100, [WodMovement(name: "deadlift", reps: 3, weightKg: 120)]),
            wod("b", "2026-10-05", ts: 200, [WodMovement(name: "deadlift", reps: 3, weightKg: 130)]),
            wod("d", "2026-10-12", ts: 400, [WodMovement(name: "deadlift", reps: 3, weightKg: 140)]),
            wod("e", "2026-10-14", ts: 500, [WodMovement(name: "deadlift", reps: 3, weightKg: 100)]),
        ])
        let e = ms[0].entries
        XCTAssertEqual(e.map(\.wodId), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(e.map(\.isRecord), [false, true, true, false, false])
        XCTAssertEqual(ms[0].bestWeightKg, 140)
        XCTAssertEqual(ms[0].bestDay, "2026-10-10")
        XCTAssertEqual(ms[0].latestWeightKg, 100)
        XCTAssertEqual(ms[0].latestDay, "2026-10-14")
        XCTAssertEqual(ms[0].best1RM!, 140 * 1.1, accuracy: 1e-9)
    }

    func testResultKindNoneIncludedAndSorting() {
        let ms = StrengthProgress.movements(from: [
            wod("a", "2026-10-01", ts: 100, kind: .none, [WodMovement(name: "snatch", reps: 2, weightKg: 60),
                                                         WodMovement(name: "clean", reps: 2, weightKg: 70)]),
            wod("b", "2026-10-02", ts: 200, kind: .time, [WodMovement(name: "Cleans", reps: 2, weightKg: 75)]),
        ])
        XCTAssertEqual(ms.map(\.key), ["clean", "snatch"])
        XCTAssertEqual(ms[1].entries.count, 1)
    }

    func testWeeklyAcrossYearBoundaryAndMonday() {
        // 2026-12-28 is a Monday; 2027-01-03 is the Sunday of that week; 2027-01-04 a Monday.
        let wods = [
            wod("a", "2026-12-27", ts: 1, [WodMovement(name: "squat", reps: 5, weightKg: 100)]),   // Sunday, week of 12-21
            wod("b", "2026-12-28", ts: 2, [WodMovement(name: "squat", scheme: "3x5", weightKg: 100)]), // 1500
            wod("c", "2027-01-03", ts: 3, [WodMovement(name: "squat", reps: 2, weightKg: 50)]),    // 100
            wod("d", "2027-01-04", ts: 4, [WodMovement(name: "squat", reps: 1, weightKg: 200)]),   // 200
            wod("old", "2026-01-01", ts: 0, [WodMovement(name: "squat", reps: 1, weightKg: 10)]),  // out of range
        ]
        let w = StrengthProgress.weeklyVolume(from: wods, weeks: 3, today: "2027-01-06")
        XCTAssertEqual(w.map(\.weekStart), ["2026-12-21", "2026-12-28", "2027-01-04"])
        XCTAssertEqual(w.map(\.volumeKg), [500, 1600, 200])
        XCTAssertEqual(w.map(\.entries), [1, 2, 1])
        XCTAssertTrue(w.allSatisfy { $0.skipped == 0 })
        XCTAssertEqual(StrengthProgress.weeklyVolume(from: wods, weeks: 0, today: "2027-01-06"), [])
        XCTAssertEqual(StrengthProgress.weeklyVolume(from: wods, weeks: 2, today: "nonsense"), [])
    }

    func testSkippedCount() {
        let wods = [wod("a", "2026-11-10", ts: 1, [
            WodMovement(name: "squat", reps: 5, weightKg: 100),
            WodMovement(name: "press", weightKg: 40),                 // reps unknown
            WodMovement(name: "pull-up", reps: 10),                   // no load: not counted
        ])]
        let w = StrengthProgress.weeklyVolume(from: wods, weeks: 1, today: "2026-11-13")
        XCTAssertEqual(w, [StrengthProgress.WeekVolume(weekStart: "2026-11-09", volumeKg: 500, entries: 2, skipped: 1)])
    }

    func testSummaryLines() {
        let ms = StrengthProgress.movements(from: [
            wod("a", "2026-10-02", ts: 100, [WodMovement(name: "back squat", reps: 3, weightKg: 100),
                                             WodMovement(name: "deadlift", reps: 1, weightKg: 150)]),
            wod("b", "2026-11-10", ts: 200, [WodMovement(name: "back squat", reps: 5, weightKg: 95.5),
                                             WodMovement(name: "old lift", reps: 5, weightKg: 60)]),
            wod("old", "2026-05-01", ts: 50, [WodMovement(name: "old lift", reps: 5, weightKg: 60)]),
            wod("future", "2026-12-01", ts: 900, [WodMovement(name: "future lift", reps: 5, weightKg: 60)]),
        ])
        let lines = StrengthProgress.summaryLines(ms, today: "2026-11-13")
        XCTAssertEqual(lines[0], "back squat: best 100 kg on 2026-10-02 (est. 1RM 111 kg), latest 95.5 kg on 2026-11-10")
        XCTAssertTrue(lines.contains("deadlift: best 150 kg on 2026-10-02 (est. 1RM 150 kg), latest 150 kg on 2026-10-02"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("future lift") })
        // narrow window drops October
        let narrow = StrengthProgress.summaryLines(ms, today: "2026-11-13", windowDays: 7)
        XCTAssertEqual(narrow.count, 2)
        XCTAssertTrue(narrow.allSatisfy { $0.hasPrefix("back squat") || $0.hasPrefix("old lift") })
        XCTAssertEqual(StrengthProgress.summaryLines(ms, today: "2026-11-13", limit: 1).count, 1)
        XCTAssertEqual(StrengthProgress.summaryLines(ms, today: "2026-11-13", limit: 0), [])
        // no estimate without known reps
        let none = StrengthProgress.movements(from: [wod("z", "2026-11-12", ts: 1, [WodMovement(name: "press", weightKg: 40)])])
        XCTAssertEqual(StrengthProgress.summaryLines(none, today: "2026-11-13"),
                       ["press: best 40 kg on 2026-11-12, latest 40 kg on 2026-11-12"])
    }
}
