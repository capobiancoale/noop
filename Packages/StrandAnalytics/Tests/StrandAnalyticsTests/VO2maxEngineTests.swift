import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// VO2max from walks and runs (ACSM oxygen cost + the VO2-reserve method, Swain et al. 2004) and at rest
/// (HUNT, Nes et al. 2011). Expected values are worked by hand from the published equations.
final class VO2maxEngineTests: XCTestCase {

    private let t0 = 1_800_000_000

    private func run(km: Double, minutes: Double, hr: Double, start: Int? = nil,
                     gait: VO2maxEngine.Gait = .running) -> VO2maxEngine.Session {
        VO2maxEngine.Session(start: start ?? t0, durationS: minutes * 60, distanceM: km * 1000, heartRate: hr, gait: gait)
    }

    // MARK: - Equations

    func testACSMEquations() {
        // 5 km/h = 83.33 m/min: 3.5 + 0.1·83.33 = 11.83; on a 5% grade + 1.8·83.33·0.05 = 19.33.
        XCTAssertEqual(VO2maxEngine.walkingVO2(speedKmh: 5), 11.833333, accuracy: 1e-5)
        XCTAssertEqual(VO2maxEngine.walkingVO2(speedKmh: 5, grade: 0.05), 19.333333, accuracy: 1e-5)
        // 12 km/h = 200 m/min: 3.5 + 0.2·200 = 43.5; on a 1% grade + 0.9·200·0.01 = 45.3.
        XCTAssertEqual(VO2maxEngine.runningVO2(speedKmh: 12), 43.5, accuracy: 1e-9)
        XCTAssertEqual(VO2maxEngine.runningVO2(speedKmh: 12, grade: 0.01), 45.3, accuracy: 1e-9)
        XCTAssertEqual(VO2maxEngine.oxygenCost(.walking, speedKmh: 5), VO2maxEngine.walkingVO2(speedKmh: 5))
    }

    func testReserveMethodIsExactWhenHRRMatchesVO2R() {
        // Whoever works at x% of VO2 reserve with the heart rate at x% of HR reserve gets their VO2max back.
        for (vo2max, x) in [(35.0, 0.55), (50.0, 0.7), (68.0, 0.8)] {
            let vo2 = 3.5 + x * (vo2max - 3.5)
            let f = VO2maxEngine.heartRateReserveFraction(hr: 55 + x * (190 - 55), restingHR: 55, maxHR: 190)!
            XCTAssertEqual(VO2maxEngine.vo2max(vo2: vo2, hrrFraction: f)!, vo2max, accuracy: 1e-9)
        }
        XCTAssertNil(VO2maxEngine.heartRateReserveFraction(hr: 150, restingHR: 60, maxHR: 60))
        XCTAssertNil(VO2maxEngine.vo2max(vo2: 3.0, hrrFraction: 0.6), "no work above rest")
    }

    // MARK: - One session

    func testSteadyRunEstimate() {
        // 6 km in 30 min (12 km/h) at 160 bpm, resting 50, HRmax 190: %HRR 110/140 = 0.7857;
        // VO2 43.5 → VO2max 3.5 + 40 / 0.7857 = 54.41.
        let e = try? VO2maxEngine.evaluate(run(km: 6, minutes: 30, hr: 160), restingHR: 50, maxHR: 190).get()
        XCTAssertEqual(e?.vo2, 43.5)
        XCTAssertEqual(e?.hrrFraction ?? 0, 0.785714, accuracy: 1e-6)
        XCTAssertEqual(e?.vo2max ?? 0, 54.409091, accuracy: 1e-6)
    }

    func testBriskWalkEstimate() {
        // 6 km in 60 min at 140 bpm, resting 60, HRmax 180: %HRR 0.667; VO2 13.5 → 3.5 + 10 / 0.667 = 18.5.
        let e = try? VO2maxEngine.evaluate(run(km: 6, minutes: 60, hr: 140, gait: .walking),
                                           restingHR: 60, maxHR: 180).get()
        XCTAssertEqual(e?.vo2max ?? 0, 18.5, accuracy: 1e-9)
    }

    func testGates() {
        func reason(_ s: VO2maxEngine.Session, rest: Double = 50, max: Double = 190) -> VO2maxEngine.Rejection? {
            if case .failure(let r) = VO2maxEngine.evaluate(s, restingHR: rest, maxHR: max) { return r }
            return nil
        }
        XCTAssertEqual(reason(run(km: 1.8, minutes: 9, hr: 160)), .tooShort)
        XCTAssertEqual(reason(run(km: 0.9, minutes: 12, hr: 160, gait: .walking)), .tooShort, "under 1 km")
        XCTAssertEqual(reason(run(km: 19, minutes: 95, hr: 160)), .tooLong)
        XCTAssertEqual(reason(run(km: 3, minutes: 30, hr: 160)), .paceOutOfRange, "6 km/h is not a run")
        XCTAssertEqual(reason(run(km: 3.5, minutes: 30, hr: 140, gait: .walking)), .paceOutOfRange, "7 km/h walking")
        XCTAssertEqual(reason(run(km: 5, minutes: 30, hr: 112)), .tooEasy, "44% HRR")
        XCTAssertEqual(reason(run(km: 6, minutes: 30, hr: 175)), .tooHard, "89% HRR")
        XCTAssertEqual(reason(run(km: 6, minutes: 30, hr: 160), rest: 60, max: 60), .missingData)
        XCTAssertEqual(reason(run(km: 6, minutes: 30, hr: 0)), .missingData)
        XCTAssertNil(reason(run(km: 6, minutes: 30, hr: 120)), "50% HRR is in")
        XCTAssertNil(reason(run(km: 6, minutes: 30, hr: 169)), "85% HRR is in")
    }

