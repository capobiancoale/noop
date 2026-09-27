import Foundation
import WhoopProtocol

// StrainScorer.swift — cardiovascular load on a 0–100 logarithmic strain ("Effort") scale.
//
// Ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation of
// published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
// proprietary algorithm; not medical advice).
//
// Scale note: the metric was historically 0–21 (WHOOP's Strain axis); the
// "Charge / Effort / Rest" redesign rescales the OUTPUT to 0–100 by raising
// `maxStrain` 21.0 → 100.0 only. The denominator D = 7201 is unchanged, so the log
// curve and its saturation point (TRIMP 7200 ≈ max) are preserved — a max Effort day
// stays as rare as a 21.0 day used to be. Internal metric key stays `strain`.
//
// Pipeline:
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
//   2. Per-sample intensity as %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
//   3. TRIMP accumulated over the window:
//        a. Edwards 5-zone summation (default): sample contributes its zone weight
//           (1..5 at 50/60/70/80/90 %HRR cut-offs) × duration.
//        b. Banister exponential: sample contributes duration × x × 0.64 × e^(b·x).
//   4. Logarithmic compression onto [0, 100]:
//        strain = 100 × ln(TRIMP + 1) / ln(D),  D = STRAIN_DENOMINATOR.
//
// References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
// (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 − 0.7×age).

public enum StrainScorer {

    // MARK: - Constants (strain.py)

    /// Minimum HR readings before computing strain on a DENSE stream (≈10 min at 1 Hz).
    public static let minReadings: Int = 600
    /// Sparse-stream acceptance (#482/#480): a low-cadence strap — the WHOOP 5/MG sends live
    /// standard HR only ~every 30 s — would need ~5 h of continuous wear to reach `minReadings`,
    /// so Effort sat un-scored (nil → the gauge showed a stale prior-day value) for most of the day.
    /// Also accept once the HR series SPANS at least `minSpanSeconds` of wall-clock with a small
    /// sample floor. This never fabricates load: TRIMP still integrates honestly over whatever HR is
    /// there, so a genuine low-HR day scores 0 either way — it just lets the live gauge reflect TODAY
    /// instead of yesterday. A dense 1 Hz stream is unaffected (it clears `minReadings` first).
    public static let minSparseReadings: Int = 20
    /// Wall-clock coverage (seconds) that qualifies a sparse stream. 600 s = 10 min, matching the
    /// dense gate's ≈10 min of 600 × 1 Hz samples, so both cadences trust the number at the same age.
    public static let minSpanSeconds: Int = 600
    /// Top of the strain ("Effort") scale. Rescaled 21.0 → 100.0 for the
    /// Charge/Effort/Rest redesign; only the output scale changes, the curve does not.
    public static let maxStrain: Double = 100.0

    /// Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
    /// (top zone weight 5 sustained 24 h = 7200) maps to exactly maxStrain:
    /// D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1.
    public static let strainDenominator: Double = 7201.0
    static var lnStrainDenominator: Double { log(strainDenominator) }

    /// Fallback per-sample duration (minutes) — 1 s at 1 Hz.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Minimum HR samples before the observed high-percentile HRmax is trusted.
    public static let hrmaxMinSamples: Int = 600
    /// Upper percentile for the observed-HRmax estimate.
    public static let hrmaxPercentile: Double = 99.5

