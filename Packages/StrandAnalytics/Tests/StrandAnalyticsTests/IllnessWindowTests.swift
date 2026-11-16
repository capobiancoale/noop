import XCTest
@testable import StrandAnalytics

/// Pins `IllnessSignalEngine.inputs(history:endingAt:)` to the z-building the app used to do inline in
/// `AppModel.applyIllnessSignal`, so moving it into the package (one code path for the live alert and
/// the calibration replay) cannot change what the live alert sees. `legacy` is that code, verbatim apart
/// from the storage type, and every field must match EXACTLY (no tolerance).
final class IllnessWindowTests: XCTestCase {

    typealias Day = IllnessSignalEngine.DayVitals

    private struct Legacy {
        var inputs: IllnessSignalEngine.Inputs
        var trusted: Bool
        var rhrRise: Double?
        var hrvDropPercent: Double?
        var skinRise: Double?
        var respUp: Bool
    }

    /// The old inline code. `days` is the history up to and including the day being evaluated.
    private func legacy(_ days: [Day]) -> Legacy {
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))    // ~28 days ending 3 days ago
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }
        func rm(_ kp: (Day) -> Double?) -> Double? { mean(recent.compactMap(kp)) }

        func signal(_ kp: (Day) -> Double?, cfgKey: String, illnessUp: Bool)
            -> (IllnessSignalEngine.SignalReading, Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = rm(kp) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let z = illnessUp ? dev.z : -dev.z
            return (IllnessSignalEngine.SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHR }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.hrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respiration }, cfgKey: "resp", illnessUp: true)
        var skin: (IllnessSignalEngine.SignalReading, Bool)? = nil
        if let recentSkin = rm({ $0.skinTempDevC }) {
            let z = recentSkin / 0.3
            skin = (IllnessSignalEngine.SignalReading(zIllnessward: z), true)
        }
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: rhr?.0, skinTemp: skin?.0, hrv: hrv?.0, respiration: resp?.0)
        let trusted = (rhr?.1 ?? false) || (hrv?.1 ?? false)

        var rise: Double? = nil
        if let r = rm({ $0.restingHR }), let b = mean(base.compactMap { $0.restingHR }), r > b { rise = r - b }
        var drop: Double? = nil
        if let r = rm({ $0.hrv }), let b = mean(base.compactMap { $0.hrv }), b > 0, r < b { drop = (1 - r / b) * 100 }
        var skinRise: Double? = nil
        if let r = rm({ $0.skinTempDevC }), r > 0 { skinRise = r }
        var up = false
        if let r = rm({ $0.respiration }), let b = mean(base.compactMap { $0.respiration }), r > b { up = true }
        return Legacy(inputs: inputs, trusted: trusted, rhrRise: rise, hrvDropPercent: drop,
                      skinRise: skinRise, respUp: up)
    }

    /// Deterministic pseudo-random history with gaps (nil columns) and the odd out-of-range value, so
    /// every branch (absent, unusable baseline, hard outliers, nil recent window) is exercised.
    private func history(seed: UInt64, count: Int, gapEvery: Int) -> [Day] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0xFFFF) / 65_535.0
        }
        return (0..<count).map { i in
            let key = String(format: "2025-%02d-%02d", 1 + (i / 28) % 12, 1 + i % 28)
            let hole = gapEvery > 0 && i % gapEvery == 0
            let bump = (i % 41 == 0) ? 1.0 : 0.0     // an occasional bad night in every signal
            return Day(
                day: key,
                restingHR: (hole && i % 2 == 0) ? nil : 52 + next() * 6 + bump * 12,
                hrv: (hole && i % 3 == 0) ? nil : 70 + next() * 25 - bump * 30,
                respiration: (hole && i % 5 == 0) ? nil : 14 + next() * 1.5 + bump * 2,
                skinTempDevC: (hole && i % 7 == 0) ? nil : (next() - 0.5) * 0.5 + bump * 0.8)
        }
    }

    func testWindowMatchesTheLegacyInlineCodeExactly() {
        var checked = 0
        for (seed, count, gap) in [(1 as UInt64, 90, 0), (7, 140, 4), (99, 60, 3), (12345, 200, 6), (5, 16, 0), (3, 40, 2)] {
            let h = history(seed: seed, count: count, gapEvery: gap)
            // 14 is the live path's minimum; replay starts at 30; check every day from 14 on.
            for i in 13..<h.count {
                guard let w = IllnessSignalEngine.inputs(history: h, endingAt: i) else { return XCTFail("nil window") }
                let old = legacy(Array(h[0...i]))
                XCTAssertEqual(w.inputs, old.inputs, "inputs seed \(seed) day \(i)")
                XCTAssertEqual(w.baselineTrusted, old.trusted, "trusted seed \(seed) day \(i)")
                XCTAssertEqual(w.restingHRRise, old.rhrRise, "rise seed \(seed) day \(i)")
                XCTAssertEqual(w.hrvDropPercent, old.hrvDropPercent, "drop seed \(seed) day \(i)")
                XCTAssertEqual(w.skinTempRiseC, old.skinRise, "skin seed \(seed) day \(i)")
                XCTAssertEqual(w.respirationUp, old.respUp, "resp seed \(seed) day \(i)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }

    func testWindowOutOfRangeIsNil() {
        let h = history(seed: 1, count: 20, gapEvery: 0)
        XCTAssertNil(IllnessSignalEngine.inputs(history: h, endingAt: 20))
        XCTAssertNil(IllnessSignalEngine.inputs(history: h, endingAt: -1))
        XCTAssertNil(IllnessSignalEngine.inputs(history: [], endingAt: 0))
        XCTAssertNotNil(IllnessSignalEngine.inputs(history: h, endingAt: 19))
    }

    func testWindowConstantsMatchTheLiveWindow() {
        XCTAssertEqual(IllnessSignalEngine.recentDayCount, 2)
        XCTAssertEqual(IllnessSignalEngine.baselineSpan, 31)
        XCTAssertEqual(IllnessSignalEngine.baselineGap, 3)
        XCTAssertEqual(IllnessSignalEngine.skinTempSpreadC, 0.3)
    }

    /// A hand-built illness-shaped week: the engine reads the window as the classic multi-signal rise.
    func testClassicIllnessWeekIsReadAsRaised() {
        var h = history(seed: 42, count: 60, gapEvery: 0)
        // Replace the last two days with a clear rise in every signal.
        for i in 58..<60 {
            h[i] = Day(day: h[i].day, restingHR: 70, hrv: 40, respiration: 18, skinTempDevC: 1.0)
        }
        guard let w = IllnessSignalEngine.inputs(history: h, endingAt: 59) else { return XCTFail("nil window") }
        XCTAssertTrue(w.baselineTrusted)
        let r = IllnessSignalEngine.evaluate(w.inputs, context: .init(baselineTrusted: w.baselineTrusted))
        XCTAssertEqual(r.level, .raised)
        XCTAssertGreaterThanOrEqual(r.signalCount, 3)
        XCTAssertNotNil(w.restingHRRise)
        XCTAssertNotNil(w.hrvDropPercent)
        XCTAssertNotNil(w.skinTempRiseC)
        XCTAssertTrue(w.respirationUp)
    }
}
