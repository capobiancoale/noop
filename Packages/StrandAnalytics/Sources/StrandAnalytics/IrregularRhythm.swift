import Foundation
import WhoopProtocol

// IrregularRhythm.swift — a screen for an irregularly irregular rhythm (a pattern like atrial fibrillation)
// in the strap's beat-to-beat (R-R) intervals during sleep.
//
// WHAT THIS IS, AND WHAT IT IS NOT. Smartwatch studies showed that a wrist optical sensor can flag a rhythm
// that looks like atrial fibrillation (AF) when the pulse-to-pulse intervals are persistently disorganised:
// the Apple Heart Study (Perez et al., N Engl J Med 2019;381:1909-1917: 84 % of notifications concordant with
// AF on a simultaneous ECG patch, positive predictive value 0.84, 95 % CI 0.76-0.92), the Huawei Heart Study
// (Guo et al., J Am Coll Cardiol 2019;74:2365-2375: PPV 91.6 % for "suspected AF" confirmed by clinical
// evaluation) and the Fitbit Heart Study (Lubitz et al., Circulation 2022;146:1415-1424: overlapping 5-minute
// tachograms, a notification only after 11 consecutive irregular ones, PPV 98.2 %, 95 % CI 95.5-99.5). Accuracy
// still differs by device and inconclusive tracings are common (Mannhart et al., JACC Clin Electrophysiol
// 2023;9:232-242, BASEL Wearable Study: sensitivity 58-85 %, specificity 69-79 %, 17-26 % inconclusive).
// This file does the same kind of screen on the R-R intervals NOOP already stores. It is a SCREEN: it can say
// "the beats were irregular in a way AF can be", never "you have AF". Only an ECG can confirm AF. NOOP is not
// a medical device, and nothing here is a diagnosis.
//
// METHOD (Dash S, Chon KH, Lu S, Raeder EA. Automatic real time detection of atrial fibrillation. Ann Biomed
// Eng 2009;37(9):1701-1709). Each 128-beat segment of R-R intervals gets three features from that paper, plus
// one repeating-pattern check of NOOP's own, and the segment is called irregular only when ALL FOUR agree:
//   1. RMSSD / mean R-R, after the 8 longest and 8 shortest R-R of the segment are removed (outlier trimming,
//      as in the paper): how much consecutive beats differ, relative to the heart rate.
//   2. Shannon entropy of the same trimmed R-R on a 16-bin histogram, normalised to 0...1 (ln 16 = 1): how
//      spread out and unpredictable the intervals are.
//   3. Turning-point ratio (TPR): the share of interior beats that are a local maximum or minimum of the R-R
//      series, compared with a random series, where the expected count is 2(N-2)/3 and its variance
//      (16N-29)/90 (Kendall's turning-point test). It is expressed here as a z-score. A smooth series
//      (respiratory sinus arrhythmia) has FEWER turning points than chance; a strict long-short-long-short
//      alternation (bigeminy) has MORE; AF is the one that looks like chance.
//   4. NOT in the paper: the largest absolute autocorrelation of the mean-removed R-R at lags 2 to 10 must be
//      small. An irregularly irregular rhythm has no repeating pattern; breathing does. A fit sleeper's
//      respiratory sinus arrhythmia can have a high RMSSD, a high entropy AND, at about 3 beats per breath, as
//      many turning points as chance, so criteria 1 to 3 alone call it irregular for as long as it lasts (see
//      below); it repeats, so this check rejects it. It also removed most of the false alarms on real ECG
//      databases (the ectopic-beat ones in particular), so it was kept; see the thresholds.
// The AND matters: bigeminy and trigeminy (regular patterns of ectopic beats) have a high RMSSD but a few
// clustered interval values, hence a low entropy and a TPR that is far from random, so they are not called
// irregular. Respiratory sinus arrhythmia in a young athlete has a high RMSSD; it is not called irregular
// because its R-R series is smooth (a low TPR) or, when its TPR happens to look random, because it repeats.
//
// QUALITY GATES (a false alarm is worse than a miss here, and strap beats are noisier than an ECG):
//   - physiologic R-R only (300-2000 ms, the range `HRVAnalyzer` accepts); an out-of-range interval ends the
//     stretch it sits in;
//   - a stretch also ends at any gap of more than 5 s between consecutive beats' timestamps;
//   - a segment is 128 CONSECUTIVE beats of one stretch, and the R-R it contains must match the wall-clock time it
//     covers (coverage 90-110 %): a segment with dropped beats or a hole in the recording is rejected, because
//     the intervals would no longer be neighbours.
//
// THRESHOLDS. They were not guessed: they were swept on labelled ECG databases from PhysioNet (Goldberger AL et
// al., Circulation 2000;101:e215-e220). Beats were cut into 128-beat segments with the quality gates above, R-R
// rounded to whole ms and timestamps to whole seconds like the strap delivers them (several beats can share one
// second). Positives are segments whose majority rhythm is AF; negatives are the non-AF segments of four sets
// (AF database "(N" and "(J", Normal Sinus Rhythm Database, young and elderly Fantasia volunteers) and, because
// no recording of a very fit sleeper was at hand, a synthetic respiratory sinus arrhythmia (heart rate 43-60,
// +-60-120 ms, breathing 11-19 a minute with a wandering rate and amplitude). A grid over RMSSD/mean, entropy,
// the lower turning-point bound and the autocorrelation cap picked the best sensitivity that keeps EVERY real
// set at 98.9 % specificity or better and the synthetic one at 98 % or better:
//   RMSSD / mean R-R >= 0.10,  Shannon entropy >= 0.87,  turning-point z in -5.0...+6.0,
//   largest |autocorrelation| at lags 2-10 <= 0.35.
//   (for 128 beats: 61 to 112 turning points out of 126, a TPR of 0.48 to 0.89)
// The same sweep with the three paper features alone had RMSSD/mean 0.10, entropy 0.88, z -4.0...+6.0 (sensitivity
// 89.9 %, specificity 98.5-99.7 %), but about 7 % of the synthetic fit-sleeper segments (up to 43 % at heart rate
// 50 with a +-120 ms swing) were called irregular; with the fourth check 0.1 % are.
// Measured with the final thresholds by running THIS code on the databases (segments; 95 % Wilson intervals):
//   MIT-BIH Atrial Fibrillation Database (Moody GB, Mark RG, Comput Cardiol 1983;10:227-230; 25 records, beats
//     from the automatic detector): sensitivity 90.0 % (3441 of 3824 AF segments, 89.0-90.9), specificity 98.9 %
//     on its non-AF segments (5059 of 5115, 98.6-99.2).
//   MIT-BIH Normal Sinus Rhythm Database (18 healthy adults, 24 h each): specificity 99.7 % (13158 of 13194).
//   Fantasia database (Iyengar N et al., Am J Physiol 1996;271:R1078-R1084), healthy volunteers resting supine for
//     2 h: young 21-34 y 99.6 % (1133 of 1138), elderly 68-85 y 99.9 % (1048 of 1049).
//   MIT-BIH Arrhythmia Database (Moody GB, Mark RG, IEEE Eng Med Biol Mag 2001;20(3):45-50; 30 min per record,
//     full of ectopic beats; used for checking only, not for choosing): sensitivity 92.4 % (73 of 79 AF
//     segments, 84.4-96.5), specificity 98.3 % over its non-AF segments (687 of 699), 99.8 % when only segments
//     with a single rhythm are counted (490 of 491); none of the 25 segments of bigeminy, trigeminy,
//     idioventricular, supraventricular or ventricular tachycardia and similar rhythms was called irregular.
//     Frequent ectopic beats can still cause false alarms; the 30-minute episode rule below is what keeps them
//     from becoming a verdict.
//   Atrial flutter, which this screen is not meant for: 0 of 88 segments flagged (AF database), 5 of 9 (Arrhythmia).
//   Same-data sweeps overstate performance: choosing the thresholds on half of the records and testing on the
//     other half (40 folds) gave sensitivity 82.5 % +- 9.9 and specificity 98.1 % +- 1.7 (AF database), 99.6 %
//     (normal sinus rhythm), 99.4 % (young Fantasia) and 99.9 % (elderly Fantasia).
//   For comparison, Dash et al. reported 94.4 % / 95.1 % (AF database) and 90.2 % / 91.2 % (Arrhythmia database).
// At the night level (the episode rule below) the engine found no 30-minute episode in 374 h of normal-sinus-rhythm
// recordings, 78 h of Fantasia, 22 h of the Arrhythmia database, or in the non-AF stretches of the AF database,
// and 18 of the 20 AF stretches of 45 minutes or more overlapped one. NONE of this was measured on this strap:
// optical beat timing is noisier than an ECG, movement can mimic irregularity, no real recording of a fit
// sleeper's night was available (the athlete check is a synthetic model), and brief episodes are missed.
//
// EPISODES (the Fitbit Heart Study's idea of persistence): irregular segments that follow one another with no
// regular segment between them form an episode when together they span 30 minutes or more. A rejected
// (low-quality) segment neither breaks nor extends an episode, but an episode needs at least 80 % of its span
// to have been analysed. An isolated irregular segment, which is what an ectopic burst or a bout of movement
// produces, is never a verdict by itself.
//
// Pure and DB-free: R-R intervals (wall-clock Unix seconds + ms) and the sleep windows in, numbers out.

