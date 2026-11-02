import Foundation
import WhoopProtocol

// HeartRateRecovery.swift — how fast the heart rate falls after a workout stops, and how long the
// body takes to get back near its resting level.
//
// PUBLISHED BASIS (NOT a clinical test, NOT medical advice):
//   • HRR1 = peak exercise HR − HR one minute after exercise stops. Cole CR, Blackstone EH, Pashkow FJ,
//     Snader CE, Lauer MS. "Heart-rate recovery immediately after exercise as a predictor of mortality."
//     N Engl J Med 1999;341:1351–1357. A fall of ≤ 12 bpm in the first minute was the value they called
//     abnormal. That was a supervised treadmill test with a defined cool-down, so the cut-off is only a
//     rough reference for a free-living workout.
//   • HRR2 = the same difference at two minutes. Shetler K, Marcus R, Froelicher VF, et al. "Heart rate
//     recovery: validation and methodologic issues." J Am Coll Cardiol 2001;38:1980–1987 compared recovery
//     taken at several minute marks and showed the result depends on the protocol (cool-down walking vs
//     lying down), which is why NOOP states how it measured and does not grade the 2-minute value.
//
// NOOP's own, descriptive additions (clearly NOT validated cut-offs):
//   • Checkpoints at +1, +2, +5, +10, +30, +60 min: the plain median HR around each moment.
//   • "Recovery time": the first moment the trailing 60-second median HR is within 20 % of the way
//     between resting and peak (i.e. 80 % of the drop from peak back to resting is done).
//
// Honesty rules: the peak is a 15-second median in the LAST 2 MINUTES of the workout (never a single
// raw spike); a checkpoint exists only when real samples sit inside its tolerance (no interpolation
// across gaps); nothing is returned when there is no heart rate after the workout.

/// Heart-rate recovery of one workout. Every field is derived from real samples; absent data is nil / missing.
public struct HeartRateRecovery: Equatable, Sendable {

    /// HR measured `minutes` after the workout ended (median of the samples around that moment).
    public struct Checkpoint: Equatable, Sendable {
        public let minutes: Int
        public let bpm: Double
        public init(minutes: Int, bpm: Double) { self.minutes = minutes; self.bpm = bpm }
    }

    /// One chart point: `seconds` relative to the workout end (negative = still exercising).
    public struct Point: Equatable, Sendable {
        public let seconds: Int
        public let bpm: Double
        public init(seconds: Int, bpm: Double) { self.seconds = seconds; self.bpm = bpm }
    }

    /// Workout end, Unix seconds.
    public let endTs: Int
    /// Highest 15-second median HR in the last 2 minutes of the workout (bpm).
    public let peakBpm: Double
    /// Timestamp (Unix s) of a sample inside that peak bucket.
    public let peakTs: Int
    /// Peak − HR at +60 s after the end (Cole 1999). nil when no sample sits within ±10 s of +60 s.
    /// Can be ≤ 0 when the heart rate did not fall (still moving, or a late rise).
    public let hrr1: Double?
    /// Peak − HR at +120 s after the end (Shetler 2001). nil when no sample sits within ±10 s of +120 s.
    public let hrr2: Double?
    /// HR at +1, +2, +5, +10, +30, +60 min, each only when data exists there. Ascending by minutes.
    public let checkpoints: [Checkpoint]
    /// restingHR + 0.2 × (peak − restingHR): the level that counts as "80 % of the way back to resting".
    /// nil when the resting HR is unknown or the peak is too close to it for the idea to be meaningful.
    public let recoveryThreshold: Double?
    /// Minutes after the end at which the trailing 60-second median HR first fell to the threshold.
    /// nil when the resting HR is unknown or the threshold was not reached inside the observed window.
    public let recoveryMinutes: Double?
    /// 15-second medians from −120 s to the end of the observed window, for the chart.
    public let curve: [Point]
    /// End (Unix s) of the observed window: the last sample used, never later than `now` or the requested window.
    public let windowEnd: Int
    /// True while the requested window has not elapsed yet, so more heart rate can still arrive.
    public let windowOpen: Bool
    /// True when at least 30 minutes after the end were observed.
    public let isComplete: Bool

    public init(endTs: Int, peakBpm: Double, peakTs: Int, hrr1: Double?, hrr2: Double?,
                checkpoints: [Checkpoint], recoveryThreshold: Double?, recoveryMinutes: Double?,
                curve: [Point], windowEnd: Int, windowOpen: Bool, isComplete: Bool) {
        self.endTs = endTs; self.peakBpm = peakBpm; self.peakTs = peakTs
        self.hrr1 = hrr1; self.hrr2 = hrr2; self.checkpoints = checkpoints
        self.recoveryThreshold = recoveryThreshold; self.recoveryMinutes = recoveryMinutes
        self.curve = curve; self.windowEnd = windowEnd
        self.windowOpen = windowOpen; self.isComplete = isComplete
    }

    /// True when the heart rate got back to the recovery threshold inside the observed window.
    public var reachedWithinWindow: Bool { recoveryMinutes != nil }

