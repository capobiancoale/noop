import XCTest
@testable import StrandAnalytics

final class CorrelationEngineTests: XCTestCase {

    func testPerfectPositiveCorrelation() {
        // y = 2x + 1 → r = 1, slope 2, intercept 1.
        let xy: [(Double, Double)] = [(1, 3), (2, 5), (3, 7), (4, 9), (5, 11)]
        let c = CorrelationEngine.pearson(xy)!
        XCTAssertEqual(c.r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.slope, 2.0, accuracy: 1e-9)
        XCTAssertEqual(c.intercept, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.n, 5)
        XCTAssertEqual(c.pApprox, 0.0, accuracy: 1e-9)   // |r|=1 → p 0
    }

    func testPerfectNegativeCorrelation() {
        // y = -3x + 20 → r = -1, slope -3.
        let xy: [(Double, Double)] = [(1, 17), (2, 14), (3, 11), (4, 8), (5, 5)]
        let c = CorrelationEngine.pearson(xy)!
        XCTAssertEqual(c.r, -1.0, accuracy: 1e-9)
        XCTAssertEqual(c.slope, -3.0, accuracy: 1e-9)
        XCTAssertEqual(c.intercept, 20.0, accuracy: 1e-9)
    }

    func testIndependentSeriesNearZero() {
        // Symmetric (y mirrors across the x midpoint) → exactly r = 0.
        let xy: [(Double, Double)] = [(1, 10), (2, 8), (3, 6), (4, 6), (5, 8), (6, 10)]
        let c = CorrelationEngine.pearson(xy)!
        XCTAssertEqual(c.r, 0.0, accuracy: 1e-9)
        XCTAssertEqual(c.slope, 0.0, accuracy: 1e-9)
        // r=0 → t=0 → p≈1 (A&S erf leaves a ~1e-9 residual at z=0).
        XCTAssertEqual(c.pApprox, 1.0, accuracy: 1e-6)
    }

    func testPearsonGoldenValues() {
        // x=[1..5], y=[2,4,5,4,5] → r=0.7745966692, slope 0.6, intercept 2.2,
        // pApprox (A&S-erf normal approx) ≈ 0.0338947336.
        let xy: [(Double, Double)] = [(1, 2), (2, 4), (3, 5), (4, 4), (5, 5)]
        let c = CorrelationEngine.pearson(xy)!
        XCTAssertEqual(c.r, 0.7745966692414834, accuracy: 1e-9)
        XCTAssertEqual(c.slope, 0.6, accuracy: 1e-9)
        XCTAssertEqual(c.intercept, 2.2, accuracy: 1e-9)
        XCTAssertEqual(c.pApprox, 0.033894733597028104, accuracy: 1e-6)
    }

    func testPearsonTooFewReturnsNil() {
        XCTAssertNil(CorrelationEngine.pearson([(1, 1), (2, 2)]))   // n=2 < 3
    }

    func testPearsonZeroVarianceReturnsNil() {
        // x constant → undefined correlation.
        XCTAssertNil(CorrelationEngine.pearson([(5, 1), (5, 2), (5, 3)]))
        // y constant → undefined correlation.
        XCTAssertNil(CorrelationEngine.pearson([(1, 7), (2, 7), (3, 7)]))
    }