public enum IrregularRhythm {

    // MARK: - Segments and quality gates

    /// Beats per segment (Dash et al. 2009).
    public static let segmentBeats = 128
    /// Plausible interval range (ms): the range `HRVAnalyzer` accepts too.
    public static let rrMinMs = Int(HRVAnalyzer.rrMinMs)
    public static let rrMaxMs = Int(HRVAnalyzer.rrMaxMs)
    /// A gap between consecutive beats' timestamps longer than this ends a stretch (seconds).
    public static let maxGapSeconds = 5
    /// The R-R in a segment must add up to this share of the wall-clock time it spans. The upper bound only
    /// absorbs the rounding of timestamps to whole seconds; beats that overlap in time are not trustworthy.
    public static let coverageRange: ClosedRange<Double> = 0.90...1.10
    /// The longest and the shortest R-R removed from each end before RMSSD and entropy (Dash et al. 2009).
    public static let trimmedEachEnd = 8
    /// Histogram bins of the Shannon entropy (Dash et al. 2009).
    public static let entropyBins = 16

    // MARK: - Thresholds (measured, see the header)

    /// RMSSD / mean R-R of the trimmed segment at or above this.
    public static let minNormalizedRMSSD = 0.10
    /// Normalised Shannon entropy of the trimmed segment at or above this.
    public static let minEntropy = 0.87
    /// z-score of the turning-point count against a random series, inside this range.
    public static let turningPointZRange: ClosedRange<Double> = -5.0...6.0
    /// Lags (in beats) at which the repeating-pattern check looks.
    public static let autocorrelationLags = 2...10
    /// The largest absolute autocorrelation of the segment's intervals at those lags, at or below this: an
    /// oscillation that repeats (breathing) is not an irregularly irregular rhythm.
    public static let maxAutocorrelation = 0.35

