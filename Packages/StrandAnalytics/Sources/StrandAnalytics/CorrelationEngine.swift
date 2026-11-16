import Foundation

// CorrelationEngine.swift — relationships between two daily series.
//
// Pure, deterministic, DB-free. Computes the Pearson product-moment correlation r,
// a simple ordinary-least-squares regression line (slope/intercept of y on x), and
// an approximate two-sided p-value for r.
//
//   r = Σ(x−x̄)(y−ȳ) / sqrt( Σ(x−x̄)² · Σ(y−ȳ)² )         (Pearson)
//   slope     = Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²                     (OLS, y on x)
//   intercept = ȳ − slope·x̄
//
// The p-value uses the standard t-statistic for a correlation,
//   t = r · sqrt( (n−2) / (1−r²) ),
// converted to a two-sided tail probability via a NORMAL approximation
// (2·(1−Φ(|t|))). This is an approximation — for small n the true Student-t tails
// are heavier, so pApprox slightly understates p — but it is fully deterministic
// and needs no special-function tables. Φ is evaluated with the Abramowitz &
// Stegun 7.1.26 erf rational approximation.
//
// `alignByDay` inner-joins two "yyyy-MM-dd"-keyed series on the day key, returning
// (x, y) pairs sorted by day. `lagged` shifts y forward by `lagDays` relative to x
// (x on day D paired with y on day D+lag) and correlates the result, which lets a
// caller probe directional / delayed effects (e.g. today's strain vs tomorrow's
// recovery).
//
// `associationTest` (bottom of the file) is the honest version for DAILY HEALTH series: it
// detrends both series, corrects the sample size for autocorrelation and returns an exact
// Student-t p-value plus a confidence interval. `pearson` / `lagged` stay as the raw,
// descriptive primitives the other screens build on.

/// The result of correlating two aligned series.
public struct Correlation: Equatable, Sendable {
    /// Pearson correlation coefficient in [-1, 1].
    public let r: Double
    /// Number of paired observations used.
    public let n: Int
    /// Approximate two-sided p-value for H0: r = 0 (normal approx of the t-test).
    public let pApprox: Double
    /// OLS slope of y on x.
    public let slope: Double
    /// OLS intercept of y on x.
    public let intercept: Double

    public init(r: Double, n: Int, pApprox: Double, slope: Double, intercept: Double) {
        self.r = r
        self.n = n
        self.pApprox = pApprox
        self.slope = slope
        self.intercept = intercept
    }
}

public enum CorrelationEngine {

    // MARK: - Pearson + regression

    /// Pearson r plus an OLS regression line and approximate p-value for the pairs.
    /// Returns nil when fewer than 3 pairs, or when either variable has zero
    /// variance (r undefined).
    public static func pearson(_ xy: [(Double, Double)]) -> Correlation? {
        let n = xy.count
        guard n >= 3 else { return nil }
        let nD = Double(n)

        var sumX = 0.0, sumY = 0.0
        for p in xy { sumX += p.0; sumY += p.1 }
        let meanX = sumX / nD
        let meanY = sumY / nD

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in xy {
            let dx = p.0 - meanX
            let dy = p.1 - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }

        // Zero variance in either variable → correlation undefined.
        guard sxx > 0 && syy > 0 else { return nil }

        var r = sxy / (sxx.squareRoot() * syy.squareRoot())
        // Clamp tiny floating-point overshoot so |r| ≤ 1 exactly.
        if r > 1.0 { r = 1.0 }
        if r < -1.0 { r = -1.0 }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let p = pValue(r: r, n: n)

        return Correlation(r: r, n: n, pApprox: p, slope: slope, intercept: intercept)
    }

    // MARK: - Day alignment

    /// Inner-join two "yyyy-MM-dd"-keyed series on the day key, returning the (x, y)
    /// value pairs for days present in BOTH, sorted ascending by day. Later entries
    /// for a duplicated day in either series win (last-write).
    public static func alignByDay(_ a: [(day: String, value: Double)],
                                  _ b: [(day: String, value: Double)]) -> [(Double, Double)] {
        var mapA: [String: Double] = [:]
        for row in a { mapA[row.day] = row.value }
        var mapB: [String: Double] = [:]
        for row in b { mapB[row.day] = row.value }

        let commonDays = mapA.keys.filter { mapB[$0] != nil }.sorted()
        return commonDays.map { (mapA[$0]!, mapB[$0]!) }
    }

