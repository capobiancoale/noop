import Foundation

// MARK: - Zoomable glucose + heart-rate timeline (model)
//
// The pure parts of the timeline on the WOD screen and on Today, where glucose, heart rate and carbs /
// boluses sit in lanes on one clock that zooms from the whole window down to single minutes: the CGM trace
// broken wherever the sensor had a gap (a line is never drawn across missing data), the area below 70 mg/dL,
// the figures for whatever stretch is on screen, the axis ticks (clock time, or counted from a WOD), and
// carbs / boluses grouped so their labels never pile up at the current zoom. No SwiftUI, so it is tested on
// its own. Informational only: nothing here suggests carbs or insulin.

/// A CGM trace, sorted, split into segments at gaps.
public struct GlucoseTrace: Equatable, Sendable {

    public struct Point: Equatable, Sendable, Identifiable {
        /// Unix seconds.
        public let ts: Double
        public let mgdl: Double
        /// Points of one segment are drawn joined; a gap in the readings starts a new one.
        public let segment: Int
        public var id: Double { ts }
    }

    /// A point of the filled area below a threshold: readings clamped to it, plus the points where the trace
    /// crosses it, so the fill ends exactly where the line crosses the threshold.
    public struct AreaPoint: Equatable, Sendable, Identifiable {
        public let ts: Double
        public let mgdl: Double
        public let segment: Int
        public var id: String { "\(segment):\(ts)" }
    }

    /// A gap between readings longer than this breaks the line (5-minute CGMs miss one or two now and then).
    public static let defaultMaxGap = 900.0
    /// Level 1 hypoglycaemia (international consensus, Battelino et al., Diabetes Care 2019).
    public static let lowThreshold = 70.0
    /// How long the last reading before a gap (or the end) is taken to last: one ordinary CGM interval.
    public static let lastReadingSeconds = 300.0

    public let points: [Point]

    public init(readings: [GlucoseReading], maxGapSeconds: Double = defaultMaxGap) {
        var out: [Point] = []
        var segment = 0
        var previous: Double?
        for r in readings.sorted(by: { $0.ts < $1.ts }) {
            if let p = previous {
                if r.ts == p { continue }                       // the same reading from two sources
                if r.ts - p > maxGapSeconds { segment += 1 }
            }
            out.append(Point(ts: r.ts, mgdl: r.mgdl, segment: segment))
            previous = r.ts
        }
        points = out
    }

    public var isEmpty: Bool { points.isEmpty }

