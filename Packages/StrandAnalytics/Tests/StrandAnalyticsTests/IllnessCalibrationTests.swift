import XCTest
@testable import StrandAnalytics

final class IllnessCalibrationTests: XCTestCase {

    // MARK: - Helpers

    typealias Day = IllnessSignalEngine.DayVitals

    /// "2025-01-01" plus `offset` days (UTC, proleptic Gregorian), independent of the code under test.
    private func dayKey(_ offset: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2025, month: 1, day: 1)
        guard let d0 = start.date, let d = cal.date(byAdding: .day, value: offset, to: d0) else { return "" }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A quiet history: all four signals present, small bounded wobble, nothing ever fires.
    private func quiet(_ n: Int) -> [Day] {
        (0..<n).map { i in
            let w = Double((i * 7) % 5) - 2          // -2 … 2
            return Day(day: dayKey(i), restingHR: 55 + w * 0.5, hrv: 80 + w * 2.0,
                       respiration: 14.5 + w * 0.1, skinTempDevC: w * 0.03)
        }
    }

    /// Push resting HR up 14 bpm and skin temperature up 1.2 °C on the given entries (two signals at
    /// their cap, so a day with both recent days spiked scores 80).
    private func spiked(_ days: [Day], at indices: Set<Int>) -> [Day] {
        days.enumerated().map { i, d in
            guard indices.contains(i) else { return d }
            return Day(day: d.day, restingHR: (d.restingHR ?? 55) + 14, hrv: d.hrv,
                       respiration: d.respiration, skinTempDevC: (d.skinTempDevC ?? 0) + 1.2)
        }
    }

    // MARK: - Calendar helper

