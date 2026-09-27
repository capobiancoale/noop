import Foundation

// RRArtefactCorrection.swift — automatic RR-interval artefact detection and correction.
//
// Implements Lipponen & Tarvainen (2019), the automatic beat correction Kubios HRV applies by default
// ("The automatic correction is more accurate and the method has been validated" — Kubios HRV Scientific
// User's Guide, 2026). Equation numbers follow the paper:
//
//   J.A. Lipponen, M.P. Tarvainen. A robust algorithm for heart rate variability time series artefact
//   correction using novel beat classification. J Med Eng Technol 2019;43(3):173–181.
//   doi:10.1080/03091902.2019.1640306
//
// Detection, per RR interval j (0-based here; the paper is 1-based):
//   dRRs(j) = RR(j) − RR(j−1), dRRs(0) = 0                                                        (1)
//   Th1(j)  = α·QD(dRRs(j−45 … j+45)), QD = (Q3 − Q1)/2, α = 5.2                                   (2)
//   dRR(j)  = dRRs(j) / Th1(j)                                                                      (3)
//   mRRs(j) = RR(j) − median(RR(j−5 … j+5)), doubled where negative                                (4)(5)
//   Th2(j)  = α·QD(mRRs(j−45 … j+45)),  mRR(j) = mRRs(j) / Th2(j)                                   (6)(7)
//   S12(j)  = max(dRR(j−1), dRR(j+1)) if dRR(j) > 0, min(…) if dRR(j) < 0                          (9)
//   Ectopic: (dRR > 1 ∧ S12 < −c1·dRR − c2) ∨ (dRR < −1 ∧ S12 > −c1·dRR + c2), c1 = 0.13, c2 = 0.17 (10)
//   S22(j)  = min(dRR(j+1), dRR(j+2)) if dRR(j) ≥ 0, max(…) if dRR(j) < 0                          (12)
//   Long/short: (dRR > 1 ∧ S22 < −1) ∨ (dRR < −1 ∧ S22 > 1) ∨ |mRR| > 3, for beat j and also beat
//     j+1 when |dRR(j+1)| < |dRR(j+2)|                                                              (13)
//   Missed = long ∧ |RR(j)/2 − medRR(j)| < Th2(j);  Extra = short ∧ |RR(j) + RR(j+1) − medRR(j)| < Th2(j)
//                                                                                                  (14)(15)
// Only beats with |dRR| > 1 enter the decision flow (Fig. 1; "only dRR segments with these patterns are
// classified as artifacts" — Kubios, Preprocessing of HRV data).
//
// Correction (§2.2): an extra detection is removed (RR(j) + RR(j+1) merged, so RR(j+1) is part of the
// same artefact and never classified on its own); a missed beat is added in the middle (RR(j) split in
// two halves); ectopic and long/short beats have their corrupted RR values replaced by interpolation.
// Kubios uses piecewise cubic spline interpolation (User's Guide 2026); we fit a natural cubic spline
// through up to three clean neighbours on each side of each corrupted run.
//
// Threshold reading. Eqs. 2 and 6 print QD(|x|), but the paper justifies α = 5.2 as the band that
// "covers 99.95% of all beats if [the] series is normally distributed". That holds for the quartile
// deviation of the signed series (5.2 × 0.674σ = 3.5σ → 99.95%), not of its absolute values
// (5.2 × 0.416σ = 2.2σ → 97%). We use the signed series. Validated on PhysioNet Fantasia with the
// paper's own simulation protocol (8 recordings, 61,437 normal intervals, 611 artefacts per class —
// Tools/hrv-validation): the signed reading reproduces Table 1 (normal beats kept 99.84% vs 99.963%;
// misaligned beats detected 61 / 99.0 / 100% at q = 2 / 4 / 8 vs 53.9 / 99.3 / 100%; missed 100% vs
// 100%; extra 99.2% vs 100%) and changes the RMSSD of clean 5-min samples by −2.8% on average. The
// absolute-value reading (NeuroKit2's) keeps only 98.9% of normal beats and detects 89% at q = 2, far
// more than the paper found, and changes clean RMSSD by −6.4% (−4.0% in NeuroKit2 itself, which moves
// beats instead of interpolating). With the same threshold, our labels match NeuroKit2 0.2.13
// `signal_fixpeaks(method="Kubios")` on 99.9996% of 245,259 intervals.
//
// Where the paper is silent we follow NeuroKit2: centred rolling windows truncated at the edges and
// linear-interpolated quartiles. Edges differ on purpose: the paper's dRRs(1) = 0 means a recording's
// first beat is never examined, harmless for one long recording but not for the many short runs and
// windows NOOP cleans. The first and last intervals are therefore compared with virtual intervals equal
// to the median of the six intervals at that end; these give the edge beats a dRR pattern but never
// enter a threshold or a median, so an artefact that opens or closes a run is examined like any other and
// nothing away from the edges changes. A zero threshold (at least half the window's differences
// identical, e.g. a perfectly regular synthetic stretch) leaves the beat unflagged, exactly as NeuroKit2
// does, so regular data can never be turned into artefacts.