    func testGaitFromSportName() {
        XCTAssertEqual(VO2maxEngine.gait(forSport: "Running"), .running)
        XCTAssertEqual(VO2maxEngine.gait(forSport: "Treadmill run"), .running)
        XCTAssertEqual(VO2maxEngine.gait(forSport: "jogging"), .running)
        XCTAssertEqual(VO2maxEngine.gait(forSport: "Walking"), .walking)
        XCTAssertEqual(VO2maxEngine.gait(forSport: "Treadmill walk"), .walking)
        for other in ["Hiking", "Trail running", "Rucking", "Rowing", "CrossFit", "Cycling", "detected", ""] {
            XCTAssertNil(VO2maxEngine.gait(forSport: other), other)
        }
    }

    func testSteadyHeartRateSkipsTheOnsetAndNeedsCoverage() {
        // A 20-min session from an aligned start: 3 warm-up minutes at 120, then 17 minutes at 150.
        let start = t0 - t0 % 60, end = start + 1_200
        let buckets = (0..<20).map { m in HRBucket(ts: start + m * 60, bpm: m < 3 ? 120 : 150, conf: 1) }
        XCTAssertEqual(VO2maxEngine.steadyHeartRate(buckets, start: start, end: end), 150)
        // Losing 5 of the 17 steady minutes leaves 71% coverage: not enough.
        let gappy = buckets.enumerated().filter { !(5..<10).contains($0.offset) }.map(\.element)
        XCTAssertNil(VO2maxEngine.steadyHeartRate(gappy, start: start, end: end))
        XCTAssertNil(VO2maxEngine.steadyHeartRate(buckets, start: start, end: start + 200), "no steady part")
    }

    func testRestingHeartRateIsTheNightlyMedian() {
        XCTAssertEqual(VO2maxEngine.restingHeartRate([50, 52, 48, 70]), 51)
        XCTAssertEqual(VO2maxEngine.restingHeartRate([55, 0, 53, 60]), 55, "zeros are missing nights")
        XCTAssertNil(VO2maxEngine.restingHeartRate([]))
    }

    // MARK: - HRmax

    func testMaxHRPolicy() {
        // Age 30: Tanaka 187. Believable peaks lie within 3 × 10.8 bpm of it.
        XCTAssertEqual(VO2maxEngine.maxHR(userSet: 181, workoutPeaks: [199, 198, 197], age: 30),
                       VO2maxEngine.MaxHR(bpm: 181, source: .userSet))
        XCTAssertEqual(VO2maxEngine.maxHR(userSet: nil, workoutPeaks: [195, 188, 186, 150], age: 30),
                       VO2maxEngine.MaxHR(bpm: 188, source: .observed), "second-highest believable peak")
        XCTAssertEqual(VO2maxEngine.maxHR(userSet: nil, workoutPeaks: [240, 190, 185, 183], age: 30),
                       VO2maxEngine.MaxHR(bpm: 185, source: .observed), "an optical spike above 3 SD is ignored")
        XCTAssertEqual(VO2maxEngine.maxHR(userSet: nil, workoutPeaks: [190, 185], age: 30),
                       VO2maxEngine.MaxHR(bpm: 187, source: .agePredicted), "fewer than three peaks")
        XCTAssertEqual(VO2maxEngine.maxHR(userSet: nil, workoutPeaks: [166, 160, 158], age: 30),
                       VO2maxEngine.MaxHR(bpm: 187, source: .agePredicted), "no maximal effort recorded yet")
        XCTAssertNil(VO2maxEngine.maxHR(userSet: nil, workoutPeaks: [190, 189, 188], age: nil))
    }

    // MARK: - Combining sessions

    private func estimate(_ vo2max: Double, daysAgo: Int) -> VO2maxEngine.SessionEstimate {
        VO2maxEngine.SessionEstimate(session: run(km: 6, minutes: 30, hr: 160, start: t0 - daysAgo * 86_400),
                                     restingHR: 50, maxHR: 190, vo2: 43.5, hrrFraction: 0.78, vo2max: vo2max)
    }

