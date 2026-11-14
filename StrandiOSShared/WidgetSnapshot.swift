import Foundation

/// Small, Codable glance snapshot shared between the iOS app and its widget/Live-Activity extension
/// via an App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process
/// database access — the widget never opens SQLite.
public struct WidgetSnapshot: Codable, Equatable {
    public var recovery: Int?    // Charge (0–100)
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date
    // Richer glance fields (#446). All OPTIONAL with nil defaults so a snapshot written by an OLDER app
    // build (which never encoded these keys) still decodes — Codable fills a missing optional with nil.
    public var effort: Int?      // Effort / strain on NOOP's 0–100 axis
    public var rest: Int?        // Rest (sleep_performance) score, 0–100
    public var hrv: Int?         // HRV (ms), whole-number for the glance
    public var restingHr: Int?   // Resting heart rate (bpm)

    // Today's plan (docs/PIANO_PROSSIMO_LIVELLO.md, 6d). Plain keys and numbers, because the widget does not
    // link StrandAnalytics: it builds the wording itself. Every field is OPTIONAL and defaults to nil, so a
    // snapshot stored by an older build (no such keys) still decodes (the synthesized Codable uses
    // decodeIfPresent for optionals) and simply has no plan. Built by `WidgetSnapshot.withPlan` in the app.
    public var planTraining: String?        // "push" | "maintain" | "easy"
    public var planReason: String?          // "chargeHigh" | "chargeMid" | "chargeLow" | "noCharge" | "shortSleep" | "loadSharpRise" | "hardStreak"
    public var planReasonValue: Int?        // the Charge shown for the three charge* reasons, else nil
    public var planSleepMinutes: Int?       // tonight's sleep target, minutes
    public var planBedtimeMinutes: Int?     // minutes after local midnight, 0..<1440
    public var planEnergyLow: Int?          // kcal
    public var planEnergyHigh: Int?
    public var planProteinLow: Int?         // g
    public var planProteinHigh: Int?
    public var planCarbsLow: Int?           // g
    public var planCarbsHigh: Int?
    public var planFocus: String?           // "sleepDebt" | "lowSleepAverage" | "irregularWake" | "loadHigh" | "loadLow" | "hrvDown" | "restingHrUp"
    public var planFocusValue: Int?         // minutes, bpm, pct, or ratio x 100 (see planFocus)
    public var planDay: String?             // yyyy-MM-dd of the (logical) day the plan is for

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Int? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                planTraining: String? = nil, planReason: String? = nil, planReasonValue: Int? = nil,
                planSleepMinutes: Int? = nil, planBedtimeMinutes: Int? = nil,
                planEnergyLow: Int? = nil, planEnergyHigh: Int? = nil,
                planProteinLow: Int? = nil, planProteinHigh: Int? = nil,
                planCarbsLow: Int? = nil, planCarbsHigh: Int? = nil,
                planFocus: String? = nil, planFocusValue: Int? = nil, planDay: String? = nil) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
        self.effort = effort
        self.rest = rest
        self.hrv = hrv
        self.restingHr = restingHr
        self.planTraining = planTraining
        self.planReason = planReason
        self.planReasonValue = planReasonValue
        self.planSleepMinutes = planSleepMinutes
        self.planBedtimeMinutes = planBedtimeMinutes
        self.planEnergyLow = planEnergyLow
        self.planEnergyHigh = planEnergyHigh
        self.planProteinLow = planProteinLow
        self.planProteinHigh = planProteinHigh
        self.planCarbsLow = planCarbsLow
        self.planCarbsHigh = planCarbsHigh
        self.planFocus = planFocus
        self.planFocusValue = planFocusValue
        self.planDay = planDay
    }

    /// The app's LOGICAL day rolls at 04:00 local (`Repository.logicalDayRolloverHour`), and the plan is
    /// keyed by that day, so the widget must compare against the same day or it would hide the plan between
    /// midnight and 04:00. Pure: the clock and the zone are parameters.
    public static let planRolloverHour = 4

    /// `yyyy-MM-dd` of the logical day of `date` in `timeZone` (Gregorian, POSIX digits, like the app's keys).
    public static func planDayKey(at date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let shifted = date.addingTimeInterval(-Double(planRolloverHour) * 3_600)
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// True only when a plan is stored AND it is for the logical day of `date`. Stale advice is never today's.
    public func planIsCurrent(at date: Date, timeZone: TimeZone = .current) -> Bool {
        guard planTraining != nil, let day = planDay else { return false }
        return day == WidgetSnapshot.planDayKey(at: date, timeZone: timeZone)
    }

    /// App Group suite the app and widget both use. Injected from the `APP_GROUP_ID` build setting
    /// (see project.yml) via the `AppGroupIdentifier` Info.plist key, so the value lives in exactly
    /// one place rather than being duplicated here. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets (which also reads `$(APP_GROUP_ID)`). If the entitlement is missing on
    /// either side, `UserDefaults(suiteName:)` returns nil and every consumer (PendingIntents,
    /// WidgetSnapshot.publish, Live Activity) silently no-ops — see `assertGroupProvisioned` for the
    /// debug-time canary. The fallback is the canonical upstream group and only applies if the Info.plist
    /// key is somehow absent (each process reads its OWN bundle, so the app and the widget extension
    /// each carry the key in their generated Info.plist).
    public static let suiteName: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.com.noopapp.noop"
    }()
    public static let storageKey = "noop.widget.snapshot"

    /// Debug-only canary: trips on the first run after a misprovisioning so the silent no-op gets
    /// caught immediately rather than masquerading as "widget shows nothing yet." Release builds do
    /// nothing — App Store apps can't crash on a missing entitlement.
    public static func assertGroupProvisioned() {
        assert(UserDefaults(suiteName: suiteName) != nil,
               "App Group '\(suiteName)' not provisioned on this target — check the entitlement.")
    }

    public static var placeholder: WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 8, rest: 81, hrv: 64, restingHr: 52,
                       planTraining: "push", planReason: "chargeHigh", planReasonValue: 72,
                       planSleepMinutes: 480, planBedtimeMinutes: 22 * 60 + 45,
                       planEnergyLow: 2_700, planEnergyHigh: 3_000,
                       planProteinLow: 130, planProteinHigh: 180,
                       planCarbsLow: 380, planCarbsHigh: 520,
                       planFocus: "sleepDebt", planFocusValue: 75,
                       planDay: planDayKey(at: Date()))
    }

    /// Read the last-published snapshot from the shared suite, if any.
    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared suite.
    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
    }
}
