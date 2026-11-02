import XCTest
@testable import StrandAnalytics

final class Spo2RatioOfRatiosTests: XCTestCase {

    // MARK: - Synthetic PPG

    /// SplitMix64: a tiny deterministic generator so the noise in these tests never changes between runs.
    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func uniform() -> Double {
            Double(next() >> 11) / 9_007_199_254_740_992.0
        }

        /// Irwin-Hall: twelve uniforms minus six is close enough to a unit normal for a noise floor.
        mutating func gaussian() -> Double {
            var sum = 0.0
            for _ in 0..<12 { sum += uniform() }
            return sum - 6.0
        }
    }

    private let dcRed = 70_000.0
    private let dcIr = 72_000.0

    /// Unit-rms pulse: a fundamental plus a phase-shifted second harmonic (a dicrotic-looking shape).
    private func pulse(_ t: Double, hz: Double) -> Double {
        let fundamental = sin(2.0 * Double.pi * hz * t)
        let harmonic = 0.4 * sin(4.0 * Double.pi * hz * t + 0.6)
        // rms over a whole number of cycles: sqrt((1 + 0.4^2) / 2)
        return (fundamental + harmonic) / 0.58.squareRoot()
    }

    /// red = DCr (1 + PIr s), ir = DCi (1 + PIi s); optionally a 0.2 Hz common relative drift and
    /// independent seeded noise (given as a fraction of DC, rms) on each channel.
    private func synthetic(piRed: Double, piIr: Double, sampleRate: Double, seconds: Double,
                           hz: Double = 1.1, baseline: Bool = false, noise: Double = 0,
                           seed: UInt64 = 7) -> (red: [Double], ir: [Double]) {
        var rng = SplitMix64(state: seed)
        let count = Int(seconds * sampleRate)
        var red = [Double](repeating: 0, count: count)
        var ir = [Double](repeating: 0, count: count)
        for k in 0..<count {
            let t = Double(k) / sampleRate
            let s = pulse(t, hz: hz)
            let drift = baseline ? 1.0 + 0.002 * sin(2.0 * Double.pi * 0.2 * t) : 1.0
            var r = dcRed * drift * (1.0 + piRed * s)
            var i = dcIr * drift * (1.0 + piIr * s)
            if noise > 0 {
                r += dcRed * noise * rng.gaussian()
                i += dcIr * noise * rng.gaussian()
            }
            red[k] = r
            ir[k] = i
        }
        return (red, ir)
    }

    private func rms(_ x: ArraySlice<Double>) -> Double {
        guard !x.isEmpty else { return 0 }
        let sumSq = x.reduce(0.0) { $0 + $1 * $1 }
        return (sumSq / Double(x.count)).squareRoot()
    }

    // MARK: - Dense recordings

    func testRecoversRatioHalfWithBaselineAndNoise() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120,
                             baseline: true, noise: 0.0002)
        guard let est = Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: 100) else {
            return XCTFail("a clean 120 s synthetic recording must give an estimate")
        }
        XCTAssertEqual(est.ratio, 0.5, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(est.acceptedWindows, 15)
        XCTAssertLessThanOrEqual(est.acceptedWindows, est.totalWindows)
        XCTAssertEqual(Spo2RatioOfRatios.genericSpo2(ratio: est.ratio), 97.5, accuracy: 0.6)
    }

    func testRecoversRatioPointEight() {
        let data = synthetic(piRed: 0.0016, piIr: 0.002, sampleRate: 100, seconds: 120,
                             baseline: true, noise: 0.0002)
        guard let est = Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: 100) else {
            return XCTFail("a clean 120 s synthetic recording must give an estimate")
        }
        XCTAssertEqual(est.ratio, 0.8, accuracy: 0.03)
    }

    func testWindowGridMatchesTheDocumentedLayout() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120)
        let all = Spo2RatioOfRatios.windows(red: data.red, ir: data.ir, sampleRate: 100)
        // 10 s windows every 5 s over 120 s: starts 0, 5, ..., 110.
        XCTAssertEqual(all.count, 23)
        XCTAssertEqual(all.first?.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(all.last?.start ?? -1, 110, accuracy: 1e-9)
        // Clean synthetic data: perfusion is the PI we put in, and the pulse is shared by both channels.
        let middle = all[10]
        XCTAssertEqual(middle.perfusionIr, 0.002, accuracy: 0.0002)
        XCTAssertEqual(middle.perfusionRed, 0.001, accuracy: 0.0001)
        XCTAssertGreaterThan(middle.correlation, 0.99)
        XCTAssertTrue(middle.accepted)
    }

    func testSampleRateDoesNotChangeTheRatio() {
        let dense = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120)
        let sparse = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 25, seconds: 120)
        guard let a = Spo2RatioOfRatios.estimate(red: dense.red, ir: dense.ir, sampleRate: 100),
              let b = Spo2RatioOfRatios.estimate(red: sparse.red, ir: sparse.ir, sampleRate: 25) else {
            return XCTFail("both rates must give an estimate")
        }
        XCTAssertEqual(a.ratio, b.ratio, accuracy: 0.01)
    }

    func testIndependentNoiseChannelsGiveNoEstimate() {
        // No pulse at all: only independent noise per channel, strong enough to sit inside the perfusion
        // range, so it is the correlation gate that has to refuse it.
        let data = synthetic(piRed: 0, piIr: 0, sampleRate: 100, seconds: 120, noise: 0.003)
        let all = Spo2RatioOfRatios.windows(red: data.red, ir: data.ir, sampleRate: 100)
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.correlation < Spo2RatioOfRatios.minCorrelation })
        XCTAssertTrue(all.allSatisfy { Spo2RatioOfRatios.perfusionRange.contains($0.perfusionIr) })
        XCTAssertNil(Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: 100))
    }

    func testSpreadIsTheInterquartileRangeOfAcceptedRatios() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120,
                             baseline: true, noise: 0.0002)
        guard let est = Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: 100) else {
            return XCTFail("expected an estimate")
        }
        XCTAssertGreaterThanOrEqual(est.spread, 0)
        XCTAssertLessThan(est.spread, 0.05)
        // Exactly three accepted windows is enough for an estimate but too few for an IQR.
        let short = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 20)
        let threeWindows = Spo2RatioOfRatios.estimate(red: short.red, ir: short.ir, sampleRate: 100)
        XCTAssertEqual(threeWindows?.acceptedWindows, 3)
        XCTAssertEqual(threeWindows?.spread, 0)
    }

    func testMotionBurstWindowsAreRejectedAndTheMedianHolds() {
        var data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120)
        // A 15 s burst in the red channel only (an unshared artefact): those windows must not be accepted.
        var rng = SplitMix64(state: 99)
        for k in 5_000..<6_500 {
            data.red[k] += dcRed * 0.01 * rng.gaussian()
        }
        let all = Spo2RatioOfRatios.windows(red: data.red, ir: data.ir, sampleRate: 100)
        let struck = all.filter { $0.start >= 50 && $0.start + 10 <= 65 }
        XCTAssertFalse(struck.isEmpty)
        XCTAssertTrue(struck.allSatisfy { !$0.accepted })
        guard let est = Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: 100) else {
            return XCTFail("most of the recording is clean")
        }
        XCTAssertEqual(est.ratio, 0.5, accuracy: 0.02)
    }

    // MARK: - Robustness

    func testEmptyAndDegenerateInputsDoNotCrash() {
        let none: [Double] = []
        XCTAssertEqual(Spo2RatioOfRatios.windows(red: none, ir: none, sampleRate: 100), [])
        XCTAssertNil(Spo2RatioOfRatios.estimate(red: none, ir: none, sampleRate: 100))
        XCTAssertNil(Spo2RatioOfRatios.secondSampleRatio(red: none, ir: none))
        XCTAssertEqual(Spo2RatioOfRatios.channelOrder(none, none, sampleRate: 100), .undetermined)
        XCTAssertEqual(Spo2RatioOfRatios.bandPass(none, sampleRate: 100, low: 0.5, high: 5), [])
        XCTAssertEqual(Spo2RatioOfRatios.bandPass([42], sampleRate: 100, low: 0.5, high: 5), [0])

        // Shorter than one window.
        let brief = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 5)
        XCTAssertEqual(Spo2RatioOfRatios.windows(red: brief.red, ir: brief.ir, sampleRate: 100), [])
    }

    func testMismatchedLengthsUseTheShorterSeries() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120)
        let shortIr = Array(data.ir.prefix(6_000))
        let mixed = Spo2RatioOfRatios.windows(red: data.red, ir: shortIr, sampleRate: 100)
        let trimmed = Spo2RatioOfRatios.windows(red: Array(data.red.prefix(6_000)), ir: shortIr, sampleRate: 100)
        XCTAssertFalse(mixed.isEmpty)
        XCTAssertEqual(mixed, trimmed)
        XCTAssertEqual(mixed.count, 11)  // 60 s: starts 0, 5, ..., 50
    }

    func testNonPositiveDcSkipsEveryWindow() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 60)
        let zeros = [Double](repeating: 0, count: data.ir.count)
        XCTAssertEqual(Spo2RatioOfRatios.windows(red: zeros, ir: data.ir, sampleRate: 100), [])
        let negative = data.red.map { -$0 }
        XCTAssertEqual(Spo2RatioOfRatios.windows(red: negative, ir: data.ir, sampleRate: 100), [])
        XCTAssertEqual(Spo2RatioOfRatios.windows(red: data.red, ir: negative, sampleRate: 100), [])
        XCTAssertNil(Spo2RatioOfRatios.estimate(red: negative, ir: data.ir, sampleRate: 100))
    }

    func testUnusableSampleRatesGiveNothing() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 60)
        for rate in [2.0, 0.0, -100.0, Double.nan, Double.infinity] {
            XCTAssertEqual(Spo2RatioOfRatios.windows(red: data.red, ir: data.ir, sampleRate: rate), [],
                           "rate \(rate)")
            XCTAssertNil(Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: rate),
                         "rate \(rate)")
        }
    }

    func testAFlatChannelIsNotAcceptedAndDoesNotCrash() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 60)
        let flat = [Double](repeating: dcRed, count: data.red.count)
        let all = Spo2RatioOfRatios.windows(red: flat, ir: data.ir, sampleRate: 100)
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { !$0.accepted && $0.correlation == 0 })
        XCTAssertNil(Spo2RatioOfRatios.estimate(red: flat, ir: data.ir, sampleRate: 100))
        // The other way round has no IR pulse to divide by.
        XCTAssertEqual(Spo2RatioOfRatios.windows(red: data.red, ir: flat, sampleRate: 100), [])
    }

    func testANonFiniteSampleOnlyCostsTheWindowsThatContainIt() {
        var data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120)
        data.red[3_000] = .nan
        data.ir[8_000] = .infinity
        let all = Spo2RatioOfRatios.windows(red: data.red, ir: data.ir, sampleRate: 100)
        // Sample 3000 (30 s) sits in the windows starting at 25 s and 30 s; sample 8000 (80 s) in 75 s and 80 s.
        XCTAssertEqual(all.count, 23 - 4)
        XCTAssertTrue(all.allSatisfy { $0.ratio.isFinite && $0.correlation.isFinite })
        guard let est = Spo2RatioOfRatios.estimate(red: data.red, ir: data.ir, sampleRate: 100) else {
            return XCTFail("the rest of the recording is clean")
        }
        XCTAssertEqual(est.ratio, 0.5, accuracy: 0.02)
    }

    // MARK: - One value per second

    func testSecondSampleRatioRecoversRatioHalf() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 1, seconds: 301)
        XCTAssertEqual(data.red.count, 301)
        guard let out = Spo2RatioOfRatios.secondSampleRatio(red: data.red, ir: data.ir) else {
            return XCTFail("301 one-per-second samples must give a ratio")
        }
        XCTAssertEqual(out.ratio, 0.5, accuracy: 0.03)
        XCTAssertGreaterThan(out.correlation, 0.9)
    }

    func testSecondSampleRatioDoesNotDependOnHeartRate() {
        // The pulse aliases to a different slow frequency at every heart rate; the ratio must not care.
        for hz in [0.83, 1.37, 1.62, 2.21] {
            let data = synthetic(piRed: 0.0012, piIr: 0.002, sampleRate: 1, seconds: 301, hz: hz)
            guard let out = Spo2RatioOfRatios.secondSampleRatio(red: data.red, ir: data.ir) else {
                XCTFail("no ratio at \(hz) Hz")
                continue
            }
            XCTAssertEqual(out.ratio, 0.6, accuracy: 0.03, "heart rate \(hz * 60) bpm")
        }
    }

    func testSecondSampleRatioIsPulledTowardsOneByCommonModeWobble() {
        // Documents the known weakness: a 0.2 Hz relative wobble shared by both channels is not followed by a
        // 5-sample median at 1 Hz, so it adds an equal relative residual to red and IR. The ratio is biased
        // up (here from 0.5 towards 0.84) while the correlation stays high, which is why a one-per-second
        // ratio is only ever a rough figure.
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 1, seconds: 301, baseline: true)
        guard let out = Spo2RatioOfRatios.secondSampleRatio(red: data.red, ir: data.ir) else {
            return XCTFail("expected a ratio")
        }
        XCTAssertGreaterThan(out.ratio, 0.65)
        XCTAssertLessThan(out.ratio, 1.0)
        XCTAssertGreaterThan(out.correlation, 0.9)
    }

    func testSecondSampleRatioNeedsAMinuteOfData() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 1, seconds: 301)
        let few = Spo2RatioOfRatios.secondSampleWindow - 1
        XCTAssertNil(Spo2RatioOfRatios.secondSampleRatio(red: Array(data.red.prefix(few)),
                                                         ir: Array(data.ir.prefix(few))))
        XCTAssertNotNil(Spo2RatioOfRatios.secondSampleRatio(
            red: Array(data.red.prefix(Spo2RatioOfRatios.secondSampleWindow)),
            ir: Array(data.ir.prefix(Spo2RatioOfRatios.secondSampleWindow))))
    }

    func testSecondSampleRatioRefusesDegenerateInput() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 1, seconds: 301)
        let flat = [Double](repeating: dcIr, count: data.ir.count)
        XCTAssertNil(Spo2RatioOfRatios.secondSampleRatio(red: data.red, ir: flat), "no IR pulse")
        XCTAssertNil(Spo2RatioOfRatios.secondSampleRatio(red: data.red.map { -$0 }, ir: data.ir), "negative DC")
        var holed = data.red
        holed[100] = .nan
        XCTAssertNil(Spo2RatioOfRatios.secondSampleRatio(red: holed, ir: data.ir), "non-finite sample")
    }

    // MARK: - Channel order

    func testChannelOrderTellsRedFromInfrared() {
        let data = synthetic(piRed: 0.001, piIr: 0.002, sampleRate: 100, seconds: 120,
                             baseline: true, noise: 0.0002)
        XCTAssertEqual(Spo2RatioOfRatios.channelOrder(data.red, data.ir, sampleRate: 100), .asGiven)
        XCTAssertEqual(Spo2RatioOfRatios.channelOrder(data.ir, data.red, sampleRate: 100), .swapped)
    }

    func testChannelOrderIsUndeterminedWhenBothPulseTheSame() {
        let data = synthetic(piRed: 0.0015, piIr: 0.0015, sampleRate: 100, seconds: 120)
        XCTAssertEqual(Spo2RatioOfRatios.channelOrder(data.red, data.ir, sampleRate: 100), .undetermined)
    }

    func testChannelOrderIsUndeterminedWithoutAPulse() {
        let data = synthetic(piRed: 0, piIr: 0, sampleRate: 100, seconds: 120, noise: 0.003)
        XCTAssertEqual(Spo2RatioOfRatios.channelOrder(data.red, data.ir, sampleRate: 100), .undetermined)
    }

    // MARK: - Reference curve

    func testGenericCurveClampsAndMapsKnownPoints() {
        XCTAssertEqual(Spo2RatioOfRatios.genericSpo2(ratio: -1), 100, accuracy: 1e-9)
        XCTAssertEqual(Spo2RatioOfRatios.genericSpo2(ratio: 5), 0, accuracy: 1e-9)
        XCTAssertEqual(Spo2RatioOfRatios.genericSpo2(ratio: 0.4), 100, accuracy: 1e-9)
        XCTAssertEqual(Spo2RatioOfRatios.genericSpo2(ratio: 0.6), 95, accuracy: 1e-9)
        XCTAssertEqual(Spo2RatioOfRatios.genericSpo2(ratio: 1.0), 85, accuracy: 1e-9)
    }

    func testGenericCurveDoesNotInventAValueFromNaN() {
        XCTAssertTrue(Spo2RatioOfRatios.genericSpo2(ratio: .nan).isNaN)
    }

    // MARK: - Band-pass

    func testBandPassRejectsBaselineWanderAndKeepsThePulse() {
        let fs = 100.0
        let count = Int(60 * fs)
        let edge = Int(5 * fs)

        let slow = (0..<count).map { sin(2.0 * Double.pi * 0.05 * Double($0) / fs) }
        let slowOut = Spo2RatioOfRatios.bandPass(slow, sampleRate: fs, low: 0.5, high: 5)
        XCTAssertEqual(slowOut.count, count)
        let slowIn = rms(slow[edge..<(count - edge)])
        let slowKept = rms(slowOut[edge..<(count - edge)])
        XCTAssertLessThan(slowKept, 0.1 * slowIn, "0.05 Hz must be attenuated by more than 90 %")

        let cardiac = (0..<count).map { sin(2.0 * Double.pi * 1.2 * Double($0) / fs) }
        let cardiacOut = Spo2RatioOfRatios.bandPass(cardiac, sampleRate: fs, low: 0.5, high: 5)
        let cardiacIn = rms(cardiac[edge..<(count - edge)])
        let cardiacKept = rms(cardiacOut[edge..<(count - edge)])
        XCTAssertGreaterThan(cardiacKept, 0.9 * cardiacIn, "1.2 Hz must lose less than 10 %")
    }

    func testBandPassHasNoPhaseShift() {
        let fs = 100.0
        let count = Int(40 * fs)
        let x = (0..<count).map { sin(2.0 * Double.pi * 1.2 * Double($0) / fs) }
        let y = Spo2RatioOfRatios.bandPass(x, sampleRate: fs, low: 0.5, high: 5)
        // Zero phase: the output stays in step with the input, so their correlation is ~1 and the gain ~1.
        var dot = 0.0, xx = 0.0
        for k in Int(5 * fs)..<(count - Int(5 * fs)) {
            dot += x[k] * y[k]
            xx += x[k] * x[k]
        }
        XCTAssertEqual(dot / xx, 0.97, accuracy: 0.03)
    }

    func testBandPassRemovesTheMeanAndSurvivesSlowRates() {
        let flat = [Double](repeating: 70_000, count: 500)
        let out = Spo2RatioOfRatios.bandPass(flat, sampleRate: 100, low: 0.5, high: 5)
        XCTAssertEqual(out.count, 500)
        XCTAssertTrue(out.allSatisfy { abs($0) < 1e-9 })
        // The low-pass edge is clamped to 0.45 of the sample rate, so a 4 Hz recording still filters.
        let slowRate = (0..<400).map { 70_000 + 50 * sin(2.0 * Double.pi * 1.0 * Double($0) / 4.0) }
        let slowOut = Spo2RatioOfRatios.bandPass(slowRate, sampleRate: 4, low: 0.5, high: 5)
        XCTAssertTrue(slowOut.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(rms(slowOut[40..<360]), 10)
    }
}
