import Foundation
import StrandAnalytics

// The pure part: Today's plan -> the plain fields of `WidgetSnapshot`. It needs only Foundation and
// StrandAnalytics (no UIKit / WidgetKit), so it lives outside the `#if os(iOS)` block below and a test
// can reach it. The widget extension does not link StrandAnalytics: it reads these keys and numbers and
// builds the localized words itself.
extension WidgetSnapshot {

    /// A copy of `base` carrying `plan` (for the day `day`, a `yyyy-MM-dd` key).
    ///  - `planReason`: the first reason (the Charge one, or `noCharge`); when other rules lowered the level
    ///    below what Charge alone gave, the reason that brought it to its final level instead.
    ///  - `planFocus`: the first focus, with its main number (minutes, bpm, pct, or ratio x 100).
    nonisolated static func withPlan(_ base: WidgetSnapshot, plan: DayPlan.Plan, day: String) -> WidgetSnapshot {
        var snap = base
        snap.planTraining = trainingKey(plan.training)
        let reason = widgetReason(plan)
        snap.planReason = reason?.key
        snap.planReasonValue = reason?.value
        snap.planSleepMinutes = plan.sleep.minutes
        snap.planBedtimeMinutes = plan.sleep.bedtimeMinutes
        snap.planEnergyLow = plan.nutrition?.energyKcal.lowerBound
        snap.planEnergyHigh = plan.nutrition?.energyKcal.upperBound
        snap.planProteinLow = plan.nutrition?.proteinG.lowerBound
        snap.planProteinHigh = plan.nutrition?.proteinG.upperBound
        snap.planCarbsLow = plan.nutrition?.carbsG.lowerBound
        snap.planCarbsHigh = plan.nutrition?.carbsG.upperBound
        let focus = plan.focus.first.map(focusKeyAndValue)
        snap.planFocus = focus?.key
        snap.planFocusValue = focus?.value
        snap.planDay = day
        return snap
    }

    nonisolated static func trainingKey(_ t: DayPlan.Training) -> String {
        switch t {
        case .push: return "push"
        case .maintain: return "maintain"
        case .easy: return "easy"
        }
    }

    /// The reason the widget shows. `DayPlan` lists the Charge reason first, then the rules that apply in
    /// order; replaying them on the level Charge gave finds the last one that actually lowered it.
    nonisolated static func widgetReason(_ plan: DayPlan.Plan) -> (key: String, value: Int?)? {
        guard let first = plan.reasons.first else { return nil }
        var level: Int
        switch first {
        case .chargeHigh: level = DayPlan.Training.push.rawValue
        case .chargeLow: level = DayPlan.Training.easy.rawValue
        default: level = DayPlan.Training.maintain.rawValue
        }
        var chosen = first
        for r in plan.reasons.dropFirst() {
            let before = level
            switch r {
            case .shortSleep: level = max(level - 1, DayPlan.Training.easy.rawValue)
            case .loadSharpRise: level = min(level, DayPlan.Training.maintain.rawValue)
            case .hardStreak: level = DayPlan.Training.easy.rawValue
            default: break
            }
            if level < before { chosen = r }
        }
        return reasonKeyAndValue(chosen)
    }

    nonisolated static func reasonKeyAndValue(_ r: DayPlan.Reason) -> (key: String, value: Int?) {
        switch r {
        case .chargeHigh(let n): return ("chargeHigh", n)
        case .chargeMid(let n): return ("chargeMid", n)
        case .chargeLow(let n): return ("chargeLow", n)
        case .noCharge: return ("noCharge", nil)
        case .shortSleep: return ("shortSleep", nil)
        case .loadSharpRise: return ("loadSharpRise", nil)
        case .hardStreak: return ("hardStreak", nil)
        }
    }

    nonisolated static func focusKeyAndValue(_ f: DayPlan.Focus) -> (key: String, value: Int) {
        switch f {
        case .sleepDebt(let minutes): return ("sleepDebt", minutes)
        case .lowSleepAverage(let avg, _): return ("lowSleepAverage", avg)
        case .irregularWake(let sd): return ("irregularWake", sd)
        case .loadHigh(let ratio): return ("loadHigh", Int((ratio * 100).rounded()))
        case .loadLow(let ratio): return ("loadLow", Int((ratio * 100).rounded()))
        case .hrvDown(let pct, _, _): return ("hrvDown", pct)
        case .restingHrUp(let bpm, _, _): return ("restingHrUp", Int(bpm.rounded()))
        }
    }
}

#if os(iOS)
import Foundation
import WidgetKit

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`. Charge / Effort / HRV / Resting HR all read synchronously off the SAME
    /// anchor day, so the richer fields and the headline never disagree about which day they describe.
    ///
    /// #911: the anchor is resolved the way Today resolves it (the current LOGICAL local day, `Date()`
    /// read here so the day rolls live as the extension republishes), NOT "the most recent day with any
    /// recovery score". The old anchor drifted around the day rollover: the new logical day exists but
    /// isn't scored yet, so `days.last(where: recovery != nil)` still pointed at yesterday's scored row
    /// and the widget showed the older day while Today had already moved on. We now anchor on today's
    /// row and, only when today isn't scored yet, carry over the last STRICTLY-PRIOR scored day for the
    /// recovery-derived fields (the same carry-over Today does), so the widget never blanks right after
    /// the rollover yet always describes today.
    @MainActor
    static func publish(from model: AppModel) async {
        let days = model.repo.days
        let now = Date()
        // The recovery-derived anchor: today's row when it's scored, else the freshest STRICTLY-PRIOR
        // scored day carried over. Resolved through the SHARED `Repository.widgetAnchor`, the ONE selector
        // the watch snapshot and the iOS Live Activity now also use, so all four surfaces describe the same
        // day (the #911 fix; see `Repository.widgetAnchor` for the rollover-drift rationale, the #304
        // pre-04:00 carve-out and the #547 future-day guard it folds in). The `$0.day < carriedKey` bound
        // inside the helper (matching `TodayView.selectedDayKey`) means a stale scored row can never
        // re-surface AS today.
        let day = Repository.widgetAnchor(days: days, now: now)
        // Rest (sleep_performance) for that same anchor day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile. The tail fallback (restSeries.last) is ONLY valid when the
        // anchor day IS the local today: early in a fresh day today's Rest row may not exist yet, so we
        // borrow the latest value. For an anchor that is NOT today, borrowing the tail would surface a
        // DIFFERENT day's Rest as this day's (the cross-day bug), so we leave it nil. Mirrors TodayView's
        // `restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)` and the
        // matching guard in WatchSessionBridge.
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            let anchorIsToday = day.day == Repository.localDayKey(now)
            restScore = restByDay[day.day] ?? (anchorIsToday ? restSeries.last?.value : nil)
        }
        // Today's plan, from the ONE builder the Today card and the Coach use, so the widget cannot disagree.
        let planSnapshot = await DayPlanBuilder.snapshot(repo: model.repo, now: now)
        var snap = WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            // Effort is stored on NOOP's 0–100 axis (the same value the Today Effort tile reads), so it
            // publishes as a whole number without the WHOOP-0–21 toggle the main app applies — the widget
            // extension can't reach UnitFormatter/UnitPrefs, and 0–100 is the default scale.
            effort: day?.strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr
        )
        snap = WidgetSnapshot.withPlan(snap, plan: planSnapshot.plan, day: planSnapshot.todayKey)
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
