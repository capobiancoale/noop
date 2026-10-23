import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Pins `HeartRateRecoveryEngine`: HRR1 / HRR2 (Cole 1999, Shetler 2001), the +1…+60 min checkpoints,
/// the peak taken from 15 s medians (never a raw spike), the "80 % back to resting" time, and the
/// honesty rules (no interpolation across gaps, nil without post-workout data).
final class HeartRateRecoveryTests: XCTestCase {

    private let start = 1_700_000_000
    private var end: Int { start + 1800 }   // a 30 min workout

    /// 1 Hz series: `during(rel)` for rel ≤ 0 (seconds from the end, from the workout start), `after(rel)`
    /// for rel in 1…`until`. `skip(rel)` drops samples to model a strap dropout.
    private func series(during: (Int) -> Int = { _ in 170 },
                        after: (Int) -> Int,
                        until: Int,
                        skip: (Int) -> Bool = { _ in false }) -> [HRSample] {
        var out: [HRSample] = []
        for rel in (start - end)...until where !skip(rel) {
            out.append(HRSample(ts: end + rel, bpm: rel <= 0 ? during(rel) : after(rel)))
        }
        return out
    }

    /// resting 55 + (170 − 55) · exp(−t / 90): a clean exponential fall.
    private func decay(_ rel: Int) -> Int {
        Int((55.0 + 115.0 * exp(-Double(rel) / 90.0)).rounded())
    }

    private func compute(_ samples: [HRSample], resting: Double? = 55, now: Int, windowMinutes: Int = 60) -> HeartRateRecovery? {
        HeartRateRecoveryEngine.compute(samples: samples, workoutStart: start, workoutEnd: end,
                                        restingHR: resting, now: now, windowMinutes: windowMinutes)
    }

    // MARK: - Exponential decay

    func test_exponential_decay_values() throws {
        let s = series(after: decay, until: 3600)
        let r = try XCTUnwrap(compute(s, now: end + 4000))
        XCTAssertEqual(r.peakBpm, 170, accuracy: 1)
        // HR(60 s) = 55 + 115·e^(−2/3) ≈ 114 → HRR1 ≈ 56; HR(120 s) = 55 + 115·e^(−4/3) ≈ 85 → HRR2 ≈ 85.
        XCTAssertEqual(try XCTUnwrap(r.hrr1), 170 - 114.0, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(r.hrr2), 170 - 85.3, accuracy: 2)
        XCTAssertEqual(r.speed, .fast)
        // Threshold = 55 + 0.2 · 115 = 78.
        XCTAssertEqual(try XCTUnwrap(r.recoveryThreshold), 78, accuracy: 0.01)
        // The curve crosses 78 bpm at t ≈ 145 s; the trailing-minute median lags by ~30 s → ≈ 2.9 min.
        let minutes = try XCTUnwrap(r.recoveryMinutes)
        XCTAssertEqual(minutes, 2.9, accuracy: 0.3)
        XCTAssertTrue(r.reachedWithinWindow)
    }

    func test_complete_window_has_every_checkpoint() throws {
        let s = series(after: decay, until: 3600)
        let r = try XCTUnwrap(compute(s, now: end + 4000))
        XCTAssertEqual(r.checkpoints.map { $0.minutes }, [1, 2, 5, 10, 30, 60])
        XCTAssertEqual(try XCTUnwrap(r.bpm(atMinutes: 5)), 55.0 + 115.0 * exp(-300.0 / 90.0), accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(r.bpm(atMinutes: 30)), 55, accuracy: 1)
        XCTAssertTrue(r.isComplete)
        XCTAssertFalse(r.windowOpen)
        XCTAssertEqual(r.windowEnd, end + 3600)
        XCTAssertEqual(r.observedMinutes, 60)
    }

