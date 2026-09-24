import XCTest
@testable import StrandAnalytics

/// Method-comparison statistics. Every expected value was computed independently with NumPy/SciPy
/// (scipy.stats t, chi2, norm, linregress, pearsonr, spearmanr; Lin's CCC with the DescTools z-transform
/// variance) from the same fixtures.
final class AgreementStatsTests: XCTestCase {

    private typealias A = AgreementStats

    // MARK: - Distributions

    func testQuantilesMatchSciPy() {
        XCTAssertEqual(Distributions.normalQuantile(0.975), 1.959963984540054, accuracy: 1e-9)
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 9), 2.262157162798205, accuracy: 1e-8)
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 4.5), 2.6589123472044034, accuracy: 1e-8)
        XCTAssertEqual(Distributions.tQuantile(0.975, df: 1.3), 7.500529325562029, accuracy: 1e-7)
        XCTAssertEqual(Distributions.tQuantile(0.025, df: 29), -2.045229642132704, accuracy: 1e-8)
        XCTAssertEqual(Distributions.chiSquareQuantile(0.025, df: 9), 2.7003894999803584, accuracy: 1e-8)
        XCTAssertEqual(Distributions.chiSquareQuantile(0.975, df: 9), 19.02276779864163, accuracy: 1e-7)
        XCTAssertEqual(Distributions.chiSquareQuantile(0.025, df: 3.7), 0.39457687534151664, accuracy: 1e-8)
        XCTAssertEqual(Distributions.chiSquareQuantile(0.975, df: 120.5), 152.77469534604853, accuracy: 1e-6)
    }

    // MARK: - Fixtures

    /// 30 consecutive days of HRV: WHOOP (reference) vs NOOP (test), with day-to-day correlated differences.
    private static let ref: [Double] = [62.0, 65.6, 58.7, 51.3, 56.5, 50.1, 62.7, 78.1, 56.1, 54.6, 67.9, 66.3,
                                        63.3, 50.8, 61.6, 70.3, 45.9, 56.5, 39.2, 46.5, 39.9, 59.2, 46.8, 65.3,
                                        63.9, 59.8, 31.8, 55.5, 61.4, 63.4]
    private static let test: [Double] = [57.0, 61.4, 53.6, 46.4, 57.1, 48.1, 61.2, 79.4, 55.2, 53.8, 67.4, 66.0,
                                         59.3, 49.2, 64.5, 66.7, 47.1, 57.2, 38.0, 51.9, 45.1, 57.8, 46.6, 66.4,
                                         63.7, 61.7, 33.2, 57.8, 66.6, 63.7]

    private func pairs(_ ref: [Double], _ test: [Double], start: String = "2026-03-01",
                       skip: Set<Int> = []) -> [A.Pair] {
        let d0 = A.dayNumber(start)!
        return ref.indices.filter { !skip.contains($0) }.map { i in
            A.Pair(day: Self.isoDay(d0 + i), reference: ref[i], test: test[i])
        }
    }

    private static func isoDay(_ n: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(n) * 86_400)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func assertEstimate(_ e: A.Estimate, _ v: Double, _ lo: Double, _ hi: Double,
                                accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.value, v, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(e.lower, lo, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(e.upper, hi, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Full reports

    func testConsecutiveDaysReportMatchesReference() {
        let r = A.analyze(pairs(Self.ref, Self.test))!
        XCTAssertEqual(r.n, 30)
        XCTAssertEqual(r.autocorrelation, 0.3637599195263107, accuracy: 1e-9)
        XCTAssertEqual(r.nEffective, 14.398433940120778, accuracy: 1e-6)
        assertEstimate(r.bias, -0.26333333333333175, -1.9325257059529695, 1.4058590392863057)
        XCTAssertEqual(r.sdDifference, 2.9406769014978944, accuracy: 1e-6)
        assertEstimate(r.lowerLimit, -6.026954150438045, -9.850843864399328, -3.736559162288487)
        assertEstimate(r.upperLimit, 5.500287483771381, 3.209892495621823, 9.324177197732665)
        XCTAssertEqual(r.proportionalBias.intercept, 1.4507095468587385, accuracy: 1e-6)
        assertEstimate(r.proportionalBias.slope, -0.030122894118954982, -0.14364861155328962, 0.08340282331537965)
        XCTAssertFalse(r.proportionalBias.isSignificant)
        assertEstimate(r.heteroscedasticity.slope, -0.014837789381309426, -0.08648811435266543, 0.056812535590046585)
        XCTAssertFalse(r.heteroscedasticity.isSignificant)
        XCTAssertEqual(r.meanAbsoluteError, 2.2300000000000013, accuracy: 1e-9)
        XCTAssertEqual(r.rootMeanSquareError, 2.8489179232356507, accuracy: 1e-9)
        XCTAssertEqual(r.meanAbsolutePercentError!, 4.07964631106928, accuracy: 1e-9)
        XCTAssertEqual(r.within5Percent!, 0.7, accuracy: 1e-12)
        XCTAssertEqual(r.within10Percent!, 0.9333333333333333, accuracy: 1e-12)
        assertEstimate(r.concordance, 0.9571180754294973, 0.9124595561791518, 0.9792414613628537)
        XCTAssertEqual(r.concordanceStrength, .substantial)
        XCTAssertEqual(r.pearson!, 0.9578852589795663, accuracy: 1e-9)
        XCTAssertEqual(r.spearman!, 0.9240013409822707, accuracy: 1e-9)
        // Uniform limits: the same at any level.
        let l = r.limits(atMean: 60)
        XCTAssertEqual(l.bias, r.bias.value, accuracy: 1e-12)
        XCTAssertEqual(l.lower, r.lowerLimit.value, accuracy: 1e-9)
        XCTAssertEqual(l.upper, r.upperLimit.value, accuracy: 1e-9)
    }

    func testGappedDaysUseActualLags() {
        // Days 5–9 and 20 missing: the autocorrelation uses only pairs one day apart and the effective n
        // weights every pair by ρ^(days between them).
        let r = A.analyze(pairs(Self.ref, Self.test, skip: Set([5, 6, 7, 8, 9, 20])))!
        XCTAssertEqual(r.n, 24)
        XCTAssertEqual(r.autocorrelation, 0.3451172149174115, accuracy: 1e-9)
        XCTAssertEqual(r.nEffective, 12.789042349902504, accuracy: 1e-6)
        assertEstimate(r.bias, -0.3833333333333318, -2.2349686087238454, 1.468301942057182)
        assertEstimate(r.lowerLimit, -6.328170885240093, -10.666687777718256, -3.8196711446369274)
        assertEstimate(r.upperLimit, 5.561504218573429, 3.0530044779702634, 9.90002111105159)
        assertEstimate(r.concordance, 0.949505720112299, 0.8875738699021798, 0.9777239742394487)
        XCTAssertEqual(r.concordanceStrength, .moderate)
    }

    func testProportionalBiasAndHeteroscedasticityGiveRegressionLimits() {
        let ref: [Double] = [20.1, 26.6, 28.8, 26.2, 29.4, 31.2, 37.1, 37.8, 42.8, 37.5, 50.3, 47.9, 52.8, 52.9,
                             54.8, 59.9, 63.5, 63.0, 65.7, 70.8, 68.7, 69.3, 77.6, 77.0, 75.8, 81.7, 85.3, 85.7,
                             87.3, 94.5, 99.6, 98.8, 99.8, 105.8, 109.3, 108.8, 113.9, 118.0, 116.8, 117.6]
        let test: [Double] = [21.3, 26.6, 29.4, 24.6, 27.7, 28.8, 31.5, 35.5, 40.5, 33.6, 49.4, 45.6, 49.3, 48.6,
                              52.2, 47.5, 58.6, 58.1, 49.1, 63.5, 58.7, 64.5, 64.3, 66.5, 67.7, 64.2, 77.7, 72.8,
                              78.7, 75.9, 95.5, 90.0, 83.1, 96.6, 107.2, 112.9, 76.2, 111.3, 104.6, 97.8]
        let r = A.analyze(pairs(ref, test, start: "2026-05-01"))!
        XCTAssertEqual(r.nEffective, 36.768787569011266, accuracy: 1e-6)
        assertEstimate(r.bias, -7.5699999999999985, -10.121987252361178, -5.018012747638819)
        XCTAssertTrue(r.proportionalBias.isSignificant, "NOOP reads lower the higher the value")
        assertEstimate(r.proportionalBias.slope, -0.12703106815030082, -0.20724251638169094, -0.046819619918910704)
        XCTAssertTrue(r.heteroscedasticity.isSignificant, "the disagreement grows with the level")
        assertEstimate(r.heteroscedasticity.slope, 0.08570017276646728, 0.03313886880399239, 0.13826147672894218)
        XCTAssertEqual(r.heteroscedasticity.intercept, -1.1887603333131613, accuracy: 1e-6)
        assertEstimate(r.concordance, 0.9278736476764025, 0.8788578246627918, 0.9575055362733967)
        for (a, b, lo, hi) in [(40.0, -4.270368004795935, -9.77096653710189, 1.2302305275100203),
                               (60.0, -6.810989367801951, -16.52195266571055, 2.899973930106648),
                               (100.0, -11.892232093813984, -30.023924922927872, 6.239460735299904)] {
            let l = r.limits(atMean: a)
            XCTAssertEqual(l.bias, b, accuracy: 1e-6)
            XCTAssertEqual(l.lower, lo, accuracy: 1e-6)
            XCTAssertEqual(l.upper, hi, accuracy: 1e-6)
        }
    }

    // MARK: - Edge cases

    func testTooFewDaysGiveNoReport() {
        XCTAssertNil(A.analyze(pairs(Array(Self.ref.prefix(4)), Array(Self.test.prefix(4)))))
        XCTAssertNotNil(A.analyze(pairs(Array(Self.ref.prefix(5)), Array(Self.test.prefix(5)))))
    }

    func testIndependentDaysKeepFullSampleSize() {
        // Every other day only: no pair is one day apart, so no autocorrelation can be estimated → n_eff = n.
        let skip = Set(Array(stride(from: 1, to: 30, by: 2)))
        let r = A.analyze(pairs(Self.ref, Self.test, skip: skip))!
        XCTAssertEqual(r.autocorrelation, 0)
        XCTAssertEqual(r.nEffective, Double(r.n))
    }

    func testIdenticalMethodsAgreePerfectly() {
        let r = A.analyze(pairs(Self.ref, Self.ref))!
        XCTAssertEqual(r.bias.value, 0, accuracy: 1e-12)
        XCTAssertEqual(r.sdDifference, 0, accuracy: 1e-12)
        XCTAssertEqual(r.concordance.value, 1, accuracy: 1e-12)
        XCTAssertEqual(r.concordanceStrength, .almostPerfect)
        XCTAssertEqual(r.meanAbsoluteError, 0)
    }

    func testZeroReferenceSkipsRelativeErrors() {
        var ref = Self.ref
        ref[3] = 0
        let r = A.analyze(pairs(ref, Self.test))!
        XCTAssertNil(r.meanAbsolutePercentError)
        XCTAssertNil(r.within5Percent)
    }

    func testRanksAverageTies() {
        XCTAssertEqual(A.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4])
    }

    func testDayNumberMatchesCalendar() {
        XCTAssertEqual(A.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(A.dayNumber("2000-03-01"), 11_017)
        XCTAssertEqual(A.dayNumber("2026-09-24"), 20_720)
        XCTAssertNil(A.dayNumber("2026-13-01"))
    }
}
