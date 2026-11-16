import Foundation
import WhoopProtocol

// SleepOnsetLatency.swift — where real sleep begins inside a detected in-bed span.
//
// The gravity spine opens a session once the wrist is still for most of a 15-min window (≥ 70 % still
// samples), and the per-epoch classifier only calls WAKE on motion plus cardiac activation. Lying in bed
// awake (a phone, the TV, a book) keeps the wrist about that still, so the whole stretch used to stage as
// light sleep and the night's "Asleep" time was really the moment the strap went still.
//
// Reporter's night (WHOOP 5.0, dense gravity): strap on at 22:55, phone in use in bed until ~23:55, up at
// 00:00–00:10, asleep at ~00:15. NOOP showed "Asleep 22:55". Heart rate and RMSSD did NOT separate the
// two (59 vs 57 bpm, RMSSD 54–74 vs 51–77 ms) and the strap's own band state also flipped to asleep at
// 23:25. What did separate them was how CONTINUOUS the stillness was: awake-in-bed 5-min windows were
// 60–97 % still with frequent dips, real sleep 90–100 %. The first 20-min stretch at ≥ 95 % still began at
// 00:12; on the same strap's other nights it began 2–11 min after the in-bed start.
//
// Rule: sleep onset is the start of the first `onsetWindowMin`-minute stretch whose gravity samples are at
// least `onsetStillFrac` still (same per-sample threshold as the spine). Epochs before it are relabelled
// wake (time awake in bed, i.e. sleep-onset latency), so total sleep and efficiency stop counting it, and
// the Sleep tab shows "Asleep" from the first non-wake stage. The in-bed span itself is unchanged.
// Conservative by construction: no qualifying stretch within `maxOnsetLatencyMin` (a restless night, or
// gravity too sparse to judge) returns nil and the staging is left exactly as it was.

extension SleepStager {

    /// Length (minutes) of the sustained-stillness stretch that marks sleep onset.
    public static let onsetWindowMin: Int = 20
    /// Fraction of still gravity samples the onset stretch must reach.
    public static let onsetStillFrac: Double = 0.95
    /// Search for onset only this far (minutes) into a session. A first sustained stretch later than this
    /// is more likely restless sleep than hours of lying awake, so the session is left unchanged.
    public static let maxOnsetLatencyMin: Int = 180
    /// Minimum gravity coverage of a candidate stretch (fraction of the samples expected at the median
    /// sampling interval). Below it the stretch can't be judged and is skipped.
    static let onsetMinCoverage: Double = 0.5

    /// Start (unix s) of the first `onsetWindowMin`-minute stretch inside `[start, end)` whose gravity
    /// samples are at least `onsetStillFrac` still, searched in 1-minute steps from `start`. Returns
    /// `start` when the session opens with such a stretch, nil when none begins within
    /// `maxOnsetLatencyMin` or the gravity is too sparse to judge. `grav` must be sorted by ts and
    /// `deltas` aligned with it (`gravityDeltas(grav)`).
    static func sustainedStillOnset(grav: [GravitySample], deltas: [Double],
                                    start: Int, end: Int) -> Int? {
        let windowS = onsetWindowMin * 60
        let lastStart = min(end - windowS, start + maxOnsetLatencyMin * 60)
        guard lastStart >= start, grav.count == deltas.count else { return nil }

        let lo = lowerBound(grav, start)
        let hi = lowerBound(grav, end)
        guard hi - lo >= 2 else { return nil }
        let times = grav[lo..<hi].map { $0.ts }
        // stillPrefix[k] = number of still samples among the first k samples of the session.
        var stillPrefix = [Int](repeating: 0, count: times.count + 1)
        for k in 0..<times.count {
            let still = deltas[lo + k] <= gravityStillThresholdG ? 1 : 0
            stillPrefix[k + 1] = stillPrefix[k] + still
        }
        let expected = Double(windowS) / medianIntervalS(times)
        let minSamples = max(2, Int((expected * onsetMinCoverage).rounded(.up)))

        var w = start
        while w <= lastStart {
            let a = lowerBound(times, w), b = lowerBound(times, w + windowS)
            let n = b - a
            if n >= minSamples,
               Double(stillPrefix[b] - stillPrefix[a]) >= onsetStillFrac * Double(n) {
                return w
            }
            w += 60
        }
        return nil
    }

    /// Relabel every stage before `onset` as wake (splitting the segment that straddles it) and merge
    /// adjacent same-stage segments, so the stages still tile the session. No-op when `onset` is at or
    /// before the first segment.
    static func applyOnsetLatency(_ segments: [StageSegment], onset: Int) -> [StageSegment] {
        guard let first = segments.first, onset > first.start else { return segments }
        var relabelled: [StageSegment] = []
        for s in segments {
            if s.end <= onset {
                relabelled.append(StageSegment(start: s.start, end: s.end, stage: "wake"))
            } else if s.start < onset {
                relabelled.append(StageSegment(start: s.start, end: onset, stage: "wake"))
                relabelled.append(StageSegment(start: onset, end: s.end, stage: s.stage))
            } else {
                relabelled.append(s)
            }
        }
        var out: [StageSegment] = []
        for s in relabelled {
            if let last = out.last, last.stage == s.stage, last.end == s.start {
                out[out.count - 1] = StageSegment(start: last.start, end: s.end, stage: s.stage)
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// First index whose ts is ≥ `ts` (binary search over a ts-sorted array).
    private static func lowerBound(_ grav: [GravitySample], _ ts: Int) -> Int {
        var lo = 0, hi = grav.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if grav[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func lowerBound(_ times: [Int], _ ts: Int) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Reads where real sleep began from a night's stored stage timelines, for the Sleep tab's "Asleep" time.
public enum SleepOnsetReadout {

    /// The first non-wake moment (unix s) at or after `notBefore` across a night's stored `stagesJSON`
    /// fragments, in the segment-array format (`[{"start","end","stage"}]`) that computed nights carry.
    /// nil when no fragment has a timeline (an imported night's minute totals) or no sleep stage is found.
    public static func firstAsleepTs(stagesJSONs: [String?], notBefore: Int) -> Int? {
        var best: Int? = nil
        for json in stagesJSONs {
            guard let json, let data = json.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for seg in arr {
                guard let start = (seg["start"] as? NSNumber)?.intValue,
                      let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                      let stage = seg["stage"] as? String,
                      stage != "wake", stage != "awake", end > notBefore else { continue }
                let t = max(start, notBefore)
                if best.map({ t < $0 }) ?? true { best = t }
            }
        }
        return best
    }
}
