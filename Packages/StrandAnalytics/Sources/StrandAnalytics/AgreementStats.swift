import Foundation

// AgreementStats.swift — method-comparison statistics for NOOP-vs-WHOOP benchmarking.
//
// Follows the INTERLIVE consensus for validating consumer wearables (Mühlen et al., Br J Sports Med
// 2021;55:767–779) and the sleep-technology framework of Menghini et al. (Sleep 2021;44:zsaa170): report
// the systematic bias and Bland–Altman limits of agreement, each with its 95% confidence interval, test
// for proportional bias and for heteroscedasticity, and add error and concordance indices. No universal
// "good enough" threshold is imposed. Neither device is ground truth here: agreement is not accuracy.
//
//   Bias, limits of agreement      Bland & Altman, Lancet 1986;327:307–310
//   Proportional bias,             Bland & Altman, Stat Methods Med Res 1999;8:135–160 (§3.2): the
//   heteroscedasticity               differences are regressed on the MEAN of the two methods (regressing
//                                    on one method is misleading when it has error of its own — Bland &
//                                    Altman, Lancet 1995;346:1085–1087); non-uniform limits are
//                                    b0 + b1·A ± 2.46·(c0 + c1·A), with 2.46 = 1.96·√(π/2)
//   CI of the limits (MOVER)       Zou, Stat Methods Med Res 2013;22:630–642
//   Day-to-day autocorrelation     Zięba, Metrol Meas Syst 2010;17:3–16, eqs. 10–12 and 24–25: an AR(1)
//                                    fit to the daily differences gives the effective number of
//                                    observations, the unbiased SD and the SE of the mean; consecutive
//                                    days are not independent, so plain n overstates precision
//   Concordance                    Lin, Biometrics 1989;45:255–268 (variance as corrected in Biometrics
//                                    2000;56:324–325), z-transform CI; strength bands of McBride, NIWA
//                                    Client Report HAM2005-062 (2005)

public enum AgreementStats {

    /// One day measured by both methods. `reference` is the benchmark (WHOOP), `test` is NOOP.
    public struct Pair: Equatable, Sendable {
        public let day: String          // yyyy-MM-dd
        public let reference: Double
        public let test: Double
        public init(day: String, reference: Double, test: Double) {
            self.day = day; self.reference = reference; self.test = test
        }
    }

    /// A point estimate with its 95% confidence interval.
    public struct Estimate: Equatable, Sendable {
        public let value: Double
        public let lower: Double
        public let upper: Double
    }

    /// Ordinary least-squares line y = intercept + slope·x with the slope's 95% CI.
    public struct Line: Equatable, Sendable {
        public let intercept: Double
        public let slope: Estimate
        /// True when the slope's 95% CI excludes zero.
        public var isSignificant: Bool { slope.lower > 0 || slope.upper < 0 }
    }

    /// Strength of agreement for Lin's CCC (McBride 2005).
    public enum ConcordanceStrength: String, Sendable {
        case poor, moderate, substantial, almostPerfect
        public init(_ ccc: Double) {
            // Undefined (one method constant) is not agreement: never let NaN fall through to the top band.
            guard ccc.isFinite else { self = .poor; return }
            switch ccc {
            case ..<0.90: self = .poor
            case ..<0.95: self = .moderate
            case ...0.99: self = .substantial
            default: self = .almostPerfect
            }
        }
    }

    public struct Report: Equatable, Sendable {
        public let n: Int
        /// Lag-1 autocorrelation of the daily differences (AR(1) fit), floored at 0.
        public let autocorrelation: Double
        /// Effective number of independent days (Zięba 2010), ≤ n.
        public let nEffective: Double
        public let meanReference: Double
        public let meanTest: Double
        /// Mean difference (test − reference).
        public let bias: Estimate
        /// SD of the differences, unbiased for autocorrelated days (Zięba eq. 24).
        public let sdDifference: Double
        /// bias − 1.96·SD and bias + 1.96·SD, each with its MOVER 95% CI.
        public let lowerLimit: Estimate
        public let upperLimit: Estimate
        /// Differences regressed on the mean of the two methods (proportional bias).
        public let proportionalBias: Line
        /// Absolute residuals regressed on the mean (heteroscedasticity).
        public let heteroscedasticity: Line
        /// Residual SD around the proportional-bias line (used when that line is significant).
        let residualSD: Double
        public let meanAbsoluteError: Double
        public let rootMeanSquareError: Double
        /// Mean absolute error relative to the reference, %; nil when a reference value is 0.
        public let meanAbsolutePercentError: Double?
        /// Share of days within ±5% and ±10% of the reference.
        public let within5Percent: Double?
        public let within10Percent: Double?
        public let concordance: Estimate
        public let pearson: Double?
        public let spearman: Double?