public enum RRArtefactCorrection {

    /// Threshold scale α (eqs. 2 and 6): 5.2 quartile deviations cover 99.95% of normally distributed beats.
    public static let alpha: Double = 5.2
    /// Ectopic decision boundary constants (eq. 10).
    public static let c1: Double = 0.13
    public static let c2: Double = 0.17
    /// Half-width of the 91-beat window the thresholds are estimated over (eqs. 2 and 6).
    public static let thresholdHalfWindow = 45
    /// Half-width of the 11-beat median (eq. 4).
    public static let medianHalfWindow = 5
    /// Below this many intervals the quartile thresholds are not meaningful: the run is left as is.
    public static let minIntervals = 8
    /// Clean neighbours used on each side of a corrupted run for the spline fill.
    static let splineNeighbours = 3

    /// The four artefact classes of the paper.
    public enum Artefact: String, Sendable, Equatable, CaseIterable {
        case ectopic, missed, extra, longShort
    }

    /// One corrected interval and where it came from, so callers can carry timestamps through.
    public struct CorrectedInterval: Equatable, Sendable {
        public let rrMs: Double
        /// Index of the input interval whose END beat this interval ends at (for a merge, the second one).
        public let sourceIndex: Int
        /// True for the first half of a split missed beat: it ends half an interval before `sourceIndex`.
        public let isInsertedHalf: Bool
    }

    /// Result of classifying and correcting one contiguous RR run.
    public struct Result: Equatable, Sendable {
        public let intervals: [CorrectedInterval]
        /// Label per INPUT interval; nil = normal beat.
        public let labels: [Artefact?]

        public var nn: [Double] { intervals.map(\.rrMs) }
        public func count(_ kind: Artefact) -> Int { labels.filter { $0 == kind }.count }
        /// Beats the algorithm touched (Kubios' "corrected beats").
        public var corrected: Int { labels.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    }

    // MARK: - Detection

    struct Features {
        let dRR: [Double]
        /// dRR into the virtual successor of the last interval.
        let dRRNext: Double
        let mRR: [Double]
        let medRR: [Double]
        let th2: [Double]
        let s12: [Double]
        let s22: [Double]
    }

    /// Eqs. 1–12 for one run. `head` and `tail` are virtual intervals (the local median) before the first
    /// and after the last interval: they give the edge beats a dRR pattern, but never enter a threshold or a
    /// median, so everything away from the edges is exactly the paper's.
    static func features(_ rr: [Double], head: Double, tail: Double) -> Features {
        let n = rr.count
        var dRRs = [Double](repeating: 0, count: n)
        if n > 1 { for j in 1..<n { dRRs[j] = rr[j] - rr[j - 1] } }          // eq. 1, dRRs(0) = 0
        let th1 = rollingThreshold(dRRs)                                      // eq. 2
        var dRR = normalise(dRRs, th1)                                        // eq. 3
        dRR[0] = normalise([rr[0] - head], [th1[0]])[0]                       // against the virtual predecessor
        let next = normalise([tail - rr[n - 1]], [th1[n - 1]])[0]             // into the virtual successor
        let medRR = rollingMedian(rr, halfWindow: medianHalfWindow)
        var mRRs = (0..<n).map { rr[$0] - medRR[$0] }                         // eq. 4
        for j in 0..<n where mRRs[j] < 0 { mRRs[j] *= 2 }                     // eq. 5
        let th2 = rollingThreshold(mRRs)                                      // eq. 6
        let mRR = normalise(mRRs, th2)                                        // eq. 7

        // dRR past the edges: virtual median intervals differ from each other by 0.
        func at(_ i: Int) -> Double {
            if i < 0 || i > n { return 0 }
            return i == n ? next : dRR[i]
        }
        var s12 = [Double](repeating: 0, count: n)
        var s22 = [Double](repeating: 0, count: n)
        for j in 0..<n {
            let d = dRR[j]
            if d > 0 { s12[j] = max(at(j - 1), at(j + 1)) }                   // eq. 9
            else if d < 0 { s12[j] = min(at(j - 1), at(j + 1)) }
            s22[j] = d >= 0 ? min(at(j + 1), at(j + 2)) : max(at(j + 1), at(j + 2))   // eq. 12
        }
        return Features(dRR: dRR, dRRNext: next, mRR: mRR, medRR: medRR, th2: th2, s12: s12, s22: s22)
    }

