import Foundation

// FitnessAgeEngine.swift — on-device "Fitness Age" from resting HR + activity + profile.
//
// INDEPENDENT implementation of published, peer-reviewed methods (NOT medical advice; a fitness
// comparison, never a "biological age"):
//   • VO₂max estimate: Nes et al. 2011 HUNT non-exercise model, WAIST-CIRCUMFERENCE variant — the
//     CONFIRMED original (Nes 2011, Med Sci Sports Exerc 43(11):2024-2030; coefficients reproduced
//     verbatim in JAHA/Ball State 2020, PMC7428991, and corroborated by CERG/NTNU). SEE ≈ 5.70 (men) /
//     5.14 (women). (The BMI-variant coefficients that circulate from a 2019 secondary source were NOT
//     reliably confirmable against the original and are deliberately NOT used here.)
//   • Physical-activity index: HUNT1 PA-Q (Kurtze 2008), frequency×intensity×duration ∈ [0, 15];
//     NOOP has no questionnaire, so it RECONSTRUCTS each factor from measured weekly signals.
//   • Fitness Age: invert the SAME Nes equation self-consistently — the normative curve is the Nes
//     model at population-reference resting HR and PA-index. The body term (waist) appears in both the
//     user's estimate and the normative curve, so it CANCELS: Fitness Age depends only on how the
//     user's resting HR and activity compare to a reference-fit peer of their age. This means the
//     headline number needs no body measurement at all, and an average-fitness person maps to their
//     own chronological age by construction. (We do NOT mix in a different population's reference
//     curve — e.g. the US FRIEND equation — because the scale offset would bias everyone by ~15 yr.)
//
// All numbers below are literal published coefficients. Do not change without re-verifying the source.
public enum FitnessAgeEngine {

    // MARK: - Nes 2011 waist-circumference coefficients (JAHA PMC7428991, confirmed vs CERG)
    // VO₂max = intercept − ageC·age + paiC·PA − wcC·waist − rhrC·RHR
    static let menIntercept = 100.27, menAge = 0.296, menWC = 0.369, menRHR = 0.155, menPAI = 0.226
    static let womenIntercept = 74.74, womenAge = 0.247, womenWC = 0.259, womenRHR = 0.114, womenPAI = 0.198
    public static let seeMen = 5.70, seeWomen = 5.14

    // MARK: - Normative reference point (the "average peer" the Fitness Age compares against)
    /// Population-reference resting HR (bpm): an average healthy adult. At this RHR + paiReference a
    /// person's Fitness Age equals their chronological age by construction.
    public static let restingHRReference = 65.0
    /// Population-reference PA-index (0–15): ≈ "moderately active, a few sessions a week".
    public static let paiReference = 5.0

    /// Displayed uncertainty band (years) — a presentation constant; the per-reading Nes SEE (≈5–6
    /// ml/kg/min over the ~0.3/yr age slope) is far wider, so we compute on rolling 7-day medians and
    /// show a conservative fixed ±band with a "fitness comparison, not a biological age" disclaimer.
    public static let displayBandYears = 5.0
    public static let minAge = 20.0, maxAge = 80.0

    private static func isFemale(_ sex: String) -> Bool { sex.lowercased() == "female" }

    /// Coefficient tuple for the user's sex (intercept, ageC, wcC, rhrC, paiC). Non-binary uses men's.
    private static func coeffs(_ sex: String) -> (Double, Double, Double, Double, Double) {
        isFemale(sex)
            ? (womenIntercept, womenAge, womenWC, womenRHR, womenPAI)
            : (menIntercept, menAge, menWC, menRHR, menPAI)
    }

    /// Body-mass index from metric height/weight (used by callers; not required for Fitness Age).
    public static func bmi(weightKg: Double, heightCm: Double) -> Double {
        let m = heightCm / 100.0
        guard m > 0 else { return 0 }
        return weightKg / (m * m)
    }