    func testDayNumberKnownDates() {
        XCTAssertEqual(IllnessCalibration.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(IllnessCalibration.dayNumber("1970-01-02"), 1)
        XCTAssertEqual(IllnessCalibration.dayNumber("2000-03-01"), 11_017)
        XCTAssertEqual(IllnessCalibration.dayNumber("2024-02-29"), 19_782)
        XCTAssertEqual(IllnessCalibration.dayNumber("2024-03-01"), 19_783)
        XCTAssertEqual(IllnessCalibration.dayNumber("2025-01-01"), 20_089)
        XCTAssertNil(IllnessCalibration.dayNumber("nope"))
        XCTAssertNil(IllnessCalibration.dayNumber("2025-13-01"))
        // Consecutive keys from the independent generator are consecutive numbers (incl. a leap year).
        var previous: Int?
        for i in 0..<800 {
            guard let n = IllnessCalibration.dayNumber(dayKey(i)) else { return XCTFail("bad key \(i)") }
            if let p = previous { XCTAssertEqual(n, p + 1) }
            previous = n
        }
    }

    // MARK: - Statistics: Clopper–Pearson

    func testUpperBoundForZeroEventsIsTheClosedForm() {
        for n in [1, 30, 120, 300, 1_000] {
            let expected = 1 - pow(0.05, 1 / Double(n))
            XCTAssertEqual(IllnessCalibration.clopperPearsonUpper(successes: 0, trials: n, confidence: 0.95),
                           expected, accuracy: 1e-12)
        }
        // The "rule of three": about 3 / N.
        let u = IllnessCalibration.clopperPearsonUpper(successes: 0, trials: 120, confidence: 0.95)
        XCTAssertEqual(u, 3.0 / 120.0, accuracy: 0.0008)
        XCTAssertEqual(u, 0.02465540105565639, accuracy: 1e-12)
    }

    func testUpperBoundMatchesExactBinomialReferences() {
        // Reference values: the p solving P(Bin(n, p) ≤ k) = 0.05, found by bisection on the exact
        // binomial sum (independent of the incomplete-beta code).
        let refs: [(k: Int, n: Int, p: Double)] = [
            (1, 100, 0.04655981145353899),
            (2, 120, 0.05153371368637799),
            (5, 60, 0.1672630764250897),
            (3, 200, 0.03830970849856935),
            (10, 500, 0.03368827233114452),
        ]
        for r in refs {
            XCTAssertEqual(IllnessCalibration.clopperPearsonUpper(successes: r.k, trials: r.n, confidence: 0.95),
                           r.p, accuracy: 1e-9, "k=\(r.k) n=\(r.n)")
        }
    }

    func testUpperBoundEdgesAndMonotonicity() {
        XCTAssertEqual(IllnessCalibration.clopperPearsonUpper(successes: 5, trials: 5, confidence: 0.95), 1)
        XCTAssertEqual(IllnessCalibration.clopperPearsonUpper(successes: 0, trials: 0, confidence: 0.95), 1)
        var last = 0.0
        for k in 0...12 {
            let u = IllnessCalibration.clopperPearsonUpper(successes: k, trials: 150, confidence: 0.95)
            XCTAssertGreaterThan(u, last)
            XCTAssertGreaterThan(u, Double(k) / 150)      // an upper bound sits above the estimate
            last = u
        }
    }

    func testIncompleteBetaForOneAndNIsClosedForm() {
        // I_x(1, n) = 1 − (1 − x)^n.
        for (x, n) in [(0.01, 50), (0.3, 7), (0.9, 12)] {
            XCTAssertEqual(IllnessCalibration.regularizedIncompleteBeta(x, a: 1, b: Double(n)),
                           1 - pow(1 - x, Double(n)), accuracy: 1e-12)
        }
    }

    // MARK: - Episodes

    func testEpisodesCountRunsNotDays() {
        XCTAssertEqual(IllnessCalibration.countEpisodes(raisingDays: []), 0)
        XCTAssertEqual(IllnessCalibration.countEpisodes(raisingDays: [10]), 1)
        XCTAssertEqual(IllnessCalibration.countEpisodes(raisingDays: [10, 11, 12]), 1)
        XCTAssertEqual(IllnessCalibration.countEpisodes(raisingDays: [10, 11, 13]), 2)
        XCTAssertEqual(IllnessCalibration.countEpisodes(raisingDays: [3, 4, 20, 21, 22, 40]), 3)
    }

    // MARK: - The replay uses the live code path and never looks ahead

    func testReplayWindowIgnoresEverythingAfterTheDay() {
        let base = quiet(120)
        let future = spiked(base, at: Set(100..<120))
        for i in [30, 55, 80, 99] {
            XCTAssertEqual(IllnessSignalEngine.inputs(history: base, endingAt: i),
                           IllnessSignalEngine.inputs(history: future, endingAt: i), "day \(i)")
        }
        // The spike itself is visible from its own day on.
        XCTAssertNotEqual(IllnessSignalEngine.inputs(history: base, endingAt: 110),
                          IllnessSignalEngine.inputs(history: future, endingAt: 110))
    }

    func testCalibrationOfAPrefixDoesNotChangeWhenTheFutureIsAppended() {
        let a = quiet(180)
        let b = spiked(a, at: Set(160..<165))
        let prefixOnly = IllnessCalibration.healthyDays(history: Array(b[0..<160]), flags: [:], unwellDays: [])
        let full = IllnessCalibration.healthyDays(history: b, flags: [:], unwellDays: [])
        XCTAssertEqual(prefixOnly.count, 160 - 30)
        for (x, y) in zip(prefixOnly, full) {
            XCTAssertEqual(x.dayNumber, y.dayNumber)
            XCTAssertEqual(x.score, y.score)
            XCTAssertEqual(x.signalCount, y.signalCount)
        }
    }

    func testReplayedScoreIsExactlyWhatTheEngineComputesForTheSameDay() {
        let h = spiked(quiet(150), at: [90, 91, 92])
        let days = IllnessCalibration.healthyDays(history: h, flags: [:], unwellDays: [])
        for d in days {
            guard let i = (30..<h.count).first(where: { IllnessCalibration.dayNumber(h[$0].day) == d.dayNumber }),
                  let w = IllnessSignalEngine.inputs(history: h, endingAt: i) else { return XCTFail("no window") }
            let r = IllnessSignalEngine.evaluate(w.inputs, context: .init(baselineTrusted: w.baselineTrusted))
            XCTAssertEqual(r.score, d.score, accuracy: 1e-12)
            XCTAssertEqual(r.signalCount, d.signalCount)
            XCTAssertEqual(r.level == .raised, IllnessSignalEngine.wouldRaise(
                score: d.score, signalCount: d.signalCount, personalRaiseThreshold: nil))
        }
    }

    // MARK: - Healthy-day selection

    func testQuietHistoryIsAllHealthyAndNeverAlarms() {
        let r = IllnessCalibration.calibrate(history: quiet(200))
        XCTAssertEqual(r.healthyDays, 200 - 30)               // every replayable day
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.episodes, 0)
        XCTAssertEqual(r.raiseThreshold, 50)                  // never below the default
        XCTAssertEqual(r.personalRaiseThreshold, 50)
        XCTAssertEqual(r.alarmRate, 0)
        XCTAssertEqual(r.alarmRateUpper95 ?? 0, 1 - pow(0.05, 1 / 170.0), accuracy: 1e-12)
        XCTAssertTrue(r.targetMet)
        XCTAssertEqual(r.missingDays, 0)
        XCTAssertNil(r.daysPerAlarm)
        XCTAssertEqual(r.daysPerAlarmAtMost, Int((1 / (1 - pow(0.05, 1 / 170.0))).rounded(.down)))
    }

