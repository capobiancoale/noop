import XCTest
@testable import StrandAnalytics

final class TrainingPatternTests: XCTestCase {

    let today = "2026-11-13"   // a Friday

    func key(_ back: Int) -> String { FitnessAgeEngine.shiftDay(today, by: -back)! }

    func sess(_ back: Int, start: Int = 19 * 60, dur: Int? = 60) -> TrainingPattern.Session {
        let d = key(back)
        return TrainingPattern.Session(day: d, weekday: TrainingPattern.weekday(ofDayKey: d)!,
                                       startMinutes: start, durationMinutes: dur)
    }

    /// One session on each of `weekdays` in each of the `weeks` weeks ending today (every weekday, 0 ..< 7·weeks days back).
    func weekly(_ weekdays: Set<Int>, weeks: Int, start: Int = 19 * 60, dur: Int? = 60) -> [TrainingPattern.Session] {
        (0..<(7 * weeks)).map { sess($0, start: start, dur: dur) }.filter { weekdays.contains($0.weekday) }
    }

    /// `learn` with the data starting exactly `weeks` weeks back (the app knows when its data began).
    func learn(_ s: [TrainingPattern.Session], weeks: Int = 8) -> TrainingPattern.Result {
        TrainingPattern.learn(sessions: s, today: today, dataSince: key(7 * weeks - 1))
    }

    func testWeekdayOfDayKey() {
        XCTAssertEqual(TrainingPattern.weekday(ofDayKey: "2026-11-13"), 6)   // Friday
        XCTAssertEqual(TrainingPattern.weekday(ofDayKey: "2026-11-15"), 1)   // Sunday
        XCTAssertEqual(TrainingPattern.weekday(ofDayKey: "2026-11-14"), 7)   // Saturday
        XCTAssertNil(TrainingPattern.weekday(ofDayKey: "nope"))
        XCTAssertEqual(TrainingPattern.nextWeekday(7), 1)
        XCTAssertEqual(TrainingPattern.nextWeekday(2), 3)
    }

    func testSteadyThreeDaysAWeek() {
        let r = learn(weekly([2, 4, 6], weeks: 8))
        XCTAssertEqual(r.weekdays, [2, 4, 6])
        XCTAssertEqual(r.startMinutes, 19 * 60)
        XCTAssertEqual(r.durationMinutes, 60)
        XCTAssertEqual(r.weeksObserved, 8)
        XCTAssertEqual(r.sessionDays, 24)
    }

    func testHalfOfTheWeeksIsEnoughLessIsNot() {
        // Tuesday (3) in 4 of 8 weeks counts; Thursday (5) in 3 of 8 does not.
        func tuesdays(_ n: Int) -> [TrainingPattern.Session] {
            Array((0..<56).map { sess($0) }.filter { $0.weekday == 3 }.prefix(n))
        }
        func thursdays(_ n: Int) -> [TrainingPattern.Session] {
            Array((0..<56).map { sess($0) }.filter { $0.weekday == 5 }.prefix(n))
        }
        let base = weekly([2], weeks: 8)
        let r = learn(base + tuesdays(4) + thursdays(3))
        XCTAssertEqual(r.weekdays, [2, 3])
        XCTAssertEqual(learn(base + tuesdays(3)).weekdays, [2])
    }

    func testOddNumberOfWeeksNeedsHalfRoundedUp() {
        // 5 weeks of data: 2 of 5 is under 50 %, 3 of 5 is over.
        func tuesdays(_ n: Int) -> [TrainingPattern.Session] {
            Array((0..<35).map { sess($0) }.filter { $0.weekday == 3 }.prefix(n))
        }
        let base = weekly([2], weeks: 5)
        XCTAssertEqual(learn(base + tuesdays(2), weeks: 5).weekdays, [2])
        XCTAssertEqual(learn(base + tuesdays(3), weeks: 5).weekdays, [2, 3])
    }

    func testNeedsFourWeeks() {
        // 27 days of data = 3 whole weeks: nothing is reported
        let three = TrainingPattern.learn(sessions: weekly([2, 4, 6], weeks: 4).filter { $0.day >= key(26) }, today: today, dataSince: key(26))
        XCTAssertNil(three.weekdays); XCTAssertNil(three.startMinutes); XCTAssertNil(three.durationMinutes)
        XCTAssertEqual(three.weeksObserved, 3)
        // 28 days = 4 weeks: ok
        let four = learn(weekly([2, 4, 6], weeks: 4), weeks: 4)
        XCTAssertEqual(four.weekdays, [2, 4, 6])
        XCTAssertEqual(four.weeksObserved, 4)
        XCTAssertEqual(TrainingPattern.learn(sessions: [], today: today), .empty)
    }

    func testDataSinceCountsWeeksWithoutSessions() {
        // two Mondays only, but the app has data for 8 weeks: Monday was 2 of 8, not usual
        let s = (0..<56).map { sess($0) }.filter { $0.weekday == 2 }.prefix(2)
        XCTAssertNil(TrainingPattern.learn(sessions: Array(s), today: today, dataSince: key(55)).weekdays)
        // without dataSince the span is only what the sessions show (shorter than 4 weeks here)
        XCTAssertEqual(TrainingPattern.learn(sessions: Array(s), today: today).weeksObserved, 1)
    }

    func testOldSessionsAreOutsideTheWindow() {
        var s = weekly([2, 4, 6], weeks: 8)
        s += (56..<120).map { sess($0) }.filter { $0.weekday == 3 || $0.weekday == 5 }   // Tue/Thu long ago
        XCTAssertEqual(TrainingPattern.learn(sessions: s, today: today, dataSince: key(119)).weekdays, [2, 4, 6])
    }