    /// Nes 2011 waist-variant VO₂max (ml/kg/min). Optional display metric — needs a waist measurement.
    public static func estimateVO2max(age: Double, sex: String, waistCm: Double,
                                      restingHR: Double, paIndex: Double) -> Double {
        let (intercept, ageC, wcC, rhrC, paiC) = coeffs(sex)
        return intercept - ageC*age + paiC*paIndex - wcC*waistCm - rhrC*restingHR
    }

    /// Self-consistent Fitness Age (years, clamped [20,80]). The waist term cancels, so this needs only
    /// age, sex, resting HR and the PA-index: `FA = age + (rhrC·(RHR−RHRref) − paiC·(PAI−PAIref)) / ageC`.
    public static func fitnessAge(age: Double, sex: String, restingHR: Double, paIndex: Double) -> Double {
        let (_, ageC, _, rhrC, paiC) = coeffs(sex)
        let fa = age + (rhrC*(restingHR - restingHRReference) - paiC*(paIndex - paiReference)) / ageC
        return min(maxAge, max(minAge, fa))
    }

    /// HUNT frequency score for the number of active days in the last 7. The HUNT PA-Q scores its answers
    /// never / less than once a week 0, once a week 1, 2–3 times a week 2.5, almost every day 5 (Kurtze 2008;
    /// coding as published by Nauman, Nes et al., PLoS One 2012, the HUNT resting-HR / VO₂peak study). Four
    /// days sits nearer "2–3 times" than "almost every day", so it scores 2.5.
    static func huntFrequencyScore(activeDaysPerWeek: Int) -> Double {
        switch activeDaysPerWeek {
        case ..<1:  return 0.0          // never / less than once a week
        case 1:     return 1.0          // once a week
        case 2...4: return 2.5          // 2–3 times a week
        default:    return 5.0          // 5+ days ≈ "almost every day"
        }
    }

    /// Reconstruct the HUNT PA-index (0–15 = frequency×intensity×duration) from measured weekly
    /// aggregates. Bucket edges mirror the HUNT1 PA-Q response options (Kurtze 2008):
    ///   frequency ∈ {0, 1, 2.5, 5}             ← active days in the last 7 (huntFrequencyScore)
    ///   intensity ∈ {1, 2, 3}                  ← share of active time at high intensity (HR zone 4–5)
    ///   duration  ∈ {0.10, 0.38, 0.75, 1.0}    ← average active minutes per active day
    public static func physicalActivityIndex(activeDaysPerWeek: Int,
                                             avgActiveMinutesPerDay: Double,
                                             highIntensityFraction: Double) -> Double {
        let frequency = huntFrequencyScore(activeDaysPerWeek: activeDaysPerWeek)
        let intensity: Double
        switch highIntensityFraction {
        case ..<0.15: intensity = 1.0       // easy, no real sweat
        case ..<0.5:  intensity = 2.0       // sweaty / breathless
        default:      intensity = 3.0       // near exhaustion
        }
        let duration: Double
        switch avgActiveMinutesPerDay {
        case ..<15:  duration = 0.10
        case ..<30:  duration = 0.38
        case ..<60:  duration = 0.75
        default:     duration = 1.0
        }
        if frequency == 0 { return 0 }
        return frequency * intensity * duration
    }

    /// PA-index (0–15) from NOOP's measured weekly load — the UNIVERSAL path the orchestrator uses
    /// (works on any device, since `strain` is computed from HR alone; HR-zone minutes only exist for
    /// CSV-importers). `strain` (0–100, TRIMP-based) already integrates intensity × duration, so we map
    /// the mean active-day strain straight to the HUNT intensity×duration PRODUCT (0–3) and multiply by
    /// the frequency factor — deliberately NOT re-deriving intensity and duration separately, which
    /// would double-count the same HR load. Calibrated so the reference peer (≈4 active days, mean
    /// strain ≈60) lands near PA-index 5.
    public static func physicalActivityIndexFromStrain(activeDaysPerWeek: Int,
                                                       meanActiveStrain: Double) -> Double {
        let frequency = huntFrequencyScore(activeDaysPerWeek: activeDaysPerWeek)
        if frequency == 0 { return 0 }
        let intensityDuration = min(3.0, max(0.0, meanActiveStrain / 30.0))   // strain 30→1, 60→2, 90→3
        return frequency * intensityDuration
    }