    func testFewerThan120HealthyDaysIsInactiveAndSaysHowManyAreMissing() {
        let r = IllnessCalibration.calibrate(history: quiet(130))      // 100 replayable days
        XCTAssertFalse(r.active)
        XCTAssertEqual(r.healthyDays, 100)
        XCTAssertEqual(r.missingDays, 20)
        XCTAssertEqual(r.raiseThreshold, 50)
        XCTAssertNil(r.personalRaiseThreshold)
        // Exactly 120 is enough.
        let exact = IllnessCalibration.calibrate(history: quiet(150))
        XCTAssertEqual(exact.healthyDays, 120)
        XCTAssertTrue(exact.active)
        // No history at all.
        let none = IllnessCalibration.calibrate(history: [])
        XCTAssertFalse(none.active)
        XCTAssertEqual(none.healthyDays, 0)
        XCTAssertEqual(none.missingDays, 120)
        XCTAssertNil(none.alarmRate)
        XCTAssertNil(none.alarmRateUpper95)
    }

    func testUntrustedBaselineAndMissingSignalsAreNotHealthyDays() {
        // Only resting HR recorded: one signal present, so the heads-up could never have fired.
        let rhrOnly = (0..<200).map { Day(day: dayKey($0), restingHR: 55 + Double(($0 * 7) % 5) * 0.3) }
        XCTAssertEqual(IllnessCalibration.calibrate(history: rhrOnly).healthyDays, 0)
        // Two signals present counts.
        let two = (0..<200).map { Day(day: dayKey($0), restingHR: 55 + Double(($0 * 7) % 5) * 0.3,
                                     hrv: 80 + Double(($0 * 3) % 4)) }
        XCTAssertEqual(IllnessCalibration.calibrate(history: two).healthyDays, 170)
    }