    func testMedianStartAndDurationRoundedTo5() {
        var s: [TrainingPattern.Session] = []
        let starts = [18 * 60, 18 * 60, 19 * 60, 19 * 60, 19 * 60 + 7, 20 * 60, 20 * 60, 20 * 60 + 10]
        let durs = [55, 60, 60, 62, 65, 70, 50, 75]
        for (i, st) in starts.enumerated() { s.append(sess(i * 3, start: st, dur: durs[i])) }
        s.append(sess(55))   // opens the 8-week window
        let r = TrainingPattern.learn(sessions: s, today: today)
        // starts sorted: 1080 1080 1140 1140 1147 1200 1200 1210 1140(sess55) -> 9 values, median = 1140
        XCTAssertEqual(r.startMinutes, 1140)
        // durations: 50 55 60 60 60 62 65 70 75 -> median 60
        XCTAssertEqual(r.durationMinutes, 60)
        // an even count rounds: 1140 and 1147 -> 1143.5 -> 1145
        XCTAssertEqual(TrainingPattern.roundTo5(1143.5), 1145)
    }

    func testTooFewSessionsForStartAndDuration() {
        let s = (0..<5).map { sess($0 * 11) }                 // 5 training days over 8 weeks
        let r = learn(s)
        XCTAssertNil(r.startMinutes); XCTAssertNil(r.durationMinutes)
        XCTAssertEqual(r.sessionDays, 5)
        let six = learn((0..<6).map { sess($0 * 9) })
        XCTAssertEqual(six.startMinutes, 19 * 60)
        // unknown durations do not count for the duration
        let noDur = learn((0..<6).map { sess($0 * 9, dur: nil) })
        XCTAssertEqual(noDur.startMinutes, 19 * 60); XCTAssertNil(noDur.durationMinutes)
    }

    func testTwoSessionsOnOneDayAreOneTrainingDay() {
        var s = weekly([2, 4, 6], weeks: 8)
        // a WOD logged at 19:05 with no length, next to the strap workout at 19:00 for 60 min, on every training day
        s += s.map { TrainingPattern.Session(day: $0.day, weekday: $0.weekday, startMinutes: $0.startMinutes + 5, durationMinutes: nil) }
        let r = learn(s)
        XCTAssertEqual(r.sessionDays, 24)
        XCTAssertEqual(r.startMinutes, 19 * 60)         // the longest one (known length) gives the start
        XCTAssertEqual(r.durationMinutes, 60)
        // the longest wins even when it started later
        let a = TrainingPattern.Session(day: key(0), weekday: 6, startMinutes: 18 * 60, durationMinutes: 25)
        let b = TrainingPattern.Session(day: key(0), weekday: 6, startMinutes: 19 * 60, durationMinutes: 50)
        let more = weekly([6], weeks: 8).filter { $0.day != key(0) }
        XCTAssertEqual(learn(more + [a, b]).sessionDays, 8)
    }

    func testShortBoutsAreNotTraining() {
        let walks = weekly([1, 3, 5, 7], weeks: 8, dur: 19)
        let gym = weekly([2, 4], weeks: 8)
        let r = learn(walks + gym)
        XCTAssertEqual(r.weekdays, [2, 4])
        XCTAssertEqual(learn(weekly([2], weeks: 8, dur: 20)).weekdays, [2])
    }

    func testBadSessionsAreIgnored() {
        let bad = [TrainingPattern.Session(day: key(1), weekday: 0, startMinutes: 600, durationMinutes: 60),
                   TrainingPattern.Session(day: key(2), weekday: 3, startMinutes: 1440, durationMinutes: 60)]
        XCTAssertEqual(TrainingPattern.learn(sessions: bad, today: today), .empty)
    }

    func testResolveUsesLearnedThenProfile() {
        let learned = TrainingPattern.Result(weekdays: [2, 4, 6], startMinutes: 20 * 60, durationMinutes: nil,
                                             weeksObserved: 8, sessionDays: 24)
        let s = TrainingPattern.resolve(learned: learned, profileDaysPerWeek: 5, profileStartMinutes: 19 * 60,
                                        profileSessionMinutes: 60)
        XCTAssertEqual(s.weekdays, [2, 4, 6])
        XCTAssertEqual(s.daysPerWeek, 3)
        XCTAssertEqual(s.startMinutes, 20 * 60)
        XCTAssertEqual(s.sessionMinutes, 60)
        XCTAssertTrue(s.daysLearned); XCTAssertTrue(s.startLearned); XCTAssertFalse(s.durationLearned)
        XCTAssertFalse(s.isFullyLearned)
        XCTAssertEqual(s.trains(on: 2), true)
        XCTAssertEqual(s.trains(on: 3), false)

        let p = TrainingPattern.resolve(learned: .empty, profileDaysPerWeek: 5, profileStartMinutes: 19 * 60,
                                        profileSessionMinutes: 60)
        XCTAssertNil(p.weekdays)
        XCTAssertEqual(p.daysPerWeek, 5)
        XCTAssertEqual(p.startMinutes, 19 * 60)
        XCTAssertEqual(p.sessionMinutes, 60)
        XCTAssertFalse(p.daysLearned)
        XCTAssertNil(p.trains(on: 2))
        XCTAssertEqual(TrainingPattern.resolve(learned: .empty, profileDaysPerWeek: 12, profileStartMinutes: -1,
                                               profileSessionMinutes: 0).daysPerWeek, 7)
        XCTAssertNil(TrainingPattern.resolve(learned: .empty, profileDaysPerWeek: 3, profileStartMinutes: -1,
                                             profileSessionMinutes: 0).startMinutes)
    }
}
