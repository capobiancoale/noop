import Foundation

// MARK: - Where a logged WOD sat in time
//
// The span the WOD screen's glucose and heart-rate timeline shades and counts from (see GlucoseTimeline.swift
// for the timeline itself). Informational only: nothing here suggests carbs or insulin.

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
