import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - VO₂max inputs and the user's own measurements
//
// Gathers what VO2maxEngine needs from the store: walks and runs with a distance, the wearer's heart rate over
// each (per-minute means aggregated in SQL, so no raw samples are loaded), the nightly resting heart rate before
// each and a personal HRmax. Also keeps the VO₂max values the user enters (a lab test, a field test, another
// device's reading) so they can be set beside the estimates. The maths lives in StrandAnalytics.VO2maxEngine.

extension Repository {

    /// A walk or run considered for the exercise estimate, with the numbers behind its outcome.
    struct VO2maxCandidate: Identifiable {
        let startTs: Int
        let sport: String
        let source: String
        let distanceM: Double
        let durationS: Double
        let gait: VO2maxEngine.Gait
        /// Steady-state heart rate used (the strap's per-minute means after the first 3 minutes, else the
        /// workout's own average), nil when neither exists.
        let heartRate: Double?
        let heartRateFromStrap: Bool
        /// Median nightly resting heart rate of the 14 days up to the session, nil without any.
        let restingHR: Double?
        let outcome: Result<VO2maxEngine.SessionEstimate, VO2maxEngine.Rejection>
        var id: String { "\(source)-\(startTs)" }
        var estimate: VO2maxEngine.SessionEstimate? { try? outcome.get() }
        var speedKmh: Double { durationS > 0 ? distanceM / durationS * 3.6 : 0 }
    }

    struct VO2maxInputs {
        let maxHR: VO2maxEngine.MaxHR?
        /// Newest first.
        let candidates: [VO2maxCandidate]
        var estimates: [VO2maxEngine.SessionEstimate] { candidates.compactMap(\.estimate) }
    }

    /// The walks and runs of the last `days` evaluated for the exercise estimate. `userSetMaxHR` is the
    /// profile's HRmax override (0 = not set).
    func vo2maxInputs(days: Int = 365, age: Int, userSetMaxHR: Int) async -> VO2maxInputs {
        let rows = await workoutRows(days: days, reconcileHr: false)
        let maxHR = VO2maxEngine.maxHR(userSet: userSetMaxHR > 0 ? Double(userSetMaxHR) : nil,
                                       workoutPeaks: rows.compactMap(\.maxHr).map(Double.init),
                                       age: age > 0 ? Double(age) : nil)
        // Nightly resting HR by (wake) day, from the merged daily rows (an import wins over NOOP's own value).
        var nightly: [String: Double] = [:]
        for d in self.days { if let r = d.restingHr, r > 0 { nightly[d.day] = Double(r) } }
        let calendar = Calendar.current

        var out: [VO2maxCandidate] = []
        for row in rows {
            guard let gait = VO2maxEngine.gait(forSport: row.sport),
                  let distance = row.distanceM, distance > 0 else { continue }
            let duration = row.durationS ?? Double(row.endTs - row.startTs)
            guard duration > 0 else { continue }
            let buckets = await hrBuckets(from: row.startTs + VO2maxEngine.heartRateOnsetS, to: row.endTs,
                                          bucketSeconds: 60)
            let strapHR = VO2maxEngine.steadyHeartRate(buckets, start: row.startTs, end: row.endTs)
            let heartRate = strapHR ?? row.avgHr.map(Double.init)
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            let nights = (0..<VO2maxEngine.restingHRNights).compactMap { back -> Double? in
                guard let d = calendar.date(byAdding: .day, value: -back, to: start) else { return nil }
                return nightly[Self.dayString(d)]
            }
            let restingHR = VO2maxEngine.restingHeartRate(nights)
            let session = VO2maxEngine.Session(start: row.startTs, durationS: duration, distanceM: distance,
                                               heartRate: heartRate ?? 0, gait: gait)
            let outcome: Result<VO2maxEngine.SessionEstimate, VO2maxEngine.Rejection>
            if let restingHR, let maxHR {
                outcome = VO2maxEngine.evaluate(session, restingHR: restingHR, maxHR: maxHR.bpm)
            } else {
                outcome = .failure(.missingData)
            }
            out.append(VO2maxCandidate(startTs: row.startTs, sport: row.sport, source: row.source,
                                       distanceM: distance, durationS: duration, gait: gait,
                                       heartRate: heartRate, heartRateFromStrap: strapHR != nil,
                                       restingHR: restingHR, outcome: outcome))
        }
        return VO2maxInputs(maxHR: maxHR, candidates: out.sorted { $0.startTs > $1.startTs })
    }

    // MARK: - The user's own VO₂max values

    /// How an entered value was measured. Stored as its raw value beside the value.
    enum VO2maxMethod: Int, CaseIterable, Identifiable {
        case lab = 1, field = 2, device = 3
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .lab: return String(localized: "Lab test (gas analysis)")
            case .field: return String(localized: "Field test")
            case .device: return String(localized: "Another device or app")
            }
        }
    }

    struct VO2maxEntry: Identifiable, Equatable {
        let day: String
        let value: Double
        let method: VO2maxMethod
        var id: String { day }
    }

    /// Source id and keys the entries are stored under (one entry per day; a second one that day replaces it).
    static let vo2maxManualSource = "manual-vo2max"
    static let vo2maxManualKey = "vo2max_manual"
    static let vo2maxManualMethodKey = "vo2max_manual_method"
    /// Values outside this range are not a human VO₂max (mL/kg/min).
    static let vo2maxPlausible: ClosedRange<Double> = 10...95

    /// Every entered value, newest first.
    func vo2maxEntries() async -> [VO2maxEntry] {
        guard let store = await storeHandle() else { return [] }
        let values = (try? await store.metricSeries(deviceId: Self.vo2maxManualSource, key: Self.vo2maxManualKey,
                                                    from: "0000-01-01", to: "9999-12-31")) ?? []
        let methods = (try? await store.metricSeries(deviceId: Self.vo2maxManualSource,
                                                     key: Self.vo2maxManualMethodKey,
                                                     from: "0000-01-01", to: "9999-12-31")) ?? []
        let methodByDay = Dictionary(methods.map { ($0.day, Int($0.value)) }, uniquingKeysWith: { a, _ in a })
        return values.map { p in
            VO2maxEntry(day: p.day, value: p.value,
                        method: methodByDay[p.day].flatMap(VO2maxMethod.init(rawValue:)) ?? .device)
        }
        .sorted { $0.day > $1.day }
    }

    /// Store one entered value. Returns false when it is implausible or the store is unavailable.
    @discardableResult
    func saveVO2maxEntry(day: String, value: Double, method: VO2maxMethod) async -> Bool {
        guard Self.vo2maxPlausible.contains(value), let store = await storeHandle() else { return false }
        do {
            try await store.upsertMetricSeries([
                MetricPoint(day: day, key: Self.vo2maxManualKey, value: value),
                MetricPoint(day: day, key: Self.vo2maxManualMethodKey, value: Double(method.rawValue)),
            ], deviceId: Self.vo2maxManualSource)
        } catch {
            return false
        }
        await refresh()
        return true
    }

    func deleteVO2maxEntry(day: String) async {
        guard let store = await storeHandle() else { return }
        for key in [Self.vo2maxManualKey, Self.vo2maxManualMethodKey] {
            _ = try? await store.deleteMetricSeries(deviceId: Self.vo2maxManualSource, key: key, from: day, to: day)
        }
        await refresh()
    }
}
