import Foundation

// MARK: - A WOD's glucose timeline
//
// What the glucose chart of a logged WOD shows, computed here (no SwiftUI) so it is testable: where the WOD
// really sat in time, the readings on a clock that starts at the WOD (minutes before it are negative), the
// trace split wherever the CGM had a gap (a line is never drawn across missing data), the lowest reading,
// the time spent below 70 mg/dL, and carbs and bolus insulin as events on the same clock. Informational
// only: nothing here suggests carbs or insulin.

/// Where a logged WOD sat in time.
public struct WodTimeWindow: Equatable, Sendable {
    /// Unix seconds.
    public let start: Double
    public let end: Double
    /// True when a workout recorded by the strap or Apple Health gave the span; false when it is the logged
    /// time taken as the start, plus the WOD's duration.
    public let recorded: Bool

    public init(start: Double, end: Double, recorded: Bool) {
        self.start = start; self.end = end; self.recorded = recorded
    }

    public var durationMinutes: Double { (end - start) / 60 }

    /// Duration assumed when the WOD has neither a result time nor a time cap.
    public static let defaultMinutes = 20.0
    /// A recorded workout longer than this is not a WOD (an all-day import, a hike).
    public static let maxRecordedMinutes = 240.0
    /// How far from the span a logged WOD could occupy a recorded workout may sit and still be that WOD.
    public static let matchSlack = 3_600.0

    /// The WOD's span. The logged time may mark its start or its end, so the WOD lies somewhere in
    /// [logged − duration, logged + duration]: the recorded workout overlapping that span most is the WOD
    /// (or, when none overlaps, the nearest within `matchSlack`), the same rule the Effort score uses to
    /// find a logged session's heart rate. Without one, the logged time is taken as the start.
    public static func resolve(loggedTs: Double, durationS: Double?,
                               workouts: [(start: Double, end: Double)]) -> WodTimeWindow {
        let duration = (durationS ?? 0) > 0 ? durationS! : defaultMinutes * 60
        let coreLo = loggedTs - duration, coreHi = loggedTs + duration
        func overlap(_ w: (start: Double, end: Double)) -> Double { max(0, min(w.end, coreHi) - max(w.start, coreLo)) }
        func distance(_ w: (start: Double, end: Double)) -> Double { max(0, w.start - coreHi, coreLo - w.end) }
        let candidates = workouts.filter {
            $0.end > $0.start && $0.end - $0.start <= maxRecordedMinutes * 60 && distance($0) <= matchSlack
        }
        let best = candidates.max { a, b in
            let oa = overlap(a), ob = overlap(b)
            return oa != ob ? oa < ob : distance(a) > distance(b)
        }
        if let best { return WodTimeWindow(start: best.start, end: best.end, recorded: true) }
        return WodTimeWindow(start: loggedTs, end: loggedTs + duration, recorded: false)
    }
}

/// The glucose chart of one WOD, on a clock where 0 is the WOD's start.
public struct WodGlucoseTimeline: Equatable, Sendable {

    public struct Reading: Equatable, Sendable, Identifiable {
        /// Minutes from the WOD's start (negative before it).
        public let minutes: Double
        public let mgdl: Double
        /// Readings of one segment are drawn joined; a CGM gap starts a new one.
        public let segment: Int
        /// Unix seconds.
        public let ts: Double
        public var id: Double { ts }
    }

    /// Carbs (grams) or bolus insulin (units) taken close together, as one marker.
    public struct Event: Equatable, Sendable, Identifiable {
        public let minutes: Double
        public let amount: Double
        public let ts: Double
        public var id: Double { ts }
    }

    /// A point of the filled area below `lowThreshold`: readings clamped to it, plus the points where the
    /// trace crosses it, so the fill ends exactly where the line crosses the threshold.
    public struct AreaPoint: Equatable, Sendable, Identifiable {
        public let minutes: Double
        public let mgdl: Double
        public let segment: Int
        public var id: String { "\(segment):\(minutes)" }
    }

    /// An x-axis tick, counted from the WOD: whole hours before its start, or after its end (the window
    /// runs `hoursBefore` before the start to `hoursAfter` after the end, as the panel's title says).
    public struct Tick: Equatable, Sendable {
        public enum Anchor: Equatable, Sendable { case beforeStart, afterEnd }
        public let minutes: Double
        public let hours: Int
        public let anchor: Anchor
    }

    public static let hoursBefore = 2.0
    public static let hoursAfter = 4.0
    /// A gap between readings longer than this breaks the line (5-minute CGMs miss one or two now and then).
    public static let maxGapMinutes = 15.0
    /// Events closer than this share one marker, their amounts summed.
    public static let mergeMinutes = 20.0
    public static let lowThreshold = 70.0

