import Foundation
import WhoopStore
import StrandImport

// MARK: - Measured blood pressure: Apple Health and the Lab Book as one daily series
//
// `bp_systolic` / `bp_diastolic` are MEASURED values only. Two places can hold a measurement: Apple
// Health (a cuff that writes there; read as a daily mean into the `apple-health` metric series) and the
// Lab Book (a reading the user typed, stored one row per measurement in `labMarker`). The metric
// explorer, the metric detail and Compare read these two keys through `exploreSeries` / `resolvedSeries`,
// which route here so both sources show up, merged to ONE value per local day (the mean of that day's
// readings; see `BloodPressure.mergeDaily` for how Apple's daily mean counts). The Apple Health page keeps
// reading `series(key:source:)`, the verbatim Apple-only series.
//
// NOOP never estimates blood pressure. A cuffless estimate from a wrist optical sensor is not
// validated without a cuff calibration (Stergiou et al., J Hypertens 2022; ISO 81060-3:2022), and the
// strap hands NOOP only heart rate and beat-to-beat intervals.

extension Repository {

    /// The two metric keys that carry a measured blood pressure.
    nonisolated static func isBloodPressureKey(_ key: String) -> Bool {
        key == BloodPressure.systolicKey || key == BloodPressure.diastolicKey
    }

    /// One merged value per local day for a blood-pressure key over `[from, to]` (`yyyy-MM-dd`,
    /// inclusive): Apple Health's daily mean plus every Lab Book reading of that key, averaged per day.
    /// Lab Book readings are read for the same device id the Lab Book screen writes them under.
    func bloodPressureSeries(key: String, store: WhoopStore,
                             from: String, to: String) async -> [(day: String, value: Double)] {
        guard Self.isBloodPressureKey(key) else { return [] }
        let apple = (try? await store.metricSeries(deviceId: Self.appleHealthSource, key: key,
                                                   from: from, to: to)) ?? []
        let lab = (try? await store.labMarkers(deviceId: deviceId, markerKey: key)) ?? []
        let labReadings = lab.compactMap { row -> (day: String, value: Double)? in
            guard let value = row.value, row.day >= from, row.day <= to else { return nil }
            return (day: row.day, value: value)
        }
        let appleDaily = apple.map { (day: $0.day, value: $0.value) }
        return BloodPressure.mergeDaily(appleDaily: appleDaily, labReadings: labReadings)
    }

    /// The same merged series over a trailing window of `days` (or the whole history when `fullHistory`),
    /// the window the Explore read path uses.
    func bloodPressureSeries(key: String, days: Int, fullHistory: Bool) async -> [(day: String, value: Double)] {
        guard let store = await storeHandle() else { return [] }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))
        return await bloodPressureSeries(key: key, store: store, from: from, to: to)
    }

    /// The latest paired reading and the 30-day averages for the blood-pressure card, or nil when no
    /// day has both a systolic and a diastolic value.
    func bloodPressureOverview() async -> BloodPressure.Summary? {
        guard let store = await storeHandle() else { return nil }
        let from = "0000-01-01", to = "9999-12-31"
        let systolic = await bloodPressureSeries(key: BloodPressure.systolicKey, store: store, from: from, to: to)
        let diastolic = await bloodPressureSeries(key: BloodPressure.diastolicKey, store: store, from: from, to: to)
        let days = BloodPressure.pair(systolic: systolic, diastolic: diastolic)
        return BloodPressure.summary(days, today: Self.dayString(Date()))
    }

    /// Save readings the user typed in the Lab Book editor (one row, or the systolic and diastolic pair).
    /// The store re-projects the `lab-book` daily series on write; the refresh then lets the screens that
    /// watch the dashboard caches re-read.
    func addLabMarkers(_ drafts: [LabMarkerRow]) async {
        guard !drafts.isEmpty, let store = await storeHandle() else { return }
        _ = try? await store.upsertLabMarkers(drafts)
        await refresh()
    }
}
