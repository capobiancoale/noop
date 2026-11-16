import Foundation
import WhoopProtocol

// NightCoverage.swift — how much of a night the strap actually recorded, and whether that is enough for a
// nightly HRV (the signal Charge is built on).
//
// WHY THIS EXISTS. Charge compares last night's HRV with the person's own baseline. The nightly HRV comes
// from the beat-to-beat (R-R) intervals stored during sleep, and on a WHOOP 5.0/MG those arrive over the
// live heart-rate stream while the phone is connected. When the phone sleeps (Low Power Mode, Background App
// Refresh off) the night has heart rate but few or no R-R beats, no HRV is produced, Charge stays empty and
// the person sees only a bare gauge. This engine turns the raw coverage into plain facts the Today screen
// can show ("heart rate for 6.9 h, 38 % of the night with beats") and into the honest list of things worth
// trying, so an empty Charge reads as a solvable gap rather than a broken app.
//
// It adds no new scoring. The usable-window rule below is exactly the nightly HRV rule:
// `SleepStager.sessionAvgHRV` averages the RMSSD of the 5-minute tumbling windows that pass
// `HRVAnalyzer.windowQuality` (>= 120 s of clean beats, Munoz et al., PLoS One 2015;10:e0138921; <= 5 %
// corrected beats, Kubios HRV user's guide; <= 36 % intervals lost, Sheridan et al., Psychiatry Investig
// 2020;17:960). A night produces an HRV when at least one window passes.
//
// Pure and DB-free: timestamps in, numbers out. All times are wall-clock unix seconds.

public enum NightCoverage {

    /// Window length of the nightly HRV average (`SleepStager.sessionAvgHRV`).
    public static let windowSeconds = 5 * 60

    /// Below this share of the night with any heart-rate sample the strap simply did not record the night
    /// (dead battery, off the wrist, never synced), which is a different problem from missing beats.
    public static let minHeartRateShare = 0.2

    /// What the coverage says about last night's HRV.
    public enum Verdict: Equatable, Sendable {
        /// Almost no heart rate was recorded: the strap did not capture the night.
        case noHeartRate
        /// Heart rate was recorded but (almost) no beat-to-beat intervals came with it.
        case noBeatToBeat
        /// Some beats, but no 5-minute stretch clean enough to compute an HRV.
        case tooSparse
        /// At least one 5-minute stretch is usable: the night yields an HRV.
        case enough
    }

    /// One night's coverage, measured inside `[start, end)`.
    public struct Summary: Equatable, Sendable {
        /// Length of the window, in seconds.
        public let sleepSeconds: Int
        /// Distinct seconds with at least one heart-rate sample.
        public let hrSeconds: Int
        /// R-R intervals (beats) stored in the window.
        public let rrBeats: Int
        /// Distinct seconds with at least one R-R interval.
        public let rrSeconds: Int
        /// 5-minute windows whose RMSSD the nightly HRV would accept.
        public let usableWindows: Int
        /// 5-minute windows the night spans (the last one may be partial).
        public let totalWindows: Int

        /// Hours of heart rate recorded (1 Hz samples counted once per second).
        public var hrHours: Double { Double(hrSeconds) / 3600 }
        /// Share (0...1) of the night with a heart-rate sample.
        public var hrShare: Double { sleepSeconds > 0 ? min(1, Double(hrSeconds) / Double(sleepSeconds)) : 0 }
        /// Share (0...1) of the night with at least one R-R interval.
        public var rrShare: Double { sleepSeconds > 0 ? min(1, Double(rrSeconds) / Double(sleepSeconds)) : 0 }

        public var verdict: Verdict {
            if hrShare < NightCoverage.minHeartRateShare { return .noHeartRate }
            if rrBeats < HRVAnalyzer.minBeats { return .noBeatToBeat }
            if usableWindows == 0 { return .tooSparse }
            return .enough
        }

        public init(sleepSeconds: Int, hrSeconds: Int, rrBeats: Int, rrSeconds: Int,
                    usableWindows: Int, totalWindows: Int) {
            self.sleepSeconds = sleepSeconds
            self.hrSeconds = hrSeconds
            self.rrBeats = rrBeats
            self.rrSeconds = rrSeconds
            self.usableWindows = usableWindows
            self.totalWindows = totalWindows
        }
    }

    /// Measure `[start, end)`. `hrTimestamps` are the timestamps of the stored heart-rate samples (one per
    /// second on a connected strap); `rr` the stored R-R intervals. Nil when the window is empty or inverted.
    public static func summarize(hrTimestamps: [Int], rr: [RRInterval], start: Int, end: Int) -> Summary? {
        guard end > start else { return nil }

        var hrSecs = Set<Int>()
        for ts in hrTimestamps where ts >= start && ts < end { hrSecs.insert(ts) }

        let beats = rr.filter { $0.ts >= start && $0.ts < end }.sorted { $0.ts < $1.ts }
        var rrSecs = Set<Int>()
        for b in beats { rrSecs.insert(b.ts) }

        // One pass over the sorted beats: each 5-minute window takes its slice and is judged by the same
        // gate the nightly HRV uses.
        var usable = 0
        var windows = 0
        var cursor = 0
        var t = start
        while t < end {
            windows += 1
            let upper = t + windowSeconds
            var slice: [RRInterval] = []
            while cursor < beats.count, beats[cursor].ts < upper {
                if beats[cursor].ts >= t { slice.append(beats[cursor]) }
                cursor += 1
            }
            if !slice.isEmpty, HRVAnalyzer.windowQuality(slice).accepted { usable += 1 }
            t = upper
        }

        return Summary(sleepSeconds: end - start, hrSeconds: hrSecs.count, rrBeats: beats.count,
                       rrSeconds: rrSecs.count, usableWindows: usable, totalWindows: windows)
    }

    /// Nights in `nightlyHrv` that count toward Charge's baseline: a value inside the HRV baseline's own
    /// plausibility bounds, the same predicate `Baselines.update` and `RecoveryScorer.calibrationNights` use
    /// (an out-of-range night is never folded in, so it must not be counted here either).
    public static func usableHrvNights(nightlyHrv: [Double?], cfg: MetricCfg = Baselines.hrvCfg) -> Int {
        nightlyHrv.compactMap { $0 }.filter { $0 >= cfg.minVal && $0 <= cfg.maxVal }.count
    }

    /// The things worth trying, each shown only when the coverage points at it.
    public struct Fixes: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Keep NOOP connected to the strap overnight (R-R arrives over the live stream).
        public static let stayConnected = Fixes(rawValue: 1 << 0)
        /// Charge the strap so it can store the night.
        public static let chargeStrap = Fixes(rawValue: 1 << 1)
        /// Wear the strap snugly overnight (a loose fit loses beats).
        public static let wearSnug = Fixes(rawValue: 1 << 2)
    }

    /// What to suggest for `summary`; nil means no main sleep was found at all, where any of the three could
    /// be the cause. A night that already yields an HRV needs none.
    public static func suggestedFixes(for summary: Summary?) -> Fixes {
        guard let summary else { return [.stayConnected, .chargeStrap, .wearSnug] }
        switch summary.verdict {
        case .noHeartRate: return [.stayConnected, .chargeStrap, .wearSnug]
        case .noBeatToBeat, .tooSparse: return [.stayConnected, .wearSnug]
        case .enough: return []
        }
    }
}
