import XCTest
@testable import StrandImport

final class GlucoseTimelineTests: XCTestCase {

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

    // MARK: The glucose trace

    private func trace(_ values: [(Double, Double)], gap: Double = GlucoseTrace.defaultMaxGap) -> GlucoseTrace {
        GlucoseTrace(readings: values.shuffled().map {
            GlucoseReading(ts: t0 + $0.0 * 60, day: "d", minutesLocal: 0, mgdl: $0.1)
        }, maxGapSeconds: gap)
    }

    private func at(_ minutes: Double) -> Double { t0 + minutes * 60 }

    func testGapsBreakTheLineAndDuplicatesAreDropped() {
        var values = stride(from: 0.0, through: 30, by: 5).map { ($0, 150.0) }
        values += stride(from: 50.0, through: 70, by: 5).map { ($0, 110.0) }           // a 20-minute gap
        values.append((10, 150))                                                      // the same reading twice
        let tr = trace(values)
        XCTAssertEqual(tr.points.count, 12)
        XCTAssertEqual(tr.points.map(\.ts), tr.points.map(\.ts).sorted())
        XCTAssertEqual(Set(tr.points.map(\.segment)), [0, 1])
        XCTAssertEqual(tr.points.first { $0.ts == at(50) }?.segment, 1)
    }

    func testTheVisiblePointsReachPastBothEdges() {
        let tr = trace(stride(from: 0.0, through: 60, by: 5).map { ($0, 100.0) })
        let v = tr.visible(from: at(12), to: at(31))
        XCTAssertEqual(v.first?.ts, at(10))
        XCTAssertEqual(v.last?.ts, at(35))
        XCTAssertEqual(tr.inside(from: at(12), to: at(30)).map(\.ts), [at(15), at(20), at(25), at(30)])
        XCTAssertTrue(tr.visible(from: at(100), to: at(120)).count <= 1)
    }

    func testTheNearestReadingMustBeCloseEnough() {
        let tr = trace([(0, 100), (5, 110), (10, 120)])
        XCTAssertEqual(tr.nearest(to: at(6), within: 300)?.mgdl, 110)
        XCTAssertEqual(tr.nearest(to: at(8), within: 300)?.mgdl, 120)
        XCTAssertNil(tr.nearest(to: at(20), within: 300))
        XCTAssertNil(GlucoseTrace(readings: []).nearest(to: t0, within: 300))
    }

    func testFiguresForTheWindowOnScreen() {
        let tr = trace([(-10, 181), (40, 90), (45, 68), (50, 55), (55, 39), (60, 62), (65, 75), (70, 86)])
        let e = tr.extremes(from: at(-60), to: at(120))
        XCTAssertEqual(e?.low.mgdl, 39)
        XCTAssertEqual(e?.low.ts, at(55))
        XCTAssertEqual(e?.high.mgdl, 181)
        XCTAssertEqual(tr.extremes(from: at(44), to: at(51))?.high.mgdl, 68)
        XCTAssertNil(tr.extremes(from: at(100), to: at(110)))
        XCTAssertEqual(tr.mean(from: at(40), to: at(45)), 79)
        // 45, 50, 55, 60 are low: four 5-minute steps.
        XCTAssertEqual(tr.secondsBelow(from: at(-60), to: at(120)), 20 * 60)
        // Clipped to the window: half of 45–50, then 50–52.
        XCTAssertEqual(tr.secondsBelow(from: at(47.5), to: at(52)), 4.5 * 60, accuracy: 1e-6)
    }

    func testTheLastLowReadingBeforeAGapCountsOneInterval() {
        let tr = trace([(0, 90), (5, 60), (40, 60)])                   // gap after 5; 40 is the last reading
        XCTAssertEqual(tr.secondsBelow(from: at(0), to: at(60)), 10 * 60)
    }

    func testTheLowAreaEndsWhereTheTraceCrossesSeventy() {
        let tr = trace([(0, 90), (5, 60), (10, 90), (40, 150), (45, 160)])      // a 30-minute gap after 10
        let area = tr.lowArea()
        XCTAssertEqual(area.map { (($0.ts - t0) / 60 * 1_000).rounded() / 1_000 }, [0, 3.333, 5, 6.667, 10])
        XCTAssertEqual(area.map(\.mgdl), [70, 70, 60, 70, 70])
        XCTAssertEqual(Set(area.map(\.segment)), [0], "the segment that stays above 70 has no area")
        XCTAssertTrue(trace([(0, 120), (5, 130)]).lowArea().isEmpty)
    }

