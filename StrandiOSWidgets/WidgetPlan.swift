import SwiftUI
import StrandDesign

/// The plan fields of a `WidgetSnapshot`, ready to draw: nil when there is no plan or it is not for today.
///
/// The widget does not link StrandAnalytics, so the app publishes keys and numbers (see
/// `WidgetSnapshot.withPlan`) and this type builds the localized words. The wording follows the app's
/// Today's plan card (`DayPlanCard`), shortened to fit a widget. General estimates, not medical advice.
struct WidgetPlan: Equatable {

    enum Training: String {
        case push, maintain, easy
    }

    let training: Training
    let reasonKey: String?
    let reasonValue: Int?
    let sleepMinutes: Int?
    let bedtimeMinutes: Int?
    let energy: ClosedRange<Int>?
    let protein: ClosedRange<Int>?
    let carbs: ClosedRange<Int>?
    let focusKey: String?
    let focusValue: Int?

    /// `date` is the entry date: a plan whose day is not the logical today of that date is treated as
    /// absent, so yesterday's advice is never shown as today's.
    init?(_ snap: WidgetSnapshot, at date: Date) {
        guard snap.planIsCurrent(at: date),
              let raw = snap.planTraining,
              let training = Training(rawValue: raw) else { return nil }
        self.training = training
        self.reasonKey = snap.planReason
        self.reasonValue = snap.planReasonValue
        self.sleepMinutes = snap.planSleepMinutes
        self.bedtimeMinutes = snap.planBedtimeMinutes
        self.energy = WidgetPlan.range(snap.planEnergyLow, snap.planEnergyHigh)
        self.protein = WidgetPlan.range(snap.planProteinLow, snap.planProteinHigh)
        self.carbs = WidgetPlan.range(snap.planCarbsLow, snap.planCarbsHigh)
        self.focusKey = snap.planFocus
        self.focusValue = snap.planFocusValue
    }

    private static func range(_ low: Int?, _ high: Int?) -> ClosedRange<Int>? {
        guard let low, let high, low <= high else { return nil }
        return low...high
    }

    // MARK: - Words

    var word: String {
        switch training {
        case .push: return String(localized: "Push")
        case .maintain: return String(localized: "Maintain")
        case .easy: return String(localized: "Easy day")
        }
    }

    var symbol: String {
        switch training {
        case .push: return "bolt.fill"
        case .maintain: return "equal.circle.fill"
        case .easy: return "leaf.fill"
        }
    }

    /// One short line saying why (nil when a Charge reason has lost its number).
    var reasonText: String? {
        switch reasonKey {
        case "chargeHigh", "chargeMid", "chargeLow":
            guard let n = reasonValue else { return nil }
            return String(localized: "Charge \(n.formatted())%")
        case "noCharge": return String(localized: "No Charge yet")
        case "shortSleep": return String(localized: "Short night")
        case "loadSharpRise": return String(localized: "Load well above your usual")
        case "hardStreak": return String(localized: "Several hard days in a row")
        default: return nil
        }
    }

    /// "Tonight in bed by 22:45", or the sleep target when there is no bedtime.
    var sleepLine: String? {
        if let bed = bedtimeMinutes {
            return String(localized: "Tonight in bed by \(WidgetPlan.clock(bed))")
        }
        if let m = sleepMinutes {
            return String(localized: "Tonight: \(WidgetPlan.duration(m))")
        }
        return nil
    }

    /// Short form for the Lock Screen: "In bed by 22:45".
    var shortBedLine: String? {
        if let bed = bedtimeMinutes {
            return String(localized: "in bed by \(WidgetPlan.clock(bed))")
        }
        if let m = sleepMinutes {
            return String(localized: "Tonight: \(WidgetPlan.duration(m))")
        }
        return nil
    }

    /// Second line of the sleep block in the large widget, only when a bedtime already took the first.
    var sleepTargetLine: String? {
        guard bedtimeMinutes != nil, let m = sleepMinutes else { return nil }
        return String(localized: "Sleep target \(WidgetPlan.duration(m))")
    }

    /// "Push · bed 22:45" for the inline accessory; just the word when there is no bedtime.
    var inlineText: String {
        guard let bed = bedtimeMinutes else { return word }
        return String(localized: "\(word) · bed \(WidgetPlan.clock(bed))")
    }

    var focusText: String? {
        guard let key = focusKey, let v = focusValue else { return nil }
        switch key {
        case "sleepDebt":
            return String(localized: "Sleep debt \(WidgetPlan.duration(v))")
        case "lowSleepAverage":
            return String(localized: "Sleeps \(WidgetPlan.duration(v)) a night on average")
        case "irregularWake":
            return String(localized: "Wake time varies by about \(v.formatted()) min")
        case "loadHigh":
            return String(localized: "Load high: \(WidgetPlan.ratio(v))× your usual")
        case "loadLow":
            return String(localized: "Load low: \(WidgetPlan.ratio(v))× your usual")
        case "hrvDown":
            return String(localized: "HRV \(v.formatted())% below your usual")
        case "restingHrUp":
            return String(localized: "Resting HR \(v.formatted()) bpm above your usual")
        default:
            return nil
        }
    }

    // MARK: - Formatting (locale-aware)

    /// Minutes after local midnight as a clock time; 12 or 24 hour follows the device.
    static func clock(_ minutes: Int, calendar: Calendar = .current, reference: Date = Date()) -> String {
        let m = ((minutes % 1_440) + 1_440) % 1_440
        let date = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: reference) ?? reference
        return date.formatted(.dateTime.hour().minute())
    }

    /// "7 h 30 min" / "45 min", in the device language.
    static func duration(_ minutes: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: TimeInterval(max(0, minutes) * 60)) ?? "\(minutes) min"
    }

    /// A load ratio published as ratio x 100, shown with one decimal ("1.5").
    static func ratio(_ x100: Int) -> String {
        (Double(x100) / 100).formatted(.number.precision(.fractionLength(1)))
    }

    /// "2700–3000": whole numbers, no thousands separator (the app's nutrition card does the same).
    static func rangeText(_ r: ClosedRange<Int>) -> String {
        "\(r.lowerBound.formatted(.number.grouping(.never)))–\(r.upperBound.formatted(.number.grouping(.never)))"
    }
}
