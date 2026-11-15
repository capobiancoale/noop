import Foundation

// GlucoseTrainingResponse.swift — how the athlete's glucose behaved around training sessions, per kind of
// session. DESCRIPTIVE ONLY: it reports what happened in the data. It never suggests insulin, carbohydrates
// or any therapy change, and it says "not enough sessions" rather than show a number from too few.
//
// Pure: no clock, no HealthKit, no time zone. Glucose comes in as (unix seconds, mg/dL) points; the night
// after a session comes in as two timestamps chosen by the caller (23:00 → 07:00 local), so the engine knows
// nothing about calendars.
//
// KIND RULE (`kind(sport:wodType:wodFormat:durationMin:)`), applied in this order:
//   1. strength — the WOD type is Weightlifting, or the WOD format is Strength, or (no WOD) the sport is a
//      lifting sport ("strength", "weightlifting", "powerlifting", "lifting").
//   2. long — a cardio / endurance sport (running, cycling, rowing, hiking, swimming) lasting >= 45 min, or
//      any non-strength session lasting >= 60 min.
//   3. metcon — everything else (CrossFit, For Time, AMRAP, EMOM, HIIT, functional, ...).
//
// PER SESSION (from its own glucose points, nearest reading must be within 15 min):
//   startValue    reading nearest the start
//   duringDelta   value at the end − value at the start
//   after2hDelta  value at end + 2 h − value at the end
//   minAfter6h    lowest reading in [end, end + 6 h]
//   nightLow      any reading < 70 mg/dL inside the caller's night window (nil when the night is not covered)
//   coverage      share of [start − 1 h, end + 6 h] covered by readings no more than 15 min apart
//   A session with coverage < 0.7 is EXCLUDED (counted, never averaged).
//
// PER KIND: means over the included sessions, a night count, and a curve of glucose at 15-min steps from
// −60 to +360 min after the session START (mean and 25th / 75th percentile, a step needing >= 3 sessions).
// Below `minSessions` included sessions the summary carries only the counts (`isReliable == false`).
// A mean built from fewer than `minSessions` values (a session too recent to have its 2-hour reading, say)
// is nil as well.

public enum GlucoseTrainingResponse {

    // MARK: Tunables

    /// Included sessions needed before any number is shown for a kind.
    public static let minSessions = 4
    /// Sessions with data needed at one curve step.
    public static let minCurveSessions = 3
    /// Share of the −1 h … +6 h window that must be covered, below which a session is excluded.
    public static let minCoverage = 0.7
    /// Readings further apart than this do not cover the time between them (seconds).
    public static let maxGapSeconds = 900.0
    /// Hypoglycaemia level 1 (Battelino et al., Diabetes Care 2019), mg/dL.
    public static let lowThreshold = 70.0
    /// Curve steps, minutes from the session start.
    public static let curveMinutes: [Int] = Array(stride(from: -60, through: 360, by: 15))
    /// Window read around a session, seconds before the start / after the end.
    public static let windowBefore = 3_600.0
    public static let windowAfter = 6.0 * 3_600

    // MARK: Types

    public enum Kind: String, CaseIterable, Sendable, Equatable {
        case strength, metcon, long
    }

    public struct Point: Equatable, Sendable {
        public let ts: Double
        public let mgdl: Double
        public init(ts: Double, mgdl: Double) { self.ts = ts; self.mgdl = mgdl }
    }

    public struct Session: Equatable, Sendable, Identifiable {
        public let id: String
        public let kind: Kind
        /// Unix seconds.
        public let start: Double
        public let end: Double
        public init(id: String, kind: Kind, start: Double, end: Double) {
            self.id = id; self.kind = kind; self.start = start; self.end = end
        }
        public var durationMin: Double { (end - start) / 60 }
    }

    /// The night after a session, two unix timestamps chosen by the caller.
    public struct NightWindow: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// Everything the engine needs for one session.
    public struct Input: Sendable {
        public let session: Session
        public let points: [Point]
        public let night: NightWindow?
        public init(session: Session, points: [Point], night: NightWindow?) {
            self.session = session; self.points = points; self.night = night
        }
    }

    public struct SessionResult: Equatable, Sendable {
        public let session: Session
        public let startValue: Double?
        public let duringDelta: Double?
        public let after2hDelta: Double?
        public let minAfter6h: Double?
        /// true: a reading below 70 in the night; false: the night was covered with none; nil: not observed.
        public let nightLow: Bool?
        public let coverage: Double
        /// Glucose at each of `curveMinutes` (nil where no reading brackets the step).
        public let curve: [Double?]
        public var included: Bool { coverage >= GlucoseTrainingResponse.minCoverage }
    }