    func test_curve_runs_from_minus_two_minutes_and_is_ascending() throws {
        let s = series(after: decay, until: 600)
        let r = try XCTUnwrap(compute(s, now: end + 600))
        let first = try XCTUnwrap(r.curve.first)
        XCTAssertLessThanOrEqual(first.seconds, -105)
        XCTAssertGreaterThanOrEqual(first.seconds, -120)
        XCTAssertEqual(first.bpm, 170, accuracy: 0.5)
        let last = try XCTUnwrap(r.curve.last)
        XCTAssertLessThanOrEqual(last.seconds, 600)
        XCTAssertGreaterThan(last.seconds, 580)
        XCTAssertEqual(r.curve.map { $0.seconds }, r.curve.map { $0.seconds }.sorted())
        // 8 buckets before the end + 40 after.
        XCTAssertEqual(r.curve.count, 48)
    }

    // MARK: - Peak

    func test_single_spike_is_not_the_peak() throws {
        // A 220 bpm glitch 30 s before the end sits inside the 15 s bucket's 15 samples: the median ignores it.
        let s = series(during: { $0 == -30 ? 220 : 170 }, after: decay, until: 600)
        let r = try XCTUnwrap(compute(s, now: end + 600))
        XCTAssertEqual(r.peakBpm, 170, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(r.hrr1), 56, accuracy: 2)
    }

    func test_peak_is_taken_from_the_last_two_minutes_only() throws {
        // 190 bpm early on, then an easier finish at 150: the peak that counts is the finish.
        let s = series(during: { $0 < -300 ? 190 : 150 }, after: { _ in 100 }, until: 600)
        let r = try XCTUnwrap(compute(s, now: end + 600))
        XCTAssertEqual(r.peakBpm, 150, accuracy: 0.5)
    }

    func test_short_workout_uses_the_whole_workout() throws {
        // 90 s workout (shorter than the 2 min look-back).
        let shortStart = end - 90
        var s: [HRSample] = []
        for rel in -300...300 {
            // Easy 80 bpm before the workout started, 160 during it.
            let bpm = rel < -90 ? 80 : (rel <= 0 ? 160 : Int((60.0 + 100.0 * exp(-Double(rel) / 90.0)).rounded()))
            s.append(HRSample(ts: end + rel, bpm: bpm))
        }
        let r = try XCTUnwrap(HeartRateRecoveryEngine.compute(samples: s, workoutStart: shortStart, workoutEnd: end,
                                                              restingHR: 60, now: end + 300))
        XCTAssertEqual(r.peakBpm, 160, accuracy: 0.5)
        // Nothing from before the workout start leaks into the curve (first bucket is the one holding −90 s).
        let first = try XCTUnwrap(r.curve.first)
        XCTAssertGreaterThanOrEqual(first.seconds, -105)
        XCTAssertEqual(first.bpm, 160, accuracy: 0.5)
    }

    func test_fewer_than_two_samples_in_last_two_minutes_is_nil() {
        let s = [HRSample(ts: end - 5, bpm: 170)] + (1...600).map { HRSample(ts: end + $0, bpm: 120) }
        XCTAssertNil(compute(s, now: end + 600))
    }

    // MARK: - Gaps

    func test_gap_around_one_minute_gives_nil_hrr1_but_later_checkpoints() throws {
        // 40 s without data around +60 s: nothing within ±10 s of +60 s. +120 s and later survive.
        let s = series(after: decay, until: 3600, skip: { (40...80).contains($0) })
        let r = try XCTUnwrap(compute(s, now: end + 4000))
        XCTAssertNil(r.hrr1)
        XCTAssertNil(r.bpm(atMinutes: 1))
        XCTAssertNotNil(r.hrr2)
        XCTAssertEqual(r.checkpoints.map { $0.minutes }, [2, 5, 10, 30, 60])
    }

    func test_gap_shorter_than_tolerance_still_measures() throws {
        // 8 s dropout centred on +60 s leaves samples inside ±10 s, so the median still has data.
        let s = series(after: decay, until: 600, skip: { (56...64).contains($0) })
        let r = try XCTUnwrap(compute(s, now: end + 600))
        XCTAssertEqual(try XCTUnwrap(r.hrr1), 56, accuracy: 2.5)
    }