    /// Full Fitness Age from already-aggregated weekly inputs. Returns nil only if RHR or age is
    /// missing (the headline number needs nothing else). `vo2max` is filled only when a waist
    /// measurement is supplied; callers gate data-coverage (≥4 of 7 days) separately.
    public static func compute(age: Double, sex: String, restingHR: Double, paIndex: Double,
                               waistCm: Double? = nil, lowerConfidence: Bool = false) -> FitnessAgeResult? {
        guard age > 0, restingHR > 0 else { return nil }
        let fa = fitnessAge(age: age, sex: sex, restingHR: restingHR, paIndex: paIndex)
        let vo2: Double?
        if let w = waistCm, w > 0 {
            vo2 = estimateVO2max(age: age, sex: sex, waistCm: w, restingHR: restingHR, paIndex: paIndex)
        } else {
            vo2 = nil
        }
        let nb = sex.lowercased() != "male" && sex.lowercased() != "female"
        return FitnessAgeResult(
            vo2max: vo2, fitnessAge: fa, chronoAge: age, deltaYears: age - fa,
            bandYears: displayBandYears, lowerConfidence: lowerConfidence || nb)
    }
}

// MARK: - Daily VO₂max series (HUNT non-exercise model)
//
// VO₂max is an aerobic CAPACITY: it moves over weeks of training or detraining, not minute to minute, and no
// validated method turns a wrist strap's heart rate into a new VO₂max every few minutes without an external
// workload (speed or power), which a CrossFit class does not have. A value per 10-minute window would be invented
// noise. What can honestly be done more often is to RE-EVALUATE the estimate whenever new evidence lands (a new
// night's resting heart rate, a trained day) and to keep a real daily history of it.
//
// So the app recomputes it every 10 minutes and after every sync, and stores ONE point per day: the Nes et al.
// (Med Sci Sports Exerc 2011) waist-variant estimate above, on the 7 calendar days ending on that day: the median
// nightly resting heart rate (at least `minCoverageDays` nights, as `assessReadiness` requires) and the PA-index
// reconstructed from the window's strain, with the same "active day" rule the weekly Fitness Age uses. The
// model's standard error (`seeMen` / `seeWomen`, about 5 mL/kg/min) is far wider than a week-to-week change, so
// the series is read as a trend, not as a measurement.
extension FitnessAgeEngine {

    /// Calendar days in the window a daily estimate is computed on (the same week the Fitness Age rolls).
    public static let vo2maxWindowDays = 7
    /// Strain (0–100) from which a day counts as an ACTIVE day in the PA-index: the weekly Fitness Age's rule.
    public static let activeDayStrain = 30.0

    /// The inputs of one daily estimate: what the 7 days ending on a day contributed.
    public struct VO2maxWindow: Equatable, Sendable {
        public let restingHR: Double   // median of the window's nightly resting heart rates, bpm
        public let paIndex: Double     // HUNT PA-index (0–15) from the window's strain
        public let nights: Int         // nights with a resting heart rate in the window
        public let activeDays: Int     // days at or above `activeDayStrain`
        public init(restingHR: Double, paIndex: Double, nights: Int, activeDays: Int) {
            self.restingHR = restingHR; self.paIndex = paIndex
            self.nights = nights; self.activeDays = activeDays
        }
    }

    /// Standard error of the Nes 2011 waist model (mL/kg/min) for the sex's model (non-binary uses men's).
    public static func vo2maxStandardError(sex: String) -> Double {
        isFemale(sex) ? seeWomen : seeMen
    }

    /// What the 7 calendar days ending on `day` give the estimate, or nil with fewer than `minCoverageDays`
    /// nights of resting heart rate. Days are matched by calendar date, so a day with no row is simply absent
    /// from the window (never replaced by an older one). A day listed twice keeps its non-nil values.
    public static func vo2maxWindow(days: [(day: String, restingHR: Double?, strain: Double?)],
                                    endingOn day: String) -> VO2maxWindow? {
        guard let end = dayOrdinal(day) else { return nil }
        return window(dayInputs(days), endingOn: end)
    }