    // MARK: - Lagged correlation

    /// Correlate x[day] against y[day + lagDays]. A positive lag asks "does x today
    /// predict y `lagDays` later?"; a negative lag looks backward. Days are matched
    /// on the calendar by offsetting x's day key by `lagDays` and joining to y.
    ///
    /// Returns nil when fewer than 3 lag-matched pairs survive or when `pearson`
    /// rejects them (zero variance).
    public static func lagged(x: [(day: String, value: Double)],
                              y: [(day: String, value: Double)],
                              lagDays: Int) -> Correlation? {
        var mapY: [String: Double] = [:]
        for row in y { mapY[row.day] = row.value }

        var pairs: [(Double, Double)] = []
        // Sort x by day for deterministic ordering of the pair list.
        let sortedX = x.sorted { $0.day < $1.day }
        for row in sortedX {
            guard let shifted = shiftDay(row.day, by: lagDays) else { continue }
            if let yv = mapY[shifted] {
                pairs.append((row.value, yv))
            }
        }
        return pearson(pairs)
    }

    // MARK: - p-value

    /// Two-sided p-value for H0: r = 0 via t = r·sqrt((n−2)/(1−r²)) and a normal
    /// approximation of the t tail. n ≤ 2 → 1.0 (no evidence); |r| = 1 → 0.0.
    static func pValue(r: Double, n: Int) -> Double {
        guard n > 2 else { return 1.0 }
        let oneMinusR2 = 1.0 - r * r
        if oneMinusR2 <= 0 { return 0.0 }  // |r| == 1
        let t = r * (Double(n - 2) / oneMinusR2).squareRoot()
        // Two-sided tail of the standard normal at |t|.
        return 2.0 * (1.0 - normalCDF(abs(t)))
    }

    /// Standard-normal CDF Φ(z) using the A&S 7.1.26 erf approximation.
    static func normalCDF(_ z: Double) -> Double {
        0.5 * (1.0 + erfApprox(z / 2.0.squareRoot()))
    }

    /// erf(x) — Abramowitz & Stegun 7.1.26, |error| ≤ 1.5e-7.
    static func erfApprox(_ x: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let ax = abs(x)
        let t = 1.0 / (1.0 + 0.3275911 * ax)
        let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
                        - 0.284496736) * t + 0.254829592) * t * exp(-ax * ax)
        return sign * y
    }

    // MARK: - Day arithmetic

    /// Shift a "yyyy-MM-dd" day string by `delta` days (can be negative), returning
    /// a normalised "yyyy-MM-dd" string. Uses a fixed UTC calendar so it is
    /// deterministic and timezone-free. Returns nil if the input can't be parsed.
    static func shiftDay(_ day: String, by delta: Int) -> String? {
        if delta == 0 { return day }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }

        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: comps),
              let shifted = cal.date(byAdding: .day, value: delta, to: base) else { return nil }
        let out = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let oy = out.year, let om = out.month, let od = out.day else { return nil }
        return String(format: "%04d-%02d-%02d", oy, om, od)
    }
}

// MARK: - Significance-tested association (detrended, autocorrelation-aware)
//
// Why this exists. Daily health series are NOT independent draws. Consecutive days resemble
// each other (autocorrelation) and most series drift slowly together (fitness, season, a new
// strap, a diet phase). Both effects make a raw Pearson r between two day-by-day series look
// stronger, and look "significant", far more often than it is:
//
//   1. Shared slow trend  → two unrelated drifting series correlate (the classic spurious
//      correlation of Yule, J. Royal Statistical Society, 1926). Fix: remove each series' own
//      linear trend over the calendar day index and correlate the RESIDUALS (the day-to-day
//      fluctuation around the trend).
//   2. Autocorrelation    → n paired days carry fewer than n independent pieces of evidence.
//      Fix: shrink the sample size to an EFFECTIVE n before the t-test, using the lag-1
//      autocorrelations ρx, ρy of the two (residual) series (Bretherton et al., "The effective
//      number of spatial degrees of freedom of a time-varying field", J. Climate 12, 1999):
//
//          n_eff = n · (1 − ρx·ρy) / (1 + ρx·ρy),   clamped to [3, n]
//
//      (A positive ρx·ρy shrinks n; a negative product would grow it, which we never allow.)
//   3. p-value            → exact two-sided Student-t tail with df = n_eff − 2 (not the normal
//      approximation `pApprox` uses; at small df the t tails are materially heavier).
//   4. Interval           → 95 % CI by Fisher's z transform, z = atanh(r), SE = 1/√(n_eff − 3).
//
// The result is an ASSOCIATION in the user's own data, never a causal claim, and it is only
// returned when there are enough overlapping days to say anything (`minDays`, default 14).

