import Foundation
import WhoopProtocol

// HRVAnalyzer.swift — RMSSD + SDNN from RR intervals with artefact correction.
//
// The Task Force (1996) RMSSD and SDNN definitions are reproduced exactly:
//
//   RMSSD = sqrt( mean( (NN[i+1] − NN[i])^2 ) )   over ADJACENT normal beats   (Task Force 1996)
//   SDNN  = sample standard deviation of NN (ddof = 1)                          (Task Force 1996)
//
// Cleaning pipeline (`clean` / `cleanTimed`):
//   1. Hard plausibility split: values outside [hardMinMs, hardMaxMs] = [150, 3000] ms are not heartbeats
//      (dropouts, noise) — they are removed and split the series. With timestamps, a time gap longer than
//      the interval itself also splits it. Successive differences are never taken across a split.
//   2. Artefact correction per contiguous run: Lipponen & Tarvainen (2019), the validated automatic
//      correction Kubios HRV uses (see RRArtefactCorrection.swift) — extra detections are merged, missed
//      beats split, ectopic and misplaced beats re-estimated by cubic-spline interpolation. Correcting
//      instead of deleting keeps RMSSD built from truly adjacent beats; the paper reports RMSSD errors of
//      −0.4% to +4.6% after correction versus +398% (one missed beat) and +430% (one extra beat) without.
//   3. Physiological range: corrected values outside [300, 2000] ms (≈200–30 bpm) are removed and split.
//   4. Require >= minBeats (20) clean intervals before a trustworthy result.
//
// This replaces the earlier Malik 20%-of-local-median deletion (kept as `rejectEctopic` for reference):
// a fixed 20% rule cannot adapt to the person's own variability, so it deletes genuine beats on high-HRV
// nights (large respiratory swings) and, by deleting, forms successive differences between beats that
// were never adjacent. Lipponen–Tarvainen's thresholds adapt to the local distribution (91-beat window).
//
// Nightly window quality (`windowQuality`), all evidence-based:
//   • ≥ 120 s of clean beats — RMSSD from 120 s agrees with a 4–5 min reference at r = 0.986
//     (Munoz et al., PLoS One 2015;10:e0138921, n = 3,387);
//   • ≤ 5% corrected beats — Kubios' default acceptance threshold ("the number of corrected beats should
//     not be too high (preferably <5%)", Kubios HRV Scientific User's Guide 2026);
//   • ≤ 36% of delivered intervals lost — RMSSD stayed within 5% with up to 36% of beat intervals removed
//     (Sheridan et al., Psychiatry Investig 2020;17:960).

public enum HRVAnalyzer {

    /// Minimum plausible RR interval (ms) — 300 ms ≈ 200 bpm.
    public static let rrMinMs: Double = 300
    /// Maximum plausible RR interval (ms) — 2000 ms ≈ 30 bpm.
    public static let rrMaxMs: Double = 2000
    /// Hard bounds applied BEFORE correction. Wider than the physiological range on purpose: a missed
    /// beat at 40 bpm (2 × 1500 ms) must reach the corrector to be split back, and an extra detection's
    /// short half must reach it to be merged.
    public static let hardMinMs: Double = 150
    public static let hardMaxMs: Double = 3000
    /// Minimum valid intervals required for a trustworthy RMSSD/SDNN.
    public static let minBeats: Int = 20
    /// Legacy Malik-style ectopic threshold (20%), used only by `rejectEctopic`.
    public static let ectopicThreshold: Double = 0.20
    /// Half-width (in beats) of the legacy Malik local-median window.
    public static let ectopicWindowRadius: Int = 2

    /// Default ceiling on the fraction of input beats that were lost or needed correction before a SPOT
    /// reading is refused as too noisy (#585). Spot-only: passed by the on-demand callers, never by the
    /// nightly windowed path.
    public static let defaultSpotMaxRejectedFraction: Double = 0.35