    /// Classify every interval of one contiguous RR run (ms). Runs shorter than `minIntervals` come back
    /// all-normal: their quartile thresholds would be meaningless.
    public static func classify(_ rr: [Double]) -> [Artefact?] {
        let n = rr.count
        var labels = [Artefact?](repeating: nil, count: n)
        guard n >= minIntervals else { return labels }
        let head = quantile(rr[0...medianHalfWindow].sorted(), 0.5)
        let tail = quantile(rr[(n - 1 - medianHalfWindow)...].sorted(), 0.5)
        let f = features(rr, head: head, tail: tail)

        func isLong(_ k: Int) -> Bool { (f.dRR[k] > 1 && f.s22[k] < -1) || f.mRR[k] > 3 }
        func isShort(_ k: Int) -> Bool { (f.dRR[k] < -1 && f.s22[k] > 1) || f.mRR[k] < -3 }
        // The interval after an extra detection is merged into it by the correction: it belongs to the
        // same artefact, so it is never classified (or counted) on its own.
        func consumedByExtra(_ k: Int) -> Bool { k > 0 && labels[k - 1] == .extra }
        func classifyLongShort(_ k: Int) {                                    // eqs. 13–15
            guard labels[k] == nil, !consumedByExtra(k) else { return }
            if isLong(k) {
                labels[k] = abs(rr[k] / 2 - f.medRR[k]) < f.th2[k] ? .missed : .longShort
            } else if isShort(k) {
                // An extra detection is merged with the next interval, so it needs a real one.
                labels[k] = k + 1 < n && abs(rr[k] + rr[k + 1] - f.medRR[k]) < f.th2[k] ? .extra : .longShort
            }
        }

        for j in 0..<n where labels[j] == nil && !consumedByExtra(j) {
            let d = f.dRR[j], s12 = f.s12[j]
            // Entry gate of the decision flow (Fig. 1): only a beat whose |dRR| exceeds its threshold is
            // examined ("only dRR segments with these patterns are classified as artifacts", Kubios).
            guard abs(d) > 1 else { continue }
            if (d > 1 && s12 < -c1 * d - c2) || (d < -1 && s12 > -c1 * d + c2) {   // eq. 10
                labels[j] = .ectopic
                continue
            }
            classifyLongShort(j)
            if j + 1 < n, abs(f.dRR[j + 1]) < abs(j + 2 < n ? f.dRR[j + 2] : f.dRRNext) { classifyLongShort(j + 1) }
        }
        return labels
    }

    // MARK: - Correction

    /// Classify and correct one contiguous RR run (ms). Merges extra detections, splits missed beats and
    /// replaces ectopic / long-short values by a natural cubic spline through the clean neighbours.
    public static func correct(_ rr: [Double]) -> Result {
        let labels = classify(rr)
        let n = rr.count

        // RR values to re-estimate: a long/short beat's own interval, and BOTH intervals around an ectopic
        // beat (the NPN/PNP centre and the interval before it — the premature or late beat sits between them).
        var corrupt = [Bool](repeating: false, count: n)
        for k in 0..<n {
            switch labels[k] {
            case .longShort?: corrupt[k] = true
            case .ectopic?: corrupt[k] = true; if k > 0 { corrupt[k - 1] = true }
            default: break
            }
        }

        // Exact corrections first (§2.2): merge extra detections, split missed beats.
        var out: [CorrectedInterval] = []
        var outCorrupt: [Bool] = []
        out.reserveCapacity(n + labels.filter { $0 == .missed }.count)
        var k = 0
        while k < n {
            if labels[k] == .extra, k + 1 < n {
                out.append(CorrectedInterval(rrMs: rr[k] + rr[k + 1], sourceIndex: k + 1, isInsertedHalf: false))
                outCorrupt.append(false)
                k += 2
            } else if labels[k] == .missed {
                out.append(CorrectedInterval(rrMs: rr[k] / 2, sourceIndex: k, isInsertedHalf: true))
                out.append(CorrectedInterval(rrMs: rr[k] / 2, sourceIndex: k, isInsertedHalf: false))
                outCorrupt.append(false); outCorrupt.append(false)
                k += 1
            } else {
                out.append(CorrectedInterval(rrMs: rr[k], sourceIndex: k, isInsertedHalf: false))
                outCorrupt.append(corrupt[k])
                k += 1
            }
        }

        let filled = fillCorrupted(out.map(\.rrMs), corrupt: outCorrupt)
        let intervals = zip(out, filled).map {
            CorrectedInterval(rrMs: $1, sourceIndex: $0.sourceIndex, isInsertedHalf: $0.isInsertedHalf)
        }
        return Result(intervals: intervals, labels: labels)
    }

