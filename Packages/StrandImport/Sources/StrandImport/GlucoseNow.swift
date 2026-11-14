import Foundation

// MARK: - Glucose now (Today's glucose card)
//
// The latest CGM reading from Apple Health and which way glucose is heading, as CGM apps show it: the rate of
// change over the last 15 minutes in the usual steps of 1, 2 and 3 mg/dL per minute. Apple Health keeps no
// trend arrow, so the rate is worked out here, as a least-squares line through those minutes' readings so one
// noisy reading doesn't flip the arrow. Also the glucose a workout started and ended at, and its lowest from
// the start to an hour after the end (the acute window for a low after exercise, Moser et al., Diabetologia
// 2020). Informational only: nothing here suggests carbs or insulin, and the CGM app and Loop stay the source
// of truth.

/// The latest glucose reading and the rate it is changing at.
public struct GlucoseNow: Equatable, Sendable {

    /// Which way glucose is heading, in the steps CGM trend arrows use.
    public enum Trend: Int, Equatable, Sendable, CaseIterable {
        case fallingFast = -3, falling = -2, fallingSlowly = -1, steady = 0, risingSlowly = 1, rising = 2, risingFast = 3
    }

    /// The latest reading: Unix seconds and mg/dL.
    public let ts: Double
    public let mgdl: Double
    /// mg/dL per minute over the last `trendMinutes`; nil when the readings there are too few or too close
    /// together to say.
    public let ratePerMinute: Double?

    public init(ts: Double, mgdl: Double, ratePerMinute: Double?) {
        self.ts = ts; self.mgdl = mgdl; self.ratePerMinute = ratePerMinute
    }

    /// Minutes of readings the rate comes from.
    public static let trendMinutes = 15.0
    /// Readings needed in that window for a rate, and how far apart its first and last must be: three
    /// 5-minute CGM readings, or more from a 1-minute sensor.
    public static let minTrendReadings = 3
    public static let minTrendSpanMinutes = 8.0
    /// A reading older than this is not "now": the card shows its time and no arrow. The same gap that
    /// breaks the line on the glucose charts (`GlucoseTrace.defaultMaxGap`).
    public static let staleMinutes = 15.0

    public var trend: Trend? { ratePerMinute.map(Self.trend(ratePerMinute:)) }

    /// Whether the latest reading is too old to show as the current glucose.
    public func isStale(now: Double) -> Bool { now - ts > Self.staleMinutes * 60 }

    /// The latest of `readings` and the rate over the minutes before it; nil without readings.
    public static func latest(_ readings: [GlucoseReading]) -> GlucoseNow? {
        guard let last = readings.max(by: { $0.ts < $1.ts }) else { return nil }
        let from = last.ts - trendMinutes * 60
        let recent = readings.filter { $0.ts >= from && $0.ts <= last.ts }
        return GlucoseNow(ts: last.ts, mgdl: last.mgdl, ratePerMinute: rate(recent))
    }

    /// The least-squares slope of the readings, in mg/dL per minute. The same reading written twice (by the
    /// CGM app and by Loop) counts once.
    static func rate(_ readings: [GlucoseReading]) -> Double? {
        var seen = Set<Double>()
        let points = readings.sorted { $0.ts < $1.ts }.filter { seen.insert($0.ts).inserted }
        guard points.count >= minTrendReadings, let first = points.first, let last = points.last,
              last.ts - first.ts >= minTrendSpanMinutes * 60 else { return nil }
        let xs = points.map { ($0.ts - first.ts) / 60 }
        let ys = points.map(\.mgdl)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var sxx = 0.0, sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - mx) * (x - mx)
            sxy += (x - mx) * (y - my)
        }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// The arrow for a rate: steady within ±1 mg/dL per minute, then slowly up to 2, plainly up to 3, fast
    /// beyond.
    public static func trend(ratePerMinute r: Double) -> Trend {
        let size = abs(r)
        let up = r > 0
        if size <= 1 { return .steady }
        if size <= 2 { return up ? .risingSlowly : .fallingSlowly }
        if size <= 3 { return up ? .rising : .falling }
        return up ? .risingFast : .fallingFast
    }
}

/// Glucose around one workout: at its start, at its end, and the lowest from the start to an hour after the
/// end.
public struct WorkoutGlucose: Equatable, Sendable {
    public let startMgdl: Double?
    public let endMgdl: Double?
    public let lowestMgdl: Double?

    public init(startMgdl: Double?, endMgdl: Double?, lowestMgdl: Double?) {
        self.startMgdl = startMgdl; self.endMgdl = endMgdl; self.lowestMgdl = lowestMgdl
    }

    /// How far from the start or end the reading taken for it may lie (one missed 5-minute reading).
    public static let edgeMinutes = 10.0
    /// How long after the end the lowest is looked for.
    public static let afterMinutes = 60.0

    /// Whether glucose went below 70 mg/dL between the start and an hour after the end.
    public var wentLow: Bool { lowestMgdl.map { $0 < GlucoseTrace.lowThreshold } ?? false }

    /// The readings of `trace` around a workout from `start` to `end` (Unix seconds); nil when none lies near it.
    public static func around(_ trace: GlucoseTrace, start: Double, end: Double) -> WorkoutGlucose? {
        guard end >= start else { return nil }
        let atStart = trace.nearest(to: start, within: edgeMinutes * 60)?.mgdl
        let atEnd = trace.nearest(to: end, within: edgeMinutes * 60)?.mgdl
        let lowest = trace.extremes(from: start, to: end + afterMinutes * 60)?.low.mgdl
        guard atStart != nil || atEnd != nil || lowest != nil else { return nil }
        return WorkoutGlucose(startMgdl: atStart, endMgdl: atEnd, lowestMgdl: lowest)
    }
}