    /// One dated waist measurement: the "yyyy-MM-dd" day it was taken and its circumference in cm.
    public struct WaistMeasurement: Equatable, Sendable {
        public let day: String
        public let cm: Double
        public init(day: String, cm: Double) { self.day = day; self.cm = cm }
    }

    /// The waist a day's estimate uses: the latest measurement taken on or before `day`, so a new
    /// measurement counts from its own day on and never rewrites the days before it (a waist that went down
    /// shows as an improvement instead of moving the whole history). Before the first measurement, the first
    /// one: the model needs a waist, and the weeks before the first entry are better estimated with it than
    /// left empty. Several measurements on one day count as their mean. nil without a positive measurement.
    public static func waistCm(on day: String, from measurements: [WaistMeasurement]) -> Double? {
        var byDay: [String: (sum: Double, n: Double)] = [:]
        for m in measurements where m.cm > 0 && dayOrdinal(m.day) != nil {
            let acc = byDay[m.day] ?? (sum: 0, n: 0)
            byDay[m.day] = (sum: acc.sum + m.cm, n: acc.n + 1)
        }
        let days = byDay.keys.sorted()
        guard let first = days.first, let firstAcc = byDay[first] else { return nil }
        guard let latest = days.last(where: { $0 <= day }), let acc = byDay[latest] else {
            return firstAcc.sum / firstAcc.n
        }
        return acc.sum / acc.n
    }

    /// One HUNT VO₂max estimate per day (mL/kg/min), oldest first: for every listed day with at least
    /// `minCoverageDays` resting-HR nights among the 7 calendar days ending on it, the Nes estimate with that
    /// window's median resting heart rate and strain-based PA-index, and the waist measured by that day
    /// (`waistCm(on:from:)`). Empty without a positive age and a waist measurement. A day with no resting HR or
    /// strain of its own may still be listed (e.g. today, before its night is scored): it then reads the six
    /// days before it.
    public static func dailyVO2maxSeries(days: [(day: String, restingHR: Double?, strain: Double?)],
                                         age: Double, sex: String,
                                         waists: [WaistMeasurement]) -> [(day: String, vo2max: Double)] {
        guard age > 0, waists.contains(where: { $0.cm > 0 }) else { return [] }
        let inputs = dayInputs(days)
        return inputs.keys.sorted().compactMap { ordinal -> (day: String, vo2max: Double)? in
            let day = dayString(ordinal: ordinal)
            guard let w = window(inputs, endingOn: ordinal),
                  let waist = waistCm(on: day, from: waists) else { return nil }
            let v = estimateVO2max(age: age, sex: sex, waistCm: waist,
                                   restingHR: w.restingHR, paIndex: w.paIndex)
            guard v.isFinite else { return nil }
            return (day: day, vo2max: v)
        }
    }

    /// The same series with one waist for every day.
    public static func dailyVO2maxSeries(days: [(day: String, restingHR: Double?, strain: Double?)],
                                         age: Double, sex: String,
                                         waistCm: Double) -> [(day: String, vo2max: Double)] {
        dailyVO2maxSeries(days: days, age: age, sex: sex,
                          waists: [WaistMeasurement(day: "1970-01-01", cm: waistCm)])
    }

    /// Mean of the points inside the `windowDays` calendar days ending on each point's day (the point included),
    /// oldest first: the smoothed line drawn over the daily points. Points on an unparseable day are dropped.
    public static func rollingMean(_ series: [(day: String, value: Double)],
                                   windowDays: Int = 7) -> [(day: String, value: Double)] {
        guard windowDays > 0 else { return [] }
        let pts = series.compactMap { p -> (ordinal: Int, value: Double)? in
            dayOrdinal(p.day).map { (ordinal: $0, value: p.value) }
        }
        .sorted { $0.ordinal < $1.ordinal }
        return pts.indices.map { i in
            var sum = 0.0, n = 0.0
            var j = i
            while j >= 0, pts[j].ordinal > pts[i].ordinal - windowDays {
                sum += pts[j].value; n += 1; j -= 1
            }
            return (day: dayString(ordinal: pts[i].ordinal), value: sum / n)
        }
    }