    /// Index of the first point at or after `ts` (binary search; `points.count` when none).
    private func firstIndex(atOrAfter ts: Double) -> Int {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The points inside [from, to], plus the one just outside each edge, so a line drawn from them runs to
    /// the edges of the window instead of stopping short.
    public func visible(from: Double, to: Double) -> [Point] {
        guard !points.isEmpty, to >= from else { return [] }
        let lo = max(0, firstIndex(atOrAfter: from) - 1)
        let hi = min(points.count, firstIndex(atOrAfter: to) + 1)
        return lo < hi ? Array(points[lo..<hi]) : []
    }

    /// The points strictly inside [from, to].
    public func inside(from: Double, to: Double) -> ArraySlice<Point> {
        let lo = firstIndex(atOrAfter: from)
        var hi = firstIndex(atOrAfter: to)
        if hi < points.count, points[hi].ts == to { hi += 1 }
        return lo < hi ? points[lo..<hi] : []
    }

    /// The reading closest to `ts`, if one lies within `within` seconds of it.
    public func nearest(to ts: Double, within: Double) -> Point? {
        guard !points.isEmpty else { return nil }
        let i = firstIndex(atOrAfter: ts)
        var best: Point?
        for j in [i - 1, i] where points.indices.contains(j) {
            let p = points[j]
            if abs(p.ts - ts) <= within, best.map({ abs(p.ts - ts) < abs($0.ts - ts) }) ?? true { best = p }
        }
        return best
    }

    /// The lowest and highest readings inside [from, to] (the first of equal values).
    public func extremes(from: Double, to: Double) -> (low: Point, high: Point)? {
        let slice = inside(from: from, to: to)
        guard let low = slice.min(by: { $0.mgdl < $1.mgdl }),
              let high = slice.max(by: { $0.mgdl < $1.mgdl }) else { return nil }
        return (low, high)
    }

    /// The mean of the readings inside [from, to].
    public func mean(from: Double, to: Double) -> Double? {
        let slice = inside(from: from, to: to)
        guard !slice.isEmpty else { return nil }
        return slice.reduce(0) { $0 + $1.mgdl } / Double(slice.count)
    }

    /// Seconds inside [from, to] spent below `threshold`: each low reading counts until the next reading of
    /// its segment, and the last one before a gap (or the end) for one CGM interval.
    public func secondsBelow(_ threshold: Double = lowThreshold, from: Double, to: Double) -> Double {
        guard to > from else { return 0 }
        var total = 0.0
        let start = max(0, firstIndex(atOrAfter: from) - 1)
        var i = start
        while i < points.count, points[i].ts < to {
            let p = points[i]
            if p.mgdl < threshold {
                let next = i + 1 < points.count && points[i + 1].segment == p.segment
                    ? points[i + 1].ts : p.ts + Self.lastReadingSeconds
                total += max(0, min(next, to) - max(p.ts, from))
            }
            i += 1
        }
        return total
    }

    /// The area between the trace and `threshold` where the trace is below it, for the segments that dip
    /// below it (empty when none does).
    public func lowArea(below threshold: Double = lowThreshold) -> [AreaPoint] {
        var area: [AreaPoint] = []
        var i = 0
        while i < points.count {
            let segment = points[i].segment
            var j = i
            while j < points.count, points[j].segment == segment { j += 1 }
            let run = points[i..<j]
            if run.contains(where: { $0.mgdl < threshold }) {
                for k in run.indices {
                    let p = points[k]
                    area.append(AreaPoint(ts: p.ts, mgdl: min(p.mgdl, threshold), segment: segment))
                    guard k + 1 < j else { continue }
                    let q = points[k + 1]
                    if (p.mgdl < threshold) != (q.mgdl < threshold), q.mgdl != p.mgdl {
                        let f = (threshold - p.mgdl) / (q.mgdl - p.mgdl)
                        if f > 0, f < 1 {
                            area.append(AreaPoint(ts: p.ts + f * (q.ts - p.ts), mgdl: threshold, segment: segment))
                        }
                    }
                }
            }
            i = j
        }
        return area
    }

    /// mg/dL shown: at least 50…200 and the target range (so the band reads), widened to every reading, so
    /// a low is never clipped. Stays the same while zooming, so values compare across the day.
    public func displayRange(targetLow: Double = 70, targetHigh: Double = 180) -> ClosedRange<Double> {
        let lowest = points.map(\.mgdl).min() ?? targetLow
        let highest = points.map(\.mgdl).max() ?? targetHigh
        let lower = (min(55, targetLow - 10, lowest - 8) / 10).rounded(.down) * 10
        let upper = (max(200, targetHigh + 20, highest + 12) / 20).rounded(.up) * 20
        return max(0, lower)...upper
    }
}

// MARK: - Carbs and boluses

/// Carbs (grams) or bolus insulin (units) taken close together, drawn as one marker.
public struct TimelineEvent: Equatable, Sendable, Identifiable {
    /// The first entry's time (Unix seconds).
    public let ts: Double
    /// The entries' amounts summed.
    public let amount: Double
    public let count: Int
    public var id: Double { ts }
}

public enum TimelineEvents {
    /// Entries within `within` seconds of a group's first entry join that group, their amounts summed, so
    /// their labels never overlap at the current zoom. Entries of zero or less are left out.
    public static func merged(_ entries: [(ts: Double, amount: Double)], within: Double) -> [TimelineEvent] {
        var out: [TimelineEvent] = []
        for e in entries.filter({ $0.amount > 0 }).sorted(by: { $0.ts < $1.ts }) {
            if let first = out.last, e.ts - first.ts <= within {
                out[out.count - 1] = TimelineEvent(ts: first.ts, amount: first.amount + e.amount, count: first.count + 1)
            } else {
                out.append(TimelineEvent(ts: e.ts, amount: e.amount, count: 1))
            }
        }
        return out
    }