/// The outcome of `CorrelationEngine.associationTest`.
public struct CorrelationTest: Equatable, Sendable {
    /// Pearson r of the DETRENDED paired series, in [-1, 1].
    public let r: Double
    /// Number of paired days used.
    public let n: Int
    /// Effective number of independent pairs after the autocorrelation correction, in [3, n].
    public let effectiveN: Double
    /// Exact two-sided p-value for H0: r = 0, Student-t with df = effectiveN − 2.
    public let p: Double
    /// Lower end of the 95 % confidence interval for r (Fisher z on `effectiveN`).
    public let ciLow: Double
    /// Upper end of the 95 % confidence interval for r.
    public let ciHigh: Double
    /// The lag used: x on day D was paired with y on day D + lagDays.
    public let lagDays: Int

    public init(r: Double, n: Int, effectiveN: Double, p: Double,
                ciLow: Double, ciHigh: Double, lagDays: Int) {
        self.r = r
        self.n = n
        self.effectiveN = effectiveN
        self.p = p
        self.ciLow = ciLow
        self.ciHigh = ciHigh
        self.lagDays = lagDays
    }
}

extension CorrelationEngine {

    // MARK: Association test

    /// Detrended, autocorrelation-corrected association between two daily series.
    ///
    /// Both series are detrended (see `detrended`), then x on day D is paired with y on day
    /// D + `lagDays` (the same calendar arithmetic as `lagged`; a positive lag asks "does x
    /// today show up in y `lagDays` later?"). Pearson r is taken over the residual pairs, the
    /// effective sample size comes from the lag-1 autocorrelations of the two paired residual
    /// series, and p / CI follow from it.
    ///
    /// Returns nil when fewer than `minDays` pairs survive, or when either residual series
    /// has no variance (r undefined).
    public static func associationTest(x: [(day: String, value: Double)],
                                       y: [(day: String, value: Double)],
                                       lagDays: Int = 0,
                                       minDays: Int = 14) -> CorrelationTest? {
        let xr = detrendedIndexed(x)
        let yr = detrendedIndexed(y)
        guard !xr.isEmpty, !yr.isEmpty else { return nil }

        var yByDay: [Int: Double] = [:]
        yByDay.reserveCapacity(yr.count)
        for row in yr { yByDay[row.index] = row.value }

        var px: [Double] = []
        var py: [Double] = []
        px.reserveCapacity(xr.count)
        py.reserveCapacity(xr.count)
        for row in xr {
            if let yv = yByDay[row.index + lagDays] {
                px.append(row.value)
                py.append(yv)
            }
        }

        let n = px.count
        guard n >= max(minDays, 3) else { return nil }
        guard let c = pearson(Array(zip(px, py))) else { return nil }

        let rhoX = lag1Autocorrelation(px) ?? 0
        let rhoY = lag1Autocorrelation(py) ?? 0
        let nD = Double(n)
        let product = rhoX * rhoY
        var nEff = nD
        if 1.0 + product > 1e-9 {
            nEff = nD * (1.0 - product) / (1.0 + product)
        }
        nEff = min(max(nEff, 3.0), nD)

        let df = nEff - 2.0
        let r = c.r
        let denom = 1.0 - r * r
        var p = 0.0
        if denom > 0 {
            let t = r * (df / denom).squareRoot()
            p = studentTwoSidedP(t: t, df: df)
        }

        var ciLow = -1.0
        var ciHigh = 1.0
        if nEff > 3.0 {
            let se = 1.0 / (nEff - 3.0).squareRoot()
            let clamped = min(max(r, -0.999999999999), 0.999999999999)
            let z = 0.5 * log((1.0 + clamped) / (1.0 - clamped))   // atanh(r)
            let zCrit = 1.959963984540054                          // Φ⁻¹(0.975)
            ciLow = tanhViaExp(z - zCrit * se)
            ciHigh = tanhViaExp(z + zCrit * se)
        }

        return CorrelationTest(r: r, n: n, effectiveN: nEff, p: p,
                               ciLow: ciLow, ciHigh: ciHigh, lagDays: lagDays)
    }