        public var concordanceStrength: ConcordanceStrength { ConcordanceStrength(concordance.value) }

        /// Bias and limits of agreement at a given mean of the two methods. Uniform limits unless the data
        /// show proportional bias and/or heteroscedasticity, in which case the Bland–Altman 1999 regression
        /// limits are used.
        public func limits(atMean a: Double) -> (bias: Double, lower: Double, upper: Double) {
            let b = proportionalBias.isSignificant
                ? proportionalBias.intercept + proportionalBias.slope.value * a : bias.value
            let half: Double
            if heteroscedasticity.isSignificant {
                half = AgreementStats.zNonUniform
                    * max(0, heteroscedasticity.intercept + heteroscedasticity.slope.value * a)
            } else {
                half = AgreementStats.z * (proportionalBias.isSignificant ? residualSD : sdDifference)
            }
            return (b, b - half, b + half)
        }
    }

    /// 1.96, the two-sided 95% normal quantile Bland & Altman use for the limits.
    static let z = Distributions.normalQuantile(0.975)
    /// 1.96·√(π/2) = 2.46: turns a mean absolute residual into the 95% half-width (Bland & Altman 1999).
    static let zNonUniform = Distributions.normalQuantile(0.975) * (Double.pi / 2).squareRoot()

    /// Full agreement report, or nil with fewer than 5 paired days (too few for any of the intervals).
    public static func analyze(_ pairs: [Pair]) -> Report? {
        let p = pairs.sorted { $0.day < $1.day }
        let n = p.count
        guard n >= 5 else { return nil }
        let x = p.map(\.reference), y = p.map(\.test)
        let d = zip(y, x).map { $0 - $1 }
        let a = zip(y, x).map { ($0 + $1) / 2 }
        let nD = Double(n)
        let dMean = d.reduce(0, +) / nD
        let ss = d.reduce(0) { $0 + ($1 - dMean) * ($1 - dMean) }

        // Autocorrelation between days (AR(1)) → effective n, unbiased SD, SE of the mean (Zięba 2010).
        let days = p.map { dayNumber($0.day) }
        let rho = lag1Autocorrelation(d, days: days)
        let nEff = effectiveN(days: days, rho: rho)
        let dfEff = max(nEff - 1, 1)
        let sd = (ss * nEff / (nD * dfEff)).squareRoot()                   // eq. 24a
        let se = (ss / (nD * dfEff)).squareRoot()                          // eq. 25
        let t = Distributions.tQuantile(0.975, df: dfEff)
        let bias = Estimate(value: dMean, lower: dMean - t * se, upper: dMean + t * se)

        // MOVER limits of agreement (Zou 2013): combine the CI of the mean with the chi-square CI of the SD.
        let sdLow = sd * (dfEff / Distributions.chiSquareQuantile(0.975, df: dfEff)).squareRoot()
        let sdHigh = sd * (dfEff / Distributions.chiSquareQuantile(0.025, df: dfEff)).squareRoot()
        let lo = dMean - z * sd, hi = dMean + z * sd
        let lowerLimit = Estimate(value: lo,
                                  lower: lo - hypot(dMean - bias.lower, z * (sdHigh - sd)),
                                  upper: lo + hypot(bias.upper - dMean, z * (sd - sdLow)))
        let upperLimit = Estimate(value: hi,
                                  lower: hi - hypot(dMean - bias.lower, z * (sd - sdLow)),
                                  upper: hi + hypot(bias.upper - dMean, z * (sdHigh - sd)))

        // Proportional bias and heteroscedasticity against the mean of the methods (Bland & Altman 1999).
        let prop = ols(x: a, y: d)
        let fitted = prop.isSignificant ? a.map { prop.intercept + prop.slope.value * $0 } : Array(repeating: dMean, count: n)
        let residuals = zip(d, fitted).map { $0 - $1 }
        let residualSD = (residuals.reduce(0) { $0 + $1 * $1 } / Double(max(n - 2, 1))).squareRoot()
        let hetero = ols(x: a, y: residuals.map(abs))

        // Error indices.
        let mae = d.reduce(0) { $0 + abs($1) } / nD
        let rmse = (d.reduce(0) { $0 + $1 * $1 } / nD).squareRoot()
        let hasZeroRef = x.contains(0)
        let mape = hasZeroRef ? nil : zip(d, x).reduce(0) { $0 + abs($1.0) / abs($1.1) } / nD * 100
        func within(_ f: Double) -> Double? {
            hasZeroRef ? nil : Double(zip(d, x).filter { abs($0.0) <= f * abs($0.1) }.count) / nD
        }

        return Report(n: n, autocorrelation: rho, nEffective: nEff,
                      meanReference: x.reduce(0, +) / nD, meanTest: y.reduce(0, +) / nD,
                      bias: bias, sdDifference: sd, lowerLimit: lowerLimit, upperLimit: upperLimit,
                      proportionalBias: prop, heteroscedasticity: hetero, residualSD: residualSD,
                      meanAbsoluteError: mae, rootMeanSquareError: rmse, meanAbsolutePercentError: mape,
                      within5Percent: within(0.05), within10Percent: within(0.10),
                      concordance: linCCC(x, y), pearson: pearson(x, y), spearman: spearman(x, y))
    }