    /// The grouping distance for a window `span` seconds wide: about a 24th of it, never under a minute.
    public static func mergeDistance(span: Double) -> Double { max(60, span / 24) }
}

// MARK: - Axis ticks

/// A tick of the timeline's time axis.
public struct TimelineTick: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A time of day.
        case clock
        /// Before the WOD's start; `offset` counts back from it.
        case beforeStart
        /// During the WOD; `offset` is the time elapsed since its start, like a workout clock.
        case duringWod
        /// After the WOD's end; `offset` counts on from it.
        case afterEnd
    }
    /// Unix seconds.
    public let ts: Double
    public let kind: Kind
    /// Seconds from the anchor (the WOD's start, or its end after it); 0 for clock ticks.
    public let offset: Double
    public var id: Double { ts }
}

public enum TimelineTicks {
    /// Tick spacings, in seconds, from 15 s up to 6 h.
    public static let steps: [Double] = [15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600]

    /// The smallest step giving at most `maxTicks` ticks across `span` seconds.
    public static func step(span: Double, maxTicks: Int = 5) -> Double {
        steps.first { span / $0 <= Double(maxTicks) } ?? steps[steps.count - 1]
    }

    /// Times of day on multiples of `step` in local time (`utcOffset` seconds east of UTC) within [from, to].
    public static func clock(from: Double, to: Double, step: Double, utcOffset: Double) -> [TimelineTick] {
        guard step > 0, to >= from else { return [] }
        var t = ((from + utcOffset) / step).rounded(.up) * step - utcOffset
        var out: [TimelineTick] = []
        while t <= to {
            out.append(TimelineTick(ts: t, kind: .clock, offset: 0))
            t += step
        }
        return out
    }

    /// Ticks counted from a WOD within [from, to]: multiples of `step` back from its start, the elapsed time
    /// from its start while it lasts, and multiples of `step` on from its end. A tick closer than 0.6 steps
    /// to the one before it is dropped, so labels never collide where the three runs meet.
    public static func wod(from: Double, to: Double, wodStart: Double, wodEnd: Double,
                           step: Double) -> [TimelineTick] {
        guard step > 0, to >= from, wodEnd >= wodStart else { return [] }
        var all: [TimelineTick] = []
        var k = ((wodStart - from) / step).rounded(.down)
        while k >= 1 {
            all.append(TimelineTick(ts: wodStart - k * step, kind: .beforeStart, offset: k * step))
            k -= 1
        }
        var elapsed = 0.0
        while wodStart + elapsed <= wodEnd {
            all.append(TimelineTick(ts: wodStart + elapsed, kind: .duringWod, offset: elapsed))
            elapsed += step
        }
        var after = step
        while wodEnd + after <= to {
            all.append(TimelineTick(ts: wodEnd + after, kind: .afterEnd, offset: after))
            after += step
        }
        var out: [TimelineTick] = []
        for t in all.sorted(by: { $0.ts < $1.ts }) where t.ts >= from && t.ts <= to {
            if let last = out.last, t.ts - last.ts < 0.6 * step { continue }
            out.append(t)
        }
        return out
    }

    /// The label of a tick counted from a WOD: "−30′" / "−1h30" before it, a workout clock ("5:00") during
    /// it, "+15′" / "+2h" after it; minutes and seconds ("−1:30") when the ticks are under a minute apart.
    /// Empty for clock ticks, which the view formats as a time of day.
    public static func label(_ tick: TimelineTick, step: Double) -> String {
        switch tick.kind {
        case .clock: return ""
        case .beforeStart: return "\u{2212}" + span(tick.offset, step: step)
        case .afterEnd: return "+" + span(tick.offset, step: step)
        case .duringWod: return workoutClock(tick.offset)
        }
    }

    /// "1:05" (minutes:seconds), or "1:02:05" past an hour.
    public static func workoutClock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3_600 { return String(format: "%d:%02d:%02d", s / 3_600, (s % 3_600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func span(_ seconds: Double, step: Double) -> String {
        let s = Int(seconds.rounded())
        if step < 60 { return workoutClock(seconds) }
        if s < 3_600 { return "\(s / 60)\u{2032}" }
        let m = (s % 3_600) / 60
        return m == 0 ? "\(s / 3_600)h" : String(format: "%dh%02d", s / 3_600, m)
    }
}