    /// The "yyyy-MM-dd" day `n` calendar days after `day` (before when negative), nil for an unparseable day.
    public static func shiftDay(_ day: String, by n: Int) -> String? {
        dayOrdinal(day).map { dayString(ordinal: $0 + n) }
    }

    // MARK: Calendar arithmetic on "yyyy-MM-dd" strings (no time zone involved: a day is just a date)

    private struct DayInputs { var restingHR: Double?; var strain: Double? }

    private static func dayInputs(_ days: [(day: String, restingHR: Double?, strain: Double?)]) -> [Int: DayInputs] {
        var out: [Int: DayInputs] = [:]
        for d in days {
            guard let o = dayOrdinal(d.day) else { continue }
            var cur = out[o] ?? DayInputs()
            if let r = d.restingHR, r.isFinite, r > 0 { cur.restingHR = r }
            if let s = d.strain, s.isFinite, s >= 0 { cur.strain = s }
            out[o] = cur
        }
        return out
    }

    private static func window(_ inputs: [Int: DayInputs], endingOn end: Int) -> VO2maxWindow? {
        var rhrs: [Double] = []
        var activeStrains: [Double] = []
        for o in (end - (vo2maxWindowDays - 1))...end {
            guard let d = inputs[o] else { continue }
            if let r = d.restingHR { rhrs.append(r) }
            if let s = d.strain, s >= activeDayStrain { activeStrains.append(s) }
        }
        guard rhrs.count >= minCoverageDays, let rhr = VO2maxEngine.median(rhrs) else { return nil }
        let meanActive = activeStrains.isEmpty ? 0 : activeStrains.reduce(0, +) / Double(activeStrains.count)
        let pa = physicalActivityIndexFromStrain(activeDaysPerWeek: activeStrains.count,
                                                 meanActiveStrain: meanActive)
        return VO2maxWindow(restingHR: rhr, paIndex: pa, nights: rhrs.count, activeDays: activeStrains.count)
    }

    /// Days since 1970-01-01 of a proleptic-Gregorian "yyyy-MM-dd" (Hinnant's days_from_civil), nil if malformed.
    private static func dayOrdinal(_ day: String) -> Int? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12                       // March = 0
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The inverse of `dayOrdinal` (Hinnant's civil_from_days).
    private static func dayString(ordinal: Int) -> String {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
    }
}

// MARK: - Readiness checklist
//
// Transparency over a black-box number: show the user exactly which inputs we have, grouped by what
// each one unlocks, and a single confidence verdict. Weight/height/waist deliberately sit under "your
// VO₂max number" — NOT under the Fitness Age — because the body term cancels out of the age (see the
// engine doc); claiming weight sharpens the age would be dishonest. The age is driven by age, sex, and
// the COVERAGE of resting-HR + activity over the last 7 days.

public enum FitnessReadinessStatus: String, Sendable { case satisfied, partial, missing }

/// What a given input affects — so the checklist can be honest about its impact.
public enum FitnessReadinessRole: String, Sendable {
    case drivesAge          // required for / sharpens the headline Fitness Age
    case unlocksVO2max      // only powers the separate VO₂max estimate
}

public struct FitnessReadinessItem: Equatable, Sendable {
    public let key: String
    public let label: String
    public let status: FitnessReadinessStatus
    public let required: Bool        // true → the number can't be computed without it
    public let role: FitnessReadinessRole
    public let detail: String        // short hint, e.g. "4 of last 7 nights"
    public init(key: String, label: String, status: FitnessReadinessStatus,
                required: Bool, role: FitnessReadinessRole, detail: String) {
        self.key = key; self.label = label; self.status = status
        self.required = required; self.role = role; self.detail = detail
    }
}

public enum FitnessAgeConfidence: String, Sendable {
    case ready      // everything we need, good coverage
    case estimate   // computes, but partial coverage — a softer claim
    case notReady   // can't compute yet (missing a required input)
}

public struct FitnessAgeReadiness: Equatable, Sendable {
    public let items: [FitnessReadinessItem]
    public let confidence: FitnessAgeConfidence
    public var canCompute: Bool { confidence != .notReady }
    public init(items: [FitnessReadinessItem], confidence: FitnessAgeConfidence) {
        self.items = items; self.confidence = confidence
    }
}

extension FitnessAgeEngine {
    /// Minimum nights of resting-HR before the headline can be computed at all.
    public static let minCoverageDays = 4
    /// Coverage at/above which an input reads as fully satisfied (a "confident" week).
    public static let goodCoverageDays = 6

