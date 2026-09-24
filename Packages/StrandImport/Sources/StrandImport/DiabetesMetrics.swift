import Foundation

// MARK: - Diabetes daily KPIs (read-only, informational)
//
// Pure, platform-free reductions of Apple Health diabetes samples (glucose, insulin, carbs)
// written by an automated-insulin-delivery app such as Loop. Kept OUT of `HealthKitBridge`
// on purpose: the bridge only fetches raw samples and hands them here, so all the clinical
// arithmetic (Time-in-Range, variability, hypo events, overnight lows, basal/bolus split,
// GMI, glucose around workouts) lives in one testable place — the same "single source of
// truth" discipline `AppleHealthAggregator` follows.
//
// These are INFORMATIONAL trends only. Apple Health lags the CGM/pump, so nothing here is a
// treatment surface; the CGM app and Loop remain the source of truth for any dosing decision.
// All glucose values are in mg/dL, insulin in international units (U), attributed to the
// sample's own local civil day (the caller pre-buckets each reading's `day`).

/// One glucose reading, already bucketed into its local civil day by the caller.
public struct GlucoseReading: Sendable, Equatable {
    /// Epoch seconds — used only for the workout-window intersection (ordering within a day
    /// is the array order the caller supplies, which must be ascending by time).
    public let ts: Double
    /// `yyyy-MM-dd` local civil day the reading belongs to.
    public let day: String
    /// Local minute-of-day 0…1439, used to isolate the overnight window (00:00–06:00).
    public let minutesLocal: Int
    /// Blood glucose in mg/dL.
    public let mgdl: Double

    public init(ts: Double, day: String, minutesLocal: Int, mgdl: Double) {
        self.ts = ts; self.day = day; self.minutesLocal = minutesLocal; self.mgdl = mgdl
    }
}

/// One insulin-delivery sample, bucketed into its local civil day, tagged by delivery reason.
public struct InsulinDose: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case basal, bolus, unknown }
    public let day: String
    public let units: Double
    public let kind: Kind
    public init(day: String, units: Double, kind: Kind) {
        self.day = day; self.units = units; self.kind = kind
    }
}

/// A workout window for the glucose-around-exercise linkage, in epoch seconds, attributed to
/// its local civil day.
public struct WorkoutWindow: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let day: String
    public init(start: Double, end: Double, day: String) {
        self.start = start; self.end = end; self.day = day
    }
}

/// Per-day glucose KPIs. Percentages are 0–100. Fields that need readings that weren't present
/// stay `nil` (never a fabricated 0) so the UI can honestly show "not available".
public struct GlucoseDayStats: Sendable, Equatable {
    public let day: String
    public let readings: Int
    public let mean: Double
    public let min: Double
    public let max: Double
    /// Time-in-range 70–180 mg/dL, as a percentage of the day's readings.
    public let tirPct: Double
    /// Time-below-range < 70 mg/dL (includes the severe band below).
    public let tbrPct: Double
    /// Time-below-range severe < 54 mg/dL.
    public let tbrSeverePct: Double
    /// Time-above-range > 180 mg/dL (includes the very-high band below).
    public let tarPct: Double
    /// Time-above-range very high > 250 mg/dL.
    public let tarHighPct: Double
    /// Coefficient of variation = SD / mean × 100 (sample SD). `nil` with fewer than 2 readings.
    public let cvPct: Double?
    /// Count of hypoglycaemia events starting this day (consensus definition, see `HypoEvent`).
    public let hypoEvents: Int
    /// Mean glucose in the 00:00–06:00 local window; `nil` if no overnight readings.
    public let overnightMean: Double?
    /// Lowest glucose in the 00:00–06:00 local window; `nil` if no overnight readings.
    public let overnightMin: Double?

    public init(day: String, readings: Int, mean: Double, min: Double, max: Double,
                tirPct: Double, tbrPct: Double, tbrSeverePct: Double, tarPct: Double,
                tarHighPct: Double, cvPct: Double?, hypoEvents: Int,
                overnightMean: Double?, overnightMin: Double?) {
        self.day = day; self.readings = readings; self.mean = mean; self.min = min; self.max = max
        self.tirPct = tirPct; self.tbrPct = tbrPct; self.tbrSeverePct = tbrSeverePct
        self.tarPct = tarPct; self.tarHighPct = tarHighPct; self.cvPct = cvPct
        self.hypoEvents = hypoEvents; self.overnightMean = overnightMean; self.overnightMin = overnightMin
    }
}