    public struct CurvePoint: Equatable, Sendable {
        public let minute: Int
        public let mean: Double
        public let p25: Double
        public let p75: Double
        /// Sessions with data at this step.
        public let n: Int
    }

    public struct Summary: Equatable, Sendable {
        public let kind: Kind
        /// Sessions included (coverage >= 0.7).
        public let sessions: Int
        /// Sessions left out for too little glucose data.
        public let excluded: Int
        /// nil unless `isReliable` and at least `minSessions` sessions have the figure.
        public let meanDuringDelta: Double?
        public let meanAfter2hDelta: Double?
        public let nightsWithLow: Int
        public let nightsObserved: Int
        public let curve: [CurvePoint]
        /// Median length of the included sessions, minutes (nil when unreliable).
        public let medianDurationMin: Double?
        public var isReliable: Bool { sessions >= GlucoseTrainingResponse.minSessions }
        /// Whether the night count may be shown.
        public var nightsReliable: Bool { isReliable && nightsObserved >= GlucoseTrainingResponse.minSessions }
    }

    // MARK: Classifier

    private static let cardioStems = ["run", "cycl", "bik", "row", "hik", "swim"]
    private static let liftingStems = ["strength", "weightlift", "powerlift", "lifting"]

    /// Words of a sport name, lower-cased ("TraditionalStrengthTraining" and "Traditional Strength Training"
    /// both give traditional / strength / training).
    private static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prevLower = false
        for ch in s {
            if ch.isLetter {
                if ch.isUppercase && prevLower && !cur.isEmpty { out.append(cur.lowercased()); cur = "" }
                cur.append(ch)
                prevLower = ch.isLowercase
            } else {
                if !cur.isEmpty { out.append(cur.lowercased()); cur = "" }
                prevLower = false
            }
        }
        if !cur.isEmpty { out.append(cur.lowercased()) }
        return out
    }

    private static func sportMatches(_ sport: String?, stems: [String]) -> Bool {
        guard let sport else { return false }
        return words(sport).contains { w in stems.contains { w.hasPrefix($0) } }
    }

    public static func kind(sport: String?, wodType: String?, wodFormat: String?, durationMin: Double) -> Kind {
        func norm(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        let isWod = !norm(wodType).isEmpty || !norm(wodFormat).isEmpty
        if norm(wodType) == "weightlifting" || norm(wodFormat) == "strength" { return .strength }
        if !isWod && sportMatches(sport, stems: liftingStems) { return .strength }
        if durationMin >= 45 && (sportMatches(sport, stems: cardioStems) || sportMatches(wodType, stems: cardioStems)) {
            return .long
        }
        if durationMin >= 60 { return .long }
        return .metcon
    }

    // MARK: Per-session evaluation

    /// The reading nearest `t` within `maxGapSeconds`, from sorted points.
    static func nearest(_ pts: [Point], to t: Double, within: Double = maxGapSeconds) -> Double? {
        guard !pts.isEmpty else { return nil }
        var lo = 0, hi = pts.count
        while lo < hi { let m = (lo + hi) / 2; if pts[m].ts < t { lo = m + 1 } else { hi = m } }
        var best: Point?
        for i in [lo - 1, lo] where i >= 0 && i < pts.count {
            let d = abs(pts[i].ts - t)
            if d <= within, best == nil || d < abs(best!.ts - t) { best = pts[i] }
        }
        return best?.mgdl
    }

    /// Glucose at `t`, linearly interpolated between the two readings around it when they are no more than
    /// `maxGapSeconds` apart (or the exact reading); nil in a gap.
    static func interpolate(_ pts: [Point], at t: Double) -> Double? {
        guard !pts.isEmpty else { return nil }
        var lo = 0, hi = pts.count
        while lo < hi { let m = (lo + hi) / 2; if pts[m].ts < t { lo = m + 1 } else { hi = m } }
        if lo < pts.count, pts[lo].ts == t { return pts[lo].mgdl }
        guard lo > 0, lo < pts.count else { return nil }
        let a = pts[lo - 1], b = pts[lo]
        guard b.ts - a.ts <= maxGapSeconds, b.ts > a.ts else { return nil }
        return a.mgdl + (b.mgdl - a.mgdl) * (t - a.ts) / (b.ts - a.ts)
    }

    /// Share of [from, to] covered by consecutive readings no more than `maxGapSeconds` apart.
    static func coverage(_ pts: [Point], from: Double, to: Double) -> Double {
        guard to > from, pts.count >= 2 else { return 0 }
        var covered = 0.0
        for i in 1..<pts.count {
            let a = pts[i - 1].ts, b = pts[i].ts
            if b < from { continue }
            if a > to { break }
            if b - a <= maxGapSeconds { covered += max(0, min(b, to) - max(a, from)) }
        }
        return min(1, covered / (to - from))
    }

    public static func evaluate(_ input: Input) -> SessionResult {
        let s = input.session
        let pts = input.points.filter { $0.ts.isFinite && $0.mgdl.isFinite && $0.mgdl > 0 }.sorted { $0.ts < $1.ts }
        let cov = coverage(pts, from: s.start - windowBefore, to: s.end + windowAfter)
        let startV = nearest(pts, to: s.start)
        let endV = nearest(pts, to: s.end)
        let during: Double? = {
            guard let a = startV, let b = endV else { return nil }
            return b - a
        }()
        let after2h: Double? = {
            guard let e = endV, let later = nearest(pts, to: s.end + 7_200) else { return nil }
            return later - e
        }()
        let post = pts.filter { $0.ts >= s.end && $0.ts <= s.end + windowAfter }
        let night: Bool? = {
            guard let w = input.night, w.end > w.start else { return nil }
            let inNight = pts.filter { $0.ts >= w.start && $0.ts <= w.end }
            if inNight.contains(where: { $0.mgdl < lowThreshold }) { return true }
            return coverage(pts, from: w.start, to: w.end) >= minCoverage ? false : nil
        }()
        let curve = curveMinutes.map { interpolate(pts, at: s.start + Double($0) * 60) }
        return SessionResult(session: s, startValue: startV, duringDelta: during, after2hDelta: after2h,
                             minAfter6h: post.map(\.mgdl).min(), nightLow: night, coverage: cov, curve: curve)
    }

    // MARK: Per-kind summaries

    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// Percentile `p` (0...1) by linear interpolation between ranks (type 7).
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        if sorted.count == 1 { return sorted[0] }
        let r = p * Double(sorted.count - 1)
        let lo = Int(r.rounded(.down)), hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (r - Double(lo))
    }

    static func median(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : percentile(v.sorted(), 0.5)
    }

    public static func summary(kind: Kind, results: [SessionResult]) -> Summary {
        let mine = results.filter { $0.session.kind == kind }
        let used = mine.filter(\.included)
        let excluded = mine.count - used.count
        guard used.count >= minSessions else {
            return Summary(kind: kind, sessions: used.count, excluded: excluded, meanDuringDelta: nil,
                           meanAfter2hDelta: nil, nightsWithLow: 0, nightsObserved: 0, curve: [],
                           medianDurationMin: nil)
        }
        let during = used.compactMap(\.duringDelta)
        let after = used.compactMap(\.after2hDelta)
        let nights = used.compactMap(\.nightLow)
        var curve: [CurvePoint] = []
        for (i, m) in curveMinutes.enumerated() {
            let vals = used.compactMap { $0.curve[i] }.sorted()
            guard vals.count >= minCurveSessions, let mu = mean(vals) else { continue }
            curve.append(CurvePoint(minute: m, mean: mu, p25: percentile(vals, 0.25),
                                    p75: percentile(vals, 0.75), n: vals.count))
        }
        return Summary(kind: kind, sessions: used.count, excluded: excluded,
                       meanDuringDelta: during.count >= minSessions ? mean(during) : nil,
                       meanAfter2hDelta: after.count >= minSessions ? mean(after) : nil,
                       nightsWithLow: nights.filter { $0 }.count, nightsObserved: nights.count,
                       curve: curve, medianDurationMin: median(used.map { $0.session.durationMin }))
    }

    /// One summary per kind, in `Kind.allCases` order.
    public static func summaries(_ results: [SessionResult]) -> [Summary] {
        Kind.allCases.map { summary(kind: $0, results: results) }
    }

    /// Evaluate every input and summarise per kind.
    public static func analyze(_ inputs: [Input]) -> [Summary] {
        summaries(inputs.map(evaluate))
    }
}