    private static func coverageStatus(_ days: Int, floor: Int) -> FitnessReadinessStatus {
        if days >= goodCoverageDays { return .satisfied }
        if days >= floor || days > 0 { return .partial }
        return .missing
    }

    /// Build the readiness checklist + overall confidence from the inputs we have. The orchestrator
    /// passes profile-completeness flags and the 7-day coverage counts.
    public static func assessReadiness(hasAge: Bool, hasSex: Bool,
                                       rhrDays: Int, activityDays: Int,
                                       hasHeightWeight: Bool, hasWaist: Bool) -> FitnessAgeReadiness {
        let items: [FitnessReadinessItem] = [
            FitnessReadinessItem(key: "age", label: "Your age",
                status: hasAge ? .satisfied : .missing, required: true, role: .drivesAge,
                detail: hasAge ? "Set" : "Add it in Settings"),
            FitnessReadinessItem(key: "sex", label: "Biological sex",
                status: hasSex ? .satisfied : .missing, required: true, role: .drivesAge,
                detail: hasSex ? "Set" : "Add it in Settings"),
            FitnessReadinessItem(key: "rhr", label: "Resting heart rate",
                status: coverageStatus(rhrDays, floor: minCoverageDays), required: true, role: .drivesAge,
                detail: "\(rhrDays) of last 7 nights"),
            FitnessReadinessItem(key: "activity", label: "Recent activity",
                status: coverageStatus(activityDays, floor: minCoverageDays), required: false, role: .drivesAge,
                detail: "\(activityDays) of last 7 days"),
            FitnessReadinessItem(key: "bodyMetrics", label: "Height & weight",
                status: hasHeightWeight ? .satisfied : .missing, required: false, role: .unlocksVO2max,
                detail: hasHeightWeight ? "Unlocks your VO₂max" : "Add to also see VO₂max"),
            FitnessReadinessItem(key: "waist", label: "Waist (optional)",
                status: hasWaist ? .satisfied : .missing, required: false, role: .unlocksVO2max,
                detail: hasWaist ? "Sharpens VO₂max" : "Optional - sharpens VO₂max"),
        ]
        let confidence: FitnessAgeConfidence
        if !hasAge || !hasSex || rhrDays < minCoverageDays {
            confidence = .notReady
        } else if rhrDays >= goodCoverageDays && activityDays >= goodCoverageDays {
            confidence = .ready
        } else {
            confidence = .estimate
        }
        return FitnessAgeReadiness(items: items, confidence: confidence)
    }
}

/// A computed Fitness Age plus the inputs needed to present it honestly. `vo2max` is optional — the
/// headline Fitness Age does not require a body measurement; the VO₂max estimate does (a waist entry).
public struct FitnessAgeResult: Equatable, Sendable {
    public let vo2max: Double?         // estimated VO₂max (ml/kg/min), nil without a waist measurement
    public let fitnessAge: Double      // years, clamped [20, 80]
    public let chronoAge: Double       // the user's calendar age
    public let deltaYears: Double      // chronoAge − fitnessAge (positive = younger than your age)
    public let bandYears: Double       // ± presentation band
    public let lowerConfidence: Bool   // true for non-binary (sex-specific model) or sparse data

    public init(vo2max: Double?, fitnessAge: Double, chronoAge: Double,
                deltaYears: Double, bandYears: Double, lowerConfidence: Bool) {
        self.vo2max = vo2max; self.fitnessAge = fitnessAge; self.chronoAge = chronoAge
        self.deltaYears = deltaYears; self.bandYears = bandYears; self.lowerConfidence = lowerConfidence
    }
}
