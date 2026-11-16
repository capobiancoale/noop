import XCTest
@testable import Strand

/// The wake-up target of "Today's plan": the user's own time, else NOOP's smart alarm, else automatic.
final class DayPlanWakeTargetTests: XCTestCase {

    private let rome = TimeZone(identifier: "Europe/Rome")!

    /// Saturday 14 Nov 2026, 20:00 in Rome; the morning after is a Sunday (Calendar weekday 1).
    private var saturdayEvening: Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = rome
        return c.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 20))!
    }

    private func defaults() -> (UserDefaults, () -> Void) {
        let suite = "DayPlanWakeTargetTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    func testValidWakeMinutes() {
        XCTAssertEqual(DayPlanBuilder.validWakeMinutes(nil), -1)
        XCTAssertEqual(DayPlanBuilder.validWakeMinutes(-1), -1)
        XCTAssertEqual(DayPlanBuilder.validWakeMinutes(1440), -1)
        XCTAssertEqual(DayPlanBuilder.validWakeMinutes(0), 0)
        XCTAssertEqual(DayPlanBuilder.validWakeMinutes(1439), 1439)
    }

    func testStoredProfileValuesCarryTheWakeTime() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        XCTAssertEqual(DayPlanBuilder.ProfileValues.stored(defaults: d).wakeTimeMinutes, -1)
        d.set(405, forKey: DayPlanBuilder.wakeTimeKey)
        XCTAssertEqual(DayPlanBuilder.ProfileValues.stored(defaults: d).wakeTimeMinutes, 405)
        d.set(5000, forKey: DayPlanBuilder.wakeTimeKey)
        XCTAssertEqual(DayPlanBuilder.ProfileValues.stored(defaults: d).wakeTimeMinutes, -1)
    }

    func testSmartAlarmOffGivesNothing() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        XCTAssertNil(DayPlanBuilder.smartAlarmWakeMinutes(defaults: d, now: saturdayEvening, timeZone: rome))
        d.set(false, forKey: DayPlanBuilder.smartAlarmEnabledKey)
        d.set(390, forKey: DayPlanBuilder.smartAlarmMinutesKey)
        XCTAssertNil(DayPlanBuilder.smartAlarmWakeMinutes(defaults: d, now: saturdayEvening, timeZone: rome))
    }

    func testSmartAlarmOnEveryDayAndDefaultTime() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        d.set(true, forKey: DayPlanBuilder.smartAlarmEnabledKey)
        XCTAssertEqual(DayPlanBuilder.smartAlarmWakeMinutes(defaults: d, now: saturdayEvening, timeZone: rome), 420)
        d.set(375, forKey: DayPlanBuilder.smartAlarmMinutesKey)
        XCTAssertEqual(DayPlanBuilder.smartAlarmWakeMinutes(defaults: d, now: saturdayEvening, timeZone: rome), 375)
    }

    func testSmartAlarmWeekdaysMustIncludeTomorrow() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        d.set(true, forKey: DayPlanBuilder.smartAlarmEnabledKey)
        d.set(375, forKey: DayPlanBuilder.smartAlarmMinutesKey)
        d.set([2, 3, 4, 5, 6], forKey: DayPlanBuilder.smartAlarmWeekdaysKey)   // Mon-Fri
        XCTAssertNil(DayPlanBuilder.smartAlarmWakeMinutes(defaults: d, now: saturdayEvening, timeZone: rome))
        d.set([1], forKey: DayPlanBuilder.smartAlarmWeekdaysKey)               // Sunday
        XCTAssertEqual(DayPlanBuilder.smartAlarmWakeMinutes(defaults: d, now: saturdayEvening, timeZone: rome), 375)
    }

    func testUserTimeBeatsTheAlarmAndAutomaticFallsBack() {
        let (d, cleanup) = defaults(); defer { cleanup() }
        d.set(true, forKey: DayPlanBuilder.smartAlarmEnabledKey)
        d.set(375, forKey: DayPlanBuilder.smartAlarmMinutesKey)
        XCTAssertEqual(DayPlanBuilder.wakeTarget(userMinutes: 450, defaults: d, now: saturdayEvening, timeZone: rome), 450)
        XCTAssertEqual(DayPlanBuilder.wakeTarget(userMinutes: -1, defaults: d, now: saturdayEvening, timeZone: rome), 375)
        d.set(false, forKey: DayPlanBuilder.smartAlarmEnabledKey)
        XCTAssertNil(DayPlanBuilder.wakeTarget(userMinutes: -1, defaults: d, now: saturdayEvening, timeZone: rome))
    }
}