    // MARK: - Episode and night rules

    /// An episode spans at least this many minutes (Fitbit Heart Study: about 30 minutes of irregular tachograms).
    public static let episodeMinMinutes = 30.0
    /// Share of an episode's span that must have been analysed.
    public static let episodeMinAnalysedShare = 0.80
    /// Analysed minutes a night needs before any verdict (below: `notEnoughData`).
    public static let minAnalysedMinutes = 60.0

    // MARK: - Types

    /// The features of one segment: the three of Dash et al. (2009) and the repeating-pattern check.
    public struct Features: Equatable, Sendable {
        /// RMSSD / mean R-R after trimming the 8 longest and 8 shortest intervals.
        public let normalizedRMSSD: Double
        /// Shannon entropy of the trimmed intervals on 16 equal bins, normalised to 0...1.
        public let entropy: Double
        /// z-score of the turning-point count against the random-series expectation 2(N-2)/3, SD sqrt((16N-29)/90).
        public let turningPointZ: Double
        /// Turning points / (N - 2).
        public let turningPointRatio: Double
        /// Largest absolute autocorrelation of the mean-removed intervals at lags 2...10 (0 = no repeating
        /// pattern, 1 = a pure oscillation).
        public let autocorrelation: Double

        public init(normalizedRMSSD: Double, entropy: Double, turningPointZ: Double, turningPointRatio: Double,
                    autocorrelation: Double) {
            self.normalizedRMSSD = normalizedRMSSD
            self.entropy = entropy
            self.turningPointZ = turningPointZ
            self.turningPointRatio = turningPointRatio
            self.autocorrelation = autocorrelation
        }
    }