    public let window: WodTimeWindow
    public let readings: [Reading]
    public let nadir: Reading?
    /// The area below `lowThreshold`, for the segments that dip below it (empty when none does).
    public let lowArea: [AreaPoint]
    /// Minutes the trace spent below `lowThreshold`.
    public let minutesBelowLow: Double
    public let carbs: [Event]
    public let boluses: [Event]
    public let ticks: [Tick]
    /// Minutes shown: `hoursBefore` before the start to `hoursAfter` after the end.
    public let xDomain: ClosedRange<Double>
    /// mg/dL shown: at least 50…200 (so the 70–180 band reads) and every reading, never clipping a low.
    public let yDomain: ClosedRange<Double>

    public init(window: WodTimeWindow, readings: [GlucoseReading], carbs: [CarbEntry], insulin: [InsulinEntry]) {
        self.window = window
        let from = window.start - Self.hoursBefore * 3_600
        let to = window.end + Self.hoursAfter * 3_600
        func minutes(_ ts: Double) -> Double { (ts - window.start) / 60 }

        var points: [Reading] = []
        var segment = 0
        var previous: Double?
        for r in readings.filter({ $0.ts >= from && $0.ts <= to }).sorted(by: { $0.ts < $1.ts }) {
            if let p = previous, r.ts - p > Self.maxGapMinutes * 60 { segment += 1 }
            points.append(Reading(minutes: minutes(r.ts), mgdl: r.mgdl, segment: segment, ts: r.ts))
            previous = r.ts
        }
        self.readings = points
        self.nadir = points.min { $0.mgdl < $1.mgdl }

        let low = Self.lowThreshold
        var area: [AreaPoint] = []
        for seg in Set(points.filter { $0.mgdl < low }.map(\.segment)).sorted() {
            let run = points.filter { $0.segment == seg }
            for (i, p) in run.enumerated() {
                area.append(AreaPoint(minutes: p.minutes, mgdl: min(p.mgdl, low), segment: seg))
                guard run.indices.contains(i + 1) else { continue }
                let q = run[i + 1]
                let f = (low - p.mgdl) / (q.mgdl - p.mgdl)
                if (p.mgdl < low) != (q.mgdl < low), f > 0, f < 1 {
                    area.append(AreaPoint(minutes: p.minutes + f * (q.minutes - p.minutes), mgdl: low, segment: seg))
                }
            }
        }
        self.lowArea = area

        // A low reading counts until the next reading of its segment; the last one before a gap (or the
        // end) counts one ordinary 5-minute CGM interval.
        var below = 0.0
        for (i, r) in points.enumerated() where r.mgdl < Self.lowThreshold {
            let next = points.indices.contains(i + 1) && points[i + 1].segment == r.segment
                ? points[i + 1].minutes - r.minutes : 5
            below += next
        }
        self.minutesBelowLow = below

        func merged(_ events: [(ts: Double, amount: Double)]) -> [Event] {
            var out: [Event] = []
            for e in events.filter({ $0.ts >= from && $0.ts <= to && $0.amount > 0 }).sorted(by: { $0.ts < $1.ts }) {
                if let first = out.last, e.ts - first.ts <= Self.mergeMinutes * 60 {
                    out[out.count - 1] = Event(minutes: first.minutes, amount: first.amount + e.amount, ts: first.ts)
                } else {
                    out.append(Event(minutes: minutes(e.ts), amount: e.amount, ts: e.ts))
                }
            }
            return out
        }
        self.carbs = merged(carbs.map { ($0.ts, $0.grams) })
        self.boluses = merged(insulin.filter(\.bolus).map { ($0.ts, $0.units) })

        let duration = window.durationMinutes
        self.xDomain = (-Self.hoursBefore * 60)...(duration + Self.hoursAfter * 60)
        var ticks: [Tick] = []
        for h in stride(from: Int(Self.hoursBefore), through: 1, by: -1) {
            ticks.append(Tick(minutes: Double(-h * 60), hours: h, anchor: .beforeStart))
        }
        for h in 1...Int(Self.hoursAfter) {
            ticks.append(Tick(minutes: duration + Double(h * 60), hours: h, anchor: .afterEnd))
        }
        self.ticks = ticks

        let lowest = points.map(\.mgdl).min() ?? 70, highest = points.map(\.mgdl).max() ?? 180
        let lower = (min(55, lowest - 8) / 10).rounded(.down) * 10
        let upper = (max(200, highest + 12) / 20).rounded(.up) * 20
        self.yDomain = lower...upper
    }
}
