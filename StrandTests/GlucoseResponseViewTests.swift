import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The pure loading steps behind `GlucoseResponseView`: which sessions count, the night after one, and the
/// glucose windows to read.
final class GlucoseResponseViewTests: XCTestCase {
    typealias L = GlucoseResponseLoader
    typealias G = GlucoseTrainingResponse

    private let rome = TimeZone(identifier: "Europe/Rome")!
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = rome; return c }

    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Int {
        Int(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970)
    }

    private let now = 1_800_000_000

    private func wod(_ id: String, ts: Int, end: Int?, type: String = "CrossFit", format: String? = "AMRAP") -> WodLogRow {
        WodLogRow(id: id, ts: ts, day: "2026-01-01", type: type, title: id, format: format,
                  createdTs: ts, endTs: end)
    }

    private func workout(_ start: Int, minutes: Int, sport: String) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: "test", durationS: nil,
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    // MARK: sessions

    func testWodWithSpanBecomesSessionAndHidesOverlappingWorkout() {
        let start = now - 5 * 86_400
        let w = wod("a", ts: start, end: start + 60 * 60, type: "Weightlifting", format: "Strength")
        let overlapping = workout(start + 600, minutes: 40, sport: "Strength")
        let other = workout(now - 3 * 86_400, minutes: 50, sport: "Running")
        let s = L.sessions(wods: [w], workouts: [overlapping, other], nowTs: now)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].id, "wod-a")
        XCTAssertEqual(s[0].kind, .strength)
        XCTAssertEqual(s[0].end - s[0].start, 3_600)
        XCTAssertEqual(s[1].kind, .long)   // a 50-minute run
    }

    func testWodWithoutSpanAndNoRecordedWorkoutIsLeftOut() {
        let w = wod("b", ts: now - 86_400, end: nil)
        XCTAssertTrue(L.sessions(wods: [w], workouts: [], nowTs: now).isEmpty)
    }

    func testWodWithoutSpanTakesTheRecordedWorkout() {
        let start = now - 86_400
        let w = wod("c", ts: start, end: nil)
        let rec = workout(start - 300, minutes: 25, sport: "CrossFit")
        let s = L.sessions(wods: [w], workouts: [rec], nowTs: now)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].id, "wod-c")
        XCTAssertEqual(s[0].kind, .metcon)
        XCTAssertEqual(s[0].start, Double(start - 300))
    }

    func testOlderThanNinetyDaysAndImplausibleSpansAreDropped() {
        let old = wod("old", ts: now - 91 * 86_400, end: now - 91 * 86_400 + 1_800)
        let short = wod("short", ts: now - 86_400, end: now - 86_400 + 120)
        let longDay = wod("day", ts: now - 2 * 86_400, end: now - 2 * 86_400 + 10 * 3_600)
        XCTAssertTrue(L.sessions(wods: [old, short, longDay], workouts: [], nowTs: now).isEmpty)
    }

    func testWalkingAndYogaAreNotSessionsAndTwinWorkoutsCollapse() {
        let a = now - 86_400
        let rows = [workout(a, minutes: 30, sport: "Walking"), workout(a + 3_600, minutes: 40, sport: "Yoga"),
                    workout(a + 7_200, minutes: 30, sport: "HIIT"), workout(a + 7_300, minutes: 28, sport: "HIIT")]
        let s = L.sessions(wods: [], workouts: rows, nowTs: now)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].kind, .metcon)
    }

    func testSessionEndingInTheFutureIsLeftOut() {
        let w = wod("f", ts: now - 600, end: now + 1_800)
        XCTAssertTrue(L.sessions(wods: [w], workouts: [], nowTs: now).isEmpty)
    }

    // MARK: night

    func testNightWindowAfterAnAfternoonSession() {
        let end = Date(timeIntervalSince1970: TimeInterval(ts(2026, 3, 10, 18, 30)))
        let n = L.nightWindow(after: end, calendar: cal)!
        XCTAssertEqual(Int(n.start), ts(2026, 3, 10, 23))
        XCTAssertEqual(Int(n.end), ts(2026, 3, 11, 7))
    }

    func testNightWindowAfterALateSessionStartsAtItsEnd() {
        let e = ts(2026, 3, 10, 23, 40)
        let n = L.nightWindow(after: Date(timeIntervalSince1970: TimeInterval(e)), calendar: cal)!
        XCTAssertEqual(Int(n.start), e)
        XCTAssertEqual(Int(n.end), ts(2026, 3, 11, 7))
    }

    func testNightWindowAfterASmallHoursSessionIsThatMorning() {
        let e = ts(2026, 3, 11, 1, 10)
        let n = L.nightWindow(after: Date(timeIntervalSince1970: TimeInterval(e)), calendar: cal)!
        XCTAssertEqual(Int(n.start), e)
        XCTAssertEqual(Int(n.end), ts(2026, 3, 11, 7))
    }

    func testNightNotOverYetIsNotObserved() {
        let end = ts(2026, 3, 10, 18)
        let s = G.Session(id: "x", kind: .metcon, start: Double(end - 1_800), end: Double(end))
        XCTAssertNil(L.night(for: s, nowTs: Double(ts(2026, 3, 11, 5)), calendar: cal))
        XCTAssertNotNil(L.night(for: s, nowTs: Double(ts(2026, 3, 11, 8)), calendar: cal))
    }

    // MARK: windows and slices

    func testFetchRangesMergeAndSplit() {
        let base = Double(ts(2026, 3, 1, 8))
        // Two sessions 2 h apart share one window; one 30 days later has its own.
        let a = G.Session(id: "a", kind: .metcon, start: base, end: base + 1_800)
        let b = G.Session(id: "b", kind: .metcon, start: base + 7_200, end: base + 9_000)
        let c = G.Session(id: "c", kind: .metcon, start: base + 30 * 86_400, end: base + 30 * 86_400 + 1_800)
        let r = L.fetchRanges(for: [c, a, b], nowTs: base + 90 * 86_400, calendar: cal)
        XCTAssertEqual(r.count, 2)
        XCTAssertLessThan(r[0].upperBound, r[1].lowerBound)
        XCTAssertLessThanOrEqual(r[0].lowerBound, base - 3_600)
        XCTAssertGreaterThanOrEqual(r[0].upperBound, base + 9_000 + 6 * 3_600)
        // Never past now.
        let capped = L.fetchRanges(for: [a], nowTs: base + 3_600, calendar: cal)
        XCTAssertEqual(capped.first!.upperBound, base + 3_600)
        // A long run of sessions is cut into pieces of at most 10 days.
        let many = (0..<30).map { G.Session(id: "m\($0)", kind: .metcon, start: base + Double($0) * 86_400,
                                            end: base + Double($0) * 86_400 + 1_800) }
        let pieces = L.fetchRanges(for: many, nowTs: base + 90 * 86_400, calendar: cal)
        XCTAssertGreaterThan(pieces.count, 2)
        XCTAssertTrue(pieces.allSatisfy { $0.upperBound - $0.lowerBound <= 10 * 86_400 + 1 })
    }

    func testSliceAndPointsAndInputs() {
        let raw: [(ts: Double, mgdl: Double)] = [(30, 3), (10, 1), (20, 2), (20, 99), (40, 4)]
        let pts = L.points(from: raw)
        XCTAssertEqual(pts.map(\.ts), [10, 20, 30, 40])
        XCTAssertEqual(Array(L.slice(pts, from: 15, to: 30)).map(\.ts), [20, 30])
        XCTAssertTrue(L.slice(pts, from: 50, to: 60).isEmpty)

        let base = Double(ts(2026, 3, 1, 8))
        let s = G.Session(id: "s", kind: .metcon, start: base, end: base + 1_800)
        let all = stride(from: base - 86_400, through: base + 2 * 86_400, by: 300).map { G.Point(ts: $0, mgdl: 100) }
        let input = L.inputs(sessions: [s], points: all, nowTs: base + 5 * 86_400, calendar: cal)[0]
        XCTAssertLessThan(input.points.count, all.count)
        XCTAssertNotNil(input.night)
        XCTAssertEqual(GlucoseTrainingResponse.evaluate(input).nightLow, false)
    }
}
