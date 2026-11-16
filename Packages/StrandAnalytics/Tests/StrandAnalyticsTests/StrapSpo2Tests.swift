import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The nightly blood-oxygen value built from the WHOOP 5.0/MG strap's own byte-82 readings. The recipe
/// (windows, median, mean, the 8-window rule) is the one validated against the WHOOP app's nightly value;
/// these tests pin every constant and edge so a change cannot drift from it silently.
final class StrapSpo2Tests: XCTestCase {

    typealias Sample = (ts: Int, raw: Int)

    /// `values.count` consecutive seconds starting at `start`.
    private func run(from start: Int, _ values: [Int]) -> [Sample] {
        values.enumerated().map { (ts: start + $0.offset, raw: $0.element) }
    }

    /// One 30 s reading of a constant percentage.
    private func reading(at start: Int, pct: Int, seconds: Int = 30) -> [Sample] {
        run(from: start, Array(repeating: pct, count: seconds))
    }

    /// `medians.count` readings 1200 s apart, each a constant percentage.
    private func readings(first: Int, medians: [Int]) -> [Sample] {
        var out: [Sample] = []
        for (i, m) in medians.enumerated() { out += reading(at: first + i * 1200, pct: m) }
        return out
    }

    // MARK: - windows

    func testTwoWindowsTwelveHundredSecondsApart() {
        let samples = reading(at: 10_000, pct: 94) + reading(at: 11_200, pct: 96)
        let w = StrapSpo2.windows(samples)
        XCTAssertEqual(w, [
            StrapSpo2.Window(start: 10_000, end: 10_029, seconds: 30, medianPct: 94),
            StrapSpo2.Window(start: 11_200, end: 11_229, seconds: 30, medianPct: 96),
        ])
    }

