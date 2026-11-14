import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The pure steps of `DayPlanBuilder` (wake times, last night, stored profile, goal parsing).
final class DayPlanBuilderTests: XCTestCase {

    private let rome = TimeZone(identifier: "Europe/Rome")!

    private func cal(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }

    /// Unix seconds of a wall-clock time in `tz`.
    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, in tz: TimeZone) -> Int {
        let date = cal(tz).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        return Int(date.timeIntervalSince1970)
    }

    private func night(endingOn d: Int, hour: Int, minute: Int, hours: Double = 7.5, in tz: TimeZone) -> CachedSleepSession {
        let end = ts(2026, 3, d, hour, minute, in: tz)
        return CachedSleepSession(startTs: end - Int(hours * 3600), endTs: end,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    func testWakeMinutesAreLocalTimeOfDayOldestFirst() {
        // Given out of order; Rome is UTC+1 in early March, so the result must follow the zone, not UTC.
        let sleeps = [night(endingOn: 12, hour: 7, minute: 15, in: rome),
                      night(endingOn: 10, hour: 6, minute: 30, in: rome),
                      night(endingOn: 11, hour: 6, minute: 45, in: rome)]
        XCTAssertEqual(DayPlanBuilder.wakeMinutes(sleeps: sleeps, timeZone: rome), [390, 405, 435])
        // The same instants read in UTC are an hour earlier.
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(DayPlanBuilder.wakeMinutes(sleeps: sleeps, timeZone: utc), [330, 345, 375])
    }

    func testWakeMinutesSkipNapsAndKeepOnlyTheLastFourteenNights() {
        var sleeps = (1...20).map { night(endingOn: $0, hour: 7, minute: 0, in: rome) }
        sleeps.append(night(endingOn: 20, hour: 15, minute: 0, hours: 1.5, in: rome))   // a nap, ignored
        let wakes = DayPlanBuilder.wakeMinutes(sleeps: sleeps, timeZone: rome)
        XCTAssertEqual(wakes.count, 14)
        XCTAssertTrue(wakes.allSatisfy { $0 == 420 })
    }

    func testWakeMinutesEmpty() {
        XCTAssertEqual(DayPlanBuilder.wakeMinutes(sleeps: [], timeZone: rome), [])
    }

    func testLastNightIsTheLongestSessionEndingOnTheLocalDay() {
        let now = Date(timeIntervalSince1970: Double(ts(2026, 3, 12, 10, 0, in: rome)))
        let yesterday = night(endingOn: 11, hour: 7, minute: 0, in: rome)
        let short = night(endingOn: 12, hour: 5, minute: 0, hours: 3.5, in: rome)
        let main = night(endingOn: 12, hour: 7, minute: 10, hours: 7, in: rome)
        let found = DayPlanBuilder.lastNight(sleeps: [yesterday, short, main], now: now, timeZone: rome)
        XCTAssertEqual(found, main)
    }

    func testLastNightNilWhenNothingEndedToday() {
        let now = Date(timeIntervalSince1970: Double(ts(2026, 3, 12, 10, 0, in: rome)))
        let old = night(endingOn: 10, hour: 7, minute: 0, in: rome)
        XCTAssertNil(DayPlanBuilder.lastNight(sleeps: [old], now: now, timeZone: rome))
    }

    func testGoalParsingFallsBackToPerformance() {
        XCTAssertEqual(DayPlanBuilder.goal(from: "fatLoss"), .fatLoss)
        XCTAssertEqual(DayPlanBuilder.goal(from: "health"), .health)
        XCTAssertEqual(DayPlanBuilder.goal(from: "nonsense"), .performance)
        XCTAssertEqual(DayPlanBuilder.goal(from: nil), .performance)
    }

    func testStoredProfileValuesReadTheProfileKeysAndDefaults() {
        let suite = "DayPlanBuilderTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        // Same defaults as ProfileStore.init().
        XCTAssertEqual(DayPlanBuilder.ProfileValues.stored(defaults: d),
                       DayPlanBuilder.ProfileValues(age: 30, sex: "male", weightKg: 75, heightCm: 178, goal: .performance))

        d.set(41, forKey: ProfileStore.ageKey)
        d.set("female", forKey: ProfileStore.sexKey)
        d.set(62.5, forKey: ProfileStore.weightKey)
        d.set(168.0, forKey: ProfileStore.heightKey)
        d.set("strength", forKey: DayPlanBuilder.goalKey)
        XCTAssertEqual(DayPlanBuilder.ProfileValues.stored(defaults: d),
                       DayPlanBuilder.ProfileValues(age: 41, sex: "female", weightKg: 62.5, heightCm: 168, goal: .strength))
    }
}