    /// One quality-passed 128-beat segment and the call made on it.
    public struct Segment: Equatable, Sendable {
        /// Seconds (Unix) at which the segment's first interval began: its first beat's timestamp minus that
        /// interval. Consecutive segments of a stretch therefore tile with no hole.
        public let startTs: Double
        /// Timestamp (Unix seconds) of the segment's last beat.
        public let endTs: Double
        /// Sum of the segment's R-R, in seconds: the time it covers.
        public let durationSeconds: Double
        public let features: Features
        /// True when all four criteria hold.
        public let isIrregular: Bool

        public init(startTs: Double, endTs: Double, durationSeconds: Double, features: Features, isIrregular: Bool) {
            self.startTs = startTs
            self.endTs = endTs
            self.durationSeconds = durationSeconds
            self.features = features
            self.isIrregular = isIrregular
        }
    }

    /// A run of irregular segments that qualifies as an episode.
    public struct Episode: Equatable, Sendable {
        public let startTs: Double
        public let endTs: Double
        /// Span from the start of its first segment to the end of its last, in minutes.
        public let minutes: Double

        public init(startTs: Double, endTs: Double, minutes: Double) {
            self.startTs = startTs
            self.endTs = endTs
            self.minutes = minutes
        }
    }

    /// A sleep window to analyse, in Unix seconds. `end` is exclusive.
    public struct Window: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// What a night's beats say. Never a diagnosis.
    public enum Verdict: String, Codable, Sendable {
        /// Under 60 analysed minutes: too few clean beats to say anything either way.
        case notEnoughData
        /// Enough clean beats and no irregular segment.
        case regular
        /// Some irregular segments, but never 30 minutes in a row: usually ectopic beats, movement or noise.
        case someIrregularSegments
        /// An irregular rhythm lasting 30 minutes or more.
        case irregularEpisode
    }

    /// The result for one night (all its windows together).
    public struct NightResult: Equatable, Sendable {
        /// Minutes covered by the quality-passed segments.
        public let analysedMinutes: Double
        /// Minutes covered by the irregular segments.
        public let irregularMinutes: Double
        /// Minutes in the sleep windows.
        public let windowMinutes: Double
        /// Irregular minutes / analysed minutes x 100; 0 when nothing was analysed.
        public let burdenPercent: Double
        /// The longest episode, in minutes; 0 when there was none.
        public let longestEpisodeMinutes: Double
        public let episodeCount: Int
        /// Quality-passed segments, and how many of them were irregular.
        public let segmentCount: Int
        public let irregularSegmentCount: Int
        public let verdict: Verdict

        public init(analysedMinutes: Double, irregularMinutes: Double, windowMinutes: Double,
                    burdenPercent: Double, longestEpisodeMinutes: Double, episodeCount: Int,
                    segmentCount: Int, irregularSegmentCount: Int, verdict: Verdict) {
            self.analysedMinutes = analysedMinutes
            self.irregularMinutes = irregularMinutes
            self.windowMinutes = windowMinutes
            self.burdenPercent = burdenPercent
            self.longestEpisodeMinutes = longestEpisodeMinutes
            self.episodeCount = episodeCount
            self.segmentCount = segmentCount
            self.irregularSegmentCount = irregularSegmentCount
            self.verdict = verdict
        }

