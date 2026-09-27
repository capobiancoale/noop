import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Session-RPE (Foster 2001) load folded into Effort where the heart rate under-reads it, converted with
/// the Edwards-TRIMP / session-RPE ratio measured in CrossFit-style WODs (Tibana et al. 2018).
final class SessionLoadTests: XCTestCase {

    private let maxHR = 190.0, rest = 60.0
    private let day0 = 1_800_000_000 - 1_800_000_000 % 86_400   // a UTC midnight

    /// One sample a minute for the whole day at `base` bpm, with `bursts` of (start minute, minutes, bpm).
    private func dayHR(base: Int = 60, bursts: [(Int, Int, Int)] = []) -> [HRSample] {
        (0..<1440).map { m in
            let bpm = bursts.first { m >= $0.0 && m < $0.0 + $0.1 }?.2 ?? base
            return HRSample(ts: day0 + m * 60, bpm: bpm)
        }
    }

    private func strain(_ hr: [HRSample], _ sessions: [StrainScorer.LoggedSession],
                        bouts: [(start: Int, end: Int)] = []) -> Double? {
        StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: "male", sessions: sessions, bouts: bouts,
                            dayStart: day0, dayEnd: day0 + 86_400)
    }

    func testRatioComesFromTibana2018() {
        // Fran: TRIMP 19.8 over RPE 8.7 × 4.06 min; Fight Gone Bad: 77.7 over 9.6 × 17 min.
        let fran = 19.8 / (8.7 * 4.06), fgb = 77.7 / (9.6 * 17)
        XCTAssertEqual((fran + fgb) / 2, StrainScorer.trimpPerSessionRPE, accuracy: 0.005)
    }

    func testNoSessionsIsThePlainHeartRateEffort() {
        let hr = dayHR(bursts: [(600, 30, 150)])
        XCTAssertEqual(strain(hr, []), StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: "male"))
    }

    func testStrengthSessionTheHeartRateMissesAddsItsLoad() {
        // 45 min of heavy lifting at 110 bpm: 58% HRmax (classic Edwards weight 1 → 45 TRIMP) and 38% HRR
        // (NOOP weight 0 → the heart-rate Effort is 0). RPE 8 × 45 min = 360 AU → expected 0.52 × 360 = 187.2.
        let hr = dayHR(bursts: [(600, 45, 110)])
        let s = StrainScorer.LoggedSession(rpe: 8, durationMin: 45, ts: day0 + 600 * 60, timeKnown: true)
        XCTAssertEqual(StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: "male"), 0)
        let windows = StrainScorer.sessionWindows([s], bouts: [], dayStart: day0, dayEnd: day0 + 86_400)
        XCTAssertEqual(StrainScorer.sessionExcessTRIMP(windows, hr: hr, maxHR: maxHR), 187.2 - 45, accuracy: 1e-9)
        XCTAssertEqual(strain(hr, [s])!, StrainScorer.trimpToStrain(142.2), accuracy: 1e-9)
    }

    func testMetconTheHeartRateCapturedAddsNothing() {
        // 20 min at 175 bpm (92% HRmax, weight 5 → 100 classic TRIMP) rated 9: expected 0.52 × 180 = 93.6.
        let hr = dayHR(bursts: [(1080, 20, 175)])
        let s = StrainScorer.LoggedSession(rpe: 9, durationMin: 20, ts: day0 + 1100 * 60, timeKnown: true)
        XCTAssertEqual(strain(hr, [s]), StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: "male"),
                       "never counted twice")
    }

    func testStrapOffDuringTheSessionAddsTheFullLoad() {
        // Heart rate all day except a 60-min gap where the WOD happened.
        let hr = dayHR(bursts: [(300, 30, 150)]).filter { $0.ts < day0 + 900 * 60 || $0.ts >= day0 + 960 * 60 }
        let s = StrainScorer.LoggedSession(rpe: 7, durationMin: 30, ts: day0 + 900 * 60, timeKnown: true)
        let base = StrainScorer.trimp(hr, maxHR: maxHR, restingHR: rest)!
        XCTAssertEqual(strain(hr, [s])!, StrainScorer.trimpToStrain(base + 0.52 * 210), accuracy: 1e-9)
    }

    func testLoggedTimeCanMarkTheStartOrTheEnd() {
        // The same 45-min lifting block, logged at its start or at its end: the window covers both.
        let hr = dayHR(bursts: [(600, 45, 110)])
        let atStart = StrainScorer.LoggedSession(rpe: 8, durationMin: 45, ts: day0 + 600 * 60, timeKnown: true)
        let atEnd = StrainScorer.LoggedSession(rpe: 8, durationMin: 45, ts: day0 + 645 * 60, timeKnown: true)
        XCTAssertEqual(strain(hr, [atStart]), strain(hr, [atEnd]))
    }

    func testTimeUnknownSessionMatchesTheDetectedWorkout() {
        // Imported with a date only (anchored to noon) while the class was at 18:00: matched to the detected
        // workout, whose 30 min at 175 bpm (150 classic TRIMP) exceed 0.52 × 8 × 30 = 124.8 → nothing added.
        let hr = dayHR(bursts: [(1080, 30, 175)])
        let s = StrainScorer.LoggedSession(rpe: 8, durationMin: 30, ts: day0 + 720 * 60, timeKnown: false)
        let bout = (start: day0 + 1080 * 60, end: day0 + 1110 * 60)
        XCTAssertEqual(strain(hr, [s], bouts: [bout]), StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: "male"))
        // With no detected workout nothing locates it: the full load is added (it cannot be found in the HR).
        let base = StrainScorer.trimp(hr, maxHR: maxHR, restingHR: rest)!
        XCTAssertEqual(strain(hr, [s])!, StrainScorer.trimpToStrain(base + 124.8), accuracy: 1e-9)
    }

    func testSessionsSharingAWindowArePooled() {
        // Strength then a short metcon in the same class, both matched to one detected workout: their
        // expected loads add up and the heart rate of that workout is subtracted once.
        let hr = dayHR(bursts: [(600, 40, 110), (640, 10, 170)])
        let bout = (start: day0 + 600 * 60, end: day0 + 650 * 60)
        let lift = StrainScorer.LoggedSession(rpe: 8, durationMin: 40, ts: day0 + 600 * 60, timeKnown: true)
        let metcon = StrainScorer.LoggedSession(rpe: 9, durationMin: 10, ts: day0 + 640 * 60, timeKnown: true)
        let windows = StrainScorer.sessionWindows([lift, metcon], bouts: [bout], dayStart: day0, dayEnd: day0 + 86_400)
        // First session takes the workout; the second finds none left and uses its own span (which overlaps).
        let excess = StrainScorer.sessionExcessTRIMP(windows, hr: hr, maxHR: maxHR)
        // 40 min at 110 (weight 1) + 10 min at 170 (89% HRmax, weight 4) = 80 classic TRIMP in the pooled span.
        XCTAssertEqual(excess, 0.52 * (320 + 90) - 80, accuracy: 1e-9)
    }

    func testNoHeartRateAtAllMeansNoEffort() {
        let s = StrainScorer.LoggedSession(rpe: 8, durationMin: 45, ts: day0 + 600 * 60, timeKnown: true)
        XCTAssertNil(strain([], [s]), "a log alone never makes an Effort")
    }

    // MARK: - From a WOD row

    private func wod(ts: Int, rpe: Double?, result: Int? = nil, cap: Int? = nil) -> WodLogRow {
        WodLogRow(id: "w", ts: ts, day: "2027-01-15", type: "WOD", title: "Test", timeCapS: cap,
                  resultSeconds: result, rpe: rpe, createdTs: ts)
    }

    func testSessionFromWodUsesResultTimeElseTimeCap() {
        let a = StrainScorer.LoggedSession(wod: wod(ts: day0 + 64_800, rpe: 8, result: 754, cap: 1200), tzOffsetSeconds: 0)!
        XCTAssertEqual(a.durationMin, 754.0 / 60, accuracy: 1e-12)
        XCTAssertTrue(a.timeKnown)
        let b = StrainScorer.LoggedSession(wod: wod(ts: day0 + 64_800, rpe: 12, cap: 1200), tzOffsetSeconds: 0)!
        XCTAssertEqual(b.durationMin, 20)
        XCTAssertEqual(b.rpe, 10, "the CR-10 scale tops out at 10")
        XCTAssertNil(StrainScorer.LoggedSession(wod: wod(ts: day0, rpe: nil, cap: 1200), tzOffsetSeconds: 0))
        XCTAssertNil(StrainScorer.LoggedSession(wod: wod(ts: day0, rpe: 8), tzOffsetSeconds: 0))
    }

    func testDateOnlyImportsAreTimeUnknown() {
        // Imports anchor a date-only WOD to local noon (UTC+2 here).
        let noonLocal = day0 + 12 * 3600 - 7200
        XCTAssertFalse(StrainScorer.LoggedSession(wod: wod(ts: noonLocal, rpe: 7, cap: 600), tzOffsetSeconds: 7200)!.timeKnown)
        XCTAssertTrue(StrainScorer.LoggedSession(wod: wod(ts: noonLocal + 60, rpe: 7, cap: 600), tzOffsetSeconds: 7200)!.timeKnown)
    }

    // MARK: - Through analyzeDay

    func testAnalyzeDayFoldsLoggedSessionsIntoEffort() {
        let hr = dayHR(base: 62, bursts: [(600, 45, 112)])
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let day = AnalyticsEngine.dayString(day0, offsetSec: 0)
        let plain = AnalyticsEngine.analyzeDay(day: day, hr: hr, dayHr: hr, profile: profile)
        let s = StrainScorer.LoggedSession(rpe: 8, durationMin: 45, ts: day0 + 600 * 60, timeKnown: true)
        let withWod = AnalyticsEngine.analyzeDay(day: day, hr: hr, dayHr: hr, profile: profile, loggedSessions: [s])
        XCTAssertNotNil(plain.daily.strain)
        XCTAssertGreaterThan(withWod.daily.strain!, plain.daily.strain! + 10)
    }
}