    func testGapOverThirtySecondsSplitsAndExactlyThirtyDoesNot() {
        // Second 0...9, then the next second 31 s after the last one: two windows.
        let split = run(from: 0, Array(repeating: 95, count: 10)) + run(from: 40, Array(repeating: 95, count: 10))
        XCTAssertEqual(StrapSpo2.windows(split).count, 2)
        // The same shape with the gap exactly 30 s (last second 9, next 39): still one window.
        let joined = run(from: 0, Array(repeating: 95, count: 10)) + run(from: 39, Array(repeating: 95, count: 10))
        let w = StrapSpo2.windows(joined)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.first?.seconds, 20)
    }

    func testSpanOfSixtySecondsOrMoreSplits() {
        // One second every 10 s: 0,10,...,110. Second 60 is 60 s after the window's first second, so it opens
        // a new window; each half has 6 seconds and both are usable.
        let samples: [Sample] = stride(from: 0, through: 110, by: 10).map { (ts: $0, raw: 95) }
        let w = StrapSpo2.windows(samples)
        XCTAssertEqual(w.map(\.start), [0, 60])
        XCTAssertEqual(w.map(\.end), [50, 110])
        XCTAssertEqual(w.map(\.seconds), [6, 6])
        // 61 consecutive seconds: the first 60 (0...59, span 59 < 60) are one window and second 60 starts a
        // new one-second window, which is dropped.
        let long = run(from: 0, Array(repeating: 95, count: 61))
        let lw = StrapSpo2.windows(long)
        XCTAssertEqual(lw.count, 1)
        XCTAssertEqual(lw.first?.seconds, 60)
        XCTAssertEqual(lw.first?.end, 59)
    }

    func testWindowNeedsFiveInRangeSeconds() {
        XCTAssertTrue(StrapSpo2.windows(run(from: 0, [95, 95, 95, 95])).isEmpty, "4 seconds is not a window")
        XCTAssertEqual(StrapSpo2.windows(run(from: 0, [95, 95, 95, 95, 95])).count, 1, "5 seconds is")
    }

    func testStatusCodesAndOutOfRangeValuesNeverEnterTheMedian() {
        // 10 percentage seconds mixed with status codes (32, 160) and values just outside 70...100 (69, 101).
        // Only the 10 in-range seconds count, and the median ignores everything else.
        let values = [32, 90, 90, 160, 90, 90, 69, 90, 101, 90, 90, 90, 0, 90, 90]
        let w = StrapSpo2.windows(run(from: 500, values))
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.first?.seconds, 10)
        XCTAssertEqual(w.first?.medianPct, 90)
    }

    func testBoundariesSeventyAndHundredAreInRange() {
        XCTAssertEqual(StrapSpo2.windows(run(from: 0, Array(repeating: 70, count: 5))).first?.medianPct, 70)
        XCTAssertEqual(StrapSpo2.windows(run(from: 0, Array(repeating: 100, count: 5))).first?.medianPct, 100)
        XCTAssertTrue(StrapSpo2.windows(run(from: 0, Array(repeating: 69, count: 8))).isEmpty)
        XCTAssertTrue(StrapSpo2.windows(run(from: 0, Array(repeating: 101, count: 8))).isEmpty)
    }

    func testEvenCountTakesTheLowerMiddle() {
        // Six values, sorted 90 91 92 93 94 95: the lower middle is index (6-1)/2 = 2 -> 92 (not 92.5, not 93).
        let even = StrapSpo2.windows(run(from: 0, [95, 90, 93, 91, 94, 92]))
        XCTAssertEqual(even.first?.medianPct, 92)
        // Seven values: the true middle, index 3.
        let odd = StrapSpo2.windows(run(from: 0, [95, 90, 93, 91, 94, 92, 99]))
        XCTAssertEqual(odd.first?.medianPct, 93)
        // Eight values with a split middle pair: 90 90 90 91 | 99 99 99 99 -> index 3 -> 91.
        let split = StrapSpo2.windows(run(from: 0, [99, 90, 99, 90, 99, 90, 99, 91]))
        XCTAssertEqual(split.first?.medianPct, 91)
    }

    func testUnsortedInputAndDuplicateTimestampsKeepTheFirst() {
        // Seconds 0...4 at 90 given out of order, plus a LATER duplicate of second 2 at 100: the first value
        // for a repeated timestamp wins, so there are still exactly 5 seconds and the median is 90.
        let samples: [Sample] = [(ts: 4, raw: 90), (ts: 2, raw: 90), (ts: 0, raw: 90), (ts: 3, raw: 90),
                                 (ts: 1, raw: 90), (ts: 2, raw: 100)]
        let w = StrapSpo2.windows(samples)
        XCTAssertEqual(w, [StrapSpo2.Window(start: 0, end: 4, seconds: 5, medianPct: 90)])
    }

    func testEmptyAndAllZeroInputGiveNoWindows() {
        XCTAssertTrue(StrapSpo2.windows([]).isEmpty)
        XCTAssertTrue(StrapSpo2.windows(run(from: 0, Array(repeating: 0, count: 20))).isEmpty)
    }

    // MARK: - night

    func testNoNonzeroSampleInTheSpanIsNil() {
        XCTAssertNil(StrapSpo2.night([], from: 0, to: 1_000))
        XCTAssertNil(StrapSpo2.night(run(from: 0, Array(repeating: 0, count: 10)), from: 0, to: 1_000),
                     "zeros are the strap saying nothing")
        XCTAssertNil(StrapSpo2.night(reading(at: 5_000, pct: 95), from: 0, to: 1_000),
                     "samples outside the span do not count")
    }

    func testSevenUsableWindowsGiveNoValueEightGiveOne() {
        let seven = readings(first: 0, medians: [95, 95, 95, 95, 95, 95, 95])
        let n7 = StrapSpo2.night(seven, from: 0, to: 20_000)
        XCTAssertEqual(n7?.windows.count, 7)
        XCTAssertEqual(n7?.attempted, 7)
        XCTAssertEqual(n7?.readings, 7 * 30)
        XCTAssertNil(n7?.pct, "fewer than 8 usable windows is no value, never a guess")

        let eight = readings(first: 0, medians: [95, 95, 95, 95, 95, 95, 95, 95])
        let n8 = StrapSpo2.night(eight, from: 0, to: 20_000)
        XCTAssertEqual(n8?.windows.count, 8)
        XCTAssertEqual(n8?.pct, 95.0)
    }

    func testNightlyValueIsTheMeanOfWindowMediansRoundedToOneDecimal() {
        // Mean 94.25 -> 94.3 (half away from zero on the tenths).
        let a = StrapSpo2.night(readings(first: 0, medians: [94, 94, 94, 94, 94, 94, 95, 95]), from: 0, to: 20_000)
        XCTAssertEqual(a?.pct, 94.3)
        // Mean 95.125 -> 95.1.
        let b = StrapSpo2.night(readings(first: 0, medians: [95, 95, 95, 95, 95, 95, 95, 96]), from: 0, to: 20_000)
        XCTAssertEqual(b?.pct, 95.1)
        // Nine windows, mean 93.888... -> 93.9.
        let c = StrapSpo2.night(readings(first: 0, medians: [93, 94, 94, 94, 94, 94, 94, 94, 94]),
                                from: 0, to: 20_000)
        XCTAssertEqual(c?.pct, 93.9)
        // The mean is of the window MEDIANS, not of every second: a short noisy window weighs as much as a
        // long clean one.
        let long = reading(at: 0, pct: 98, seconds: 50)
        var mixed = long
        for i in 1..<8 { mixed += reading(at: i * 1200, pct: 94, seconds: 5) }
        XCTAssertEqual(StrapSpo2.night(mixed, from: 0, to: 20_000)?.pct, 94.5)   // (98 + 7 * 94) / 8
    }

    func testSamplesOutsideTheSpanAreIgnoredAndTheBoundsAreInclusive() {
        // Eight windows inside [10_000, 30_000], one fully before and one fully after.
        var samples = reading(at: 1_000, pct: 80)                     // before
        samples += readings(first: 10_000, medians: Array(repeating: 96, count: 8))
        samples += reading(at: 40_000, pct: 80)                       // after
        let n = StrapSpo2.night(samples, from: 10_000, to: 30_000)
        XCTAssertEqual(n?.windows.count, 8)
        XCTAssertEqual(n?.attempted, 8)
        XCTAssertEqual(n?.readings, 8 * 30)
        XCTAssertEqual(n?.pct, 96.0)

        // A reading whose first second is exactly `from` and whose last is exactly `to` is kept whole.
        let edge = reading(at: 100, pct: 90, seconds: 30)             // 100...129
        let kept = StrapSpo2.night(edge, from: 100, to: 129)
        XCTAssertEqual(kept?.readings, 30)
        let cut = StrapSpo2.night(edge, from: 101, to: 128)
        XCTAssertEqual(cut?.readings, 28)
    }

    func testStatusCodesCountTowardAttemptedButNeverTheValue() {
        // 8 good windows, plus a window of status codes only (32, 160) and a 4-second window of 95s: neither
        // is usable, both are attempts.
        var samples = readings(first: 0, medians: Array(repeating: 95, count: 8))
        samples += run(from: 20_000, [32, 32, 32, 160, 160, 160, 32, 32])
        samples += run(from: 21_200, [95, 95, 95, 95])
        let n = StrapSpo2.night(samples, from: 0, to: 30_000)
        XCTAssertEqual(n?.windows.count, 8)
        XCTAssertEqual(n?.attempted, 10)
        XCTAssertEqual(n?.readings, 8 * 30 + 4)
        XCTAssertEqual(n?.pct, 95.0, "status codes must not move the average")
    }

    func testAttemptedWindowsGroupNonzeroSecondsByTheSameRule() {
        // Codes and percentages interleaved inside one 30 s reading are ONE attempt, not several.
        let mixed = run(from: 0, [32, 95, 95, 95, 95, 95, 160, 95, 95, 95])
        let n = StrapSpo2.night(mixed, from: 0, to: 100)
        XCTAssertEqual(n?.attempted, 1)
        XCTAssertEqual(n?.windows.count, 1)
        XCTAssertNil(n?.pct)
    }

    // MARK: - logLine

    func testLogLineWithAValue() {
        let w = StrapSpo2.Window(start: 0, end: 29, seconds: 30, medianPct: 95)
        let night = StrapSpo2.Night(pct: 95.3, windows: Array(repeating: w, count: 14), attempted: 16, readings: 402)
        XCTAssertEqual(StrapSpo2.logLine(day: "2026-10-27", night: night),
                       "spo2 day=2026-10-27 strap windows=14/16 readings=402 nightly=95.3%")
        let whole = StrapSpo2.Night(pct: 96.0, windows: Array(repeating: w, count: 8), attempted: 8, readings: 240)
        XCTAssertEqual(StrapSpo2.logLine(day: "2026-10-27", night: whole),
                       "spo2 day=2026-10-27 strap windows=8/8 readings=240 nightly=96.0%")
        let full = StrapSpo2.Night(pct: 100.0, windows: Array(repeating: w, count: 9), attempted: 9, readings: 270)
        XCTAssertEqual(StrapSpo2.logLine(day: "2026-10-27", night: full),
                       "spo2 day=2026-10-27 strap windows=9/9 readings=270 nightly=100.0%")
    }

    func testLogLineWithoutAValue() {
        let w = StrapSpo2.Window(start: 0, end: 29, seconds: 30, medianPct: 95)
        let night = StrapSpo2.Night(pct: nil, windows: Array(repeating: w, count: 5), attempted: 9, readings: 150)
        XCTAssertEqual(StrapSpo2.logLine(day: "2026-10-27", night: night),
                       "spo2 day=2026-10-27 strap windows=5/9 readings=150 nightly=none (needs 8 windows)")
    }

    func testLogLineOfARealNightRoundTripsTheValueWithADot() throws {
        let samples = readings(first: 0, medians: [94, 94, 94, 94, 94, 94, 95, 95])
        let night = try XCTUnwrap(StrapSpo2.night(samples, from: 0, to: 20_000))
        XCTAssertEqual(StrapSpo2.logLine(day: "2026-10-27", night: night),
                       "spo2 day=2026-10-27 strap windows=8/8 readings=240 nightly=94.3%")
    }

    // MARK: - analyzeDay

    /// A still, low-HR night ending on `endDay` at 06:00 UTC (same synthetic shape the engine tests use).
    private func syntheticNight(endDay: String, hours: Int)
        -> (hr: [HRSample], rr: [RRInterval], gravity: [GravitySample]) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let midnight = Int(fmt.date(from: endDay)?.timeIntervalSince1970 ?? 0)
        let end = midnight + 6 * 3600
        let start = end - hours * 3600
        let hr = (start..<end).map { HRSample(ts: $0, bpm: 50) }
        let grav = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        var rr: [RRInterval] = []
        var toggle = false
        for t in stride(from: start, to: end, by: 2) {
            rr.append(RRInterval(ts: t, rrMs: toggle ? 1205 : 1195))
            toggle.toggle()
        }
        return (hr, rr, grav)
    }

    func testAnalyzeDayWithoutStrapReadingsLeavesSpo2Nil() {
        let day = "2026-06-15"
        let n = syntheticNight(endDay: day, hours: 7)
        let result = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                profile: UserProfile(age: 30))
        XCTAssertEqual(result.sleepSessions.count, 1)
        XCTAssertNil(result.daily.spo2Pct)
        XCTAssertNil(result.strapSpo2)
    }

    func testAnalyzeDayAveragesEightWindowsInsideTheDetectedNight() throws {
        let day = "2026-06-15"
        let n = syntheticNight(endDay: day, hours: 7)
        let baseline = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                  profile: UserProfile(age: 30))
        let session = try XCTUnwrap(baseline.sleepSessions.first)
        // First reading about 1175 s after the night starts, then every 1200 s: 8 windows of 30 s.
        let medians = [96, 95, 95, 94, 96, 97, 95, 94]
        let samples = readings(first: session.start + 1_175, medians: medians)
        let result = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                profile: UserProfile(age: 30), strapSpo2: samples)
        let night = try XCTUnwrap(result.strapSpo2)
        XCTAssertEqual(night.windows.count, 8)
        XCTAssertEqual(night.attempted, 8)
        XCTAssertEqual(night.readings, 8 * 30)
        // (96 + 95 + 95 + 94 + 96 + 97 + 95 + 94) / 8 = 95.25 -> 95.3
        XCTAssertEqual(try XCTUnwrap(result.daily.spo2Pct), 95.3, accuracy: 1e-9)
        XCTAssertEqual(night.pct, result.daily.spo2Pct)
        // The strap input must not move anything else the engine computes.
        XCTAssertEqual(result.daily.totalSleepMin, baseline.daily.totalSleepMin)
        XCTAssertEqual(result.daily.restingHr, baseline.daily.restingHr)
    }

    func testAnalyzeDayWithSevenWindowsHasNoValueButKeepsTheCounts() throws {
        let day = "2026-06-15"
        let n = syntheticNight(endDay: day, hours: 7)
        let baseline = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                  profile: UserProfile(age: 30))
        let session = try XCTUnwrap(baseline.sleepSessions.first)
        let samples = readings(first: session.start + 1_175, medians: Array(repeating: 95, count: 7))
        let result = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                profile: UserProfile(age: 30), strapSpo2: samples)
        XCTAssertNil(result.daily.spo2Pct, "7 windows is not a night")
        XCTAssertEqual(result.strapSpo2?.windows.count, 7)
        XCTAssertEqual(result.strapSpo2?.attempted, 7)
    }

    func testAnalyzeDayIgnoresReadingsFarOutsideTheNight() throws {
        let day = "2026-06-15"
        let n = syntheticNight(endDay: day, hours: 7)
        let baseline = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                  profile: UserProfile(age: 30))
        let session = try XCTUnwrap(baseline.sleepSessions.first)
        // 8 windows entirely before the padded start (an hour early): nothing in the span, so no night at all.
        let early = readings(first: session.start - 3_600 - 8 * 1_200, medians: Array(repeating: 95, count: 8))
        let result = AnalyticsEngine.analyzeDay(day: day, hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                profile: UserProfile(age: 30), strapSpo2: early)
        XCTAssertNil(result.strapSpo2)
        XCTAssertNil(result.daily.spo2Pct)
    }

    func testAnalyzeDayWithNoNightHasNoStrapSpo2() {
        // Readings supplied for a day that detected no night: nothing to attach them to.
        let n = syntheticNight(endDay: "2026-06-18", hours: 7)
        let samples = readings(first: 1_000_000, medians: Array(repeating: 95, count: 8))
        let result = AnalyticsEngine.analyzeDay(day: "2026-06-19", hr: n.hr, rr: n.rr, gravity: n.gravity,
                                                profile: UserProfile(age: 30), strapSpo2: samples)
        XCTAssertTrue(result.sleepSessions.isEmpty)
        XCTAssertNil(result.strapSpo2)
        XCTAssertNil(result.daily.spo2Pct)
    }
}
