import XCTest
@testable import StrandImport

final class WodGlucoseTimelineTests: XCTestCase {

    private let t0 = 1_790_000_000.0          // an arbitrary instant: the logged time

    // MARK: Where the WOD sat

    func testARecordedWorkoutAroundTheLoggedTimeIsTheWod() {
        // Logged at 12:00 for a 30-minute WOD; the strap recorded 12:05–12:41.
        let w = WodTimeWindow.resolve(loggedTs: t0, durationS: 1_800,
                                      workouts: [(t0 + 300, t0 + 2_460)])
        XCTAssertEqual(w, WodTimeWindow(start: t0 + 300, end: t0 + 2_460, recorded: true))
    }

    func testTheLoggedTimeMayMarkTheEnd() {
        // Logged when finished: the workout ran in the 30 minutes before the logged time.
        let w = WodTimeWindow.resolve(loggedTs: t0, durationS: 1_800, workouts: [(t0 - 1_900, t0 - 60)])
        XCTAssertTrue(w.recorded)
        XCTAssertEqual(w.start, t0 - 1_900)
    }

    func testTheWorkoutOverlappingMostWinsOverAWarmUpNearby() {
        let warmUp = (start: t0 - 2_400, end: t0 - 1_900)       // outside the WOD's possible span, within slack
        let wod = (start: t0 + 60, end: t0 + 1_900)
        let w = WodTimeWindow.resolve(loggedTs: t0, durationS: 1_800, workouts: [warmUp, wod])
        XCTAssertEqual(w.start, wod.start)
    }

    func testFarOrAllDayWorkoutsAreNotTheWod() {
        let farLater = (start: t0 + 6 * 3_600, end: t0 + 7 * 3_600)
        let allDay = (start: t0 - 10 * 3_600, end: t0 + 10 * 3_600)
        let w = WodTimeWindow.resolve(loggedTs: t0, durationS: 1_200, workouts: [farLater, allDay])
        XCTAssertEqual(w, WodTimeWindow(start: t0, end: t0 + 1_200, recorded: false))
    }

    func testWithoutADurationTheWodIsAssumedTwentyMinutes() {
        let w = WodTimeWindow.resolve(loggedTs: t0, durationS: nil, workouts: [])
        XCTAssertEqual(w.durationMinutes, 20)
        XCTAssertFalse(w.recorded)
    }

    // MARK: The chart model

    private func reading(_ minutesFromStart: Double, _ mgdl: Double, window: WodTimeWindow) -> GlucoseReading {
        GlucoseReading(ts: window.start + minutesFromStart * 60, day: "d", minutesLocal: 0, mgdl: mgdl)
    }

    func testTheClockStartsAtTheWodAndTheAxisCountsFromItsStartAndEnd() {
        let window = WodTimeWindow(start: t0, end: t0 + 30 * 60, recorded: true)
        let tl = WodGlucoseTimeline(window: window, readings: [reading(-30, 150, window: window)], carbs: [], insulin: [])
        XCTAssertEqual(tl.readings.first?.minutes, -30)
        XCTAssertEqual(tl.xDomain, -120...(30 + 240))
        XCTAssertEqual(tl.ticks.map(\.minutes), [-120, -60, 90, 150, 210, 270])
        XCTAssertEqual(tl.ticks.map(\.hours), [2, 1, 1, 2, 3, 4])
        XCTAssertEqual(tl.ticks.first?.anchor, .beforeStart)
        XCTAssertEqual(tl.ticks.last?.anchor, .afterEnd)
    }