    /// Length of the observed window, rounded to whole minutes (≥ 0).
    public var observedMinutes: Int { max(0, Int((Double(windowEnd - endTs) / 60.0).rounded())) }

    /// Informational label for the 1-minute drop; nil when HRR1 is unknown.
    public var speed: HeartRateRecoveryEngine.Speed? { hrr1.map(HeartRateRecoveryEngine.hrr1Speed) }

    /// HR at the checkpoint `minutes` after the end, or nil.
    public func bpm(atMinutes minutes: Int) -> Double? {
        checkpoints.first(where: { $0.minutes == minutes })?.bpm
    }
}

public enum HeartRateRecoveryEngine {

    // MARK: - Constants

    /// Checkpoints reported, minutes after the end.
    public static let checkpointMinutes: [Int] = [1, 2, 5, 10, 30, 60]
    /// ±tolerance (s) around the +1 and +2 minute checkpoints (the HR is falling fast there).
    public static let nearToleranceS: Int = 10
    /// ±tolerance (s) around the +5 minute and later checkpoints.
    public static let farToleranceS: Int = 30
    /// Bucket width (s) of the medians used for the peak and the chart.
    public static let bucketS: Int = 15
    /// How far back from the end the peak is searched (s).
    public static let peakLookbackS: Int = 120
    /// Trailing window (s) of the median used to detect "back near resting".
    public static let rollingWindowS: Int = 60
    /// Fraction of the peak-to-resting gap that may remain when the body counts as recovered.
    public static let remainingFraction: Double = 0.2
    /// Peaks closer than this to the resting HR (bpm) give no meaningful recovery threshold.
    public static let minReserveBpm: Double = 10
    /// Minimum samples in the trailing window before its median is trusted.
    public static let minRollingSamples: Int = 3
    /// Plausible HR range (bpm); samples outside are dropped.
    public static let hrRange: ClosedRange<Int> = 30...230
    /// Observed seconds after the end from which a recovery is called complete (30 min).
    public static let completeAfterS: Int = 30 * 60

    // MARK: - Speed label

    /// How the 1-minute drop compares with the usual range.
    ///
    /// INFORMATIONAL only. A free-living drop is not a clinical test, and it depends on how you cool
    /// down (walking on vs sitting or lying down gives very different numbers), so compare the same
    /// kind of cool-down from one workout to the next rather than reading a verdict into one value.
    public enum Speed: Equatable, Sendable {
        /// ≤ 12 bpm: the value Cole 1999 called abnormal after a treadmill test.
        case slow
        /// 13–24 bpm.
        case typical
        /// ≥ 25 bpm: common in well-trained people.
        case fast
    }

    /// Label for an HRR1 value (rounded to the nearest whole bpm first, as heart rate is reported in whole bpm).
    public static func hrr1Speed(_ hrr1: Double) -> Speed {
        let v = hrr1.rounded()
        if v <= 12 { return .slow }
        if v < 25 { return .typical }
        return .fast
    }

    // MARK: - Compute

    /// Heart-rate recovery after one workout.
    ///
    /// - Parameters:
    ///   - samples: HR samples around the workout and its aftermath (any order; duplicates are harmless).
    ///   - workoutStart / workoutEnd: workout bounds, Unix seconds.
    ///   - restingHR: the person's resting HR (bpm) for the recovery-time threshold, or nil.
    ///   - now: current Unix time. Samples after it are ignored and the window never extends past it.
    ///   - windowMinutes: how long after the end to look (default 60).
    /// - Returns: nil when the workout bounds are invalid, there is no usable HR after the end, or
    ///   fewer than 2 samples fall in the last 2 minutes of the workout (no honest peak).
    public static func compute(samples: [HRSample],
                               workoutStart: Int,
                               workoutEnd: Int,
                               restingHR: Double?,
                               now: Int,
                               windowMinutes: Int = 60) -> HeartRateRecovery? {
        guard workoutEnd > workoutStart, windowMinutes > 0, workoutEnd < now else { return nil }

        // 1. Clean: plausible range, not in the future, ascending.
        let clean = samples
            .filter { hrRange.contains($0.bpm) && $0.ts <= now }
            .map { (ts: $0.ts, bpm: Double($0.bpm)) }
            .sorted { $0.ts < $1.ts }

        // 2. Observed window: from the end to the last sample, bounded by `now` and the requested window.
        let nominalEnd = min(now, workoutEnd + windowMinutes * 60)
        let post = clean.filter { $0.ts > workoutEnd && $0.ts <= nominalEnd }
        guard let lastPost = post.last else { return nil }
        let windowEnd = lastPost.ts

        // 3. Peak: highest 15 s median in the last 2 minutes of the workout.
        let leadStart = max(workoutStart, workoutEnd - peakLookbackS + 1)
        let lead = clean.filter { $0.ts >= leadStart && $0.ts <= workoutEnd }
        guard lead.count >= 2 else { return nil }
        guard let peak = peakBucket(lead, end: workoutEnd) else { return nil }

        // 4. Checkpoints (+1, +2, +5, +10, +30, +60 min) and the two classic drops.
        var checkpoints: [HeartRateRecovery.Checkpoint] = []
        for m in checkpointMinutes {
            let target = workoutEnd + m * 60
            guard target <= windowEnd else { continue }
            let tol = m <= 2 ? nearToleranceS : farToleranceS
            if let v = medianAround(clean, target: target, tolerance: tol) {
                checkpoints.append(HeartRateRecovery.Checkpoint(minutes: m, bpm: v))
            }
        }
        let hrr1 = checkpoints.first(where: { $0.minutes == 1 }).map { peak.bpm - $0.bpm }
        let hrr2 = checkpoints.first(where: { $0.minutes == 2 }).map { peak.bpm - $0.bpm }

        // 5. Recovery threshold + time.
        var threshold: Double?
        var recoveryMinutes: Double?
        if let rest = restingHR, rest.isFinite, rest > 0, peak.bpm - rest >= minReserveBpm {
            let thr = rest + remainingFraction * (peak.bpm - rest)
            threshold = thr
            if let t = firstBelow(post, end: workoutEnd, threshold: thr) {
                recoveryMinutes = Double(t - workoutEnd) / 60.0
            }
        }

        // 6. Chart curve: 15 s medians from −120 s to the end of the window.
        let curveSamples = clean.filter { $0.ts >= leadStart && $0.ts <= windowEnd }
        let curve = bucketMedians(curveSamples, end: workoutEnd).map {
            HeartRateRecovery.Point(seconds: $0.mid, bpm: $0.median)
        }

        return HeartRateRecovery(
            endTs: workoutEnd, peakBpm: peak.bpm, peakTs: peak.ts,
            hrr1: hrr1, hrr2: hrr2, checkpoints: checkpoints,
            recoveryThreshold: threshold, recoveryMinutes: recoveryMinutes,
            curve: curve, windowEnd: windowEnd,
            windowOpen: now < workoutEnd + windowMinutes * 60,
            isComplete: windowEnd - workoutEnd >= completeAfterS)
    }