        /// Share (0...1) of the sleep windows that was analysed.
        public var analysedShare: Double {
            windowMinutes > 0 ? min(analysedMinutes / windowMinutes, 1) : 0
        }
    }

    // MARK: - Night

    /// Screen one night. `rr` holds the strap's intervals; only those inside a window (start <= ts < end) are
    /// used, each window is analysed on its own (an episode never bridges two windows) and the results are added.
    /// Overlapping windows are merged first so no beat is counted twice. A night with under 60 analysed minutes is
    /// `notEnoughData` even if the little that was analysed held an episode; its numbers are still returned.
    public static func screen(rr: [RRInterval], windows: [Window]) -> NightResult {
        let merged = mergedWindows(windows)
        let ordered = sortedStable(rr)
        var analysed = 0.0
        var irregular = 0.0
        var windowSeconds = 0.0
        var longest = 0.0
        var episodeCount = 0
        var segmentCount = 0
        var irregularCount = 0

        for w in merged {
            windowSeconds += Double(w.end - w.start)
            let inside = ordered.filter { $0.ts >= w.start && $0.ts < w.end }
            let segs = segments(sortedRR: inside)
            for s in segs {
                analysed += s.durationSeconds
                segmentCount += 1
                if s.isIrregular {
                    irregular += s.durationSeconds
                    irregularCount += 1
                }
            }
            for e in episodes(in: segs) {
                episodeCount += 1
                longest = max(longest, e.minutes)
            }
        }

        let analysedMin = analysed / 60
        let irregularMin = irregular / 60
        let burden = analysed > 0 ? 100 * irregular / analysed : 0
        let verdict: Verdict
        if analysedMin < minAnalysedMinutes {
            verdict = .notEnoughData
        } else if episodeCount > 0 {
            verdict = .irregularEpisode
        } else if irregularCount > 0 {
            verdict = .someIrregularSegments
        } else {
            verdict = .regular
        }
        return NightResult(analysedMinutes: analysedMin, irregularMinutes: irregularMin,
                           windowMinutes: windowSeconds / 60, burdenPercent: burden,
                           longestEpisodeMinutes: longest, episodeCount: episodeCount,
                           segmentCount: segmentCount, irregularSegmentCount: irregularCount,
                           verdict: verdict)
    }

    // MARK: - Segments

    /// The quality-passed 128-beat segments of `rr` (any order), earliest first. Non-overlapping: a stretch of
    /// consecutive good beats is cut into whole segments from its start, the leftover (under 128 beats) is not
    /// analysed. Segments that fail the coverage gate are left out.
    public static func segments(rr: [RRInterval]) -> [Segment] {
        segments(sortedRR: sortedStable(rr))
    }

    private static func segments(sortedRR beats: [RRInterval]) -> [Segment] {
        let n = beats.count
        var out: [Segment] = []
        var i = 0
        while i < n {
            guard isPhysiologic(beats[i].rrMs) else {
                i += 1
                continue
            }
            // Grow the stretch of physiologic beats with no hole between neighbours.
            var j = i + 1
            while j < n, isPhysiologic(beats[j].rrMs), beats[j].ts - beats[j - 1].ts <= maxGapSeconds {
                j += 1
            }
            var k = i
            while k + segmentBeats <= j {
                if let seg = makeSegment(beats[k..<(k + segmentBeats)]) { out.append(seg) }
                k += segmentBeats
            }
            i = j
        }
        return out
    }

    private static func isPhysiologic(_ rrMs: Int) -> Bool {
        rrMs >= rrMinMs && rrMs <= rrMaxMs
    }