/// Per-day insulin split. `total` sums every sample (basal + bolus + any without a reason tag),
/// so it matches the raw delivered dose even when some samples carry no reason metadata.
public struct InsulinDayStats: Sendable, Equatable {
    public let day: String
    public let basal: Double
    public let bolus: Double
    public let unknown: Double
    public var total: Double { basal + bolus + unknown }
    public init(day: String, basal: Double, bolus: Double, unknown: Double) {
        self.day = day; self.basal = basal; self.bolus = bolus; self.unknown = unknown
    }
}

/// Per-day glucose response around exercise: the lowest glucose seen inside any workout window
/// (extended by `postMinutes` to catch the acute post-exercise drop) and how many of those
/// readings were hypos (< 70). `minMgdl` is `nil` when no glucose fell inside a workout window.
public struct PostWorkoutGlucose: Sendable, Equatable {
    public let day: String
    public let minMgdl: Double?
    public let lows: Int
    public init(day: String, minMgdl: Double?, lows: Int) {
        self.day = day; self.minMgdl = minMgdl; self.lows = lows
    }
}

/// Clinical thresholds (mg/dL), defaulted to the international CGM consensus (Battelino 2019).
/// Exposed so a future mmol/L or per-user target could swap them without touching the maths.
public struct GlucoseThresholds: Sendable, Equatable {
    public let low: Double         // below-range boundary (default 70)
    public let severeLow: Double   // severe below-range (default 54)
    public let high: Double        // above-range boundary (default 180)
    public let veryHigh: Double    // very-high (default 250)
    public init(low: Double = 70, severeLow: Double = 54, high: Double = 180, veryHigh: Double = 250) {
        self.low = low; self.severeLow = severeLow; self.high = high; self.veryHigh = veryHigh
    }
    public static let standard = GlucoseThresholds()
}

/// A CGM hypoglycaemia event as the international consensus defines it (Battelino et al., Lancet Diabetes
/// Endocrinol 2023;11:42–57): at least 15 consecutive minutes below 70 mg/dL, ending only after at least 15
/// consecutive minutes at or above 70. Level 2 when it contains at least 15 consecutive minutes below
/// 54 mg/dL; extended when more than 120 consecutive minutes are below 70.
public struct HypoEvent: Sendable, Equatable {
    /// Epoch seconds of the first low minute.
    public let start: Double
    /// Epoch seconds the event ended (start of the 15-minute recovery), or the last reading before data
    /// stopped (`censored`).
    public let end: Double
    /// Lowest glucose in the event (mg/dL).
    public let nadir: Double
    /// 1 (below 70) or 2 (contains ≥ 15 consecutive minutes below 54).
    public let level: Int
    /// More than 120 consecutive minutes below 70.
    public let extended: Bool
    /// Data stopped before a 15-minute recovery was seen, so the end is the last known low.
    public let censored: Bool
    /// Began between 00:00 and 05:59 local time (the consensus nocturnal window).
    public let nocturnal: Bool

    public var durationMin: Double { (end - start) / 60 }

    public init(start: Double, end: Double, nadir: Double, level: Int, extended: Bool, censored: Bool,
                nocturnal: Bool) {
        self.start = start; self.end = end; self.nadir = nadir; self.level = level
        self.extended = extended; self.censored = censored; self.nocturnal = nocturnal
    }
}

/// The glucose response around one logged WOD (a workout NOOP itself stored, distinct from an Apple
/// Health workout). Computed from raw CGM readings in a window spanning a little before the workout to
/// a few hours after — the shape a Type-1 athlete cares about: where glucose started, how low it dipped
/// (exercise often drops it), where it ended, and whether it crossed into hypo.
public struct WodGlucoseResponse: Sendable, Equatable {
    public let count: Int
    public let startMgdl: Double        // reading at/just before the workout start (baseline)
    public let endMgdl: Double          // last reading in the window
    public let minMgdl: Double
    public let maxMgdl: Double
    public let nadirAfterMgdl: Double?  // lowest reading AFTER the workout ended (post-exercise low)
    public let anyLow: Bool             // any reading below the low threshold anywhere in the window
    public init(count: Int, startMgdl: Double, endMgdl: Double, minMgdl: Double, maxMgdl: Double,
                nadirAfterMgdl: Double?, anyLow: Bool) {
        self.count = count; self.startMgdl = startMgdl; self.endMgdl = endMgdl
        self.minMgdl = minMgdl; self.maxMgdl = maxMgdl
        self.nadirAfterMgdl = nadirAfterMgdl; self.anyLow = anyLow
    }
    /// End − start: net glucose change across the window (negative = a drop, common with training).
    public var deltaMgdl: Double { endMgdl - startMgdl }
}