    // MARK: - Internals

    private struct Bucket {
        let index: Int
        let median: Double
        let count: Int
        let ts: Int
        /// Bucket centre in seconds relative to the workout end.
        var mid: Int { index * HeartRateRecoveryEngine.bucketS + HeartRateRecoveryEngine.bucketS / 2 + 1 }
    }

    /// Floor division that rounds toward negative infinity (Swift's `/` truncates toward zero).
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// 15 s medians relative to the end: bucket `b` covers relative seconds (15·b, 15·(b+1)], so the
    /// last second of the workout (relative 0) closes bucket −1 and the first second after it opens bucket 0.
    private static func bucketMedians(_ pts: [(ts: Int, bpm: Double)], end: Int) -> [Bucket] {
        var groups: [Int: [(ts: Int, bpm: Double)]] = [:]
        for p in pts {
            let b = floorDiv(p.ts - end - 1, bucketS)
            groups[b, default: []].append(p)
        }
        return groups.keys.sorted().compactMap { b -> Bucket? in
            guard let g = groups[b], !g.isEmpty else { return nil }
            let med = median(g.map { $0.bpm })
            // A real sample of the bucket nearest to the median stands in for "when" (earliest on a tie).
            let rep = g.min { abs($0.bpm - med) < abs($1.bpm - med) } ?? g[0]
            return Bucket(index: b, median: med, count: g.count, ts: rep.ts)
        }
    }

    /// Highest bucket median among the lead-in samples. Buckets with ≥ 3 samples win when any exist,
    /// so a lone spike in a thinly sampled bucket cannot become the peak.
    private static func peakBucket(_ lead: [(ts: Int, bpm: Double)], end: Int) -> (bpm: Double, ts: Int)? {
        let buckets = bucketMedians(lead, end: end)
        let robust = buckets.filter { $0.count >= 3 }
        let pool = robust.isEmpty ? buckets : robust
        guard var best = pool.first else { return nil }
        for b in pool where b.median > best.median { best = b }
        return (best.median, best.ts)
    }

    /// Median of the samples within ±`tolerance` s of `target`, or nil when none exist.
    private static func medianAround(_ pts: [(ts: Int, bpm: Double)], target: Int, tolerance: Int) -> Double? {
        let near = pts.filter { abs($0.ts - target) <= tolerance }.map { $0.bpm }
        return near.isEmpty ? nil : median(near)
    }

    /// First time `t` (≥ end + 60 s, so the trailing window is a full minute) at which the median of the
    /// samples in (t − 60 s, t] is ≤ `threshold`; nil when it never is. `post` must be ascending.
    private static func firstBelow(_ post: [(ts: Int, bpm: Double)], end: Int, threshold: Double) -> Int? {
        var lo = 0
        for (i, p) in post.enumerated() where p.ts - end >= rollingWindowS {
            while post[lo].ts <= p.ts - rollingWindowS { lo += 1 }
            let window = post[lo...i]
            guard window.count >= minRollingSamples else { continue }
            if median(window.map { $0.bpm }) <= threshold { return p.ts }
        }
        return nil
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