    // MARK: Detrending

    /// Remove each series' ordinary-least-squares linear trend over the CALENDAR day index
    /// (days counted from the first day key, so a gap of ten days weighs ten days, not one
    /// array slot) and return the residuals, ascending by day. One value per day: repeated
    /// day keys are averaged. Rows whose key does not parse as "yyyy-MM-dd" are dropped.
    public static func detrended(_ series: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        detrendedIndexed(series).map { (day: $0.day, value: $0.value) }
    }

    /// Residuals plus the integer day number, shared by `detrended` and `associationTest`.
    fileprivate static func detrendedIndexed(
        _ series: [(day: String, value: Double)]
    ) -> [(day: String, index: Int, value: Double)] {
        // One mean value per calendar day, ascending.
        var sums: [Int: (day: String, sum: Double, count: Int)] = [:]
        for row in series {
            guard let idx = dayNumber(row.day), row.value.isFinite else { continue }
            let acc = sums[idx] ?? (row.day, 0.0, 0)
            sums[idx] = (acc.day, acc.sum + row.value, acc.count + 1)
        }
        let days = sums.keys.sorted()
        guard let first = days.first else { return [] }

        var ts: [Double] = []
        var vs: [Double] = []
        ts.reserveCapacity(days.count)
        vs.reserveCapacity(days.count)
        for idx in days {
            guard let acc = sums[idx] else { continue }
            ts.append(Double(idx - first))
            vs.append(acc.sum / Double(acc.count))
        }

        let n = ts.count
        let nD = Double(n)
        let meanT = ts.reduce(0, +) / nD
        let meanV = vs.reduce(0, +) / nD
        var stt = 0.0
        var stv = 0.0
        for i in 0..<n {
            let dt = ts[i] - meanT
            stt += dt * dt
            stv += dt * (vs[i] - meanV)
        }
        let slope = stt > 0 ? stv / stt : 0.0

        var res: [Double] = []
        res.reserveCapacity(n)
        var rss = 0.0
        for i in 0..<n {
            let fitted = meanV + slope * (ts[i] - meanT)
            let e = vs[i] - fitted
            res.append(e)
            rss += e * e
        }
        // A series that is (numerically) exactly its own trend leaves only rounding dust,
        // which would otherwise correlate "perfectly" with anything. Treat it as flat.
        let scale = max(1.0, meanV * meanV)
        if rss <= 1e-20 * nD * scale {
            res = Array(repeating: 0.0, count: n)
        }

        var out: [(day: String, index: Int, value: Double)] = []
        out.reserveCapacity(n)
        for (k, idx) in days.enumerated() {
            guard let acc = sums[idx] else { continue }
            out.append((day: acc.day, index: idx, value: res[k]))
        }
        return out
    }

    // MARK: Autocorrelation

    /// Lag-1 sample autocorrelation, ρ₁ = Σ(vᵢ−m)(vᵢ₋₁−m) / Σ(vᵢ−m)². nil for fewer than
    /// 3 values or a constant series.
    public static func lag1Autocorrelation(_ values: [Double]) -> Double? {
        let n = values.count
        guard n >= 3 else { return nil }
        let mean = values.reduce(0, +) / Double(n)
        var num = 0.0
        var den = 0.0
        for i in 0..<n {
            let d = values[i] - mean
            den += d * d
            if i > 0 { num += d * (values[i - 1] - mean) }
        }
        guard den > 0 else { return nil }
        return min(max(num / den, -1.0), 1.0)
    }

    // MARK: Student-t tail