/// One carbohydrate-intake entry from Apple Health, epoch-seconds timestamped, for placing carbs on a
/// workout timeline and splitting them into pre-/post-workout totals.
public struct CarbEntry: Sendable, Equatable {
    public let ts: Double
    public let grams: Double
    public init(ts: Double, grams: Double) { self.ts = ts; self.grams = grams }
}

/// One insulin-delivery entry from Apple Health, epoch-seconds timestamped, for placing insulin on a
/// workout timeline and totalling it pre/post. `bolus` is true for a bolus/correction dose, false for
/// basal.
public struct InsulinEntry: Sendable, Equatable {
    public let ts: Double
    public let units: Double
    public let bolus: Bool
    public init(ts: Double, units: Double, bolus: Bool) { self.ts = ts; self.units = units; self.bolus = bolus }
}

/// A GENERAL, non-personalised tendency of how a kind of training usually moves blood glucose. This is
/// education (physiology), never a prescription: the UI pairs it with a "not medical advice" note and
/// never turns it into a carb or insulin dose. Steady aerobic work tends to lower glucose (and can keep
/// lowering it for hours — the post-exercise hypo window); heavy strength/anaerobic efforts can push it
/// up transiently; mixed metcons do a bit of both.
public enum ExerciseGlycemicTendency: Sendable, Equatable {
    case lowers, raises, mixed, unknown
}

public enum DiabetesMetrics {

    /// Minute-of-day (exclusive) that ends the overnight window. 06:00 → 360.
    public static let overnightEndMinute = 6 * 60

    // MARK: Glucose

    /// Reduce glucose readings into per-day KPIs. Days with no readings simply don't appear in the
    /// result — the UI treats an absent day as "not available". Hypoglycaemia events follow the consensus
    /// definition (`hypoEvents(_:)`), attributed to the day each event starts.
    public static func glucoseDaily(_ readings: [GlucoseReading],
                                    thresholds: GlucoseThresholds = .standard) -> [String: GlucoseDayStats] {
        struct Acc {
            var vals: [Double] = []
            var inRange = 0, below = 0, belowSevere = 0, above = 0, aboveHigh = 0
            var overnight: [Double] = []
        }
        // Events are found on the whole series (they can straddle midnight), then counted on the day of
        // the reading they start at.
        let sorted = readings.sorted { $0.ts < $1.ts }
        var eventsByDay: [String: Int] = [:]
        for e in hypoEvents(sorted, low: thresholds.low, severeLow: thresholds.severeLow, tzOffsetSeconds: nil) {
            if let r = sorted.first(where: { $0.ts >= e.start }) ?? sorted.last { eventsByDay[r.day, default: 0] += 1 }
        }
        var byDay: [String: Acc] = [:]
        // Preserve first-seen day order isn't needed (dictionary output), but per-day order IS the
        // input order, which the caller guarantees ascending.
        for r in readings {
            var a = byDay[r.day] ?? Acc()
            a.vals.append(r.mgdl)
            if r.mgdl < thresholds.low {
                a.below += 1
                if r.mgdl < thresholds.severeLow { a.belowSevere += 1 }
            } else if r.mgdl > thresholds.high {
                a.above += 1
                if r.mgdl > thresholds.veryHigh { a.aboveHigh += 1 }
            } else {
                a.inRange += 1
            }
            if r.minutesLocal < overnightEndMinute { a.overnight.append(r.mgdl) }
            byDay[r.day] = a
        }

        var out: [String: GlucoseDayStats] = [:]
        for (day, a) in byDay {
            let n = a.vals.count
            guard n > 0 else { continue }
            let mean = a.vals.reduce(0, +) / Double(n)
            let lo = a.vals.min() ?? mean
            let hi = a.vals.max() ?? mean
            let pct = { (c: Int) in Double(c) / Double(n) * 100.0 }
            let cv: Double? = {
                guard n >= 2, mean > 0 else { return nil }
                let variance = a.vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
                return variance.squareRoot() / mean * 100.0
            }()
            out[day] = GlucoseDayStats(
                day: day, readings: n, mean: mean, min: lo, max: hi,
                tirPct: pct(a.inRange), tbrPct: pct(a.below), tbrSeverePct: pct(a.belowSevere),
                tarPct: pct(a.above), tarHighPct: pct(a.aboveHigh), cvPct: cv,
                hypoEvents: eventsByDay[day] ?? 0,
                overnightMean: a.overnight.isEmpty ? nil : a.overnight.reduce(0, +) / Double(a.overnight.count),
                overnightMin: a.overnight.min()
            )
        }
        return out
    }