    func testSummaryIsTheMedianOfTheNewestFiveInNinetyDays() {
        let all = [estimate(40, daysAgo: 100),                           // outside the window
                   estimate(52, daysAgo: 60), estimate(47, daysAgo: 50),  // 6th newest: dropped
                   estimate(49, daysAgo: 40), estimate(55, daysAgo: 30),
                   estimate(50, daysAgo: 20), estimate(51, daysAgo: 10), estimate(58, daysAgo: 1)]
        let s = VO2maxEngine.summarize(all, asOf: t0)!
        XCTAssertEqual(s.sessions.map(\.vo2max), [58, 51, 50, 55, 49], "newest first")
        XCTAssertEqual(s.vo2max, 51)
        XCTAssertEqual(s.low, 49); XCTAssertEqual(s.high, 58)
        // Even count: the mean of the middle two.
        XCTAssertEqual(VO2maxEngine.summarize([estimate(50, daysAgo: 2), estimate(54, daysAgo: 1)], asOf: t0)?.vo2max, 52)
        XCTAssertNil(VO2maxEngine.summarize([estimate(50, daysAgo: 95)], asOf: t0))
        XCTAssertNil(VO2maxEngine.summarize([estimate(50, daysAgo: 1)], asOf: t0 - 2 * 86_400), "not yet run")
    }

    func testTrendReadsEachSessionDay() {
        let all = [estimate(50, daysAgo: 20), estimate(56, daysAgo: 10), estimate(53, daysAgo: 1)]
        let trend = VO2maxEngine.trend(all)
        XCTAssertEqual(trend.map(\.start), [t0 - 20 * 86_400, t0 - 10 * 86_400, t0 - 86_400])
        XCTAssertEqual(trend.map(\.estimate.vo2max), [50, 53, 53])
    }

    // MARK: - From WODs (heart-rate ratio)

    func testHeartRateRatioUsesUthsFactors() {
        // Men 15.3 × 190 / 50 = 58.14; women 14.5 × 180 / 60 = 43.5 (Uth 2004, 2005).
        XCTAssertEqual(VO2maxEngine.hrRatioVO2max(maxHR: 190, restingHR: 50, sex: "male")!, 58.14, accuracy: 1e-9)
        XCTAssertEqual(VO2maxEngine.hrRatioVO2max(maxHR: 180, restingHR: 60, sex: "female")!, 43.5, accuracy: 1e-9)
        XCTAssertEqual(VO2maxEngine.hrRatioVO2max(maxHR: 190, restingHR: 50, sex: "nonbinary"),
                       VO2maxEngine.hrRatioVO2max(maxHR: 190, restingHR: 50, sex: "male"))
        XCTAssertNil(VO2maxEngine.hrRatioVO2max(maxHR: 60, restingHR: 60, sex: "male"))
        XCTAssertNil(VO2maxEngine.hrRatioVO2max(maxHR: 190, restingHR: 0, sex: "male"))
    }

    func testSupineRestingHRIsTheMeanOfTheFinalTwoMinutes() {
        // 15 minutes at 1 Hz: settling at 70 bpm for 13 minutes, then 58 bpm for the final two.
        let start = t0
        let capture = (0..<900).map { HRSample(ts: start + $0, bpm: $0 < 780 ? 70 : 58) }
        XCTAssertEqual(VO2maxEngine.supineRestingHR(capture, start: start), 58)
        // Stopped after 13 min 20 s: the final two minutes were never recorded.
        XCTAssertNil(VO2maxEngine.supineRestingHR(Array(capture.prefix(800)), start: start))
        // 30 of the final 120 seconds missing: 75% coverage, below the 80% floor.
        let gappy = capture.filter { !($0.ts >= start + 800 && $0.ts < start + 830) }
        XCTAssertNil(VO2maxEngine.supineRestingHR(gappy, start: start))
        // Two readings in the same second count once for coverage and both enter the mean.
        let doubled = capture + [HRSample(ts: start + 899, bpm: 60)]
        XCTAssertEqual(VO2maxEngine.supineRestingHR(doubled, start: start)!, (58.0 * 120 + 60) / 121, accuracy: 1e-9)
    }

    // MARK: - At rest

    func testRestingEstimateIsNesWithItsError() {
        // Men: 100.27 − 0.296·35 + 0.226·11.25 − 0.369·85 − 0.155·55 = 52.5625.
        let r = VO2maxEngine.restingEstimate(age: 35, sex: "male", waistCm: 85, restingHR: 55, paIndex: 11.25)
        XCTAssertEqual(r?.vo2max ?? 0, 52.5625, accuracy: 1e-9)
        XCTAssertEqual(r?.standardError, 5.70)
        XCTAssertEqual(VO2maxEngine.restingEstimate(age: 35, sex: "female", waistCm: 75, restingHR: 58,
                                                    paIndex: 5)?.standardError, 5.14)
        XCTAssertNil(VO2maxEngine.restingEstimate(age: 35, sex: "male", waistCm: 0, restingHR: 55, paIndex: 5))
    }
}