    func testSpikesOnHealthyDaysRaiseThePersonalThreshold() {
        // Four 2-day spikes with nothing logged: each one is a false alarm for a heads-up that fires at
        // 50, and the day with both recent days spiked scores 80 (two signals at the cap).
        let h = spiked(quiet(200), at: [60, 61, 100, 101, 140, 141, 175, 176])
        let r = IllnessCalibration.calibrate(history: h)
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.healthyDays, 170)
        XCTAssertGreaterThan(r.raiseThreshold, 50)
        XCTAssertLessThanOrEqual(r.raiseThreshold, 100)
        XCTAssertTrue(r.targetMet)
        XCTAssertLessThanOrEqual(r.episodes * 60, r.healthyDays)
        // "Smallest": the grid step below misses the target, the chosen one meets it.
        let days = IllnessCalibration.healthyDays(history: h, flags: [:], unwellDays: [])
        XCTAssertGreaterThan(IllnessCalibration.episodes(in: days, at: 50) * 60, days.count)
        let below = IllnessCalibration.episodes(in: days, at: r.raiseThreshold - 1)
        XCTAssertGreaterThan(below * 60, days.count)
        XCTAssertEqual(IllnessCalibration.episodes(in: days, at: r.raiseThreshold), r.episodes)
        // The default threshold would have produced 4 false-alarm episodes here.
        XCTAssertEqual(IllnessCalibration.episodes(in: days, at: 50), 4)
        // And the personal threshold really does silence the engine on those days.
        let strict = IllnessSignalEngine.Context(personalRaiseThreshold: r.personalRaiseThreshold)
        for i in [61, 101, 141, 176] {
            guard let w = IllnessSignalEngine.inputs(history: h, endingAt: i) else { return XCTFail("no window") }
            let loose = IllnessSignalEngine.evaluate(w.inputs, context: .init())
            let tight = IllnessSignalEngine.evaluate(w.inputs, context: strict)
            XCTAssertEqual(loose.level, .raised, "day \(i)")
            XCTAssertNotEqual(tight.level, .raised, "day \(i)")
        }
    }

    func testWhenNoThresholdReachesTheTargetItUsesTheCeilingAndSaysSo() {
        // Many full-strength (all four signals, score 100) spikes: even T = 100 raises on each.
        var h = quiet(200)
        let idx = Set([60, 61, 80, 81, 100, 101, 120, 121, 140, 141, 160, 161])
        h = h.enumerated().map { i, d in
            idx.contains(i)
            ? Day(day: d.day, restingHR: (d.restingHR ?? 55) + 25, hrv: (d.hrv ?? 80) - 45,
                  respiration: (d.respiration ?? 14.5) + 4, skinTempDevC: (d.skinTempDevC ?? 0) + 2)
            : d
        }
        let r = IllnessCalibration.calibrate(history: h)
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.raiseThreshold, 100)
        XCTAssertFalse(r.targetMet)
        XCTAssertGreaterThan(r.episodes * 60, r.healthyDays)
        XCTAssertEqual(r.episodes, 6)
        XCTAssertEqual(r.alarmRate ?? 0, 6.0 / Double(r.healthyDays), accuracy: 1e-12)
        XCTAssertGreaterThan(r.alarmRateUpper95 ?? 0, r.alarmRate ?? 1)
    }

    func testDaysAroundAnUnwellLogAreNotHealthy() {
        let h = spiked(quiet(200), at: [100, 101])
        let plain = IllnessCalibration.healthyDays(history: h, flags: [:], unwellDays: [])
        XCTAssertEqual(plain.count, 170)
        XCTAssertEqual(IllnessCalibration.episodes(in: plain, at: 50), 1)
        // The user logged feeling unwell on the second spike day: ±7 days drop out, 15 in all.
        let unwell = IllnessCalibration.healthyDays(history: h, flags: [:], unwellDays: [dayKey(101)])
        XCTAssertEqual(unwell.count, 170 - 15)
        XCTAssertEqual(IllnessCalibration.episodes(in: unwell, at: 50), 0)
        let dropped = Set(plain.map(\.dayNumber)).subtracting(unwell.map(\.dayNumber))
        let expected = Set((94...108).compactMap { IllnessCalibration.dayNumber(dayKey($0)) })
        XCTAssertEqual(dropped, expected)
        // A malformed unwell key is ignored, not a crash.
        XCTAssertEqual(IllnessCalibration.healthyDays(history: h, flags: [:], unwellDays: ["x"]).count, 170)
    }

    func testConfoundedDaysAreNotHealthyDays() {
        let h = spiked(quiet(200), at: [100, 101])
        // Alcohol logged on the second spike day rules out that day and the next (its window).
        for flag in [IllnessCalibration.DayFlags(alcohol: true),
                     IllnessCalibration.DayFlags(hardOrLateWorkout: true),
                     IllnessCalibration.DayFlags(nocturnalLow: true),
                     IllnessCalibration.DayFlags(travel: true),
                     IllnessCalibration.DayFlags(stress: true),
                     IllnessCalibration.DayFlags(sauna: true)] {
            let days = IllnessCalibration.healthyDays(history: h, flags: [dayKey(101): flag], unwellDays: [])
            XCTAssertEqual(days.count, 170 - 2)
            XCTAssertEqual(IllnessCalibration.episodes(in: days, at: 50), 0)
        }
        XCTAssertFalse(IllnessCalibration.DayFlags().any)
        // A flag on a day outside the replay window changes nothing.
        let outside = IllnessCalibration.healthyDays(history: h,
                                                     flags: [dayKey(5): .init(alcohol: true)], unwellDays: [])
        XCTAssertEqual(outside.count, 170)
    }

    // MARK: - Journal reading (shared by the live alert and the calibration)

    func testQuestionTagsKeepTheLiveSubstringRules() {
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Did you drink any alcohol?"),
                       .init(alcohol: true))
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Had a hard WORKOUT?"), .init(workout: true))
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Did you train late?"), .init(workout: true))
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Any exercise today?"), .init(workout: true))
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Did you feel sick or ill?"), .init(unwell: true))
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Feeling unwell"), .init(unwell: true))
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Did you read before bed?"), .init())
        XCTAssertEqual(IllnessCalibration.tags(forQuestion: "Did you use a sauna?"), .init())
    }

    func testDayFlagsFromJournalAndNightLows() {
        let entries: [(day: String, question: String, answeredYes: Bool)] = [
            ("2025-03-01", "Did you drink any alcohol?", true),
            ("2025-03-02", "Did you drink any alcohol?", false),        // a "no" flags nothing
            ("2025-03-03", "Did you train today?", true),
            ("2025-03-04", "Did you feel sick or ill?", true),
            ("2025-03-05", "Did you feel sick or ill?", false),
        ]
        let r = IllnessCalibration.dayFlags(entries: entries, nightLowDays: ["2025-03-03", "2025-03-09"])
        XCTAssertEqual(r.flags["2025-03-01"], .init(alcohol: true))
        XCTAssertNil(r.flags["2025-03-02"])
        XCTAssertEqual(r.flags["2025-03-03"], .init(hardOrLateWorkout: true, nocturnalLow: true))
        XCTAssertEqual(r.flags["2025-03-09"], .init(nocturnalLow: true))
        XCTAssertNil(r.flags["2025-03-04"])                              // unwell is not a confounder flag
        XCTAssertEqual(r.unwellDays, ["2025-03-04"])
    }

    // MARK: - Snapshot staleness

    func testSnapshotStaleness() {
        let result = IllnessCalibration.calibrate(history: quiet(200))
        let s = IllnessCalibration.Snapshot(result: result, computedDay: "2025-07-01", historyDays: 200)
        XCTAssertFalse(s.isStale(historyDays: 200, today: "2025-07-01"))
        XCTAssertFalse(s.isStale(historyDays: 229, today: "2025-07-20"))
        XCTAssertTrue(s.isStale(historyDays: 230, today: "2025-07-20"))     // history grew by 30
        XCTAssertTrue(s.isStale(historyDays: 205, today: "2025-07-31"))     // a month has passed
        XCTAssertFalse(s.isStale(historyDays: 205, today: "2025-07-30"))
        XCTAssertTrue(s.isStale(historyDays: 150, today: "2025-07-02"))     // history shrank
        XCTAssertTrue(s.isStale(historyDays: 200, today: "2025-06-01"))     // clock went backwards
        XCTAssertTrue(s.isStale(historyDays: 200, today: "garbage"))
        let old = IllnessCalibration.Snapshot(result: result, computedDay: "2025-07-01",
                                              historyDays: 200, version: IllnessCalibration.version + 1)
        XCTAssertTrue(old.isStale(historyDays: 200, today: "2025-07-01"))
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let h = spiked(quiet(200), at: [60, 61, 100, 101, 140, 141, 175, 176])
        let s = IllnessCalibration.Snapshot(result: IllnessCalibration.calibrate(history: h),
                                            computedDay: "2025-07-01", historyDays: 200)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(IllnessCalibration.Snapshot.self, from: data), s)
    }

    // MARK: - Constants

    func testConstantsArePinned() {
        XCTAssertEqual(IllnessCalibration.minimumHealthyDays, 120)
        XCTAssertEqual(IllnessCalibration.targetDaysPerAlarm, 60)
        XCTAssertEqual(IllnessCalibration.thresholdFloor, 50)
        XCTAssertEqual(IllnessCalibration.thresholdCeiling, 100)
        XCTAssertEqual(IllnessCalibration.unwellMarginDays, 7)
        XCTAssertEqual(IllnessCalibration.upperBoundConfidence, 0.95)
        XCTAssertEqual(IllnessCalibration.firstReplayIndex, 30)
        XCTAssertEqual(IllnessCalibration.recomputeAfterDays, 30)
    }

    func testIllIsMatchedAsAWholeWordOnly() {
        XCTAssertTrue(IllnessCalibration.tags(forQuestion: "Did you feel ill?").unwell)
        XCTAssertTrue(IllnessCalibration.tags(forQuestion: "Any illness symptoms?").unwell)
        XCTAssertTrue(IllnessCalibration.tags(forQuestion: "Feeling sick?").unwell)
        XCTAssertFalse(IllnessCalibration.tags(forQuestion: "Did you still train?").unwell)
        XCTAssertFalse(IllnessCalibration.tags(forQuestion: "Took a sleeping pill?").unwell)
        XCTAssertFalse(IllnessCalibration.tags(forQuestion: "Chill evening?").unwell)
    }
}