    func test_far_checkpoint_uses_the_wider_tolerance() throws {
        // No samples within ±10 s of +5 min but some within ±30 s: the 5 min checkpoint still exists.
        let s = series(after: decay, until: 900, skip: { (285...315).contains($0) })
        let r = try XCTUnwrap(compute(s, now: end + 900))
        XCTAssertNotNil(r.bpm(atMinutes: 5))
    }

    // MARK: - Recovery time

    func test_no_resting_hr_gives_no_recovery_time() throws {
        let s = series(after: decay, until: 600)
        let r = try XCTUnwrap(compute(s, resting: nil, now: end + 600))
        XCTAssertNil(r.recoveryThreshold)
        XCTAssertNil(r.recoveryMinutes)
        XCTAssertFalse(r.reachedWithinWindow)
        // The resting-independent numbers are still there.
        XCTAssertNotNil(r.hrr1)
    }

    func test_not_reached_within_window() throws {
        // HR plateaus at 120 for the whole hour: never within 20 % of the way back from 170 to 55 (78 bpm).
        let s = series(after: { _ in 120 }, until: 3600)
        let r = try XCTUnwrap(compute(s, now: end + 4000))
        XCTAssertEqual(try XCTUnwrap(r.recoveryThreshold), 78, accuracy: 0.01)
        XCTAssertNil(r.recoveryMinutes)
        XCTAssertFalse(r.reachedWithinWindow)
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.speed, .fast)   // 170 → 120 is still a 50 bpm fall in the first minute
    }

    func test_peak_too_close_to_resting_has_no_threshold() throws {
        let s = series(during: { _ in 62 }, after: { _ in 58 }, until: 600)
        let r = try XCTUnwrap(compute(s, now: end + 600))
        XCTAssertNil(r.recoveryThreshold)
        XCTAssertNil(r.recoveryMinutes)
    }

    // MARK: - Open window

    func test_window_still_open() throws {
        let s = series(after: decay, until: 600)
        let r = try XCTUnwrap(compute(s, now: end + 600))
        XCTAssertFalse(r.isComplete)
        XCTAssertTrue(r.windowOpen)
        XCTAssertNil(r.bpm(atMinutes: 30))
        XCTAssertNil(r.bpm(atMinutes: 60))
        XCTAssertNotNil(r.bpm(atMinutes: 10))
        XCTAssertEqual(r.windowEnd, end + 600)
    }

    func test_samples_in_the_future_are_ignored() throws {
        let s = series(after: decay, until: 3600)
        let r = try XCTUnwrap(compute(s, now: end + 300))
        XCTAssertEqual(r.windowEnd, end + 300)
        XCTAssertNil(r.bpm(atMinutes: 10))
    }

    func test_short_requested_window_is_closed_but_not_complete() throws {
        let s = series(after: decay, until: 3600)
        let r = try XCTUnwrap(compute(s, now: end + 4000, windowMinutes: 3))
        XCTAssertFalse(r.windowOpen)
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.windowEnd, end + 180)
        XCTAssertNotNil(r.hrr1)
        XCTAssertNotNil(r.hrr2)
    }

    // MARK: - No data

    func test_no_samples_after_the_end_is_nil() {
        let s = series(after: decay, until: 0)
        XCTAssertNil(compute(s, now: end + 600))
    }

    func test_implausible_samples_are_dropped() {
        // Only 0 bpm (strap off wrist) after the end: nothing usable.
        let s = series(after: { _ in 0 }, until: 600)
        XCTAssertNil(compute(s, now: end + 600))
    }

    func test_invalid_bounds_are_nil() {
        let s = series(after: decay, until: 600)
        XCTAssertNil(HeartRateRecoveryEngine.compute(samples: s, workoutStart: end, workoutEnd: end,
                                                     restingHR: 55, now: end + 600))
    }

    // MARK: - Speed label

    func test_speed_boundaries() {
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(-4), .slow)
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(12), .slow)
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(12.4), .slow)
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(13), .typical)
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(24), .typical)
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(25), .fast)
        XCTAssertEqual(HeartRateRecoveryEngine.hrr1Speed(41), .fast)
    }
}