    /// Nightly window gate: minimum clean-beat coverage (Munoz 2015).
    public static let minWindowCoverageSeconds: Double = 120
    /// Nightly window gate: maximum share of corrected beats (Kubios acceptance threshold, 5%).
    public static let maxCorrectedFraction: Double = 0.05
    /// Nightly window gate: maximum share of delivered intervals lost as implausible (Sheridan 2020).
    public static let maxDroppedFraction: Double = 0.36

    /// Result of an HRV computation over a window.
    public struct HRVResult: Equatable, Sendable {
        /// RMSSD in milliseconds, or nil when too few valid beats.
        public let rmssd: Double?
        /// SDNN (sample SD, ddof=1) in milliseconds, or nil when too few valid beats.
        public let sdnn: Double?
        /// Mean NN interval (ms) over the cleaned beats, or nil.
        public let meanNN: Double?
        /// pNN50: % of successive |ΔNN| > 50 ms (adjacent beats only), or nil.
        public let pnn50: Double?
        /// Count of RR intervals supplied to the analysis (before cleaning).
        public let nInput: Int
        /// Count of clean NN intervals after correction and range filtering.
        public let nClean: Int
        /// Intervals removed as implausible (never heartbeats).
        public let nDropped: Int
        /// Beats the artefact correction merged, split or re-estimated.
        public let nCorrected: Int

        public init(rmssd: Double?, sdnn: Double?, meanNN: Double?, pnn50: Double?,
                    nInput: Int, nClean: Int, nDropped: Int = 0, nCorrected: Int = 0) {
            self.rmssd = rmssd
            self.sdnn = sdnn
            self.meanNN = meanNN
            self.pnn50 = pnn50
            self.nInput = nInput
            self.nClean = nClean
            self.nDropped = nDropped
            self.nCorrected = nCorrected
        }