    // MARK: Hypoglycaemia events (Battelino 2023)

    /// Grid step (minutes) the CGM trace is resampled to before counting consecutive minutes.
    public static let eventGridMinutes = 5
    /// Longest gap between readings that is bridged by linear interpolation (minutes); a longer gap is
    /// missing data. Both follow iglu's consensus-episode implementation (Broll et al., PLoS One 2021).
    public static let maxInterpolatedGapMinutes = 45
    /// Consecutive minutes below a threshold that start an event, and at or above it that end one.
    public static let eventMinutes = 15
    /// Consecutive minutes below 70 mg/dL beyond which an event is "extended".
    public static let extendedMinutes = 120

    /// Consensus hypoglycaemia events in a CGM trace (any order; re-sorted). The trace is resampled to a
    /// 5-minute grid, interpolating across gaps of up to 45 minutes; a longer gap is missing data, which
    /// closes an open event at its last known low (`censored`). `tzOffsetSeconds` places the nocturnal
    /// window (00:00–05:59 local); nil leaves every event `nocturnal == false`.
    public static func hypoEvents(_ readings: [GlucoseReading], low: Double = 70, severeLow: Double = 54,
                                  tzOffsetSeconds: Int?) -> [HypoEvent] {
        let grid = resampled(readings)
        guard !grid.isEmpty else { return [] }
        let level1 = episodes(grid, below: low)
        let level2 = episodes(grid, below: severeLow)
        let step = Double(eventGridMinutes * 60)
        return level1.map { e in
            let startTs = grid[e.first].ts, endTs = e.censored ? grid[e.last].ts + step : grid[e.endIndex].ts
            let nadir = grid[e.first...e.last].compactMap(\.mgdl).min() ?? low
            let isLevel2 = level2.contains { l2 in grid[l2.first].ts < endTs && grid[l2.last].ts >= startTs }
            let nocturnal = tzOffsetSeconds.map { off -> Bool in
                let local = ((Int(startTs) + off) % 86_400 + 86_400) % 86_400
                return local < 6 * 3_600
            } ?? false
            return HypoEvent(start: startTs, end: endTs, nadir: nadir, level: isLevel2 ? 2 : 1,
                             extended: e.longestLowRun * eventGridMinutes > extendedMinutes,
                             censored: e.censored, nocturnal: nocturnal)
        }
    }

    struct GridPoint { let ts: Double; let mgdl: Double? }

    /// The trace on a regular grid aligned to the epoch; nil where the surrounding readings are further
    /// apart than `maxInterpolatedGapMinutes`.
    static func resampled(_ readings: [GlucoseReading]) -> [GridPoint] {
        let r = readings.sorted { $0.ts < $1.ts }
        guard let first = r.first, let last = r.last else { return [] }
        let step = Double(eventGridMinutes * 60), maxGap = Double(maxInterpolatedGapMinutes * 60)
        var out: [GridPoint] = []
        var t = (first.ts / step).rounded(.up) * step
        var j = 0
        while t <= last.ts {
            while j + 1 < r.count && r[j + 1].ts <= t { j += 1 }
            let a = r[j]
            if a.ts == t {
                out.append(GridPoint(ts: t, mgdl: a.mgdl))
            } else if j + 1 < r.count, r[j + 1].ts - a.ts <= maxGap {
                let b = r[j + 1]
                out.append(GridPoint(ts: t, mgdl: a.mgdl + (b.mgdl - a.mgdl) * (t - a.ts) / (b.ts - a.ts)))
            } else {
                out.append(GridPoint(ts: t, mgdl: nil))
            }
            t += step
        }
        return out
    }

    struct Episode { let first: Int; let last: Int; let endIndex: Int; let censored: Bool; let longestLowRun: Int }

