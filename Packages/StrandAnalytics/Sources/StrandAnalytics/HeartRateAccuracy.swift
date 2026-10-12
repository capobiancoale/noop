import Foundation
import WhoopProtocol

// HeartRateAccuracy.swift — checks the person can run on the heart rate their strap reports, and the numbers
// that put it in context.
//
// A wrist strap reads the pulse optically (PPG). Nothing in the phone can say whether that reading is
// "right" in absolute terms: only a chest strap or an ECG can. What the data DOES allow, honestly:
//
//   1. Self-consistency (`rrConsistency`). The strap reports a heart rate and, separately, the time between
//      beats (R-R intervals). Both come from the same optical signal, so 60000 / R-R must agree with the
//      reported heart rate. A large gap means the optical signal was disturbed (motion, a loose fit) at that
//      moment, which is exactly when a wrist reading is least trustworthy. It does NOT prove the absolute
//      accuracy: a bias common to both would not show.
//   2. A manual count (`palpation`). Counting your own pulse for 30 s at the wrist or neck is the classic
//      bedside check (resolution: one counted beat is 2 bpm), and it IS independent of the strap.
//   3. Your own baseline (`sleeping`, `waking`). "My heart rate is always high" is a judgement against what
//      is normal FOR THAT PERSON: their sleeping floor, their calmest waking stretches, and their usual range.
//
// Context for expectations (not used in any computation): wrist PPG heart rate agrees well with an ECG at
// rest and degrades with intense, rhythmic arm movement because the sensor can lock onto the movement
// cadence instead of the pulse (Shcherbina et al., J Pers Med 2017;7:3; Bent et al., npj Digit Med 2020;3:18).
//
// Pure and DB-free: samples in, numbers out. All times are wall-clock unix seconds. Informational only,
// not a medical device.

public enum HeartRateAccuracy {

    // MARK: - Strap against its own beat-to-beat timing

    /// Half-width (s) of the R-R window around each heart-rate sample.
    public static let rrWindowRadiusSeconds = 5
    /// Intervals a window needs (after filtering) before it can be compared.
    public static let rrMinIntervals = 3
    /// Plausible interval range (ms): 300...2000 is 200...30 bpm, the range `HRVAnalyzer` accepts too.
    public static let rrMinMs = HRVAnalyzer.rrMinMs
    public static let rrMaxMs = HRVAnalyzer.rrMaxMs
    /// Comparisons needed before an agreement is reported (a smaller sample is not a statement).
    public static let minAgreementSamples = 30
    /// A reading "agrees" when it is within this many bpm of the R-R derived rate.
    public static let toleranceBpm = 5.0

    /// How the strap's reported heart rate compares with the rate its own R-R intervals imply.
    public struct Agreement: Equatable, Sendable {
        /// Heart-rate samples that could be compared (one per second with enough clean R-R around it).
        public let n: Int
        /// Mean of (strap - R-R derived) in bpm. Positive: the strap reads higher than its beat timing.
        public let meanBias: Double
        /// Mean absolute difference, bpm.
        public let meanAbsError: Double
        /// Share (0...1) of comparisons within `toleranceBpm`.
        public let shareWithin5Bpm: Double
    }

    /// For each second with a heart-rate sample, take the R-R intervals within +-5 s, keep those in
    /// 300...2000 ms, drop the ones more than 20 % away from their neighbours' median (the Malik 1989 /
    /// `HRVAnalyzer.rejectEctopic` artefact rule), and compare the strap's bpm with 60000 / median(R-R).
    /// A second needs at least 3 intervals before AND after that filtering; nil when fewer than 30 seconds
    /// could be compared.
    public static func rrConsistency(hr: [(ts: Int, bpm: Double)],
                                     rr: [(ts: Int, rrMs: Double)]) -> Agreement? {
        guard !hr.isEmpty, !rr.isEmpty else { return nil }
        let beats = rr.sorted { $0.ts < $1.ts }
        let stamps = beats.map(\.ts)

        var n = 0
        var sumDiff = 0.0
        var sumAbs = 0.0
        var within = 0
        for sample in hr where sample.bpm > 0 {
            var i = lowerBound(stamps, sample.ts - rrWindowRadiusSeconds)
            var window: [Double] = []
            while i < beats.count, beats[i].ts <= sample.ts + rrWindowRadiusSeconds {
                let v = beats[i].rrMs
                if v >= rrMinMs && v <= rrMaxMs { window.append(v) }
                i += 1
            }
            guard window.count >= rrMinIntervals else { continue }
            let kept = HRVAnalyzer.rejectEctopic(window)
            guard kept.count >= rrMinIntervals, let m = median(kept), m > 0 else { continue }
            let diff = sample.bpm - 60_000 / m
            n += 1
            sumDiff += diff
            sumAbs += abs(diff)
            if abs(diff) <= toleranceBpm { within += 1 }
        }
        guard n >= minAgreementSamples else { return nil }
        let nD = Double(n)
        return Agreement(n: n, meanBias: sumDiff / nD, meanAbsError: sumAbs / nD,
                         shareWithin5Bpm: Double(within) / nD)
    }

