#if os(iOS)
import Foundation
import HealthKit
import WhoopStore
import StrandImport

/// Reads one window of Apple Health for `HealthKitBridge.sync` and turns it into store rows.
///
/// Every query hands back plain values built on HealthKit's own queue, and `rows(for:reads:)` is pure, so
/// the bridge runs the reads concurrently and the aggregation off the main actor: the app stays usable
/// while a year of history comes in. Windows follow `HealthImportPlan` (StrandImport), including the
/// margins that keep a windowed read identical, day for day, to one read of the whole period: statistics
/// and sleep start a day early, glucose 3 hours early and 24 hours late, and only the window's own days are
/// kept. ON-DEVICE ONLY: plain HealthKit reads of samples NOOP did not author.
enum HealthImportReader {

    /// HealthKit refuses to read while the iPhone is locked (its database is protected); the import then
    /// pauses instead of storing the empty answers as if there were no data.
    enum ReadError: Error { case locked }

    /// Which part of the data a read belongs to, for the progress line.
    enum Group {
        case heart, activity, body, diabetes, sleep, workouts

        var label: String {
            switch self {
            case .heart: return String(localized: "Heart")
            case .activity: return String(localized: "Activity")
            case .body: return String(localized: "Body")
            case .diabetes: return String(localized: "Glucose & Insulin")
            case .sleep: return String(localized: "Sleep")
            case .workouts: return String(localized: "Workouts")
            }
        }
    }

    /// One day's values from a statistics query (only the options the query asked for are filled).
    struct DayStats {
        var average: Double?
        var maximum: Double?
        var sum: Double?
        var mostRecent: Double?
        var isEmpty: Bool { average == nil && maximum == nil && sum == nil && mostRecent == nil }
    }

    /// One daily statistics query and where its values go. Pure closures, no captured state.
    struct StatSpec: @unchecked Sendable {
        let id: HKQuantityTypeIdentifier
        let unit: HKUnit
        let options: HKStatisticsOptions
        let group: Group
        let apply: (inout DayAgg, DayStats) -> Void
    }

    /// Everything read for one window, handed from the concurrent reads to the row builder once.
    struct WindowReads: @unchecked Sendable {
        var stats: [[String: DayStats]]          // aligned with `statSpecs()`
        var glucose: [GlucoseReading] = []
        var insulin: [InsulinDose] = []
        var sleep: [SleepStageSample] = []
        var workouts: [WorkoutRow] = []
    }

    /// The store rows of one window.
    struct WindowRows: @unchecked Sendable {
        let apple: [AppleDaily]
        let daily: [DailyMetric]
        let points: [MetricPoint]
        let workouts: [WorkoutRow]
    }

    /// The day's aggregate every read feeds (the fields of `AppleDailyAggregate` plus the sleep stages).
    struct DayAgg {
        var restingHr: Double?; var avgHr: Double?; var maxHr: Double?; var hrv: Double?
        var spo2: Double?; var respRate: Double?; var steps: Double?
        var activeKcal: Double?; var basalKcal: Double?; var vo2max: Double?
        var weightKg: Double?; var bodyFatPct: Double?; var leanMassKg: Double?; var bmi: Double?
        var asleepMin: Double?; var deepMin: Double?; var remMin: Double?; var coreMin: Double?
        var glucoseAvg: Double?; var glucoseMin: Double?; var glucoseMax: Double?
        var insulinTotal: Double?; var carbsG: Double?
        var bpSystolic: Double?; var bpDiastolic: Double?; var waterL: Double?; var waistCm: Double?
    }

    /// Source tag of workouts imported from Apple Health (matches `HealthKitBridge.appleWorkoutSource`).
    static let workoutSource = "apple-health"

    // MARK: - What is read

