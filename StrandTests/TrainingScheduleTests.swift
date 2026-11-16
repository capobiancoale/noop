import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The training-schedule steps of `DayPlanBuilder`: stored answers, validation and the conversion of workouts and
/// WODs into `TrainingPattern` sessions in the phone's time zone.
final class TrainingScheduleTests: XCTestCase {

    private let rome = TimeZone(identifier: "Europe/Rome")!

    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, in tz: TimeZone) -> Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return Int(c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970)
    }

    private func workout(start: Int, durationS: Double?) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + Int(durationS ?? 0), sport: "CrossFit", source: "test",
                   durationS: durationS, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                   zonesJSON: nil, notes: nil)
    }

    private func wod(ts: Int, endTs: Int?) -> WodLogRow {
        WodLogRow(id: UUID().uuidString, ts: ts, day: "x", type: "WOD", title: "Fran", createdTs: ts, endTs: endTs)
    }

    // MARK: Stored answers

    func testDefaultsAreTheUsersOwnAnswers() {
        let d = UserDefaults(suiteName: "TrainingScheduleTests.defaults")!
        d.removePersistentDomain(forName: "TrainingScheduleTests.defaults")
        let v = DayPlanBuilder.ProfileValues.stored(defaults: d)
        XCTAssertEqual(v.trainingDaysPerWeek, 5)
        XCTAssertEqual(v.usualTrainingMinutes, 19 * 60)
        XCTAssertEqual(v.usualSessionMinutes, 60)
    }

    func testStoredAnswersAreReadBackAndInvalidOnesFallBack() {
        let d = UserDefaults(suiteName: "TrainingScheduleTests.stored")!
        d.removePersistentDomain(forName: "TrainingScheduleTests.stored")
        d.set(4, forKey: DayPlanBuilder.trainingDaysKey)
        d.set(20 * 60, forKey: DayPlanBuilder.trainingTimeKey)
        d.set(75, forKey: DayPlanBuilder.sessionMinutesKey)
        let v = DayPlanBuilder.ProfileValues.stored(defaults: d)
        XCTAssertEqual(v.trainingDaysPerWeek, 4)
        XCTAssertEqual(v.usualTrainingMinutes, 1200)
        XCTAssertEqual(v.usualSessionMinutes, 75)

        XCTAssertEqual(DayPlanBuilder.validTrainingDays(0), 5)
        XCTAssertEqual(DayPlanBuilder.validTrainingDays(8), 5)
        XCTAssertEqual(DayPlanBuilder.validTrainingDays(7), 7)
        XCTAssertEqual(DayPlanBuilder.validTrainingMinutes(-1), 1140)
        XCTAssertEqual(DayPlanBuilder.validTrainingMinutes(1440), 1140)
        XCTAssertEqual(DayPlanBuilder.validTrainingMinutes(0), 0)
        XCTAssertEqual(DayPlanBuilder.validSessionMinutes(10), 60)
        XCTAssertEqual(DayPlanBuilder.validSessionMinutes(241), 60)
        XCTAssertEqual(DayPlanBuilder.validSessionMinutes(15), 15)
        XCTAssertEqual(DayPlanBuilder.validSessionMinutes(nil), 60)
    }

    // MARK: Sessions

    func testWorkoutBecomesALocalSession() {
        // Wednesday 2026-03-11 19:05 in Rome (UTC+1): 62 minutes
        let s = DayPlanBuilder.trainingSessions(
            workouts: [workout(start: ts(2026, 3, 11, 19, 5, in: rome), durationS: 62 * 60)], wods: [], timeZone: rome)
        XCTAssertEqual(s, [TrainingPattern.Session(day: "2026-03-11", weekday: 4, startMinutes: 19 * 60 + 5,
                                                   durationMinutes: 62)])
    }

    func testDayAndWeekdayFollowTheZoneNotUTC() {
        // 00:30 Rome on Thursday 2026-03-12 is still Wednesday in UTC
        let start = ts(2026, 3, 12, 0, 30, in: rome)
        let s = DayPlanBuilder.trainingSessions(workouts: [workout(start: start, durationS: 3600)], wods: [], timeZone: rome)
        XCTAssertEqual(s.first?.day, "2026-03-12")
        XCTAssertEqual(s.first?.weekday, 5)
        XCTAssertEqual(s.first?.startMinutes, 30)
    }

    func testWorkoutLengthFallsBackToItsEndAndWodsUseTheirSpan() {
        let start = ts(2026, 3, 11, 18, 0, in: rome)
        let fromEnd = DayPlanBuilder.trainingSessions(
            workouts: [WorkoutRow(startTs: start, endTs: start + 45 * 60, sport: "x", source: "t", durationS: nil,
                                  energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                  zonesJSON: nil, notes: nil)], wods: [], timeZone: rome)
        XCTAssertEqual(fromEnd.first?.durationMinutes, 45)

        let withSpan = DayPlanBuilder.trainingSessions(
            workouts: [], wods: [wod(ts: start, endTs: start + 70 * 60)], timeZone: rome)
        XCTAssertEqual(withSpan.first?.durationMinutes, 70)
        XCTAssertEqual(withSpan.first?.startMinutes, 18 * 60)

        let noSpan = DayPlanBuilder.trainingSessions(workouts: [], wods: [wod(ts: start, endTs: nil)], timeZone: rome)
        XCTAssertNil(noSpan.first?.durationMinutes)
        XCTAssertEqual(noSpan.count, 1)
    }

    func testEightWeeksOfThreeSessionsAreLearned() {
        // Mon/Wed/Fri 19:00 for 8 weeks ending Friday 2026-03-13
        var workouts: [WorkoutRow] = []
        for back in 0..<56 {
            let day = ts(2026, 3, 13, 19, 0, in: rome) - back * 86_400
            var c = Calendar(identifier: .gregorian); c.timeZone = rome
            if [2, 4, 6].contains(c.component(.weekday, from: Date(timeIntervalSince1970: Double(day)))) {
                workouts.append(workout(start: day, durationS: 3600))
            }
        }
        let sessions = DayPlanBuilder.trainingSessions(workouts: workouts, wods: [], timeZone: rome)
        let r = TrainingPattern.learn(sessions: sessions, today: "2026-03-13", dataSince: "2026-01-17")
        XCTAssertEqual(r.weekdays, [2, 4, 6])
        XCTAssertEqual(r.startMinutes, 19 * 60)
        XCTAssertEqual(r.durationMinutes, 60)
    }
}