    func testAlignByDayInnerJoinSorted() {
        let a: [(day: String, value: Double)] = [
            ("2026-01-03", 30), ("2026-01-01", 10), ("2026-01-02", 20),
        ]
        let b: [(day: String, value: Double)] = [
            ("2026-01-02", 200), ("2026-01-01", 100), ("2026-01-09", 900),  // 01-09 only in b
        ]
        let pairs = CorrelationEngine.alignByDay(a, b)
        // Common days 01-01, 01-02 in sorted order.
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].0, 10); XCTAssertEqual(pairs[0].1, 100)
        XCTAssertEqual(pairs[1].0, 20); XCTAssertEqual(pairs[1].1, 200)
    }

    func testLaggedPicksTheRightOffset() {
        // Build y as x shifted FORWARD by one day: y[D+1] = x[D].
        // So lag = +1 (x[D] vs y[D+1]) should be a perfect positive correlation;
        // lag = 0 should be much weaker / undefined here.
        let x: [(day: String, value: Double)] = [
            ("2026-01-01", 1), ("2026-01-02", 2), ("2026-01-03", 3),
            ("2026-01-04", 4), ("2026-01-05", 5),
        ]
        let y: [(day: String, value: Double)] = [
            ("2026-01-02", 1), ("2026-01-03", 2), ("2026-01-04", 3),
            ("2026-01-05", 4), ("2026-01-06", 5),
        ]
        let lag1 = CorrelationEngine.lagged(x: x, y: y, lagDays: 1)!
        XCTAssertEqual(lag1.r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(lag1.n, 5)   // all five x days map onto a y day

        // lag 0: only days present in both are 01-02..01-05 (4 pairs). x there is
        // 2,3,4,5 and y there is 1,2,3,4 → still perfectly linear, r=1 but a
        // DIFFERENT intercept; the discriminator is which lag includes the most
        // data and the strongest relationship. Use lag 2 to show it falls off.
        let lag2 = CorrelationEngine.lagged(x: x, y: y, lagDays: 2)
        // x[D] vs y[D+2]: pairs (01-01→01-03:1,2),(01-02→01-04:2,3),(01-03→01-05:3,4),
        // (01-04→01-06:4,5) → 4 pairs, still linear r=1. To truly distinguish, build
        // a non-monotone y below; here we just assert lag2 has fewer pairs than lag1.
        XCTAssertEqual(lag2!.n, 4)
        XCTAssertLessThan(lag2!.n, lag1.n)
    }

    func testLaggedDiscriminatesOnNonMonotoneSeries() {
        // x is a sawtooth; y equals x shifted forward by exactly 2 days.
        // Then lag=+2 must give r=1 while lag=+1 gives a weaker correlation.
        let xv: [Double] = [1, 5, 2, 6, 3, 7, 4]
        var x: [(day: String, value: Double)] = []
        var y: [(day: String, value: Double)] = []
        let base = 1
        for (i, v) in xv.enumerated() {
            let dDay = String(format: "2026-02-%02d", base + i)
            x.append((dDay, v))
            // y on day+2 carries the same value.
            let yDay = String(format: "2026-02-%02d", base + i + 2)
            y.append((yDay, v))
        }
        let lag2 = CorrelationEngine.lagged(x: x, y: y, lagDays: 2)!
        XCTAssertEqual(lag2.r, 1.0, accuracy: 1e-9)   // exact match at the true lag

        let lag1 = CorrelationEngine.lagged(x: x, y: y, lagDays: 1)!
        XCTAssertLessThan(abs(lag1.r), 0.999)         // weaker at the wrong lag
        XCTAssertGreaterThan(lag2.r, lag1.r)          // best at the true offset
    }

    func testLaggedZeroLagEqualsAlign() {
        let x: [(day: String, value: Double)] = [
            ("2026-03-01", 1), ("2026-03-02", 2), ("2026-03-03", 3), ("2026-03-04", 4),
        ]
        let y: [(day: String, value: Double)] = [
            ("2026-03-01", 2), ("2026-03-02", 1), ("2026-03-03", 4), ("2026-03-04", 3),
        ]
        let lag0 = CorrelationEngine.lagged(x: x, y: y, lagDays: 0)!
        let direct = CorrelationEngine.pearson(CorrelationEngine.alignByDay(x, y))!
        XCTAssertEqual(lag0.r, direct.r, accuracy: 1e-12)
        XCTAssertEqual(lag0.slope, direct.slope, accuracy: 1e-12)
    }

    func testShiftDayCrossesMonthAndYear() {
        XCTAssertEqual(CorrelationEngine.shiftDay("2026-01-31", by: 1), "2026-02-01")
        XCTAssertEqual(CorrelationEngine.shiftDay("2026-03-01", by: -1), "2026-02-28")
        XCTAssertEqual(CorrelationEngine.shiftDay("2025-12-31", by: 1), "2026-01-01")
        XCTAssertEqual(CorrelationEngine.shiftDay("2024-02-28", by: 1), "2024-02-29") // leap year
    }

    // MARK: - Student-t tail (exact)

    func testStudentTwoSidedPKnownValues() {
        // Reference values by numerical integration of the Student-t density.
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 2.0, df: 10), 0.0733880348, accuracy: 1e-7)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 2.228138852, df: 10), 0.05, accuracy: 1e-7)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 1.96, df: 1000), 0.0502731850, accuracy: 1e-7)
        // df = 1 is the Cauchy law: P(|T| >= 1) = 0.5. df = 2: P(|T| >= t) = 1 - t / sqrt(t^2 + 2).
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 1.0, df: 1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 1.0, df: 2), 1.0 - 1.0 / 3.0.squareRoot(), accuracy: 1e-12)
        // Fractional df (an effective sample size) is fine.
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 3.0, df: 5.5), 0.0267234807, accuracy: 1e-7)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 2.5, df: 26.3), 0.0189762723, accuracy: 1e-7)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 4.0, df: 40), 0.000265912396, accuracy: 1e-9)
    }

    func testStudentTwoSidedPSymmetryAndEdges() {
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: -2.0, df: 10),
                       CorrelationEngine.studentTwoSidedP(t: 2.0, df: 10), accuracy: 1e-15)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 0, df: 10), 1.0)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: .infinity, df: 10), 0.0)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: 2.0, df: 0), 1.0)
        XCTAssertEqual(CorrelationEngine.studentTwoSidedP(t: .nan, df: 10), 1.0)
        // Heavier tails than the normal at small df: P(|T| >= 2) at df = 3 is about 0.139
        // against about 0.0455 for the normal.
        XCTAssertGreaterThan(CorrelationEngine.studentTwoSidedP(t: 2.0, df: 3), 0.13)
        // Monotone: a larger |t| is never less significant.
        var last = 1.0
        for i in 1...40 {
            let p = CorrelationEngine.studentTwoSidedP(t: Double(i) * 0.25, df: 17)
            XCTAssertLessThan(p, last)
            last = p
        }
    }

    // MARK: - Detrending

    func testDetrendedRemovesLinearTrendOverCalendarDays() {
        // value = 3 + 2 * (calendar day offset), with a 10-day gap in the middle. Weighting by
        // array index instead of calendar distance would leave a large residual.
        let offsets = [0, 1, 2, 3, 14, 15, 16, 17]
        let series = offsets.map { (day: day($0), value: 3.0 + 2.0 * Double($0)) }
        let res = CorrelationEngine.detrended(series)
        XCTAssertEqual(res.count, offsets.count)
        for row in res { XCTAssertEqual(row.value, 0.0, accuracy: 1e-9) }
        XCTAssertEqual(res.map(\.day), series.map(\.day))
    }

    func testDetrendedResidualsAreCenteredAndUncorrelatedWithTime() {
        var rng = TestRNG(seed: 11)
        let series = (0..<60).map { (day: day($0), value: 100.0 + 0.7 * Double($0) + 4.0 * rng.gaussian()) }
        let res = CorrelationEngine.detrended(series).map(\.value)
        XCTAssertEqual(res.reduce(0, +) / Double(res.count), 0.0, accuracy: 1e-9)
        let idx = (0..<60).map(Double.init)
        let c = CorrelationEngine.pearson(Array(zip(idx, res)))!
        XCTAssertEqual(c.r, 0.0, accuracy: 1e-9)
    }

    func testDetrendedAveragesRepeatedDaysAndSkipsBadKeys() {
        let series: [(day: String, value: Double)] = [
            ("2026-01-01", 10), ("2026-01-01", 20), ("2026-01-02", 15),
            ("not-a-day", 99), ("2026-01-03", 15),
        ]
        let res = CorrelationEngine.detrended(series)
        XCTAssertEqual(res.map(\.day), ["2026-01-01", "2026-01-02", "2026-01-03"])
        // Means 15, 15, 15 -> flat -> zero residuals.
        for row in res { XCTAssertEqual(row.value, 0.0, accuracy: 1e-12) }
    }

    func testDayNumberAgreesWithShiftDay() {
        let base = "2024-02-20"
        let b0 = CorrelationEngine.dayNumber(base)!
        for k in [-400, -31, -1, 0, 1, 9, 10, 29, 30, 365, 800] {
            let shifted = CorrelationEngine.shiftDay(base, by: k)!
            XCTAssertEqual(CorrelationEngine.dayNumber(shifted)! - b0, k)
        }
        XCTAssertEqual(CorrelationEngine.dayNumber("1970-01-01"), 0)
        XCTAssertNil(CorrelationEngine.dayNumber("2026-13-01"))
    }

    // MARK: - Lag-1 autocorrelation

    func testLag1Autocorrelation() {
        XCTAssertNil(CorrelationEngine.lag1Autocorrelation([1, 2]))
        XCTAssertNil(CorrelationEngine.lag1Autocorrelation([4, 4, 4, 4]))
        // Alternating -> strongly negative; a ramp -> strongly positive.
        let alt = CorrelationEngine.lag1Autocorrelation([1, -1, 1, -1, 1, -1, 1, -1])!
        XCTAssertLessThan(alt, -0.8)
        let ramp = CorrelationEngine.lag1Autocorrelation((0..<30).map(Double.init))!
        XCTAssertGreaterThan(ramp, 0.85)
        // Hand-computed for [1, 2, 3, 2, 1]: mean 1.8, deviations [-0.8, 0.2, 1.2, 0.2, -0.8].
        // Sum of lagged products = -0.16 + 0.24 + 0.24 - 0.16 = 0.16; sum of squares = 2.8.
        let small = CorrelationEngine.lag1Autocorrelation([1, 2, 3, 2, 1])!
        XCTAssertEqual(small, 0.16 / 2.8, accuracy: 1e-12)
    }

    // MARK: - associationTest

    func testSharedTrendGivesHighRawButNonSignificantDetrendedR() {
        // Two INDEPENDENT noise processes riding on different upward drifts (think: a slowly
        // improving fitness metric and a slowly drifting weight). Raw r is large; after
        // detrending there is nothing left.
        var rng = TestRNG(seed: 5)
        let n = 90
        let x = (0..<n).map { (day: day($0), value: 50.0 + 0.30 * Double($0) + 2.0 * rng.gaussian()) }
        let y = (0..<n).map { (day: day($0), value: 80.0 + 0.55 * Double($0) + 3.0 * rng.gaussian()) }

        let raw = CorrelationEngine.pearson(CorrelationEngine.alignByDay(x, y))!
        XCTAssertGreaterThan(raw.r, 0.85)

        let t = CorrelationEngine.associationTest(x: x, y: y)!
        XCTAssertLessThan(abs(t.r), 0.25)
        XCTAssertGreaterThan(t.p, 0.05)
        XCTAssertEqual(t.n, n)
        XCTAssertEqual(t.lagDays, 0)
    }

    func testTrueRelationSurvivesDetrending() {
        // y shares (inversely) the day-to-day fluctuation of x, on top of its own drift and noise.
        var rng = TestRNG(seed: 21)
        let n = 70
        var x: [(day: String, value: Double)] = []
        var y: [(day: String, value: Double)] = []
        for i in 0..<n {
            let shock = rng.gaussian()
            x.append((day(i), 60.0 + 0.10 * Double(i) + 5.0 * shock))
            y.append((day(i), 30.0 + 0.40 * Double(i) - 2.0 * shock + 0.8 * rng.gaussian()))
        }
        let t = CorrelationEngine.associationTest(x: x, y: y)!
        XCTAssertLessThan(t.r, -0.7)                      // negative: y moves against x
        XCTAssertLessThan(t.p, 0.001)
        XCTAssertLessThan(t.ciHigh, -0.4)                 // whole interval on the negative side
        XCTAssertLessThan(t.ciLow, t.r)
        XCTAssertGreaterThan(t.ciHigh, t.r)
    }

    func testNextDayRelationFoundWithLagOneNotLagZero() {
        // Effort today -> lower recovery TOMORROW; days are otherwise independent.
        var rng = TestRNG(seed: 33)
        let n = 80
        var load: [Double] = []
        for _ in 0..<n { load.append(rng.gaussian()) }
        var x: [(day: String, value: Double)] = []
        var y: [(day: String, value: Double)] = []
        for i in 0..<n {
            x.append((day(i), 40.0 + 10.0 * load[i]))
            let prev = i == 0 ? 0.0 : load[i - 1]
            y.append((day(i), 65.0 - 8.0 * prev + 3.0 * rng.gaussian()))
        }
        let lag1 = CorrelationEngine.associationTest(x: x, y: y, lagDays: 1)!
        XCTAssertLessThan(lag1.r, -0.7)
        XCTAssertLessThan(lag1.p, 0.001)
        XCTAssertEqual(lag1.lagDays, 1)
        XCTAssertEqual(lag1.n, n - 1)                     // last x day has no next-day y

        let lag0 = CorrelationEngine.associationTest(x: x, y: y, lagDays: 0)!
        XCTAssertLessThan(abs(lag0.r), 0.35)
        XCTAssertGreaterThan(lag0.p, 0.01)
    }

    func testAutocorrelatedNoiseShrinksEffectiveN() {
        // Two independent, strongly persistent (AR(1), phi = 0.85) series.
        var rng = TestRNG(seed: 8)
        let n = 120
        let x = ar1(n: n, phi: 0.85, rng: &rng)
        let y = ar1(n: n, phi: 0.85, rng: &rng)
        let t = CorrelationEngine.associationTest(x: x, y: y)!
        XCTAssertEqual(t.n, n)
        XCTAssertLessThan(t.effectiveN, Double(n) * 0.5)
        XCTAssertGreaterThanOrEqual(t.effectiveN, 3.0)

        // The corrected p is never smaller than the naive one (df = n - 2) on the same r.
        let denom = 1.0 - t.r * t.r
        let tStatNaive = t.r * (Double(n - 2) / denom).squareRoot()
        let naiveP = CorrelationEngine.studentTwoSidedP(t: tStatNaive, df: Double(n - 2))
        XCTAssertGreaterThanOrEqual(t.p, naiveP)
        // And the interval is wider than the naive Fisher interval.
        let z = 0.5 * log((1 + t.r) / (1 - t.r))
        let naiveHalf = 1.959963984540054 / Double(n - 3).squareRoot()
        XCTAssertLessThan(t.ciLow, tanh(z - naiveHalf))
        XCTAssertGreaterThan(t.ciHigh, tanh(z + naiveHalf))
    }

    func testIndependentPersistentSeriesRarelyFalselyFlagged() {
        // Monte-Carlo guard on the whole recipe: over many pairs of independent AR(1) series
        // the corrected test should flag only a modest share at p < 0.05, while the naive
        // test (raw r, n - 2 df) flags many.
        var corrected = 0
        var naive = 0
        let trials = 200
        for seed in 0..<trials {
            var rng = TestRNG(seed: UInt64(1_000 + seed))
            let x = ar1(n: 100, phi: 0.8, rng: &rng)
            let y = ar1(n: 100, phi: 0.8, rng: &rng)
            if let t = CorrelationEngine.associationTest(x: x, y: y), t.p < 0.05 { corrected += 1 }
            if let c = CorrelationEngine.pearson(CorrelationEngine.alignByDay(x, y)) {
                let tStat = c.r * (98.0 / (1.0 - c.r * c.r)).squareRoot()
                if CorrelationEngine.studentTwoSidedP(t: tStat, df: 98) < 0.05 { naive += 1 }
            }
        }
        XCTAssertLessThan(Double(corrected) / Double(trials), 0.12)
        XCTAssertGreaterThan(Double(naive) / Double(trials), 0.3)
    }

    func testFewerThanMinDaysReturnsNil() {
        var rng = TestRNG(seed: 2)
        let x = (0..<13).map { (day: day($0), value: rng.gaussian()) }
        let y = (0..<13).map { (day: day($0), value: rng.gaussian()) }
        XCTAssertNil(CorrelationEngine.associationTest(x: x, y: y))                 // 13 < 14
        XCTAssertNotNil(CorrelationEngine.associationTest(x: x, y: y, minDays: 10))
        // 14 pairs is enough, but a lag that drops one pair leaves 13 -> nil again.
        let x14 = (0..<14).map { (day: day($0), value: rng.gaussian()) }
        let y14 = (0..<14).map { (day: day($0), value: rng.gaussian()) }
        XCTAssertNotNil(CorrelationEngine.associationTest(x: x14, y: y14))
        XCTAssertNil(CorrelationEngine.associationTest(x: x14, y: y14, lagDays: 1))
    }

    func testAssociationTestNilOnZeroVarianceAndEmpty() {
        var rng = TestRNG(seed: 4)
        let noisy = (0..<30).map { (day: day($0), value: rng.gaussian()) }
        let flat = (0..<30).map { (day: day($0), value: 7.0) }
        let ramp = (0..<30).map { (day: day($0), value: 2.0 + 0.5 * Double($0)) }   // all trend, no residual
        XCTAssertNil(CorrelationEngine.associationTest(x: noisy, y: flat))
        XCTAssertNil(CorrelationEngine.associationTest(x: flat, y: noisy))
        XCTAssertNil(CorrelationEngine.associationTest(x: noisy, y: ramp))
        XCTAssertNil(CorrelationEngine.associationTest(x: [], y: noisy))
    }

    func testAssociationTestHandlesGapsAndUnsortedInput() {
        // Only every other day present in y, inputs reversed: the pairs are the common days.
        var rng = TestRNG(seed: 6)
        let n = 60
        var x = (0..<n).map { (day: day($0), value: 10.0 + rng.gaussian()) }
        var y = stride(from: 0, to: n, by: 2).map { (day: day($0), value: 20.0 + rng.gaussian()) }
        x.reverse()
        y.reverse()
        let t = CorrelationEngine.associationTest(x: x, y: y)!
        XCTAssertEqual(t.n, 30)
        XCTAssertLessThanOrEqual(t.effectiveN, 30.0)
    }

    func testPerfectDetrendedRelationHasZeroP() {
        // y is an exact multiple of x's fluctuation -> |r| = 1 -> p = 0, interval collapses.
        var rng = TestRNG(seed: 9)
        let x = (0..<40).map { (day: day($0), value: 5.0 + rng.gaussian()) }
        let y = x.map { (day: $0.day, value: -3.0 * $0.value + 1.0) }
        let t = CorrelationEngine.associationTest(x: x, y: y)!
        XCTAssertEqual(t.r, -1.0, accuracy: 1e-9)
        XCTAssertEqual(t.p, 0.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(t.ciHigh, -0.99)
    }

    // MARK: - Test helpers

    private func day(_ offset: Int) -> String {
        CorrelationEngine.shiftDay("2026-01-01", by: offset) ?? "2026-01-01"
    }

    private func ar1(n: Int, phi: Double, rng: inout TestRNG) -> [(day: String, value: Double)] {
        var v = rng.gaussian()
        var out: [(day: String, value: Double)] = []
        for i in 0..<n {
            v = phi * v + (1.0 - phi * phi).squareRoot() * rng.gaussian()
            out.append((day(i), 50.0 + 5.0 * v))
        }
        return out
    }
}

/// Small deterministic generator (SplitMix64) so the statistical tests are reproducible.
private struct TestRNG {
    private var state: UInt64
    /// The seed is scrambled once so neighbouring seeds start far apart in the stream
    /// (SplitMix64 streams that start a few steps apart are just shifted copies).
    init(seed: UInt64) {
        state = seed
        state = next()
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1).
    mutating func uniform() -> Double {
        (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992.0
    }

    /// Standard normal by Box-Muller.
    mutating func gaussian() -> Double {
        let u1 = uniform()
        let u2 = uniform()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }
}
