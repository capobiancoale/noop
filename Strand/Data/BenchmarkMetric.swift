import Foundation
import WhoopStore

/// The daily metrics that both NOOP computes and a WHOOP export carries, compared day by day on the
/// "NOOP vs WHOOP" screen. The WHOOP value is the reference, NOOP's is the method under test. Skin
/// temperature is left out: the export gives absolute °C, NOOP a deviation from baseline.
enum BenchmarkMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    case hrv, restingHr, respiratoryRate, totalSleep, deepSleep, remSleep, lightSleep, sleepEfficiency
    case spo2, recovery, effort

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hrv: return String(localized: "HRV (RMSSD)")
        case .restingHr: return String(localized: "Resting heart rate")
        case .respiratoryRate: return String(localized: "Respiratory rate")
        case .totalSleep: return String(localized: "Total sleep")
        case .deepSleep: return String(localized: "Deep sleep")
        case .remSleep: return String(localized: "REM sleep")
        case .lightSleep: return String(localized: "Light sleep")
        case .sleepEfficiency: return String(localized: "Sleep efficiency")
        case .spo2: return String(localized: "Blood oxygen")
        case .recovery: return String(localized: "Charge vs Recovery")
        case .effort: return String(localized: "Effort vs Day Strain")
        }
    }

    var unit: String {
        switch self {
        case .hrv: return "ms"
        case .restingHr: return "bpm"
        case .respiratoryRate: return String(localized: "br/min")
        case .totalSleep, .deepSleep, .remSleep, .lightSleep: return "min"
        case .sleepEfficiency, .spo2, .recovery: return "%"
        case .effort: return ""
        }
    }

    var decimals: Int {
        switch self {
        case .hrv, .respiratoryRate, .spo2: return 1
        default: return 0
        }
    }

    func value(_ m: DailyMetric) -> Double? {
        switch self {
        case .hrv: return m.avgHrv
        case .restingHr: return m.restingHr.map(Double.init)
        case .respiratoryRate: return m.respRateBpm
        case .totalSleep: return m.totalSleepMin
        case .deepSleep: return m.deepMin
        case .remSleep: return m.remMin
        case .lightSleep: return m.lightMin
        case .sleepEfficiency: return m.efficiency
        case .spo2: return m.spo2Pct
        case .recovery: return m.recovery
        case .effort: return m.strain
        }
    }

    /// Why the two need not agree even when both are working as designed.
    var caveat: String? {
        switch self {
        case .recovery:
            return String(localized: "Two different recovery models on the same 0–100 axis: look at whether they move together more than at the gap.")
        case .effort:
            return String(localized: "WHOOP's 0–21 Day Strain is converted to NOOP's 0–100 Effort axis on import; the two scales are built differently.")
        case .deepSleep, .remSleep, .lightSleep:
            return String(localized: "Wrist devices estimate sleep stages from heart rate and motion; a gap here does not tell you which one is right.")
        default:
            return nil
        }
    }
}