    private static func makeSegment(_ block: ArraySlice<RRInterval>) -> Segment? {
        guard let first = block.first, let last = block.last else { return nil }
        let span = Double(last.ts - first.ts)
        guard span > 0 else { return nil }
        // Coverage: the intervals AFTER the first one lie between the first and the last beat.
        var inner = 0
        for b in block.dropFirst() { inner += b.rrMs }
        let coverage = Double(inner) / 1000 / span
        guard coverageRange.contains(coverage) else { return nil }

        let rr = block.map { Double($0.rrMs) }
        guard let f = features(rr: rr) else { return nil }
        let total = rr.reduce(0, +) / 1000
        return Segment(startTs: Double(first.ts) - Double(first.rrMs) / 1000, endTs: Double(last.ts),
                       durationSeconds: total, features: f, isIrregular: isIrregular(f))
    }

    // MARK: - Features

    /// The Dash et al. (2009) features of one segment of R-R intervals (ms, in beat order). Nil when the
    /// segment is too short to trim and compare (under 2 x 8 + 3 beats) or degenerate.
    public static func features(rr: [Double]) -> Features? {
        let n = rr.count
        guard n >= 2 * trimmedEachEnd + 3 else { return nil }

        // Turning points on the raw segment: strict local extrema of the interval series.
        var turning = 0
        for i in 1..<(n - 1) {
            let a = rr[i] - rr[i - 1]
            let b = rr[i + 1] - rr[i]
            if a * b < 0 { turning += 1 }
        }
        let nD = Double(n)
        let expected = 2 * (nD - 2) / 3
        let sd = ((16 * nD - 29) / 90).squareRoot()
        let z = (Double(turning) - expected) / sd
        let ratio = Double(turning) / (nD - 2)

        // Trim the 8 longest and 8 shortest intervals (ties broken by position), keep the order of the rest.
        let order = rr.indices.sorted { (rr[$0], $0) < (rr[$1], $1) }
        var dropped = Set<Int>()
        for idx in order.prefix(trimmedEachEnd) { dropped.insert(idx) }
        for idx in order.suffix(trimmedEachEnd) { dropped.insert(idx) }
        var kept: [Double] = []
        kept.reserveCapacity(n - dropped.count)
        for i in 0..<n where !dropped.contains(i) { kept.append(rr[i]) }
        let m = kept.count
        guard m >= 2 else { return nil }
        let mean = kept.reduce(0, +) / Double(m)
        guard mean > 0 else { return nil }

        var sumSq = 0.0
        for i in 1..<m {
            let d = kept[i] - kept[i - 1]
            sumSq += d * d
        }
        let rmssd = (sumSq / Double(m - 1)).squareRoot()

        return Features(normalizedRMSSD: rmssd / mean, entropy: shannonEntropy(kept),
                        turningPointZ: z, turningPointRatio: ratio, autocorrelation: autocorrelationPeak(of: rr))
    }

    /// Largest absolute autocorrelation of the mean-removed series at `autocorrelationLags`: the biased estimator,
    /// the lag-k sum of products over the variance of the whole segment. A breathing-locked oscillation (respiratory
    /// sinus arrhythmia) repeats and scores high; an irregularly irregular rhythm has no repeating pattern.
    static func autocorrelationPeak(of values: [Double]) -> Double {
        let n = values.count
        guard n > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(n)
        let x = values.map { $0 - mean }
        let variance = x.reduce(0) { $0 + $1 * $1 }
        guard variance > 0 else { return 0 }
        var best = 0.0
        for lag in autocorrelationLags where lag < n {
            var sum = 0.0
            for i in 0..<(n - lag) { sum += x[i] * x[i + lag] }
            best = max(best, abs(sum / variance))
        }
        return best
    }