        /// An empty/insufficient-data result that preserves the input count.
        static func empty(nInput: Int) -> HRVResult {
            HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                      nInput: nInput, nClean: 0)
        }
    }

    // MARK: - Primitive Task Force statistics (no filtering)

    /// Task Force (1996) RMSSD over already-clean, ADJACENT NN intervals (ms). Returns nil when fewer
    /// than 2 values (no successive differences). No filtering applied.
    public static func rmssdRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(nn.count - 1)).squareRoot()
    }

    /// RMSSD over several contiguous runs: successive differences are taken only WITHIN a run, never
    /// across a gap, then pooled. nil when no run has two beats.
    public static func rmssd(segments: [[Double]]) -> Double? {
        var sumSq = 0.0, count = 0
        for s in segments where s.count >= 2 {
            for i in 1..<s.count { let d = s[i] - s[i - 1]; sumSq += d * d; count += 1 }
        }
        return count > 0 ? (sumSq / Double(count)).squareRoot() : nil
    }

    /// Sample standard deviation (ddof = 1) of NN intervals (ms). Returns nil for
    /// fewer than 2 values. Matches neurokit2 HRV_SDNN. No filtering applied.
    public static func sdnnRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        var ss = 0.0
        for v in nn { let d = v - mean; ss += d * d }
        return (ss / Double(nn.count - 1)).squareRoot()
    }

    // MARK: - Cleaning

    /// Range filter: keep only intervals in [rrMinMs, rrMaxMs], preserving order.
    public static func rangeFilter(_ rr: [Double]) -> [Double] {
        rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    }

    /// Malik-style ectopic rejection (Malik et al. 1989): drop any beat that deviates from its local median
    /// by more than `ectopicThreshold` (20%). No longer part of the HRV cleaning pipeline (see the file
    /// header for why); RhythmScreener still counts its rejections as an irregularity feature.
    public static func rejectEctopic(_ nn: [Double]) -> [Double] {
        guard nn.count > ectopicWindowRadius else { return nn }
        var kept: [Double] = []
        kept.reserveCapacity(nn.count)
        for i in 0..<nn.count {
            let lo = max(0, i - ectopicWindowRadius)
            let hi = min(nn.count - 1, i + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != i { neighbours.append(nn[j]) }
            guard neighbours.count >= 2 else { kept.append(nn[i]); continue }
            let med = median(neighbours)
            if med <= 0 { kept.append(nn[i]); continue }
            let deviation = abs(nn[i] - med) / med
            if deviation <= ectopicThreshold {
                kept.append(nn[i])
            }
        }
        return kept
    }

    /// A cleaned RR series: contiguous corrected runs plus what the pipeline did.
    public struct Cleaned: Equatable, Sendable {
        public let segments: [[Double]]
        public let nInput: Int
        /// Intervals removed as implausible (hard bounds before correction, physiological range after).
        public let nDropped: Int
        public let ectopic: Int
        public let missed: Int
        public let extra: Int
        public let longShort: Int

        public var nn: [Double] { segments.flatMap { $0 } }
        /// Beats the Lipponen–Tarvainen correction touched (Kubios' "corrected beats").
        public var corrected: Int { ectopic + missed + extra + longShort }
    }

    /// One clean beat with its timestamp (unix seconds of the beat that ENDS the interval).
    public struct TimedBeat: Equatable, Sendable {
        public let ts: Int
        public let rrMs: Double
        public init(ts: Int, rrMs: Double) { self.ts = ts; self.rrMs = rrMs }
    }

    /// Timestamped twin of `Cleaned`.
    public struct CleanedTimed: Equatable, Sendable {
        public let segments: [[TimedBeat]]
        public let nInput: Int
        public let nDropped: Int
        public let ectopic: Int
        public let missed: Int
        public let extra: Int
        public let longShort: Int

        public var beats: [TimedBeat] { segments.flatMap { $0 } }
        public var valueSegments: [[Double]] { segments.map { $0.map(\.rrMs) } }
        public var corrected: Int { ectopic + missed + extra + longShort }
    }

    /// Full clean of a raw RR series (ms): hard split → Lipponen–Tarvainen correction → range split.
    public static func clean(_ rr: [Double]) -> Cleaned {
        let t = cleanCore(values: rr, ts: nil)
        return Cleaned(segments: t.segments.map { $0.map(\.rrMs) }, nInput: t.nInput, nDropped: t.nDropped,
                       ectopic: t.ectopic, missed: t.missed, extra: t.extra, longShort: t.longShort)
    }

    /// Full clean of timestamped RR intervals. Also splits on time gaps (a gap longer than the interval
    /// plus 2 s of 1-second timestamp slack means beats are missing from the stream). Sorted by ts first.
    public static func cleanTimed(_ rr: [RRInterval]) -> CleanedTimed {
        let sorted = rr.sorted { $0.ts < $1.ts }
        return cleanCore(values: sorted.map { Double($0.rrMs) }, ts: sorted.map { $0.ts })
    }

    /// Full clean, flattened to one NN series (for callers that need values, not successive differences:
    /// histograms, tachograms). Successive-difference statistics must use `clean(_:).segments` instead.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        clean(rr).nn
    }

    static func cleanCore(values: [Double], ts: [Int]?) -> CleanedTimed {
        let n = values.count
        var dropped = 0
        var runs: [[Int]] = []          // indices into `values`, each a contiguous plausible run
        var current: [Int] = []
        for i in 0..<n {
            let v = values[i]
            guard v >= hardMinMs && v <= hardMaxMs else {
                dropped += 1
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            if let ts, let last = current.last {
                let slack = Int((v / 1000).rounded(.up)) + 2
                if ts[i] - ts[last] > slack { runs.append(current); current = [] }
            }
            current.append(i)
        }
        if !current.isEmpty { runs.append(current) }

        var segments: [[TimedBeat]] = []
        var ectopic = 0, missed = 0, extra = 0, longShort = 0
        for run in runs {
            let res = RRArtefactCorrection.correct(run.map { values[$0] })
            ectopic += res.count(.ectopic); missed += res.count(.missed)
            extra += res.count(.extra); longShort += res.count(.longShort)
            var seg: [TimedBeat] = []
            for iv in res.intervals {
                let srcTs = ts.map { $0[run[iv.sourceIndex]] } ?? 0
                let beatTs = iv.isInsertedHalf ? srcTs - Int((iv.rrMs / 1000).rounded()) : srcTs
                if iv.rrMs >= rrMinMs && iv.rrMs <= rrMaxMs {
                    seg.append(TimedBeat(ts: beatTs, rrMs: iv.rrMs))
                } else {
                    dropped += 1
                    if !seg.isEmpty { segments.append(seg); seg = [] }
                }
            }
            if !seg.isEmpty { segments.append(seg) }
        }
        return CleanedTimed(segments: segments, nInput: n, nDropped: dropped,
                            ectopic: ectopic, missed: missed, extra: extra, longShort: longShort)
    }

    // MARK: - Windowed analysis

    /// Compute HRV (RMSSD/SDNN/meanNN/pNN50) over the RR intervals whose ts falls
    /// in [windowStart, windowEnd] (inclusive). Pass nil bounds to use all rows. Time gaps split the
    /// series, so successive differences never span missing beats.
    public static func analyze(_ rr: [RRInterval],
                               windowStart: Int? = nil,
                               windowEnd: Int? = nil) -> HRVResult {
        let inWindow = rr.filter { sample in
            if let s = windowStart, sample.ts < s { return false }
            if let e = windowEnd, sample.ts > e { return false }
            return true
        }
        let c = cleanTimed(inWindow)
        return result(segments: c.valueSegments, nInput: c.nInput, nDropped: c.nDropped,
                      nCorrected: c.corrected, maxRejectedFraction: nil)
    }

    /// Compute HRV from raw RR-interval values (ms), applying the full cleaning
    /// pipeline. Returns an empty result when fewer than `minBeats` survive.
    ///
    /// - Parameter maxRejectedFraction: SPOT-ONLY honesty gate (#585). When non-nil, the reading is ALSO
    ///   refused (empty result) if the fraction of input beats that were lost or needed correction exceeds
    ///   this value — a short live capture that had to repair or throw away that much is too noisy to
    ///   trust. nil (the default, and what the NIGHTLY path passes) skips the gate.
    public static func analyze(rawRR: [Double], maxRejectedFraction: Double? = nil) -> HRVResult {
        let c = clean(rawRR)
        return result(segments: c.segments, nInput: c.nInput, nDropped: c.nDropped,
                      nCorrected: c.corrected, maxRejectedFraction: maxRejectedFraction)
    }

    static func result(segments: [[Double]], nInput: Int, nDropped: Int, nCorrected: Int,
                       maxRejectedFraction: Double?) -> HRVResult {
        let clean = segments.flatMap { $0 }
        guard clean.count >= minBeats else { return .empty(nInput: nInput) }
        if let maxRejectedFraction, nInput > 0 {
            let rejectedFraction = Double(nDropped + nCorrected) / Double(nInput)
            if rejectedFraction > maxRejectedFraction { return .empty(nInput: nInput) }
        }
        let mean = clean.reduce(0, +) / Double(clean.count)
        var nn50 = 0, diffs = 0
        for s in segments where s.count >= 2 {
            for i in 1..<s.count { diffs += 1; if abs(s[i] - s[i - 1]) > 50.0 { nn50 += 1 } }
        }
        let pnn50 = diffs > 0 ? Double(nn50) / Double(diffs) * 100.0 : nil
        return HRVResult(rmssd: rmssd(segments: segments), sdnn: sdnnRaw(clean), meanNN: mean,
                         pnn50: pnn50, nInput: nInput, nClean: clean.count,
                         nDropped: nDropped, nCorrected: nCorrected)
    }

    /// Quality-gated RMSSD for one nightly window (see the file header for the evidence behind each gate).
    public struct WindowQuality: Equatable, Sendable {
        /// RMSSD (ms) over the window's clean, adjacent beats; nil when no successive pair survived.
        public let rmssd: Double?
        /// Seconds of clean beats (sum of the corrected NN intervals).
        public let coverageSeconds: Double
        public let nInput: Int
        public let nDropped: Int
        public let nCorrected: Int
        /// True when the window passes every gate and its RMSSD can be used.
        public let accepted: Bool
    }

    /// Clean one window's RR intervals and decide whether its RMSSD is trustworthy.
    public static func windowQuality(_ rr: [RRInterval]) -> WindowQuality {
        let c = cleanTimed(rr)
        let r = rmssd(segments: c.valueSegments)
        let coverage = c.beats.reduce(0.0) { $0 + $1.rrMs } / 1000.0
        let n = max(1, c.nInput)
        let accepted = r != nil
            && coverage >= minWindowCoverageSeconds
            && Double(c.corrected) / Double(n) <= maxCorrectedFraction
            && Double(c.nDropped) / Double(n) <= maxDroppedFraction
        return WindowQuality(rmssd: r, coverageSeconds: coverage, nInput: c.nInput,
                             nDropped: c.nDropped, nCorrected: c.corrected, accepted: accepted)
    }

    // MARK: - Rolling / windowed rMSSD timeline (#803)

    /// One windowed rMSSD point: the rMSSD (ms) over the trailing `windowSec` of R-R intervals ending at
    /// `ts` (wall-clock unix seconds). This is an HONEST windowed rMSSD, NOT a single "HRV" number for the
    /// night - the .hrv timeline plots a point per emitted window so an autonomic-tone report (#803) shows
    /// rMSSD MOVING across the session instead of one opaque figure.
    public struct RollingRmssdPoint: Equatable, Sendable {
        /// Wall-clock unix seconds of the last R-R interval folded into this window (the window's right edge).
        public let ts: Int
        /// rMSSD (ms) over the cleaned R-R intervals inside the trailing window.
        public let rmssd: Double
        public init(ts: Int, rmssd: Double) { self.ts = ts; self.rmssd = rmssd }
    }

    /// Pure rolling/windowed rMSSD over an R-R series (#803). For each input interval, the window is the
    /// trailing `windowSec` seconds ending at that interval's `ts`; the window's R-R values are cleaned with
    /// the SAME pipeline the nightly path uses (`cleanTimed`), and a point is emitted only when at least
    /// `minBeatsPerWindow` clean intervals survive (so a sparse / artifact-heavy window emits nothing
    /// rather than a noisy spike). The result is one `(ts, rMSSD)` per qualifying window, in input order.
    ///
    /// - Parameters:
    ///   - rr: the R-R intervals (each carries its own wall-clock `ts` and `rrMs`). Need not be pre-sorted;
    ///     sorted ascending by `ts` internally so the trailing window is well-defined.
    ///   - windowSec: the trailing window width in seconds (e.g. 120 for a 2-minute rMSSD).
    ///   - stepSec: emit at most one point per this many seconds of advance (a thinning stride so a 1 Hz
    ///     stream does not emit a point per beat). 0 (the default) emits a point at every interval.
    ///   - minBeatsPerWindow: minimum clean intervals a window needs to emit a point. Defaults to a small
    ///     floor (8) because a short window legitimately holds far fewer beats than the nightly `minBeats`.
    public static func rollingRmssd(rr: [RRInterval],
                                    windowSec: Int,
                                    stepSec: Int = 0,
                                    minBeatsPerWindow: Int = 8) -> [RollingRmssdPoint] {
        guard windowSec > 0, rr.count >= minBeatsPerWindow else { return [] }
        let sorted = rr.sorted { $0.ts < $1.ts }
        var out: [RollingRmssdPoint] = []
        var lastEmitTs: Int? = nil
        var left = 0   // index of the oldest interval still inside the trailing window
        for right in 0..<sorted.count {
            let edgeTs = sorted[right].ts
            while left < right && edgeTs - sorted[left].ts > windowSec { left += 1 }
            if stepSec > 0, let last = lastEmitTs, edgeTs - last < stepSec { continue }
            let c = cleanTimed(Array(sorted[left...right]))
            guard c.beats.count >= minBeatsPerWindow, let r = rmssd(segments: c.valueSegments) else { continue }
            out.append(RollingRmssdPoint(ts: edgeTs, rmssd: r))
            lastEmitTs = edgeTs
        }
        return out
    }

    // MARK: - Helpers

    /// Median of a non-empty array. (Caller guarantees non-empty.)
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