    /// Replace every run of corrupted values by a natural cubic spline through up to `splineNeighbours`
    /// clean values on each side (index as abscissa). One-sided runs (at an edge) take the nearest clean
    /// value; a run with no clean value at all is left unchanged.
    static func fillCorrupted(_ values: [Double], corrupt: [Bool]) -> [Double] {
        var out = values
        let n = values.count
        var i = 0
        while i < n {
            guard corrupt[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && corrupt[j + 1] { j += 1 }

            var left: [(Double, Double)] = []
            var l = i - 1
            while l >= 0 && left.count < splineNeighbours {
                if !corrupt[l] { left.append((Double(l), values[l])) }
                l -= 1
            }
            var right: [(Double, Double)] = []
            var r = j + 1
            while r < n && right.count < splineNeighbours {
                if !corrupt[r] { right.append((Double(r), values[r])) }
                r += 1
            }

            if !left.isEmpty && !right.isEmpty {
                let pts = left.reversed() + right
                let spline = NaturalCubicSpline(x: pts.map(\.0), y: pts.map(\.1))
                for idx in i...j { out[idx] = spline.value(at: Double(idx)) }
            } else if let only = left.first ?? right.first {
                for idx in i...j { out[idx] = only.1 }
            }
            i = j + 1
        }
        return out
    }

    // MARK: - Rolling statistics

    /// Eqs. 2/6: α · quartile deviation of the signed series over the centred 91-beat window (truncated at
    /// the edges). See the header for why the signed series, not its absolute values.
    static func rollingThreshold(_ x: [Double]) -> [Double] {
        let n = x.count
        return (0..<n).map { j in
            let lo = max(0, j - thresholdHalfWindow), hi = min(n - 1, j + thresholdHalfWindow)
            let w = x[lo...hi].sorted()
            return alpha * (quantile(w, 0.75) - quantile(w, 0.25)) / 2
        }
    }

    /// Centred rolling median (truncated at the edges).
    static func rollingMedian(_ x: [Double], halfWindow: Int) -> [Double] {
        let n = x.count
        return (0..<n).map { j in
            let lo = max(0, j - halfWindow), hi = min(n - 1, j + halfWindow)
            return quantile(x[lo...hi].sorted(), 0.5)
        }
    }

    /// Linear-interpolated quantile of an ascending array (NumPy / pandas "linear").
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }
        guard n > 1 else { return sorted[0] }
        let pos = p * Double(n - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, n - 1)
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// Divide by a threshold; a zero threshold yields 0 (never an artefact — see header).
    static func normalise(_ x: [Double], _ th: [Double]) -> [Double] {
        zip(x, th).map { v, t in t > 0 ? v / t : 0 }
    }
}

// MARK: - Natural cubic spline

/// Natural cubic spline through (x, y), x strictly increasing. Used to fill corrected RR values.
struct NaturalCubicSpline {
    private let x: [Double]
    private let y: [Double]
    private let m: [Double]   // second derivatives at the knots

    init(x: [Double], y: [Double]) {
        self.x = x
        self.y = y
        let n = x.count
        guard n >= 3 else { m = [Double](repeating: 0, count: n); return }
        // Tridiagonal system for the interior second derivatives; natural ends: m0 = m(n−1) = 0.
        var a = [Double](repeating: 0, count: n)
        var b = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let h0 = x[i] - x[i - 1], h1 = x[i + 1] - x[i]
            a[i] = h0
            b[i] = 2 * (h0 + h1)
            c[i] = h1
            d[i] = 6 * ((y[i + 1] - y[i]) / h1 - (y[i] - y[i - 1]) / h0)
        }
        // Thomas algorithm over rows 1…n−2.
        var cp = [Double](repeating: 0, count: n)
        var dp = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let denom = b[i] - a[i] * cp[i - 1]
            cp[i] = c[i] / denom
            dp[i] = (d[i] - a[i] * dp[i - 1]) / denom
        }
        var mm = [Double](repeating: 0, count: n)
        var i = n - 2
        while i >= 1 {
            mm[i] = dp[i] - cp[i] * mm[i + 1]
            i -= 1
        }
        m = mm
    }

    func value(at t: Double) -> Double {
        let n = x.count
        guard n >= 2 else { return y.first ?? 0 }
        var k = 0
        while k < n - 2 && t > x[k + 1] { k += 1 }
        let h = x[k + 1] - x[k]
        let A = (x[k + 1] - t) / h, B = (t - x[k]) / h
        return A * y[k] + B * y[k + 1]
            + ((A * A * A - A) * m[k] + (B * B * B - B) * m[k + 1]) * h * h / 6
    }
}
