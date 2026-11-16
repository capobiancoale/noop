import XCTest
@testable import Strand

/// Pure parts of the Coach context: the glucose summary formatter and the size-fitting assembly.
@MainActor
final class AICoachContextTests: XCTestCase {

    // MARK: - Glucose summary

    func testGlucoseSummaryMeansUnitsAndLatest() {
        let series: [String: [(day: String, value: Double)]] = [
            "glucose_avg": [("2026-11-11", 110), ("2026-11-12", 120)],
            "glucose_tir": [("2026-11-11", 70), ("2026-11-12", 80)],
            "glucose_hypos": [("2026-11-10", 1), ("2026-11-12", 2)],
        ]
        let text = AICoachEngine.glucoseSummary(series: series, recentDays: ["2026-11-13", "2026-11-12"])
        let out = try! XCTUnwrap(text)
        XCTAssertTrue(out.hasPrefix("GLUCOSE, daily summaries from Apple Health, last 14 days (background only):"))
        XCTAssertTrue(out.contains("- average glucose: mean 115 mg/dL over 2 days, latest 120 mg/dL (2026-11-12)"), out)
        XCTAssertTrue(out.contains("- time in range: mean 75% over 2 days, latest 80% (2026-11-12)"), out)
        XCTAssertTrue(out.contains("- low events: 3 in total over 2 days with data, latest 2 (2026-11-12)"), out)
        XCTAssertFalse(out.contains("time below range"), "keys without data are left out")
    }

    func testGlucoseSummaryOmitsStaleLatestAndIsNilWithoutData() {
        let stale: [String: [(day: String, value: Double)]] = ["glucose_avg": [("2026-11-05", 100)]]
        let out = AICoachEngine.glucoseSummary(series: stale, recentDays: ["2026-11-13", "2026-11-12"])
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.contains("latest"))
        XCTAssertNil(AICoachEngine.glucoseSummary(series: [:], recentDays: ["2026-11-13"]))
        XCTAssertNil(AICoachEngine.glucoseSummary(series: ["glucose_avg": []], recentDays: ["2026-11-13"]))
        XCTAssertNil(AICoachEngine.glucoseSummary(series: ["insulin_total": [("2026-11-12", 30)]],
                                                  recentDays: ["2026-11-12"]), "only the glucose keys are read")
    }

    func testPreviousDayKey() {
        XCTAssertEqual(AICoachEngine.previousDayKey("2026-11-13"), "2026-11-12")
        XCTAssertEqual(AICoachEngine.previousDayKey("2026-03-01"), "2026-02-28")
        XCTAssertNil(AICoachEngine.previousDayKey("nope"))
    }

    // MARK: - Assembly and size

    private func parts(strengthSize: Int = 10) -> AICoachEngine.ContextParts {
        var p = AICoachEngine.ContextParts()
        p.head = ["TODAY", "PLAN"]
        p.workouts = "WORKOUTS" + String(repeating: "w", count: strengthSize)
        p.wods = "WODS-FULL" + String(repeating: "d", count: strengthSize)
        p.wodsShort = "WODS-SHORT"
        p.strength = "STRENGTH" + String(repeating: "s", count: strengthSize)
        p.stress = "STRESS"
        p.signals = "SIGNALS" + String(repeating: "g", count: strengthSize)
        p.glucose = "GLUCOSE"
        p.tail = ["SAFETY", "LANGUAGE"]
        return p
    }

    func testSmallContextKeepsOrderAndEverything() {
        let out = AICoachEngine.assembleContext(parts())
        let order = ["TODAY", "PLAN", "WORKOUTS", "WODS-FULL", "STRENGTH", "STRESS", "SIGNALS", "GLUCOSE", "SAFETY", "LANGUAGE"]
        var last = out.startIndex
        for key in order {
            guard let r = out.range(of: key, range: last..<out.endIndex) else { return XCTFail("missing/misordered \(key)") }
            last = r.upperBound
        }
        XCTAssertTrue(out.hasSuffix("LANGUAGE"))
        XCTAssertTrue(out.contains("TODAY\n\nPLAN"))
    }

    func testDropsStrengthFirst() {
        // Only the strength block pushes it over.
        var p = parts()
        p.strength = String(repeating: "S", count: 400)
        let limit = AICoachEngine.assembleContext(parts()).count + 100
        let out = AICoachEngine.assembleContext(p, limit: limit)
        XCTAssertFalse(out.contains("SSSS"))
        XCTAssertTrue(out.contains("SIGNALS"))
        XCTAssertTrue(out.contains("WORKOUTS"))
    }

    func testDropOrderThenWodsTrimmedAndNeverPlanSafetyLanguage() {
        let p = parts(strengthSize: 3_000)
        // Tight limit: everything droppable goes.
        let out = AICoachEngine.assembleContext(p, limit: 200)
        XCTAssertFalse(out.contains("STRENGTH"))
        XCTAssertFalse(out.contains("SIGNALS"))
        XCTAssertFalse(out.contains("WORKOUTS"))
        XCTAssertTrue(out.contains("WODS-SHORT"))
        XCTAssertFalse(out.contains("WODS-FULL"))
        for keep in ["TODAY", "PLAN", "STRESS", "GLUCOSE", "SAFETY", "LANGUAGE"] {
            XCTAssertTrue(out.contains(keep), keep)
        }
    }

    func testDropsSignalsBeforeWorkouts() {
        var p = parts()
        p.strength = nil
        p.signals = String(repeating: "G", count: 500)
        let base = AICoachEngine.assembleContext(parts()).count
        let out = AICoachEngine.assembleContext(p, limit: base + 100)
        XCTAssertFalse(out.contains("GGGG"))
        XCTAssertTrue(out.contains("WORKOUTS"))
        XCTAssertTrue(out.contains("WODS-FULL"))
    }

    func testNoConsentContextEndsWithSafetyAndLanguage() {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-aicoach-ctx"))
        let text = engine.noConsentContext()
        let lines = text.components(separatedBy: "\n\n")
        XCTAssertTrue(lines[lines.count - 2].hasPrefix("Safety rules:"))
        XCTAssertTrue(lines.last!.hasPrefix("Reply in"))
    }

    func testDefaultPromptMentionsPlanAndNoInsulin() {
        XCTAssertTrue(AICoachEngine.defaultSystemPrompt.contains("insulin"))
        XCTAssertTrue(AICoachEngine.defaultSystemPrompt.contains("plan"))
    }
}