    /// Exact two-sided p-value of Student's t with `df` degrees of freedom (df may be
    /// fractional, as with an effective sample size):
    ///
    ///     p = P(|T| ≥ |t|) = I_x(df/2, 1/2),   x = df / (df + t²)
    ///
    /// where I_x is the regularised incomplete beta function (Numerical Recipes §6.4,
    /// `betai` / `betacf`, evaluated by the modified Lentz continued fraction). Non-positive
    /// df or NaN → 1.0 (no evidence); infinite t → 0.0.
    public static func studentTwoSidedP(t: Double, df: Double) -> Double {
        guard df > 0, !t.isNaN, !df.isNaN else { return 1.0 }
        if t.isInfinite { return 0.0 }
        if t == 0 { return 1.0 }
        let x = df / (df + t * t)
        let p = regularizedIncompleteBeta(x: x, a: df / 2.0, b: 0.5)
        return min(max(p, 0.0), 1.0)
    }

    /// I_x(a, b), the regularised incomplete beta function (Numerical Recipes `betai`).
    static func regularizedIncompleteBeta(x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0.0 }
        if x >= 1 { return 1.0 }
        let logBeta = logGamma(a + b) - logGamma(a) - logGamma(b)
        let bt = exp(logBeta + a * log(x) + b * log(1.0 - x))
        // The continued fraction converges fastest for x < (a+1)/(a+b+2); otherwise use the
        // symmetry I_x(a, b) = 1 − I_{1−x}(b, a).
        if x < (a + 1.0) / (a + b + 2.0) {
            return bt * betaContinuedFraction(x: x, a: a, b: b) / a
        }
        return 1.0 - bt * betaContinuedFraction(x: 1.0 - x, a: b, b: a) / b
    }

    /// Continued fraction for the incomplete beta function (Numerical Recipes `betacf`,
    /// modified Lentz's method).
    private static func betaContinuedFraction(x: Double, a: Double, b: Double) -> Double {
        let maxIterations = 2000
        let eps = 1e-15
        let tiny = 1e-300
        let qab = a + b
        let qap = a + 1.0
        let qam = a - 1.0
        var c = 1.0
        var d = 1.0 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1.0 / d
        var h = d
        for m in 1...maxIterations {
            let mD = Double(m)
            let m2 = 2.0 * mD
            // Even step.
            var aa = mD * (b - mD) * x / ((qam + m2) * (a + m2))
            d = 1.0 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1.0 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1.0 / d
            h *= d * c
            // Odd step.
            aa = -(a + mD) * (qab + mD) * x / ((a + m2) * (qap + m2))
            d = 1.0 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1.0 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1.0 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1.0) < eps { break }
        }
        return h
    }

    /// ln Γ(x) by the Lanczos approximation (g = 7, nine coefficients, ~1e-15 relative error),
    /// with the reflection formula below 0.5. Written out rather than taken from libm because
    /// the C `lgamma` and its Swift overlays differ per platform (tuple vs Double).
    static func logGamma(_ x: Double) -> Double {
        if x < 0.5 {
            // Γ(x)·Γ(1−x) = π / sin(πx)
            return log(Double.pi / abs(sin(Double.pi * x))) - logGamma(1.0 - x)
        }
        let coefficients: [Double] = [
            0.99999999999980993,
            676.5203681218851,
            -1259.1392167224028,
            771.32342877765313,
            -176.61502916214059,
            12.507343278686905,
            -0.13857109526572012,
            9.9843695780195716e-6,
            1.5056327351493116e-7,
        ]
        let g = 7.0
        let xm = x - 1.0
        var a = coefficients[0]
        let t = xm + g + 0.5
        for i in 1..<coefficients.count {
            a += coefficients[i] / (xm + Double(i))
        }
        return 0.5 * log(2.0 * Double.pi) + (xm + 0.5) * log(t) - t + log(a)
    }

    // MARK: Helpers

    /// tanh(z) = (e^{2z} − 1) / (e^{2z} + 1), saturating cleanly for large |z|.
    private static func tanhViaExp(_ z: Double) -> Double {
        let e = exp(2.0 * z)
        if e.isInfinite { return 1.0 }
        return (e - 1.0) / (e + 1.0)
    }

    /// Whole days since 1970-01-01 for a "yyyy-MM-dd" key (Howard Hinnant's days-from-civil
    /// algorithm, proleptic Gregorian). Pure integer arithmetic, so it is timezone-free and
    /// agrees exactly with the UTC calendar arithmetic of `shiftDay`: a gap of k calendar
    /// days is k here too. nil when the key does not parse.
    static func dayNumber(_ day: String) -> Int? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
