import Foundation
import StrandAnalytics

/// All user-facing wording of the illness heads-up, built in the app so it follows the UI language.
/// The engine (`IllnessSignalEngine`) keeps English phrases because it is shared with the Android twin;
/// they are never shown as they are. The card, the banner and the notification all read the sentence
/// from here, from the engine's level, its fired signals and its suppression reasons.
///
/// On-device estimate, approximate: never a diagnosis, never a condition name.
enum IllnessCopy {

    // MARK: - Fired signals (the "why" chips)

    /// The localized phrase for each signal that can fire, from the window's raw movements. The engine
    /// surfaces only the ones that actually fire.
    static func firedLabels(from window: IllnessSignalEngine.Window) -> [String: String] {
        var labels: [String: String] = [:]
        if let rise = window.restingHRRise {
            let bpm = Int(rise.rounded())
            labels["restingHR"] = String(localized: "RHR +\(bpm)")
        }
        if let drop = window.hrvDropPercent {
            let percent = Int(drop.rounded())
            labels["hrv"] = String(localized: "HRV −\(percent)%")
        }
        if let celsius = window.skinTempRiseC {
            let shown = celsius.formatted(.number.precision(.fractionLength(1)))
            labels["skinTemp"] = String(localized: "skin temp +\(shown) °C")
        }
        if window.respirationUp {
            labels["respiration"] = String(localized: "respiration up")
        }
        return labels
    }

    // MARK: - Confounders ("explained by")

    /// The localized phrase for one of the engine's suppression reasons. An unknown key (a reason added
    /// to the engine later) is shown as it is rather than dropped.
    static func reason(_ key: String) -> String {
        switch key {
        case "alcohol": return String(localized: "alcohol")
        case "stress": return String(localized: "stress")
        case "sauna": return String(localized: "sauna")
        case "a hard or late workout": return String(localized: "a hard or late workout")
        case "travel": return String(localized: "travel")
        case "a low glucose at night": return String(localized: "a low glucose at night")
        default: return key
        }
    }

    /// "alcohol", "alcohol and stress", "alcohol, stress and sauna" in the UI language.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        let head = items.dropLast().joined(separator: ", ")
        return String(localized: "\(head) and \(last)")
    }

    // MARK: - The sentence

    /// The standing caption under every heads-up.
    static var disclaimer: String {
        String(localized: "On-device estimate (approximate), not a diagnosis.")
            + " " + String(localized: "Informational only, not medical advice.")
    }

    /// One localized sentence for the engine's decision, without the disclaimer (the notification carries
    /// that as its subtitle, the card as a caption).
    static func sentence(for result: IllnessSignalEngine.Result) -> String {
        let signals = result.firedSignals.isEmpty
            ? String(localized: "several of your signals")
            : result.firedSignals.joined(separator: ", ")
        switch result.level {
        case .raised:
            return String(localized: "Your body looks strained (\(signals)). Nothing like alcohol, a hard workout or a low glucose at night explains it, so consider taking it easy.")
        case .suppressed:
            let reasons = list(result.suppressedBy.map(reason))
            return String(localized: "Some signals are up (\(signals)), but there is a plainer explanation: \(reasons). Likely that, not illness.")
        case .mild:
            return String(localized: "A few signals are mildly up (\(signals)). Nothing alarming: worth a calmer day.")
        case .alreadyUnwell:
            // The engine's own rule for "your numbers agree": a mild-or-better score with a signal up.
            let agrees = result.score >= IllnessSignalEngine.mildThreshold && result.signalCount >= 1
            return agrees
                ? String(localized: "You logged feeling unwell, and your numbers agree. Rest up and take it easy today.")
                : String(localized: "You logged feeling unwell. Take it easy today.")
        case .quiet:
            return String(localized: "Nothing notable: your signals look like your normal range.")
        }
    }

    /// The banner text: the sentence plus the disclaimer, since the banner has no caption of its own.
    static func alert(for result: IllnessSignalEngine.Result) -> String {
        sentence(for: result) + " " + String(localized: "On-device estimate (approximate), not a diagnosis.")
    }

    // MARK: - Personal false-alarm calibration

    /// The calibration status line: what the false-alarm rate on the user's own healthy days is, or how
    /// many healthy days are still needed. nil result = not computed yet (no history to replay).
    static func calibrationLine(_ calibration: IllnessCalibration.Result?) -> String {
        guard let c = calibration, c.active else {
            let needed = IllnessCalibration.minimumHealthyDays
            let sofar = calibration?.healthyDays ?? 0
            return String(localized: "Calibration starts after \(needed) healthy days (\(sofar) so far).")
        }
        let atMost = c.daysPerAlarmAtMost ?? c.healthyDays
        if let every = c.daysPerAlarm {
            let about = Int(every.rounded())
            return String(localized: "Calibrated on your last \(c.healthyDays) healthy days: expect about 1 false alarm every \(about) days (at most 1 every \(atMost) days, 95%).")
        }
        return String(localized: "Calibrated on your last \(c.healthyDays) healthy days: no false alarms (at most 1 every \(atMost) days, 95%).")
    }

    /// Shown when even the strictest setting could not reach the target rate on the user's own data.
    static func strictestLine(_ calibration: IllnessCalibration.Result?) -> String? {
        guard let c = calibration, c.active, !c.targetMet else { return nil }
        let target = IllnessCalibration.targetDaysPerAlarm
        return String(localized: "Even the strictest setting gives more than 1 false alarm every \(target) days on your data.")
    }
}