    func testTheScaleNeverClipsALowAndKeepsTheTargetInView() {
        XCTAssertEqual(trace([(0, 100), (5, 150)]).displayRange(), 50...200)
        let r = trace([(0, 39), (5, 260)]).displayRange()
        XCTAssertLessThanOrEqual(r.lowerBound, 31)
        XCTAssertGreaterThanOrEqual(r.upperBound, 272)
        XCTAssertEqual(r.lowerBound.truncatingRemainder(dividingBy: 10), 0)
        XCTAssertGreaterThanOrEqual(trace([(0, 100)]).displayRange(targetLow: 80, targetHigh: 220).upperBound, 240)
    }

    // MARK: Carbs and boluses

    func testEntriesCloseTogetherShareOneMarker() {
        let entries: [(ts: Double, amount: Double)] = [(at(10), 10), (at(-90), 20), (at(-80), 10),
                                                       (at(90), 40), (at(95), 0)]
        let m = TimelineEvents.merged(entries, within: 20 * 60)
        XCTAssertEqual(m.map(\.amount), [30, 10, 40])
        XCTAssertEqual(m.map(\.count), [2, 1, 1])
        XCTAssertEqual(m.first?.ts, at(-90))
        XCTAssertEqual(TimelineEvents.merged(entries, within: 60).count, 4, "zoomed in, each entry is its own")
        XCTAssertEqual(TimelineEvents.mergeDistance(span: 6 * 3_600), 900)
        XCTAssertEqual(TimelineEvents.mergeDistance(span: 600), 60)
    }

    // MARK: Axis

    func testTheStepGivesAtMostFiveTicks() {
        XCTAssertEqual(TimelineTicks.step(span: 6 * 3_600 + 1_800), 7_200)
        XCTAssertEqual(TimelineTicks.step(span: 3_600), 900)
        XCTAssertEqual(TimelineTicks.step(span: 60), 15)
        XCTAssertEqual(TimelineTicks.step(span: 30 * 86_400), 21_600)
    }

    func testClockTicksSitOnLocalMultiples() {
        let utcOffset = 7_200.0                                        // two hours east of UTC
        let from = 1_790_000_000.0
        let ticks = TimelineTicks.clock(from: from, to: from + 4 * 3_600, step: 3_600, utcOffset: utcOffset)
        XCTAssertEqual(ticks.count, 4)
        for t in ticks { XCTAssertEqual((t.ts + utcOffset).truncatingRemainder(dividingBy: 3_600), 0) }
        XCTAssertGreaterThanOrEqual(ticks.first!.ts, from)
    }

    func testWodTicksCountBackFromTheStartAndOnFromTheEnd() {
        let start = t0, end = t0 + 30 * 60
        let ticks = TimelineTicks.wod(from: start - 2 * 3_600, to: end + 4 * 3_600,
                                      wodStart: start, wodEnd: end, step: 3_600)
        XCTAssertEqual(ticks.map(\.kind), [.beforeStart, .beforeStart, .duringWod,
                                          .afterEnd, .afterEnd, .afterEnd, .afterEnd])
        XCTAssertEqual(ticks.map { TimelineTicks.label($0, step: 3_600) },
                       ["\u{2212}2h", "\u{2212}1h", "0:00", "+1h", "+2h", "+3h", "+4h"])
    }

    func testZoomedIntoTheWodTheTicksAreAWorkoutClock() {
        let start = t0, end = t0 + 20 * 60
        let ticks = TimelineTicks.wod(from: start - 10 * 60, to: end + 12 * 60,
                                      wodStart: start, wodEnd: end, step: 600)
        XCTAssertEqual(ticks.map { TimelineTicks.label($0, step: 600) },
                       ["\u{2212}10\u{2032}", "0:00", "10:00", "20:00", "+10\u{2032}"])
    }

    func testTicksTooCloseWhereTheRunsMeetAreDropped() {
        // A 16-minute WOD with 15-minute ticks: 15:00 during it and +15′ after it are only 16 minutes apart,
        // which is fine; the end itself is never a tick, so nothing sits a minute from 15:00.
        let start = t0, end = t0 + 16 * 60
        let ticks = TimelineTicks.wod(from: start - 30 * 60, to: end + 30 * 60,
                                      wodStart: start, wodEnd: end, step: 900)
        let gaps = zip(ticks.dropFirst(), ticks).map { $0.ts - $1.ts }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 0.6 * 900 }, "\(gaps)")
        // Seconds when zoomed right in.
        let fine = TimelineTicks.wod(from: start - 90, to: start + 30, wodStart: start, wodEnd: end, step: 30)
        XCTAssertEqual(fine.map { TimelineTicks.label($0, step: 30) }, ["\u{2212}1:30", "\u{2212}1:00", "\u{2212}0:30", "0:00", "0:30"])
    }

    func testLongOffsetsReadAsHoursAndMinutes() {
        let tick = TimelineTick(ts: 0, kind: .afterEnd, offset: 5_400)
        XCTAssertEqual(TimelineTicks.label(tick, step: 1_800), "+1h30")
        XCTAssertEqual(TimelineTicks.workoutClock(3_725), "1:02:05")
    }
}