    /// Shannon entropy of `values` on `entropyBins` equal bins between their minimum and maximum, divided by
    /// ln(bins) so it runs from 0 (one bin) to 1 (spread evenly).
    static func shannonEntropy(_ values: [Double]) -> Double {
        guard let lo = values.min(), let hi = values.max(), hi > lo, !values.isEmpty else { return 0 }
        let width = (hi - lo) / Double(entropyBins)
        var counts = [Int](repeating: 0, count: entropyBins)
        for v in values {
            let bin = min(Int((v - lo) / width), entropyBins - 1)
            counts[bin] += 1
        }
        let total = Double(values.count)
        var h = 0.0
        for c in counts where c > 0 {
            let p = Double(c) / total
            h -= p * log(p)
        }
        return h / log(Double(entropyBins))
    }

    /// True when all four criteria hold (a bigeminy, a smooth or a repeating sinus arrhythmia fails at least one).
    public static func isIrregular(_ f: Features) -> Bool {
        f.normalizedRMSSD >= minNormalizedRMSSD
            && f.entropy >= minEntropy
            && turningPointZRange.contains(f.turningPointZ)
            && f.autocorrelation <= maxAutocorrelation
    }

    // MARK: - Episodes

    /// The episodes among `segments` (one window's, earliest first): maximal runs of irregular segments with no
    /// regular segment between them that span `episodeMinMinutes` or more with at least
    /// `episodeMinAnalysedShare` of that span analysed. A run whose span is mostly holes (the strap off, rejected
    /// segments) is split at its biggest hole and each half is judged on its own, so a long qualifying stretch is
    /// not lost because an earlier, shorter one sat far from it.
    public static func episodes(in segments: [Segment]) -> [Episode] {
        var out: [Episode] = []
        var run: [Segment] = []
        for s in segments {
            if s.isIrregular {
                run.append(s)
            } else {
                out.append(contentsOf: qualifying(run[...]))
                run.removeAll(keepingCapacity: true)
            }
        }
        out.append(contentsOf: qualifying(run[...]))
        return out
    }

    /// The hole between two consecutive segments, in seconds: 0 unless it exceeds `maxGapSeconds` (a smaller
    /// difference is only the rounding of timestamps to whole seconds).
    private static func hole(from a: Segment, to b: Segment) -> Double {
        let h = b.startTs - a.endTs
        return h > Double(maxGapSeconds) ? h : 0
    }

    private static func qualifying(_ run: ArraySlice<Segment>) -> [Episode] {
        guard let first = run.first, let last = run.last else { return [] }
        var analysed = 0.0
        var holes = 0.0
        var biggest = 0.0
        var biggestAfter = run.startIndex
        var prev: Segment?
        for idx in run.indices {
            let s = run[idx]
            analysed += s.durationSeconds
            if let p = prev {
                let h = hole(from: p, to: s)
                holes += h
                if h > biggest {
                    biggest = h
                    biggestAfter = idx
                }
            }
            prev = s
        }
        let span = analysed + holes
        guard span / 60 >= episodeMinMinutes else { return [] }
        if analysed / span >= episodeMinAnalysedShare {
            return [Episode(startTs: first.startTs, endTs: last.endTs, minutes: span / 60)]
        }
        // Mostly holes: split at the biggest one (there must be one, or the share would be ~1).
        guard biggest > 0 else { return [] }
        return qualifying(run[run.startIndex..<biggestAfter]) + qualifying(run[biggestAfter..<run.endIndex])
    }

    // MARK: - Helpers

    /// Beats ordered by timestamp, keeping the delivery order of beats that share a second.
    private static func sortedStable(_ rr: [RRInterval]) -> [RRInterval] {
        var sorted = true
        var i = 1
        while i < rr.count {
            if rr[i].ts < rr[i - 1].ts {
                sorted = false
                break
            }
            i += 1
        }
        if sorted { return rr }
        return rr.enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
    }

    /// Windows sorted by start, with overlapping or touching ones merged and empty ones dropped.
    private static func mergedWindows(_ windows: [Window]) -> [Window] {
        let valid = windows.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var out: [Window] = []
        for w in valid {
            if let last = out.last, w.start <= last.end {
                out[out.count - 1] = Window(start: last.start, end: max(last.end, w.end))
            } else {
                out.append(w)
            }
        }
        return out
    }
}