    func testReadingsOutsideTheWindowAreLeftOutAndGapsBreakTheLine() {
        let window = WodTimeWindow(start: t0, end: t0 + 20 * 60, recorded: false)
        var rs = [reading(-200, 120, window: window)]                           // before the window
        rs += stride(from: -60.0, through: 0, by: 5).map { reading($0, 150, window: window) }
        rs += stride(from: 25.0, through: 60, by: 5).map { reading($0, 110, window: window) }   // 25-min gap
        rs.append(reading(20 + 245, 100, window: window))                       // after the window
        let tl = WodGlucoseTimeline(window: window, readings: rs.shuffled(), carbs: [], insulin: [])
        XCTAssertEqual(tl.readings.first?.minutes, -60)
        XCTAssertEqual(tl.readings.last?.minutes, 60)
        XCTAssertEqual(Set(tl.readings.map(\.segment)), [0, 1])
        XCTAssertEqual(tl.readings.first(where: { $0.minutes == 25 })?.segment, 1)
    }

    func testNadirTimeBelowSeventyAndAYScaleThatNeverClipsALow() {
        let window = WodTimeWindow(start: t0, end: t0 + 30 * 60, recorded: true)
        let values: [(Double, Double)] = [(-10, 181), (40, 90), (45, 68), (50, 55), (55, 39), (60, 62), (65, 75), (70, 86)]
        let tl = WodGlucoseTimeline(window: window, readings: values.map { reading($0.0, $0.1, window: window) },
                                    carbs: [], insulin: [])
        XCTAssertEqual(tl.nadir?.mgdl, 39)
        XCTAssertEqual(tl.nadir?.minutes, 55)
        XCTAssertEqual(tl.minutesBelowLow, 20)                  // 45, 50, 55, 60: four 5-minute steps
        XCTAssertLessThanOrEqual(tl.yDomain.lowerBound, 31)
        XCTAssertGreaterThanOrEqual(tl.yDomain.upperBound, 200)
        XCTAssertEqual(tl.yDomain.lowerBound.truncatingRemainder(dividingBy: 10), 0)
    }

    func testTheLowAreaEndsWhereTheTraceCrossesSeventy() {
        let window = WodTimeWindow(start: t0, end: t0 + 20 * 60, recorded: true)
        let values: [(Double, Double)] = [(0, 90), (5, 60), (10, 90), (40, 150), (45, 160)]   // 30-min gap after 10
        let tl = WodGlucoseTimeline(window: window, readings: values.map { reading($0.0, $0.1, window: window) },
                                    carbs: [], insulin: [])
        XCTAssertEqual(tl.lowArea.map(\.minutes).map { ($0 * 1_000).rounded() / 1_000 }, [0, 3.333, 5, 6.667, 10])
        XCTAssertEqual(tl.lowArea.map(\.mgdl), [70, 70, 60, 70, 70])
        XCTAssertEqual(Set(tl.lowArea.map(\.segment)), [0], "the segment that stays above 70 has no area")
        XCTAssertEqual(tl.minutesBelowLow, 5)
    }

    func testEventsCloseTogetherShareOneMarkerAndBasalIsLeftOut() {
        let window = WodTimeWindow(start: t0, end: t0 + 30 * 60, recorded: true)
        let carbs = [CarbEntry(ts: t0 - 90 * 60, grams: 20), CarbEntry(ts: t0 - 80 * 60, grams: 10),
                     CarbEntry(ts: t0 + 90 * 60, grams: 40), CarbEntry(ts: t0 - 5 * 3_600, grams: 50)]
        let insulin = [InsulinEntry(ts: t0 - 100 * 60, units: 3, bolus: true),
                       InsulinEntry(ts: t0 + 10 * 60, units: 0.4, bolus: false),
                       InsulinEntry(ts: t0 + 120 * 60, units: 3.7, bolus: true)]
        let tl = WodGlucoseTimeline(window: window, readings: [], carbs: carbs, insulin: insulin)
        XCTAssertEqual(tl.carbs.map(\.amount), [30, 40])
        XCTAssertEqual(tl.carbs.first?.minutes, -90)
        XCTAssertEqual(tl.boluses.map(\.amount), [3, 3.7])
        XCTAssertNil(tl.nadir)
        XCTAssertEqual(tl.yDomain, 50...200)
    }
}