    // MARK: - Autocorrelation and effective sample size

    /// Lag-1 autocorrelation of `v` using only pairs of entries exactly one day apart, relative to the
    /// variance of the whole series; 0 when there are fewer than 4 such pairs. Negative values are
    /// floored at 0 so precision is never overstated.
    static func lag1Autocorrelation(_ v: [Double], days: [Int?]) -> Double {
        let n = v.count
        let mean = v.reduce(0, +) / Double(n)
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)
        guard variance > 0 else { return 0 }
        var sum = 0.0, count = 0
        for i in 1..<n {
            guard let a = days[i - 1], let b = days[i], b - a == 1 else { continue }
            sum += (v[i - 1] - mean) * (v[i] - mean)
            count += 1
        }
        guard count >= 4 else { return 0 }
        return min(max(sum / Double(count) / variance, 0), 0.99)
    }

    /// Effective number of observations for AR(1)-correlated days: n² over the sum of every element of the
    /// autocorrelation matrix, ρ^|lag in days| (Zięba 2010 eq. 10; eq. 12 when the days are consecutive).
    static func effectiveN(days: [Int?], rho: Double) -> Double {
        let n = days.count
        guard rho > 0 else { return Double(n) }
        var total = Double(n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                guard let a = days[i], let b = days[j] else { continue }
                total += 2 * pow(rho, Double(abs(b - a)))
            }
        }
        return min(Double(n), Double(n * n) / total)
    }

    /// Days since 1970-01-01 for a yyyy-MM-dd string (proleptic Gregorian), or nil.
    static func dayNumber(_ s: String) -> Int? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y0 = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        // Hinnant's days_from_civil.
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    // MARK: - Regression and correlation

    static func ols(x: [Double], y: [Double]) -> Line {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (a, b) in zip(x, y) { sxx += (a - mx) * (a - mx); sxy += (a - mx) * (b - my) }
        guard sxx > 0, x.count > 2 else {
            return Line(intercept: my, slope: Estimate(value: 0, lower: 0, upper: 0))
        }
        let slope = sxy / sxx
        let intercept = my - slope * mx
        let sse = zip(x, y).reduce(0) { $0 + pow($1.1 - intercept - slope * $1.0, 2) }
        let se = (sse / (n - 2) / sxx).squareRoot()
        let t = Distributions.tQuantile(0.975, df: n - 2)
        return Line(intercept: intercept, slope: Estimate(value: slope, lower: slope - t * se, upper: slope + t * se))
    }

    /// Lin's concordance correlation coefficient with its z-transform 95% CI.
    static func linCCC(_ x: [Double], _ y: [Double]) -> Estimate {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (a, b) in zip(x, y) { sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my); sxy += (a - mx) * (b - my) }
        sxx /= n; syy /= n; sxy /= n
        let denom = sxx + syy + (mx - my) * (mx - my)
        guard denom > 0, sxx > 0, syy > 0 else { return Estimate(value: .nan, lower: .nan, upper: .nan) }
        let pc = 2 * sxy / denom
        let r = sxy / (sxx * syy).squareRoot()
        guard abs(pc) < 1, r != 0, n > 2 else { return Estimate(value: pc, lower: pc, upper: pc) }
        let u = (my - mx) / pow(sxx * syy, 0.25)
        let varP = ((1 - r * r) * pc * pc * (1 - pc * pc) / (r * r)
                    + 2 * pow(pc, 3) * (1 - pc) * u * u / r
                    - 0.5 * pow(pc, 4) * pow(u, 4) / (r * r)) / (n - 2)
        let seZ = max(varP, 0).squareRoot() / (1 - pc * pc)
        let zc = atanh(pc)
        let q = Distributions.normalQuantile(0.975)
        return Estimate(value: pc, lower: tanh(zc - q * seZ), upper: tanh(zc + q * seZ))
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (a, b) in zip(x, y) { sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my); sxy += (a - mx) * (b - my) }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        pearson(ranks(x), ranks(y))
    }

    /// 1-based ranks, ties get their average rank.
    static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }
}

