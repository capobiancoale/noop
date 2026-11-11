import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepOnsetLatencyTests: XCTestCase {

    // 1 Hz gravity. A "fidget" sample moves the wrist by 0.05 g (well above the 0.01 g still threshold).
    private func gravity(start: Int, seconds: Int, fidgetEvery: Int?) -> [GravitySample] {
        (0..<seconds).map { i in
            let moved = fidgetEvery.map { i % $0 == 0 } ?? false
            return GravitySample(ts: start + i, x: moved ? 0.05 : 0, y: 0, z: 1.0)
        }
    }

    private func onset(_ grav: [GravitySample], start: Int, end: Int) -> Int? {
        SleepStager.sustainedStillOnset(grav: grav, deltas: SleepStager.gravityDeltas(grav),
                                        start: start, end: end)
    }

    // Awake in bed: still most of the time but fidgeting (each fidget moves the wrist out and back, so
    // ≈ 71 % still deltas, just over the spine's 70 % bar), then real sleep (no movement). Onset lands at
    // the switch, not at the in-bed start. A window may hold up to 5 % movement, so it can open a few
    // minutes before the switch (here ≈ 3).
    func testAwakeStillThenSleepFindsOnsetAtTheSwitch() {
        let t0 = 1_800_000_000
        let awake = gravity(start: t0, seconds: 75 * 60, fidgetEvery: 7)
        let asleep = gravity(start: t0 + 75 * 60, seconds: 180 * 60, fidgetEvery: nil)
        let grav = awake + asleep
        let o = onset(grav, start: t0, end: t0 + 255 * 60)
        XCTAssertNotNil(o)
        XCTAssertEqual(Double(o! - t0) / 60, 75, accuracy: 5)
    }

    // A night that opens still: onset is the session start, so nothing changes.
    func testStillFromTheStartReturnsStart() {
        let t0 = 1_800_000_000
        let grav = gravity(start: t0, seconds: 120 * 60, fidgetEvery: nil)
        XCTAssertEqual(onset(grav, start: t0, end: t0 + 120 * 60), t0)
    }

    // Restless the whole time: no sustained stretch, nil, staging left alone.
    func testRestlessThroughoutReturnsNil() {
        let t0 = 1_800_000_000
        let grav = gravity(start: t0, seconds: 120 * 60, fidgetEvery: 10)
        XCTAssertNil(onset(grav, start: t0, end: t0 + 120 * 60))
    }

    // Sustained stillness that only starts after the latency cap: nil, not a 4-hour latency.
    func testOnsetPastTheLatencyCapReturnsNil() {
        let t0 = 1_800_000_000
        let restless = gravity(start: t0, seconds: (SleepStager.maxOnsetLatencyMin + 30) * 60, fidgetEvery: 7)
        let still = gravity(start: t0 + (SleepStager.maxOnsetLatencyMin + 30) * 60, seconds: 120 * 60, fidgetEvery: nil)
        let grav = restless + still
        XCTAssertNil(onset(grav, start: t0, end: grav.last!.ts + 1))
    }

    // Gravity too sparse to judge (one sample every 10 min at a 1 Hz median elsewhere): nil.
    func testSparseGravityReturnsNil() {
        let t0 = 1_800_000_000
        let dense = gravity(start: t0 - 600, seconds: 600, fidgetEvery: nil)  // sets a 1 s median interval
        let sparse = (0..<30).map { GravitySample(ts: t0 + $0 * 600, x: 0, y: 0, z: 1.0) }
        let grav = dense + sparse
        XCTAssertNil(onset(grav, start: t0, end: t0 + 300 * 60))
    }

    // MARK: - Relabel

    func testApplyOnsetLatencyRelabelsAndSplits() {
        let segs = [StageSegment(start: 0, end: 600, stage: "light"),
                    StageSegment(start: 600, end: 1200, stage: "wake"),
                    StageSegment(start: 1200, end: 3000, stage: "light"),
                    StageSegment(start: 3000, end: 4000, stage: "deep")]
        let out = SleepStager.applyOnsetLatency(segs, onset: 1800)
        XCTAssertEqual(out, [StageSegment(start: 0, end: 1800, stage: "wake"),
                             StageSegment(start: 1800, end: 3000, stage: "light"),
                             StageSegment(start: 3000, end: 4000, stage: "deep")])
    }

    func testApplyOnsetLatencyAtStartIsNoOp() {
        let segs = [StageSegment(start: 100, end: 700, stage: "light"),
                    StageSegment(start: 700, end: 900, stage: "rem")]
        XCTAssertEqual(SleepStager.applyOnsetLatency(segs, onset: 100), segs)
        XCTAssertEqual(SleepStager.applyOnsetLatency(segs, onset: 50), segs)
    }

    // End to end: the awake-in-bed stretch is staged wake and the session's sleep starts at the switch.
    func testDetectSleepCountsAwakeInBedAsWake() {
        let t0 = 1_800_000_000 - (1_800_000_000 % 86_400) + 22 * 3600   // 22:00 UTC
        let awake = gravity(start: t0, seconds: 75 * 60, fidgetEvery: 7)
        let asleep = gravity(start: t0 + 75 * 60, seconds: 7 * 3600, fidgetEvery: nil)
        let grav = awake + asleep
        let hr = stride(from: t0, to: grav.last!.ts, by: 5).map { HRSample(ts: $0, bpm: 55) }
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        guard let s = sessions.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else {
            return XCTFail("no session detected")
        }
        let firstSleep = s.stages.first { $0.stage != "wake" }?.start
        XCTAssertNotNil(firstSleep)
        XCTAssertEqual(Double(firstSleep! - (t0 + 75 * 60)) / 60, 0, accuracy: 3)
        let wakeMin = s.stages.filter { $0.stage == "wake" }.reduce(0) { $0 + $1.end - $1.start } / 60
        XCTAssertGreaterThanOrEqual(wakeMin, Int(Double(firstSleep! - s.start) / 60) - 1)
    }

    // MARK: - Readout

    func testFirstAsleepTsSkipsLeadingWakeAcrossFragments() {
        let a = #"[{"start":100,"end":400,"stage":"wake"},{"start":400,"end":900,"stage":"light"}]"#
        let b = #"[{"start":1000,"end":1200,"stage":"deep"}]"#
        XCTAssertEqual(SleepOnsetReadout.firstAsleepTs(stagesJSONs: [a, b], notBefore: 100), 400)
        XCTAssertEqual(SleepOnsetReadout.firstAsleepTs(stagesJSONs: [a, b], notBefore: 950), 1000)
    }

    func testFirstAsleepTsNilForImportedMinuteTotals() {
        let imported = #"{"awake":12,"light":200,"deep":80,"rem":90}"#
        XCTAssertNil(SleepOnsetReadout.firstAsleepTs(stagesJSONs: [imported, nil], notBefore: 0))
    }
}