    // MARK: - Manual pulse count

    /// A counted pulse below or above this is a mis-count, not a heart rate, and is not compared.
    public static let plausibleCountedBpm = 20.0...250.0
    /// Share of the counting window the strap must have reported for the comparison to mean anything.
    public static let minPalpationCoverage = 0.5

    /// The person's own count against the strap over the same seconds.
    public struct PalpationResult: Equatable, Sendable {
        /// countedBeats x 60 / seconds.
        public let countedBpm: Double
        /// Mean of the strap's samples inside the window.
        public let strapBpm: Double
        /// strap - counted, bpm.
        public let differenceBpm: Double
        /// Difference as a percentage of the counted rate.
        public let percent: Double
        /// Distinct seconds the strap reported inside the window.
        public let samples: Int
        /// True when the two agree within `toleranceBpm` (one counted beat in 30 s already moves it 2 bpm).
        public var matches: Bool { abs(differenceBpm) <= HeartRateAccuracy.toleranceBpm }
    }

    /// Compare a manual count with the strap. `strap` are its heart-rate samples; the window is
    /// `[start, start + seconds)`. Nil when the window is empty, the count is implausible, or the strap
    /// reported less than half of the window's seconds (a disconnect mid-count makes no valid comparison).
    public static func palpation(strap: [(ts: Int, bpm: Double)], start: Int, seconds: Int,
                                 countedBeats: Int) -> PalpationResult? {
        guard seconds > 0, countedBeats > 0 else { return nil }
        let counted = Double(countedBeats) * 60 / Double(seconds)
        guard plausibleCountedBpm.contains(counted) else { return nil }
        let inside = strap.filter { $0.ts >= start && $0.ts < start + seconds && $0.bpm > 0 }
        let distinct = Set(inside.map(\.ts)).count
        guard Double(distinct) >= minPalpationCoverage * Double(seconds) else { return nil }
        let mean = inside.reduce(0.0) { $0 + $1.bpm } / Double(inside.count)
        let diff = mean - counted
        return PalpationResult(countedBpm: counted, strapBpm: mean, differenceBpm: diff,
                               percent: diff / counted * 100, samples: distinct)
    }

    // MARK: - The person's own baseline

    /// Minimum samples (5 minutes at 1 Hz) before a night's floor and mean are reported.
    public static let minSleepSamples = 300
    /// Minimum waking 5-minute windows (2 hours in all) before a waking range is reported.
    public static let minWakingWindows = 24

    /// Heart rate across one night's sleep.
    public struct SleepHeartRate: Equatable, Sendable {
        /// The lowest sustained rate: the minimum of the 5-minute means (`RecoveryScorer.restingHR`).
        public let floorBpm: Int
        /// Mean over the whole night.
        public let meanBpm: Double
        public let samples: Int
    }

    /// The night's floor and mean from the heart-rate samples inside `[start, end]`; nil with fewer than
    /// `minSleepSamples`.
    public static func sleeping(hr: [HRSample], start: Int, end: Int) -> SleepHeartRate? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end && $0.bpm > 0 }
        guard seg.count >= minSleepSamples,
              let floor = RecoveryScorer.restingHR(seg, start: start, end: end) else { return nil }
        let mean = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        return SleepHeartRate(floorBpm: floor, meanBpm: mean, samples: seg.count)
    }

    /// Heart rate across the waking hours, from 5-minute windows.
    public struct WakingHeartRate: Equatable, Sendable {
        /// Calmest waking stretches: the 10th percentile of the windows.
        public let restingBpm: Double
        /// The typical waking window (median).
        public let typicalBpm: Double
        /// The top of the usual range: the 90th percentile.
        public let highBpm: Double
        public let windows: Int
    }

    /// Waking summary from 5-minute mean heart rates (`windows`, keyed by window start), leaving out every
    /// window that overlaps a sleep session in `sleep`. The 10th/50th/90th percentiles are used instead of
    /// the minimum/maximum so a single odd window cannot define "resting" or "high". Nil with fewer than
    /// `minWakingWindows` windows.
    public static func waking(windows: [(ts: Int, bpm: Double)],
                              excluding sleep: [(start: Int, end: Int)],
                              windowSeconds: Int = 300) -> WakingHeartRate? {
        let awake = windows.filter { w in
            guard w.bpm > 0 else { return false }
            return !sleep.contains { w.ts < $0.end && w.ts + windowSeconds > $0.start }
        }
        guard awake.count >= minWakingWindows else { return nil }
        let sorted = awake.map(\.bpm).sorted()
        return WakingHeartRate(restingBpm: percentile(sorted, 0.10), typicalBpm: percentile(sorted, 0.50),
                               highBpm: percentile(sorted, 0.90), windows: sorted.count)
    }

    // MARK: - Helpers

    /// First index in the ascending `a` whose value is >= `x`.
    private static func lowerBound(_ a: [Int], _ x: Int) -> Int {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Linear-interpolated percentile (type 7) of an ascending, non-empty array.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }
}