// MARK: - Distributions

/// Quantiles of the normal, Student t and chi-square distributions from their CDFs (regularized
/// incomplete beta and gamma functions, Numerical Recipes 3rd ed. §6.1–6.4), inverted by bisection.
enum Distributions {

    static func normalCDF(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }

    static func normalQuantile(_ p: Double) -> Double {
        invert(p, lower: -40, upper: 40, cdf: normalCDF)
    }

    /// Student t CDF for any real df > 0.
    static func tCDF(_ t: Double, df: Double) -> Double {
        let ib = incompleteBeta(df / (df + t * t), a: df / 2, b: 0.5)
        return t >= 0 ? 1 - 0.5 * ib : 0.5 * ib
    }

    static func tQuantile(_ p: Double, df: Double) -> Double {
        invert(p, lower: -1e4, upper: 1e4) { tCDF($0, df: df) }
    }

    static func chiSquareCDF(_ x: Double, df: Double) -> Double {
        x <= 0 ? 0 : incompleteGammaP(df / 2, x / 2)
    }

    static func chiSquareQuantile(_ p: Double, df: Double) -> Double {
        invert(p, lower: 0, upper: max(1e3, df * 20)) { chiSquareCDF($0, df: df) }
    }

    /// Bisection on a monotone CDF to ~1e-12 relative precision.
    static func invert(_ p: Double, lower: Double, upper: Double, cdf: (Double) -> Double) -> Double {
        var lo = lower, hi = upper
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            if cdf(mid) < p { lo = mid } else { hi = mid }
            if hi - lo <= 1e-12 * max(1, abs(mid)) { break }
        }
        return (lo + hi) / 2
    }

    /// Regularized incomplete beta I_x(a, b), continued fraction by the modified Lentz method.
    static func incompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x))
        if x < (a + 1) / (a + b + 2) { return front * betaContinuedFraction(x, a: a, b: b) / a }
        return 1 - front * betaContinuedFraction(1 - x, a: b, b: a) / b
    }

    private static func betaContinuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        var c = 1.0
        var d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...10_000 {
            let md = Double(m)
            var aa = md * (b - md) * x / ((a + 2 * md - 1) * (a + 2 * md))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d; h *= d * c
            aa = -(a + md) * (a + b + md) * x / ((a + 2 * md) * (a + 2 * md + 1))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-15 { break }
        }
        return h
    }

    /// Regularized lower incomplete gamma P(a, x): series below a + 1, continued fraction above.
    static func incompleteGammaP(_ a: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        let lnPre = a * log(x) - x - lgamma(a)
        if x < a + 1 {
            var sum = 1 / a, term = 1 / a, ap = a
            for _ in 0..<10_000 {
                ap += 1; term *= x / ap; sum += term
                if abs(term) < abs(sum) * 1e-16 { break }
            }
            return sum * exp(lnPre)
        }
        let tiny = 1e-300
        var b = x + 1 - a, c = 1 / tiny, d = 1 / b, h = d
        for i in 1...10_000 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b; if abs(d) < tiny { d = tiny }
            c = b + an / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-15 { break }
        }
        return 1 - exp(lnPre) * h
    }
}