    /// Episodes below `threshold` on the grid: start at a run of ≥ 15 min below it, end at the start of
    /// the first run of ≥ 15 min at or above it (shorter recoveries stay inside the episode).
    static func episodes(_ g: [GridPoint], below threshold: Double) -> [Episode] {
        let need = eventMinutes / eventGridMinutes
        var out: [Episode] = []
        var i = 0
        while i < g.count {
            // Find the next qualifying low run.
            guard let v = g[i].mgdl, v < threshold else { i += 1; continue }
            var k = i
            while k < g.count, let x = g[k].mgdl, x < threshold { k += 1 }
            guard k - i >= need else { i = k; continue }
            // Inside an episode from i: walk until a recovery run of `need` points, or missing data.
            let start = i
            var lastLow = k - 1, longest = k - i, run = 0, censored = false, endIndex = -1
            var p = k
            while p < g.count {
                guard let x = g[p].mgdl else { censored = true; break }
                if x < threshold {
                    run = 0
                    var q = p
                    while q < g.count, let y = g[q].mgdl, y < threshold { q += 1 }
                    longest = max(longest, q - p)
                    lastLow = q - 1
                    p = q
                    continue
                }
                run += 1
                if run == need { endIndex = p - need + 1; break }
                p += 1
            }
            if endIndex < 0 { censored = true }
            out.append(Episode(first: start, last: lastLow, endIndex: max(endIndex, lastLow),
                               censored: censored, longestLowRun: longest))
            i = endIndex < 0 ? g.count : endIndex + need
        }
        return out
    }

    /// Events that started during a sleep window ([sleepStart, sleepEnd), epoch seconds) or in the
    /// consensus nocturnal window — the lows heart rate and HRV can miss (see `NocturnalHypoFlag`).
    public static func overnightEvents(_ events: [HypoEvent], sleepStart: Double?, sleepEnd: Double?) -> [HypoEvent] {
        events.filter { e in
            if e.nocturnal { return true }
            guard let s = sleepStart, let t = sleepEnd else { return false }
            return e.start < t && e.end > s
        }
    }

    /// GMI (Glucose Management Indicator) as a percentage from mean glucose in mg/dL.
    /// GMI(%) = 3.31 + 0.02392 × mean_mg/dL (Bergenstal 2018). `nil` for a non-positive mean.
    public static func gmiPercent(meanMgdl: Double) -> Double? {
        guard meanMgdl > 0 else { return nil }
        return 3.31 + 0.02392 * meanMgdl
    }

    // MARK: Insulin

    /// Sum insulin doses per day into basal / bolus / unknown. `total` (computed) sums all three.
    public static func insulinDaily(_ doses: [InsulinDose]) -> [String: InsulinDayStats] {
        struct Acc { var basal = 0.0, bolus = 0.0, unknown = 0.0 }
        var byDay: [String: Acc] = [:]
        for d in doses {
            var a = byDay[d.day] ?? Acc()
            switch d.kind {
            case .basal:   a.basal += d.units
            case .bolus:   a.bolus += d.units
            case .unknown: a.unknown += d.units
            }
            byDay[d.day] = a
        }
        var out: [String: InsulinDayStats] = [:]
        for (day, a) in byDay {
            out[day] = InsulinDayStats(day: day, basal: a.basal, bolus: a.bolus, unknown: a.unknown)
        }
        return out
    }

    // MARK: Glucose around exercise (Tier 4)

    /// The lowest glucose (and count of hypos) inside any workout window extended by `postMinutes`,
    /// per local day. Captures acute exercise-induced drops; delayed nocturnal lows are covered
    /// separately by the overnight fields of `glucoseDaily`. Attributed to the workout's own day.
    public static func postWorkoutGlucose(readings: [GlucoseReading], workouts: [WorkoutWindow],
                                          postMinutes: Double = 120,
                                          thresholds: GlucoseThresholds = .standard) -> [String: PostWorkoutGlucose] {
        guard !workouts.isEmpty, !readings.isEmpty else { return [:] }
        let pad = postMinutes * 60.0
        struct Acc { var min: Double?; var lows = 0 }
        var byDay: [String: Acc] = [:]
        for w in workouts {
            let lo = w.start
            let hi = w.end + pad
            for r in readings where r.ts >= lo && r.ts <= hi {
                var a = byDay[w.day] ?? Acc()
                a.min = a.min.map { Swift.min($0, r.mgdl) } ?? r.mgdl
                if r.mgdl < thresholds.low { a.lows += 1 }
                byDay[w.day] = a
            }
        }
        return byDay.reduce(into: [String: PostWorkoutGlucose]()) { dict, kv in
            dict[kv.key] = PostWorkoutGlucose(day: kv.key, minMgdl: kv.value.min, lows: kv.value.lows)
        }
    }

