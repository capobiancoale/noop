import Foundation
import WhoopStore
import StrandAnalytics

/// App-side glue for the illness watch: the storage-to-engine mapping and the persisted personal
/// calibration. The maths lives in StrandAnalytics (`IllnessSignalEngine`, `IllnessCalibration`); this
/// only converts rows, reads the night-low days and stores the result.
enum IllnessWatch {

    /// Apple Health daily metric: the lowest CGM reading between 00:00 and 06:00 local (mg/dL), written
    /// from the glucose the user's sensor (e.g. Loop) records to Health. See `DiabetesMetrics`.
    static let nightLowMetricKey = "glucose_overnight_min"

    /// UserDefaults key of the persisted `IllnessCalibration.Snapshot` (JSON). Never read in `body`.
    private static let calibrationKey = "noop.illnessCalibration.snapshot"

    /// The daily history as the engine reads it (plain numbers, oldest first).
    static func vitals(_ days: [DailyMetric]) -> [IllnessSignalEngine.DayVitals] {
        days.map {
            IllnessSignalEngine.DayVitals(
                day: $0.day, restingHR: $0.restingHr.map(Double.init), hrv: $0.avgHrv,
                respiration: $0.respRateBpm, skinTempDevC: $0.skinTempDevC)
        }
    }

    /// Days whose lowest overnight glucose was below the level-1 hypoglycaemia line (70 mg/dL). No
    /// glucose data gives an empty set, which leaves the illness watch exactly as it was.
    static func nightLowDays(_ overnightMin: [(day: String, value: Double)]) -> Set<String> {
        Set(overnightMin.filter { $0.value < IllnessSignalEngine.nocturnalLowMgdl }.map(\.day))
    }

    // MARK: - Persisted calibration

    static func loadCalibration(_ defaults: UserDefaults = .standard) -> IllnessCalibration.Snapshot? {
        guard let data = defaults.data(forKey: calibrationKey) else { return nil }
        return try? JSONDecoder().decode(IllnessCalibration.Snapshot.self, from: data)
    }

    static func saveCalibration(_ snapshot: IllnessCalibration.Snapshot, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: calibrationKey)
    }
}
