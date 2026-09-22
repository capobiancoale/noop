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
    /// Count of hypo excursions (a reading crossing below 70 from ≥ 70, or a day that opens < 70).
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

    /// Reduce glucose readings into per-day KPIs. Input MUST be ascending by time within each day
    /// (the hypo-excursion count relies on order); the caller sorts by sample date. Days with no
    /// readings simply don't appear in the result — the UI treats an absent day as "not available".
    public static func glucoseDaily(_ readings: [GlucoseReading],
                                    thresholds: GlucoseThresholds = .standard) -> [String: GlucoseDayStats] {
        struct Acc {
            var vals: [Double] = []
            var inRange = 0, below = 0, belowSevere = 0, above = 0, aboveHigh = 0
            var hypoEvents = 0
            var prevBelow = false
            var overnight: [Double] = []
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
                // New hypo excursion when we were not already below range.
                if !a.prevBelow { a.hypoEvents += 1 }
                a.prevBelow = true
            } else {
                if r.mgdl > thresholds.high {
                    a.above += 1
                    if r.mgdl > thresholds.veryHigh { a.aboveHigh += 1 }
                } else {
                    a.inRange += 1
                }
                a.prevBelow = false
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
                hypoEvents: a.hypoEvents,
                overnightMean: a.overnight.isEmpty ? nil : a.overnight.reduce(0, +) / Double(a.overnight.count),
                overnightMin: a.overnight.min()
            )
        }
        return out
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