    /// Summarise the glucose response around ONE logged WOD. `readings` should be ascending by ts and
    /// already limited to the window (a little before `workoutStart` to a few hours after
    /// `workoutEnd`); it is re-sorted defensively. Returns nil when there are no readings.
    public static func wodGlucoseResponse(readings: [GlucoseReading],
                                          workoutStart: Double,
                                          workoutEnd: Double,
                                          thresholds: GlucoseThresholds = .standard) -> WodGlucoseResponse? {
        let sorted = readings.sorted { $0.ts < $1.ts }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        // Baseline = the last reading at/just before the workout began, else the earliest we have.
        let baseline = sorted.last(where: { $0.ts <= workoutStart }) ?? first
        let vals = sorted.map(\.mgdl)
        let after = sorted.filter { $0.ts >= workoutEnd }.map(\.mgdl)
        return WodGlucoseResponse(
            count: sorted.count,
            startMgdl: baseline.mgdl,
            endMgdl: last.mgdl,
            minMgdl: vals.min() ?? baseline.mgdl,
            maxMgdl: vals.max() ?? baseline.mgdl,
            nadirAfterMgdl: after.min(),
            anyLow: vals.contains { $0 < thresholds.low })
    }

    /// Total carbohydrate grams whose timestamp falls in `[from, to)`. Used to split intake into the
    /// pre-workout (fuelling) and post-workout (recovery/correction) windows.
    public static func carbsIn(_ carbs: [CarbEntry], from: Double, to: Double) -> Double {
        carbs.filter { $0.ts >= from && $0.ts < to }.reduce(0) { $0 + $1.grams }
    }

    /// Total insulin units in `[from, to)`. `bolusOnly` restricts the sum to bolus/correction doses.
    public static func insulinIn(_ doses: [InsulinEntry], from: Double, to: Double, bolusOnly: Bool = false) -> Double {
        doses.filter { $0.ts >= from && $0.ts < to && (!bolusOnly || $0.bolus) }.reduce(0) { $0 + $1.units }
    }

    /// Recent glucose trend as mg/dL PER HOUR (a plain secant over the last `lastMinutes` of readings):
    /// negative = falling, positive = rising. This is a descriptive trend, NOT a clinical forecast — it
    /// has no insulin-on-board / carb-on-board model. nil when there aren't two readings far enough apart.
    public static func glucoseSlopePerHour(_ readings: [GlucoseReading], lastMinutes: Double = 30) -> Double? {
        let sorted = readings.sorted { $0.ts < $1.ts }
        guard let last = sorted.last else { return nil }
        let cutoff = last.ts - lastMinutes * 60
        let window = sorted.filter { $0.ts >= cutoff }
        guard let first = window.first, window.count >= 2 else { return nil }
        let dtHours = (last.ts - first.ts) / 3600
        guard dtHours > 0 else { return nil }
        return (last.mgdl - first.mgdl) / dtHours
    }

    /// GENERAL glycemic tendency of a WOD's kind, from its type/format keywords (EN + IT). Education
    /// only — the caller must present it as such and never derive a dose from it.
    public static func glycemicTendency(type: String, format: String?) -> ExerciseGlycemicTendency {
        let t = type.lowercased()
        let s = t + " " + (format ?? "").lowercased()
        if s.contains("strength") || s.contains("weightlift") || s.contains("forza") || s.contains("lifting") {
            return .raises
        }
        if t.contains("run") || t.contains("row") || t.contains("hyrox") || t.contains("cardio")
            || t.contains("bike") || t.contains("cycl") || t.contains("swim") || t.contains("cors")
            || t.contains("vog") || t.contains("nuot") {
            return .lowers
        }
        if s.contains("amrap") || s.contains("emom") || s.contains("for time") || s.contains("interval")
            || s.contains("metcon") || t.contains("crossfit") {
            return .mixed
        }
        return .unknown
    }
}