    /// Banister coefficients.
    public static let banisterScale: Double = 0.64
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    /// TRIMP accumulation method.
    public enum Method: Sendable, Hashable { case edwards, banister }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent).
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Classic 220 − age. Last-resort fallback only.
    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

    /// Linear-interpolated percentile of an already-sorted sequence (numpy-style).
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /// Estimate a personalized HRmax from a trailing HR series.
    /// Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let n = hrHistory.count
        let tanaka = age.map { tanakaHRmax(age: $0) }

        if n >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    // MARK: - Karvonen %HRR and Edwards zone weight

    /// Karvonen %HRR, clamped [0, 100].
    static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        if pct < 0 { return 0 }
        if pct > 100 { return 100 }
        return pct
    }

    /// Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
    /// the clamped path at both ends).
    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - TRIMP accumulation

    /// Infer per-sample duration (minutes) from the first two timestamps. Falls
    /// back to 1 s when fewer than two samples or coincident timestamps.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let deltaS = abs(Double(hr[1].ts - hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                             sampleDurationMin: Double) -> Double {
        var weighted = 0
        for s in hr { weighted += zoneWeight(Double(s.bpm), restingHR: restingHR, hrReserve: hrReserve) }
        return Double(weighted) * sampleDurationMin
    }

    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                              sampleDurationMin: Double, b: Double) -> Double {
        var acc = 0.0
        for s in hr {
            let x = pctHRR(Double(s.bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 { acc += sampleDurationMin * x * banisterScale * exp(b * x) }
        }
        return acc
    }

    // MARK: - Logarithmic map

    /// Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
    /// TRIMP ≤ 0 → 0.
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        if trimp <= 0 { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        return (value * 100).rounded() / 100
    }

    // MARK: - Denominator calibration

    /// Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
    /// least-squares line: ln(D) = maxStrain × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
    /// (reference_strain pairs must be on the same 0–maxStrain axis as the output.)
    /// Throws when fewer than 2 usable pairs (TRIMP>0, strain>0) or degenerate.
    public static func fitStrainDenominator(_ pairs: [(trimp: Double, strain: Double)]) throws -> Double {
        let usable = pairs.filter { $0.trimp > 0 && $0.strain > 0 }
        guard usable.count >= 2 else { throw StrainError.tooFewPairs }
        var sumXX = 0.0, sumXY = 0.0
        for (trimp, strain) in usable {
            let x = log(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        guard sumXY > 0 && sumXX > 0 else { throw StrainError.degenerate }
        return exp(maxStrain * sumXX / sumXY)
    }

    public enum StrainError: Error, Equatable, Sendable {
        case tooFewPairs
        case degenerate
    }

    // MARK: - Public API

    /// Cardiovascular strain / "Effort" (0–100) from an HR series. APPROXIMATE.
    ///
    /// Returns nil when there isn't yet enough data to trust the number — fewer than
    /// `minReadings` samples AND less than `minSpanSeconds` of HR coverage (the sparse-strap
    /// path, #482) — or when maxHR ≤ restingHR (invalid HRR).
    ///
    /// - Parameters:
    ///   - hr: time-ordered `[HRSample]`.
    ///   - maxHR: HRmax (bpm). Defaults to 220 − defaultAge when nil.
    ///   - restingHR: resting HR (bpm) for the HRR denominator (default 60).
    ///   - method: `.edwards` (default) or `.banister`.
    ///   - sex: "male"/"female" — selects the Banister coefficient (ignored by Edwards).
    ///   - denominator: log-map D (default STRAIN_DENOMINATOR).
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              method: Method = .edwards,
                              sex: String = "male",
                              denominator: Double = strainDenominator) -> Double? {
        // v7.0.2 perf (#707): TRIMP integrates over the day's HR stream; called once per day in the post-sync
        // scoring loop AND from the Today view (which re-reads on each live-HR tick). Memoize on the HR
        // fingerprint + every scalar that steers the score, so an identical re-request is a lookup. The
        // result is a single `Double?`; the HR array is not retained.
        let key = StrainKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            maxHR: maxHR, restingHR: restingHR, method: method,
            sexF: sex.lowercased().hasPrefix("f"), denom: denominator)
        return strainCache.value(key) {
            strainUncached(hr, maxHR: maxHR, restingHR: restingHR, method: method, sex: sex, denominator: denominator)
        }
    }

    /// Key folds `sex` to the single bit the recipe reads (`hasPrefix("f")`) so "female"/"f"/"F" all hit.
    private struct StrainKey: Hashable {
        let hr: StreamFingerprint
        let maxHR: Double?; let restingHR: Double; let method: Method
        let sexF: Bool; let denom: Double
    }
    private static let strainCache = AnalyticsMemoCache<StrainKey, Double?>(capacity: 48)

    private static func strainUncached(_ hr: [HRSample], maxHR: Double?, restingHR: Double,
                                       method: Method, sex: String, denominator: Double) -> Double? {
        trimp(hr, maxHR: maxHR, restingHR: restingHR, method: method, sex: sex)
            .map { trimpToStrain($0, denominator: denominator) }
    }

    /// The heart-rate TRIMP behind `strain`, or nil under the same data gates (too little HR, or
    /// maxHR ≤ restingHR).
    public static func trimp(_ hr: [HRSample], maxHR: Double?, restingHR: Double = defaultRestingHR,
                             method: Method = .edwards, sex: String = "male") -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        // Enough data to trust the score: a dense stream (≥ minReadings) OR a sparse-but-sustained
        // one spanning ≥ minSpanSeconds with a sample floor (#482 — the 5/MG's ~30 s HR cadence).
        let enoughData: Bool
        if hr.count >= minReadings {
            enoughData = true
        } else if hr.count >= minSparseReadings {
            let tss = hr.map { $0.ts }
            enoughData = ((tss.max() ?? 0) - (tss.min() ?? 0)) >= minSpanSeconds
        } else {
            enoughData = false
        }
        if !enoughData || effMax <= restingHR { return nil }

        let sampleDur = sampleDurationMinutes(hr)
        let hrReserve = effMax - restingHR

        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            return banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                 sampleDurationMin: sampleDur, b: b)
        case .edwards:
            return edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                sampleDurationMin: sampleDur)
        }
    }

    // MARK: - Logged sessions (session-RPE)
    //
    // Heart rate under-reads resistance and mixed-modal training: short maximal efforts, heavy sets and
    // rest between them load the muscles far more than the pulse shows, and wrist PPG reads low during
    // lifting. The validated way to quantify such a session is its session-RPE load, the Borg CR-10
    // rating times the duration (Foster et al., J Strength Cond Res 2001;15:109–115; reliable in resistance
    // training, Day et al., J Strength Cond Res 2004;18:353–358; review: Haddad et al., Front Neurosci
    // 2017;11:612). In high-intensity functional training (CrossFit-style WODs) session-RPE tracks the
    // Edwards TRIMP closely (r = 0.83–0.87) and the two scale as TRIMP ≈ 0.52 × session-RPE (Tibana et al.,
    // Sports 2018;6:68: Fran 19.8 / (8.7 × 4.06 min) = 0.56, Fight Gone Bad 77.7 / (9.6 × 17 min) = 0.48).
    //
    // A logged session therefore adds the part of 0.52 × its session-RPE load that the heart rate recorded
    // for it does not already show. The comparison is made on the classic Edwards scale (zones at 50–90% of
    // HRmax) that ratio was measured on. It is never negative, so a session the heart rate fully captured
    // (a typical metcon) adds nothing and nothing is counted twice.

    /// A logged training session (e.g. a WOD) with its perceived exertion.
    public struct LoggedSession: Equatable, Sendable {
        /// Session rating on Foster's modified Borg CR-10 scale (0–10).
        public let rpe: Double
        /// Duration of the rated effort, minutes.
        public let durationMin: Double
        /// When it was logged (unix seconds). It may mark the start or the end of the session.
        public let ts: Int
        /// False when only the date is known (imports anchor such entries to local noon).
        public let timeKnown: Bool
        public init(rpe: Double, durationMin: Double, ts: Int, timeKnown: Bool) {
            self.rpe = rpe; self.durationMin = durationMin; self.ts = ts; self.timeKnown = timeKnown
        }
        /// Foster's session-RPE load (arbitrary units).
        public var load: Double { rpe * durationMin }
    }

    /// Edwards TRIMP per session-RPE unit in functional-fitness sessions (Tibana et al. 2018).
    public static let trimpPerSessionRPE: Double = 0.52

    /// How far from its logged time a detected workout can sit and still be the logged session (seconds).
    static let sessionMatchSlackS = 3_600

    /// The heart-rate window that recorded each logged session: the detected workout (`bouts`) that best
    /// overlaps it — within an hour either side when the time is known, anywhere in the day otherwise —
    /// else the span the session could occupy whether its time marks the start or the end.
    public static func sessionWindows(_ sessions: [LoggedSession], bouts: [(start: Int, end: Int)],
                                      dayStart: Int, dayEnd: Int) -> [(expected: Double, start: Int, end: Int)] {
        var used = Set<Int>()
        return sessions.compactMap { s in
            guard s.rpe > 0, s.durationMin > 0 else { return nil }
            let expected = trimpPerSessionRPE * s.load
            let dur = Int((s.durationMin * 60).rounded())
            let core = s.timeKnown ? (lo: s.ts - dur, hi: s.ts + dur) : (lo: dayStart, hi: dayEnd)
            let search = s.timeKnown ? (lo: core.lo - sessionMatchSlackS, hi: core.hi + sessionMatchSlackS) : core
            func overlap(_ b: (start: Int, end: Int)) -> Int { max(0, min(b.end, search.hi) - max(b.start, search.lo)) }
            let candidates = bouts.indices.filter { !used.contains($0) && overlap(bouts[$0]) > 0 }
            if let best = candidates.max(by: { overlap(bouts[$0]) < overlap(bouts[$1]) }) {
                used.insert(best)
                return (expected, bouts[best].start, bouts[best].end)
            }
            return s.timeKnown ? (expected, max(dayStart, core.lo), min(dayEnd, core.hi)) : (expected, 0, 0)
        }
    }

    /// Classic Edwards (1993) TRIMP: minutes at 50–60, 60–70, 70–80, 80–90 and 90–100% of HRmax weighted 1–5.
    static func classicEdwardsTRIMP(_ hr: [HRSample], maxHR: Double, sampleDurationMin: Double) -> Double {
        guard maxHR > 0 else { return 0 }
        var weighted = 0
        for s in hr {
            let pct = Double(s.bpm) / maxHR * 100
            if pct >= 90 { weighted += 5 } else if pct >= 80 { weighted += 4 } else if pct >= 70 { weighted += 3 }
            else if pct >= 60 { weighted += 2 } else if pct >= 50 { weighted += 1 }
        }
        return Double(weighted) * sampleDurationMin
    }

    /// TRIMP the logged sessions add on top of the heart-rate TRIMP: for each window (sessions sharing one
    /// are pooled), the expected TRIMP minus the classic Edwards TRIMP the heart rate recorded there, floored
    /// at zero. A window with no heart rate at all (strap off during the session) contributes in full.
    public static func sessionExcessTRIMP(_ windows: [(expected: Double, start: Int, end: Int)],
                                          hr: [HRSample], maxHR: Double) -> Double {
        var pooled: [(start: Int, end: Int, expected: Double)] = []
        for w in windows.sorted(by: { $0.start < $1.start }) {
            if let last = pooled.last, w.end > w.start, last.end > last.start, w.start < last.end {
                pooled[pooled.count - 1] = (last.start, max(last.end, w.end), last.expected + w.expected)
            } else {
                pooled.append((w.start, w.end, w.expected))
            }
        }
        let sampleDur = sampleDurationMinutes(hr)
        return pooled.reduce(0) { acc, w in
            let inWindow = w.end > w.start ? hr.filter { $0.ts >= w.start && $0.ts < w.end } : []
            return acc + max(0, w.expected - classicEdwardsTRIMP(inWindow, maxHR: maxHR, sampleDurationMin: sampleDur))
        }
    }

    /// Day Effort with logged sessions folded in: the heart-rate TRIMP plus `sessionExcessTRIMP`, through
    /// the same logarithmic map. nil exactly when the heart-rate `strain` is nil — a log alone never makes
    /// an Effort. With no sessions this is `strain(_:maxHR:restingHR:sex:)`.
    public static func strain(_ hr: [HRSample], maxHR: Double?, restingHR: Double, sex: String,
                              sessions: [LoggedSession], bouts: [(start: Int, end: Int)],
                              dayStart: Int, dayEnd: Int) -> Double? {
        guard sessions.contains(where: { $0.rpe > 0 && $0.durationMin > 0 }) else {
            return strain(hr, maxHR: maxHR, restingHR: restingHR, sex: sex)
        }
        guard let base = trimp(hr, maxHR: maxHR, restingHR: restingHR, sex: sex) else { return nil }
        let windows = sessionWindows(sessions, bouts: bouts, dayStart: dayStart, dayEnd: dayEnd)
        let extra = sessionExcessTRIMP(windows, hr: hr, maxHR: maxHR ?? Double(defaultMaxHR()))
        return trimpToStrain(base + extra)
    }
}