    /// The daily statistics queries, one per quantity (average and maximum heart rate share one query).
    /// Point readings (weight, lean mass, BMI, waist) keep the day's latest; SpO₂ and body fat come as a
    /// 0…1 fraction and are stored as percent.
    static func statSpecs() -> [StatSpec] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return [
            StatSpec(id: .restingHeartRate, unit: bpm, options: .discreteAverage, group: .heart) { $0.restingHr = $1.average },
            StatSpec(id: .heartRate, unit: bpm, options: [.discreteAverage, .discreteMax], group: .heart) {
                $0.avgHr = $1.average; $0.maxHr = $1.maximum
            },
            StatSpec(id: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), options: .discreteAverage, group: .heart) {
                $0.hrv = $1.average
            },
            StatSpec(id: .oxygenSaturation, unit: .percent(), options: .discreteAverage, group: .heart) {
                $0.spo2 = $1.average.map { $0 * 100 }
            },
            StatSpec(id: .respiratoryRate, unit: bpm, options: .discreteAverage, group: .heart) { $0.respRate = $1.average },
            StatSpec(id: .stepCount, unit: .count(), options: .cumulativeSum, group: .activity) { $0.steps = $1.sum },
            StatSpec(id: .activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, group: .activity) {
                $0.activeKcal = $1.sum
            },
            StatSpec(id: .basalEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, group: .activity) {
                $0.basalKcal = $1.sum
            },
            StatSpec(id: .vo2Max, unit: HKUnit(from: "ml/kg*min"), options: .discreteAverage, group: .activity) {
                $0.vo2max = $1.average
            },
            StatSpec(id: .bodyMass, unit: .gramUnit(with: .kilo), options: .discreteMostRecent, group: .body) {
                $0.weightKg = $1.mostRecent
            },
            StatSpec(id: .bodyFatPercentage, unit: .percent(), options: .discreteAverage, group: .body) {
                $0.bodyFatPct = $1.average.map { $0 * 100 }
            },
            StatSpec(id: .leanBodyMass, unit: .gramUnit(with: .kilo), options: .discreteMostRecent, group: .body) {
                $0.leanMassKg = $1.mostRecent
            },
            StatSpec(id: .bodyMassIndex, unit: .count(), options: .discreteMostRecent, group: .body) { $0.bmi = $1.mostRecent },
            StatSpec(id: .insulinDelivery, unit: .internationalUnit(), options: .cumulativeSum, group: .diabetes) {
                $0.insulinTotal = $1.sum
            },
            StatSpec(id: .dietaryCarbohydrates, unit: .gram(), options: .cumulativeSum, group: .diabetes) { $0.carbsG = $1.sum },
            StatSpec(id: .bloodPressureSystolic, unit: .millimeterOfMercury(), options: .discreteAverage, group: .body) {
                $0.bpSystolic = $1.average
            },
            StatSpec(id: .bloodPressureDiastolic, unit: .millimeterOfMercury(), options: .discreteAverage, group: .body) {
                $0.bpDiastolic = $1.average
            },
            StatSpec(id: .dietaryWater, unit: .liter(), options: .cumulativeSum, group: .body) { $0.waterL = $1.sum },
            StatSpec(id: .waistCircumference, unit: .meterUnit(with: .centi), options: .discreteMostRecent, group: .body) {
                $0.waistCm = $1.mostRecent
            },
        ]
    }

    // MARK: - HealthKit reads

    /// One daily statistics collection over the window. The predicate starts `leadInDays` early so a
    /// cumulative sample that began before the window's first midnight is split into that day as a
    /// whole-period read would split it; only the window's own days are enumerated.
    static func dailyStatistics(_ spec: StatSpec, window: HealthImportWindow,
                                store: HKHealthStore) async throws -> [String: DayStats] {
        guard let type = HKQuantityType.quantityType(forIdentifier: spec.id) else { return [:] }
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -HealthImportPlan.leadInDays, to: window.start) ?? window.start
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: window.end, options: .strictStartDate),
            notNoopAuthored(),
        ])
        let unit = spec.unit, options = spec.options
        let start = window.start, end = window.end
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: options, anchorDate: cal.startOfDay(for: from),
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                if let error, Self.isLocked(error) { cont.resume(throwing: ReadError.locked); return }
                var out: [String: DayStats] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    var d = DayStats()
                    if options.contains(.discreteAverage) { d.average = stats.averageQuantity()?.doubleValue(for: unit) }
                    if options.contains(.discreteMax) { d.maximum = stats.maximumQuantity()?.doubleValue(for: unit) }
                    if options.contains(.cumulativeSum) { d.sum = stats.sumQuantity()?.doubleValue(for: unit) }
                    if options.contains(.discreteMostRecent) { d.mostRecent = stats.mostRecentQuantity()?.doubleValue(for: unit) }
                    if !d.isEmpty { out[Self.dayString(stats.startDate)] = d }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// Raw CGM readings for a window plus its glucose margins (see `HealthImportPlan.glucoseLeadIn`).
    static func glucoseReadings(around window: HealthImportWindow, store: HKHealthStore) async throws -> [GlucoseReading] {
        try await glucoseReadings(from: window.start.addingTimeInterval(-HealthImportPlan.glucoseLeadIn),
                                  to: window.end.addingTimeInterval(HealthImportPlan.glucoseLeadOut), store: store)
    }

    /// Raw CGM readings over `[from, to)` ascending by time, each with its local day and minute-of-day, in
    /// mg/dL (HealthKit converts on read, so the value is unit-unambiguous).
    static func glucoseReadings(from: Date, to: Date, store: HKHealthStore) async throws -> [GlucoseReading] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return [] }
        let mgdL = HKUnit(from: "mg/dL")
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate),
            notNoopAuthored(),
        ])
        return try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error, Self.isLocked(error) { cont.resume(throwing: ReadError.locked); return }
                let cal = Calendar.current
                var out: [GlucoseReading] = []
                out.reserveCapacity(samples?.count ?? 0)
                for case let s as HKQuantitySample in samples ?? [] {
                    let c = cal.dateComponents([.hour, .minute], from: s.startDate)
                    out.append(GlucoseReading(ts: s.startDate.timeIntervalSince1970, day: Self.dayString(s.startDate),
                                              minutesLocal: (c.hour ?? 0) * 60 + (c.minute ?? 0),
                                              mgdl: s.quantity.doubleValue(for: mgdL)))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// Insulin-delivery samples starting inside the window, tagged basal/bolus/unknown by the HealthKit
    /// delivery-reason metadata, in international units, on the local day they start.
    static func insulinDoses(in window: HealthImportWindow, store: HKHealthStore) async throws -> [InsulinDose] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .insulinDelivery) else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictStartDate),
            notNoopAuthored(),
        ])
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error, Self.isLocked(error) { cont.resume(throwing: ReadError.locked); return }
                var out: [InsulinDose] = []
                for case let s as HKQuantitySample in samples ?? [] {
                    let kind: InsulinDose.Kind
                    if let num = s.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber,
                       let reason = HKInsulinDeliveryReason(rawValue: num.intValue) {
                        kind = reason == .basal ? .basal : .bolus
                    } else {
                        kind = .unknown
                    }
                    out.append(InsulinDose(day: Self.dayString(s.startDate),
                                           units: s.quantity.doubleValue(for: .internationalUnit()), kind: kind))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// Sleep-analysis samples overlapping the window and the day before it (a sample is credited to the day
    /// it ends, so the window's first day needs the ones that began the evening before).
    static func sleepSamples(for window: HealthImportWindow, store: HKHealthStore) async throws -> [SleepStageSample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let from = Calendar.current.date(byAdding: .day, value: -HealthImportPlan.leadInDays, to: window.start) ?? window.start
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: window.end, options: []),
            notNoopAuthored(),
        ])
        return try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error, Self.isLocked(error) { cont.resume(throwing: ReadError.locked); return }
                var out: [SleepStageSample] = []
                for case let s as HKCategorySample in samples ?? [] {
                    let stage: SleepStage
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = .asleepDeep
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = .asleepREM
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = .asleepCore
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stage = .asleepUnspecified
                    case HKCategoryValueSleepAnalysis.awake.rawValue: stage = .awake
                    case HKCategoryValueSleepAnalysis.inBed.rawValue: stage = .inBed
                    default: stage = .unknown
                    }
                    out.append(SleepStageSample(start: s.startDate, end: s.endDate, stage: stage))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// Workouts starting inside the window that NOOP did not author (so our own write-back never
    /// re-imports as "Apple Health"), mapped to `WorkoutRow`s under the apple-health source. The upsert is
    /// idempotent on (deviceId, startTs). (#835)
    static func workouts(in window: HealthImportWindow, store: HKHealthStore) async throws -> [WorkoutRow] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictStartDate),
            notNoopAuthored(),
        ])
        return try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error, Self.isLocked(error) { cont.resume(throwing: ReadError.locked); return }
                var rows: [WorkoutRow] = []
                for case let workout as HKWorkout in samples ?? [] {
                    let startTs = Int(workout.startDate.timeIntervalSince1970)
                    let endTs = max(Int(workout.endDate.timeIntervalSince1970), startTs)
                    let duration = workout.duration > 0 ? workout.duration : Double(endTs - startTs)
                    rows.append(WorkoutRow(
                        startTs: startTs, endTs: endTs,
                        sport: Self.sportName(workout.workoutActivityType),
                        source: Self.workoutSource,
                        durationS: duration,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        avgHr: nil, maxHr: nil, strain: nil,
                        distanceM: workout.totalDistance?.doubleValue(for: .meter()),
                        zonesJSON: nil, notes: nil))
                }
                cont.resume(returning: rows)
            }
            store.execute(q)
        }
    }

    // MARK: - Rows (pure)

    /// Turn one window's reads into store rows: the daily aggregates, the metric-series points the Apple
    /// Health screens read, the rich glucose and insulin KPIs, post-exercise glucose and the workouts.
    /// Only the window's own days are kept, so neighbouring windows never overwrite each other.
    static func rows(for window: HealthImportWindow, reads: WindowReads) -> WindowRows {
        let ownDays = Set(HealthImportPlan.days(of: window))
        var byDay: [String: DayAgg] = [:]

        for (spec, values) in zip(statSpecs(), reads.stats) {
            for (day, v) in values where ownDays.contains(day) {
                var a = byDay[day] ?? DayAgg()
                spec.apply(&a, v)
                byDay[day] = a
            }
        }

        // Rich glucose KPIs (mean/min/max feed the daily aggregate; bands, variability, hypo events and the
        // overnight values become their own points) and the lowest glucose around each workout.
        let workoutWindows = reads.workouts.map {
            WorkoutWindow(start: Double($0.startTs), end: Double($0.endTs),
                          day: Self.dayString(Date(timeIntervalSince1970: TimeInterval($0.startTs))))
        }
        let glucose = HealthImportPlan.glucose(forDays: ownDays, readings: reads.glucose, workouts: workoutWindows)
        for (day, g) in glucose.daily {
            var a = byDay[day] ?? DayAgg()
            a.glucoseAvg = g.mean; a.glucoseMin = g.min; a.glucoseMax = g.max
            byDay[day] = a
        }
        let insulin = DiabetesMetrics.insulinDaily(reads.insulin).filter { ownDays.contains($0.key) }

        // Sleep minutes per day, each sample credited to the day it ends.
        for (day, s) in AppleSleepStages.minutesByDay(reads.sleep, dayOf: Self.dayString) where ownDays.contains(day) {
            var a = byDay[day] ?? DayAgg()
            a.asleepMin = s.asleep; a.deepMin = s.deep; a.remMin = s.rem; a.coreMin = s.core
            byDay[day] = a
        }

        let apple = byDay.map { (day, a) in
            AppleDaily(day: day, steps: a.steps.map { Int($0) },
                       activeKcal: a.activeKcal, basalKcal: a.basalKcal, vo2max: a.vo2max,
                       avgHr: a.avgHr.map { Int($0.rounded()) }, maxHr: a.maxHr.map { Int($0.rounded()) },
                       walkingHr: nil, weightKg: a.weightKg)
        }
        let daily = byDay.map { (day, a) in
            DailyMetric(day: day, totalSleepMin: a.asleepMin, efficiency: nil,
                        deepMin: a.deepMin, remMin: a.remMin, lightMin: a.coreMin, disturbances: nil,
                        restingHr: a.restingHr.map { Int($0.rounded()) }, avgHrv: a.hrv,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: a.spo2, skinTempDevC: nil, respRateBpm: a.respRate)
        }
        // The generic metricSeries the Apple Health screen, the Today sparklines and the Metric Explorer
        // read (repo.series(key:source:"apple-health") queries ONLY metricSeries), with the importer's
        // canonical keys so they match the macOS path exactly.
        let aggregates = byDay.map { (day, a) in
            AppleDailyAggregate(
                day: day, restingHr: a.restingHr, hrvSDNN: a.hrv, spo2Pct: a.spo2, respRate: a.respRate,
                avgHr: a.avgHr, maxHr: a.maxHr, steps: a.steps, activeKcal: a.activeKcal, basalKcal: a.basalKcal,
                vo2max: a.vo2max, weightKg: a.weightKg, bodyFatPct: a.bodyFatPct, leanMassKg: a.leanMassKg,
                bmi: a.bmi, asleepMin: a.asleepMin, deepMin: a.deepMin, remMin: a.remMin, coreMin: a.coreMin,
                glucoseAvg: a.glucoseAvg, glucoseMin: a.glucoseMin, glucoseMax: a.glucoseMax,
                insulinTotal: a.insulinTotal, carbsG: a.carbsG, bpSystolic: a.bpSystolic,
                bpDiastolic: a.bpDiastolic, waterL: a.waterL, waistCm: a.waistCm)
        }
        var points = AppleHealthAggregator.metricPoints(aggregates)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        points.append(contentsOf: diabetesPoints(glucose: glucose.daily, insulin: insulin))
        // Glucose response around exercise: the lowest glucose (and hypo count) inside each workout window,
        // extended 2 hours past its end. A day only appears when a real reading fell inside a window.
        for (day, p) in glucose.postWorkout {
            if let m = p.minMgdl {
                points.append(MetricPoint(day: day, key: "glucose_postex_min", value: m))
                points.append(MetricPoint(day: day, key: "glucose_postex_lows", value: Double(p.lows)))
            }
        }
        return WindowRows(apple: apple, daily: daily, points: points, workouts: reads.workouts)
    }

    /// The rich glucose and insulin daily stats as metric points. Band percentages, hypo count and the
    /// basal/bolus split are emitted for every day that HAS data (a 0% or 0 count is a real, good result),
    /// variability and overnight values only when defined; a day without readings emits nothing.
    static func diabetesPoints(glucose: [String: GlucoseDayStats], insulin: [String: InsulinDayStats]) -> [MetricPoint] {
        var out: [MetricPoint] = []
        for (day, g) in glucose {
            out.append(MetricPoint(day: day, key: "glucose_tir", value: g.tirPct))
            out.append(MetricPoint(day: day, key: "glucose_tbr", value: g.tbrPct))
            out.append(MetricPoint(day: day, key: "glucose_tbr_severe", value: g.tbrSeverePct))
            out.append(MetricPoint(day: day, key: "glucose_tar", value: g.tarPct))
            out.append(MetricPoint(day: day, key: "glucose_tar_high", value: g.tarHighPct))
            out.append(MetricPoint(day: day, key: "glucose_hypos", value: Double(g.hypoEvents)))
            if let cv = g.cvPct { out.append(MetricPoint(day: day, key: "glucose_cv", value: cv)) }
            if let ovm = g.overnightMean { out.append(MetricPoint(day: day, key: "glucose_overnight_avg", value: ovm)) }
            if let ovl = g.overnightMin { out.append(MetricPoint(day: day, key: "glucose_overnight_min", value: ovl)) }
        }
        for (day, i) in insulin {
            out.append(MetricPoint(day: day, key: "insulin_basal", value: i.basal))
            out.append(MetricPoint(day: day, key: "insulin_bolus", value: i.bolus))
        }
        return out
    }

    // MARK: - Helpers

    /// Excludes NOOP's own write-back samples from reads, so the two-way sync never reads its own output
    /// back in as "apple-health" data. `HKSource.default()` is this app's own source. (PR #375)
    static func notNoopAuthored() -> NSPredicate {
        NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))
    }

    /// True for HealthKit's "protected health data is inaccessible" error: the iPhone is locked.
    static func isLocked(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == HKErrorDomain && ns.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }

    /// The store's day key: the LOCAL civil day (`yyyy-MM-dd`), matching the daily statistics buckets
    /// (anchored at local midnight) and `Repository.dayFormatter`. A POSIX formatter is safe to share
    /// across HealthKit's queues for formatting.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// NOOP's sport label for an `HKWorkoutActivityType`. Strength training routes to the shared lifting
    /// sport so a gym session lands in the Lifting lane; anything not named falls back to "Workout".
    static func sportName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:                    return "Running"
        case .walking:                    return "Walking"
        case .hiking:                     return "Hiking"
        case .cycling:                    return "Cycling"
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return LiftingImporter.sport
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining:               return "Core training"
        case .yoga:                       return "Yoga"
        case .pilates:                    return "Pilates"
        case .rowing:                     return "Rowing"
        case .elliptical:                 return "Elliptical"
        case .stairClimbing, .stairs:     return "Stairs"
        case .jumpRope:                   return "Jump rope"
        case .boxing, .kickboxing:        return "Boxing"
        case .basketball:                 return "Basketball"
        case .soccer:                     return "Soccer"
        case .americanFootball:           return "Football"
        case .baseball:                   return "Baseball"
        case .badminton:                  return "Badminton"
        case .tennis:                     return "Tennis"
        case .tableTennis:                return "Table tennis"
        case .volleyball:                 return "Volleyball"
        case .squash, .racquetball:       return "Squash"
        case .martialArts, .taiChi:       return "Martial arts"
        case .dance, .cardioDance, .socialDance: return "Dancing"
        case .golf:                       return "Golf"
        case .climbing:                   return "Climbing"
        case .downhillSkiing, .crossCountrySkiing: return "Skiing"
        case .snowboarding:               return "Snowboarding"
        case .swimming:                   return "Swimming"
        case .surfingSports:              return "Surfing"
        case .paddleSports:               return "Paddling"
        default:                          return "Workout"
        }
    }
}
#endif
