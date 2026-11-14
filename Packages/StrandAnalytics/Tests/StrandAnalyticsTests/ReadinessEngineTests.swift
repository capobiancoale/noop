import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ReadinessEngineTests: XCTestCase {

    private func d(_ i: Int, hrv: Double?, rhr: Int?, strain: Double?, resp: Double? = nil,
                   charge: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2024-03-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: charge, strain: strain, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    /// 28 baseline days with gentle variation (so SD > 0), then `today` as day 29.
    private func baseline(todayHrv: Double?, todayRhr: Int?, todayStrain: Double?,
                          todayResp: Double? = nil, baseStrain: Double = 10,
                          todayCharge: Double? = nil) -> [DailyMetric] {
        var days: [DailyMetric] = []
        for i in 1...28 {
            days.append(d(i, hrv: i % 2 == 0 ? 62 : 58, rhr: i % 2 == 0 ? 54 : 50,
                          strain: baseStrain, resp: i % 2 == 0 ? 14.5 : 13.5))
        }
        days.append(d(29, hrv: todayHrv, rhr: todayRhr, strain: todayStrain, resp: todayResp, charge: todayCharge))
        return days
    }

    func testInsufficientWhenEmpty() {
        XCTAssertEqual(ReadinessEngine.evaluate(days: []).level, .insufficient)
    }

    func testPrimedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below, load steady.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10))
        XCTAssertEqual(r.level, .primed)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.evidence, "72 vs 60 ms")
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.evidence, "46 vs 52 bpm")
        // The Workouts card's TrainingLoad ratio: daily TRIMP behind Effort 10, this week vs the weeks before.
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.evidence, "7d 10 / usual week 10")
        XCTAssertEqual(r.acwr ?? 0, 1.0, accuracy: 1e-9)
    }

    func testRundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated → two "bad" recovery signals.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(r.level, .rundown)
    }

    func testAcwrSpikeStrains() {
        // Recovery signals neutral, but acute load spikes above chronic.
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: 15)) }
        days.append(d(29, hrv: 60, rhr: 52, strain: 15))
        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .bad)
        XCTAssertEqual(r.level, .strained)
        XCTAssertNotNil(r.acwr)
        XCTAssertGreaterThan(r.acwr!, 1.5)
    }

    /// The readiness ratio is the Workouts card's: the same days give the same number.
    func testLoadSignalMatchesTheWorkoutsCard() {
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 40)) }
        for i in 22...29 { days.append(d(i, hrv: 60, rhr: 52, strain: i % 2 == 0 ? 55 : 45)) }
        let r = ReadinessEngine.evaluate(days: days)
        let card = TrainingLoad.summary(days: days.map { (day: $0.day, effort: $0.strain) }, today: "2024-03-29")
        XCTAssertEqual(r.acwr ?? -1, card.ratio ?? -2, accuracy: 1e-12)
    }

    /// A lighter week is no readiness concern, and no load signal ever talks about injury.
    func testLighterWeekIsNeutralAndNoInjuryWording() {
        var days: [DailyMetric] = []
        for i in 1...22 { days.append(d(i, hrv: 60, rhr: 52, strain: 50)) }
        for i in 23...29 { days.append(d(i, hrv: 60, rhr: 52, strain: 20)) }
        let signal = ReadinessEngine.evaluate(days: days).signals.first { $0.key == "acwr" }
        XCTAssertEqual(signal?.flag, .neutral)
        XCTAssertFalse(signal?.detail.contains("injury") ?? true)
    }

    func testRespRateRiseFlags() {
        // Today resp rate well above baseline (~14) → illness-ish watch/bad signal present.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayResp: 18))
        XCTAssertTrue(r.signals.contains { $0.key == "respRate" })
        XCTAssertEqual(r.signals.first { $0.key == "respRate" }?.evidence, "18.0 vs 14.0 rpm")
    }

    func testExplicitTodayWithoutMatchingRowIsInsufficient() {
        // Stale historical import: newest row is 2024-03-29, but the device's real calendar day is later.
        // An explicit `today` with no matching row must read INSUFFICIENT — NOT synthesize off the newest
        // stored (stale) row (issue #23/#24).
        let days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, today: "2026-06-08").level, .insufficient)
        // The day that IS present still computes (no regression for current data).
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days, today: "2024-03-29").level, .insufficient)
        // The legacy no-`today` path is unchanged — still falls back to the most recent row.
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days).level, .insufficient)
    }

    /// A very steady resting HR (baseline 52 +/- 2) makes a 3 bpm rise "1.5 SD", but a few beats is ordinary
    /// day-to-day noise: it may only read as a watch, and 2 bpm as nothing at all.
    func testSmallRestingHrRiseOnASteadyBaselineIsNotAFlag() {
        let three = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 55, todayStrain: 10))
        XCTAssertEqual(three.signals.first { $0.key == "rhr" }?.flag, .watch)
        XCTAssertEqual(three.level, .balanced)
        let two = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 54, todayStrain: 10))
        XCTAssertEqual(two.signals.first { $0.key == "rhr" }?.flag, .neutral)
        // A real rise (8 bpm) still flags.
        let eight = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(eight.signals.first { $0.key == "rhr" }?.flag, .bad)
        XCTAssertEqual(eight.level, .strained)
    }

    /// The case behind the fix: Charge 85 (green), HRV well above baseline, resting HR up. The verdict must
    /// not say "recover" under a green Charge, nor "push" while a vital is flagged.
    func testGreenChargeIsNotOverturnedByOneVital() {
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 60, todayStrain: 10, todayCharge: 85))
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.flag, .bad)
        XCTAssertEqual(r.level, .balanced)
        // Without a Charge the same signals keep the old reading.
        let noCharge = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(noCharge.level, .strained)
        // Green Charge and everything aligned: primed.
        let aligned = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10, todayCharge: 85))
        XCTAssertEqual(aligned.level, .primed)
    }

    /// A green Charge still yields to a sharp load rise or a breathing-rate rise (which Charge barely weighs).
    func testGreenChargeStillYieldsToLoadAndBreathing() {
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: 15)) }
        days.append(d(29, hrv: 60, rhr: 52, strain: 15, charge: 80))
        XCTAssertEqual(ReadinessEngine.evaluate(days: days).level, .strained)
        let breathing = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10,
                                                                todayResp: 18, todayCharge: 80))
        XCTAssertEqual(breathing.signals.first { $0.key == "respRate" }?.flag, .bad)
        XCTAssertEqual(breathing.level, .strained)
    }

    /// A red Charge always reads as recover, even with quiet vitals; with a flagged vital it is run down.
    func testRedChargeAlwaysReadsRecover() {
        let quiet = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayCharge: 20))
        XCTAssertEqual(quiet.level, .strained)
        let flagged = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 52, todayStrain: 10, todayCharge: 20))
        XCTAssertEqual(flagged.signals.first { $0.key == "hrv" }?.flag, .bad)
        XCTAssertEqual(flagged.level, .rundown)
        // A yellow Charge leaves the signals in charge.
        let yellow = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayCharge: 50))
        XCTAssertEqual(yellow.level, .balanced)
    }

    func testStatsHelpers() {
        XCTAssertEqual(ReadinessEngine.mean([2, 4, 6]), 4)
        XCTAssertEqual(ReadinessEngine.sampleSD([2, 4, 6])!, 2.0, accuracy: 0.0001)
        XCTAssertNil(ReadinessEngine.sampleSD([5]))
        XCTAssertNil(ReadinessEngine.mean([]))
    }
}
