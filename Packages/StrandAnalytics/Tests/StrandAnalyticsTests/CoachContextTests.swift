import XCTest
import WhoopStore
@testable import StrandAnalytics

final class CoachContextTests: XCTestCase {

    func metric(_ day: String = "2026-11-12", charge: Double? = nil, strain: Double? = nil, sleep: Double? = nil,
                hrv: Double? = nil, rhr: Int? = nil, eff: Double? = nil, deep: Double? = nil,
                rem: Double? = nil, light: Double? = nil, dist: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: eff, deepMin: deep, remMin: rem, lightMin: light,
                    disturbances: dist, restingHr: rhr, avgHrv: hrv, recovery: charge, strain: strain,
                    exerciseCount: nil)
    }

    // MARK: today / profile / language / safety

    func testTodayLine() {
        XCTAssertEqual(CoachContext.todayLine(day: "2026-11-13", weekday: "Friday", localTime: "08:40", chargeScored: true),
                       "Today is Friday 2026-11-13, 08:40 local time. Today's Charge is already scored.")
        XCTAssertEqual(CoachContext.todayLine(day: "2026-11-13", weekday: "Friday", localTime: "08:40", chargeScored: false),
                       "Today is Friday 2026-11-13, 08:40 local time. Today's Charge is not scored yet.")
    }

    func testProfileLine() {
        XCTAssertEqual(CoachContext.profileLine(age: 35, sex: "male", weightKg: 80.5, heightCm: 180, maxHR: 190, goal: .strength),
                       "Profile: age 35, male, 80.5 kg, 180 cm, max heart rate 190 bpm, goal: strength.")
        XCTAssertEqual(CoachContext.profileLine(age: 0, sex: "", weightKg: 0, heightCm: 0, maxHR: 0, goal: .fatLoss),
                       "Profile: goal: fat loss.")
        XCTAssertEqual(CoachContext.profileLine(age: 40, sex: "female", weightKg: 0, heightCm: 165, maxHR: 0, goal: .health),
                       "Profile: age 40, female, 165 cm, goal: general health.")
    }

    func testLanguageLine() {
        XCTAssertEqual(CoachContext.languageLine(languageCode: "it"), "Reply in Italian.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "en"), "Reply in English.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "de"), "Reply in German.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "es"), "Reply in Spanish.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "fr"), "Reply in French.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "pt"), "Reply in Portuguese.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "zh"), "Reply in Chinese.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "ru"), "Reply in Russian.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "it-IT"), "Reply in Italian.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: "xx"), "Reply in the user's language.")
        XCTAssertEqual(CoachContext.languageLine(languageCode: ""), "Reply in the user's language.")
    }

    func testSafetyLine() {
        let s = CoachContext.safetyLine
        XCTAssertTrue(s.contains("never give insulin doses"))
        XCTAssertTrue(s.contains("basal rates, carb ratio or insulin sensitivity"))
        XCTAssertTrue(s.contains("never diagnose"))
        XCTAssertTrue(s.contains("general sports nutrition"))
        XCTAssertTrue(s.contains("diabetes team"))
    }

    // MARK: dayLine

    func testDayLine() {
        let d = metric(charge: 71, strain: 43.2, sleep: 432, hrv: 62, rhr: 51)
        XCTAssertEqual(CoachContext.dayLine(d, restScore: 84),
                       "2026-11-12: charge 71, effort 43.2, sleep 7.2h, rest 84, HRV 62ms, RHR 51bpm")
        XCTAssertEqual(CoachContext.dayLine(metric(charge: 71, sleep: 432), restScore: nil),
                       "2026-11-12: charge 71, sleep 7.2h")
        XCTAssertEqual(CoachContext.dayLine(metric(), restScore: nil), "2026-11-12")
    }

    // MARK: lastNightBlock

    func testLastNightBlock() {
        let d = metric(sleep: 432, eff: 91, deep: 80, rem: 100, light: 252, dist: 3)
        XCTAssertEqual(CoachContext.lastNightBlock(day: d, bedtime: "23:10", wake: "06:30", restScore: 84,
                                                   needMin: 480, debtMin: 45),
                       "LAST NIGHT: asleep 23:10 to 06:30, 7.2 h asleep, efficiency 91%, deep 80 min, REM 100 min, light 252 min, 3 disturbances, Rest score 84, sleep need 8.0 h, sleep debt 45 min.")
        XCTAssertEqual(CoachContext.lastNightBlock(day: metric(sleep: 432, eff: 0.9), bedtime: nil, wake: "06:30",
                                                   restScore: nil, needMin: nil, debtMin: nil),
                       "LAST NIGHT: woke 06:30, 7.2 h asleep, efficiency 90%.")
        XCTAssertNil(CoachContext.lastNightBlock(day: nil, bedtime: nil, wake: nil, restScore: nil, needMin: nil, debtMin: nil))
        XCTAssertNil(CoachContext.lastNightBlock(day: metric(), bedtime: nil, wake: nil, restScore: nil, needMin: nil, debtMin: nil))
    }

    // MARK: loadLine

    func summary(acute: Double, usual: Double?, ratio: Double?) -> TrainingLoad.Summary {
        TrainingLoad.Summary(acute: acute, acuteDays: 7, chronicWeekly: usual, chronicDays: 28, ratio: ratio,
                             band: ratio.map { TrainingLoad.band(ratio: $0) }, weeks: [])
    }

    func testLoadLine() {
        XCTAssertEqual(CoachContext.loadLine(summary(acute: 123, usual: 100, ratio: 1.23)),
                       "Training load: this week 123 against a usual week of 100 (TRIMP units), ratio 1.23, in line with the usual.")
        XCTAssertEqual(CoachContext.loadLine(summary(acute: 160, usual: 100, ratio: 1.6)),
                       "Training load: this week 160 against a usual week of 100 (TRIMP units), ratio 1.60, a sharp rise on the usual.")
        XCTAssertEqual(CoachContext.loadLine(summary(acute: 70, usual: 100, ratio: 0.7)),
                       "Training load: this week 70 against a usual week of 100 (TRIMP units), ratio 0.70, less than usual.")
        XCTAssertEqual(CoachContext.loadLine(summary(acute: 140, usual: 100, ratio: 1.4)),
                       "Training load: this week 140 against a usual week of 100 (TRIMP units), ratio 1.40, more than usual.")
        XCTAssertNil(CoachContext.loadLine(summary(acute: 10, usual: nil, ratio: nil)))
        XCTAssertNil(CoachContext.loadLine(nil))
    }

    // MARK: planBlock

    func testPlanBlockFull() {
        let plan = DayPlan.Plan(
            training: .maintain,
            reasons: [.chargeHigh(80), .shortSleep(minutes: 330, needMinutes: 480), .loadSharpRise(ratio: 1.6)],
            sleep: DayPlan.SleepTarget(minutes: 510, bedtimeMinutes: 1290),
            nutrition: DayPlan.Nutrition(restingKcal: 1755, energyKcal: 2650...2950, proteinG: 110...160,
                                         carbsG: 400...560, fluidMl: 3000),
            focus: [.sleepDebt(minutes: 90), .hrvDown(pct: 12, recent: 53.4, usual: 60.7)])
        XCTAssertEqual(CoachContext.planBlock(plan), """
        TODAY'S PLAN (computed by the app; explain and build on it, do not contradict it without a reason):
        Training: maintain (a normal session). Because: Charge 80 (high); short night: 5.5 h slept against a need of 8.0 h; training load is 1.60 times the usual week (sharp rise).
        Sleep tonight: 8.5 h (510 min), bedtime around 21:30.
        Nutrition (estimates, not prescriptions): energy 2650-2950 kcal (resting about 1755 kcal), protein 110-160 g, carbohydrate 400-560 g (general sports-nutrition range), fluids about 3000 ml.
        Focus: sleep debt of 90 min; HRV down 12% (7-day mean 53 ms against 61 ms usual).
        """)
    }

    func testPlanBlockMinimal() {
        let plan = DayPlan.Plan(training: .easy, reasons: [.noCharge],
                                sleep: DayPlan.SleepTarget(minutes: 480, bedtimeMinutes: nil),
                                nutrition: nil, focus: [])
        let text = CoachContext.planBlock(plan)
        XCTAssertEqual(text, """
        TODAY'S PLAN (computed by the app; explain and build on it, do not contradict it without a reason):
        Training: easy (light activity or recovery). Because: no Charge scored yet.
        Sleep tonight: 8.0 h (480 min).
        """)
        XCTAssertFalse(text.contains("Nutrition"))
        XCTAssertFalse(text.contains("Focus"))
    }

    // MARK: WODs

    func wod(_ id: String, day: String, ts: Int, title: String = "Fran", type: String = "metcon",
             format: String? = "For Time", kind: WodResultKind = .time, seconds: Int? = 272,
             rounds: Int? = nil, reps: Int? = nil, weight: Double? = nil, rpe: Double? = nil, rx: Bool? = nil,
             notes: String? = nil, movements: [WodMovement] = []) -> WodLogRow {
        WodLogRow(id: id, ts: ts, day: day, type: type, title: title, format: format, resultKind: kind,
                  resultSeconds: seconds, resultRounds: rounds, resultReps: reps, resultWeightKg: weight,
                  rpe: rpe, rx: rx, notes: notes, movements: movements, createdTs: ts)
    }

    func testWodLineFull() {
        let w = wod("a", day: "2026-11-10", ts: 100, rpe: 8, rx: false, notes: "SECRET NOTE",
                    movements: [WodMovement(name: "Thruster", scheme: "21-15-9", weightKg: 30, rxWeightKg: 43, notes: "SECRET MOVE NOTE"),
                                WodMovement(name: "Pull-up", reps: 21),
                                WodMovement(name: "Run", rxWeightKg: 20)])
        let text = CoachContext.wodBlock([w], today: "2026-11-13")
        XCTAssertEqual(text, """
        RECENT WODS (newest first):
        - 2026-11-10 Fran (metcon, For Time): result 4:32, RPE 8, scaled; movements: Thruster 21-15-9 @ 30 kg (RX 43 kg), Pull-up 21 reps, Run (RX 20 kg)
        """)
        XCTAssertFalse(text!.contains("SECRET"))
    }

    func testResultFormatting() {
        func line(_ w: WodLogRow) -> String { CoachContext.wodBlock([w], today: w.day)! }
        XCTAssertTrue(line(wod("t", day: "2026-11-10", ts: 1, seconds: 65)).contains("result 1:05"))
        XCTAssertTrue(line(wod("r", day: "2026-11-10", ts: 1, kind: .roundsReps, seconds: nil, rounds: 5, reps: 12))
            .contains("result 5 rounds + 12 reps"))
        XCTAssertTrue(line(wod("r2", day: "2026-11-10", ts: 1, kind: .roundsReps, seconds: nil, rounds: 5))
            .contains("result 5 rounds"))
        XCTAssertTrue(line(wod("p", day: "2026-11-10", ts: 1, kind: .reps, seconds: nil, reps: 150))
            .contains("result 150 reps"))
        XCTAssertTrue(line(wod("w", day: "2026-11-10", ts: 1, kind: .weight, seconds: nil, weight: 102.5))
            .contains("result 102.5 kg"))
        let none = line(wod("n", day: "2026-11-10", ts: 1, format: nil, kind: .none, seconds: 99, rx: true))
        XCTAssertEqual(none, "RECENT WODS (newest first):\n- 2026-11-10 Fran (metcon): RX")
        XCTAssertFalse(none.contains("result"))
    }

    func testWodWindowAndLimit() {
        let today = "2026-11-13"
        let wods = [
            wod("old", day: "2026-10-13", ts: 1, title: "Edge30"),     // exactly 31 days back: out
            wod("edge", day: "2026-10-14", ts: 2, title: "Edge30in"),   // 30 days back: in
            wod("future", day: "2026-11-14", ts: 3, title: "Future"),
            wod("bad", day: "garbage", ts: 4, title: "Bad"),
        ]
        let text = CoachContext.wodBlock(wods, today: today)!
        XCTAssertTrue(text.contains("Edge30in"))
        XCTAssertFalse(text.contains("Edge30 "))
        XCTAssertFalse(text.contains("Future"))
        XCTAssertFalse(text.contains("Bad"))
        XCTAssertNil(CoachContext.wodBlock([wods[0]], today: today))
        XCTAssertNil(CoachContext.wodBlock([], today: today))

        let many = (0..<8).map { wod("w\($0)", day: "2026-11-1\($0 % 3)", ts: $0, title: "W\($0)") }
        let limited = CoachContext.wodBlock(many, today: today)!
        let lines = limited.split(separator: "\n")
        XCTAssertEqual(lines.count, 6)       // header + 5
        XCTAssertTrue(lines[1].contains("W7"))   // newest first
        XCTAssertTrue(lines[5].contains("W3"))
        XCTAssertEqual(CoachContext.wodBlock(many, today: today, limit: 2)!.split(separator: "\n").count, 3)
        XCTAssertNil(CoachContext.wodBlock(many, today: today, limit: 0))
        // custom window
        XCTAssertNil(CoachContext.wodBlock([wod("x", day: "2026-11-01", ts: 1)], today: today, windowDays: 5))
    }

    func testDayDifference() {
        XCTAssertEqual(CoachContext.dayDifference(from: "2026-02-28", to: "2026-03-01"), 1)
        XCTAssertEqual(CoachContext.dayDifference(from: "2026-03-01", to: "2026-02-28"), -1)
        XCTAssertEqual(CoachContext.dayDifference(from: "2025-12-31", to: "2026-01-01"), 1)
        XCTAssertNil(CoachContext.dayDifference(from: "nope", to: "2026-01-01"))
    }
}
