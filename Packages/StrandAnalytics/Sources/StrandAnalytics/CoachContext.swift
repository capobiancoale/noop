import Foundation
import WhoopStore

// CoachContext.swift — plain-text blocks for the AI coach's context. Pure: no clock, no locale, no
// Calendar.current. The text is ENGLISH because a language model reads it; numbers use "." decimals whatever the
// phone's locale. A function returns nil when it has nothing to say, and a part with no data is left out (never a
// placeholder dash). Free-text WOD notes are never included.
//
// Not medical advice: the plan block repeats what `DayPlan` computed, and `safetyLine` keeps insulin, carbohydrate
// treatment decisions and diagnosis out of the coach's answers.
public enum CoachContext {

    // MARK: - Number and time formatting (locale independent)

    /// "7.2", 1 decimal.
    static func f1(_ x: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), x) }
    /// Whole number, rounded.
    static func f0(_ x: Double) -> String { String(Int(x.rounded())) }
    /// Up to 2 decimals, trailing zeros dropped: 43, 42.5, 42.25.
    static func fTrim(_ x: Double) -> String {
        let s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), x)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
    /// "HH:mm" from minutes after midnight (wrapped).
    static func hhmm(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
    /// 7.2 hours from minutes.
    static func hours(_ min: Double) -> String { f1(min / 60) }

    // MARK: - Blocks

    /// "Today is Friday 2026-11-13, 08:40 local time. Today's Charge is already scored."
    public static func todayLine(day: String, weekday: String, localTime: String, chargeScored: Bool) -> String {
        "Today is \(weekday) \(day), \(localTime) local time. "
            + (chargeScored ? "Today's Charge is already scored." : "Today's Charge is not scored yet.")
    }

    /// "Profile: age 35, male, 80.0 kg, 180 cm, max heart rate 190 bpm, goal: performance." Unknown (<= 0) parts
    /// are left out; the goal is always there. `sex` is written as given (empty is left out).
    public static func profileLine(age: Int, sex: String, weightKg: Double, heightCm: Double,
                                   maxHR: Int, goal: DayPlan.Goal) -> String? {
        var parts: [String] = []
        if age > 0 { parts.append("age \(age)") }
        let s = sex.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { parts.append(s) }
        if weightKg > 0 { parts.append("\(f1(weightKg)) kg") }
        if heightCm > 0 { parts.append("\(f0(heightCm)) cm") }
        if maxHR > 0 { parts.append("max heart rate \(maxHR) bpm") }
        parts.append("goal: \(goalName(goal))")
        return "Profile: " + parts.joined(separator: ", ") + "."
    }

    static func goalName(_ g: DayPlan.Goal) -> String {
        switch g {
        case .performance: return "performance"
        case .strength: return "strength"
        case .fatLoss: return "fat loss"
        case .endurance: return "endurance"
        case .health: return "general health"
        }
    }

    /// The app's own plan for today, spelled out with its numbers.
    public static func planBlock(_ plan: DayPlan.Plan) -> String {
        var lines = ["TODAY'S PLAN (computed by the app; explain and build on it, do not contradict it without a reason):"]

        let level: String
        switch plan.training {
        case .push: level = "push (a hard session is fine)"
        case .maintain: level = "maintain (a normal session)"
        case .easy: level = "easy (light activity or recovery)"
        }
        var t = "Training: \(level)."
        let reasons = plan.reasons.map(reasonText)
        if !reasons.isEmpty { t += " Because: " + reasons.joined(separator: "; ") + "." }
        lines.append(t)

        var sleep = "Sleep tonight: \(hours(Double(plan.sleep.minutes))) h (\(plan.sleep.minutes) min)"
        if let b = plan.sleep.bedtimeMinutes { sleep += ", bedtime around \(hhmm(b))" }
        lines.append(sleep + ".")

        if let n = plan.nutrition {
            lines.append("Nutrition (estimates, not prescriptions): energy \(n.energyKcal.lowerBound)-\(n.energyKcal.upperBound) kcal"
                + " (resting about \(n.restingKcal) kcal), protein \(n.proteinG.lowerBound)-\(n.proteinG.upperBound) g,"
                + " carbohydrate \(n.carbsG.lowerBound)-\(n.carbsG.upperBound) g (general sports-nutrition range),"
                + " fluids about \(n.fluidMl) ml.")
        }

        if !plan.focus.isEmpty {
            lines.append("Focus: " + plan.focus.map(focusText).joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    static func reasonText(_ r: DayPlan.Reason) -> String {
        switch r {
        case .chargeHigh(let c): return "Charge \(c) (high)"
        case .chargeMid(let c): return "Charge \(c) (middle)"
        case .chargeLow(let c): return "Charge \(c) (low)"
        case .noCharge: return "no Charge scored yet"
        case .shortSleep(let m, let need):
            return "short night: \(hours(Double(m))) h slept against a need of \(hours(Double(need))) h"
        case .loadSharpRise(let ratio): return "training load is \(f2(ratio)) times the usual week (sharp rise)"
        case .hardStreak(let d): return "\(d) hard days in a row"
        }
    }

    static func focusText(_ f: DayPlan.Focus) -> String {
        switch f {
        case .sleepDebt(let m): return "sleep debt of \(m) min"
        case .lowSleepAverage(let avg, let need):
            return "7-day average sleep \(hours(Double(avg))) h against a need of \(hours(Double(need))) h"
        case .irregularWake(let sd): return "irregular wake-up times (standard deviation \(sd) min)"
        case .loadHigh(let r): return "training load \(f2(r)) times the usual week"
        case .loadLow(let r): return "training load only \(f2(r)) times the usual week"
        case .hrvDown(let pct, let recent, let usual):
            return "HRV down \(pct)% (7-day mean \(f0(recent)) ms against \(f0(usual)) ms usual)"
        case .restingHrUp(let bpm, let recent, let usual):
            return "resting heart rate up \(f1(bpm)) bpm (7-day mean \(f1(recent)) against \(f1(usual)) usual)"
        }
    }

    static func f2(_ x: Double) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), x) }

    /// Last night's sleep. `bedtime` and `wake` are preformatted "HH:mm". nil when there is nothing to say.
    public static func lastNightBlock(day: DailyMetric?, bedtime: String?, wake: String?,
                                      restScore: Double?, needMin: Double?, debtMin: Double?) -> String? {
        var parts: [String] = []
        if let b = bedtime, let w = wake, !b.isEmpty, !w.isEmpty { parts.append("asleep \(b) to \(w)") }
        else if let b = bedtime, !b.isEmpty { parts.append("bedtime \(b)") }
        else if let w = wake, !w.isEmpty { parts.append("woke \(w)") }
        if let m = day?.totalSleepMin, m > 0 { parts.append("\(hours(m)) h asleep") }
        if let e = day?.efficiency, e > 0 { parts.append("efficiency \(f0(e <= 1 ? e * 100 : e))%") }
        if let d = day?.deepMin { parts.append("deep \(f0(d)) min") }
        if let r = day?.remMin { parts.append("REM \(f0(r)) min") }
        if let l = day?.lightMin { parts.append("light \(f0(l)) min") }
        if let n = day?.disturbances { parts.append("\(n) disturbances") }
        if let r = restScore { parts.append("Rest score \(f0(r))") }
        if let n = needMin, n > 0 { parts.append("sleep need \(hours(n)) h") }
        if let d = debtMin { parts.append("sleep debt \(f0(max(0, d))) min") }
        guard !parts.isEmpty else { return nil }
        return "LAST NIGHT: " + parts.joined(separator: ", ") + "."
    }

    /// This week's training load against the usual week. nil without a ratio.
    public static func loadLine(_ s: TrainingLoad.Summary?) -> String? {
        guard let s, let ratio = s.ratio, ratio.isFinite, let usual = s.chronicWeekly else { return nil }
        let word: String
        switch s.band ?? TrainingLoad.band(ratio: ratio) {
        case .below: return "Training load: this week \(f0(s.acute)) against a usual week of \(f0(usual)) (TRIMP units), ratio \(f2(ratio)), less than usual."
        case .steady: word = "in line with the usual"
        case .higher: word = "more than usual"
        case .sharpRise: word = "a sharp rise on the usual"
        }
        return "Training load: this week \(f0(s.acute)) against a usual week of \(f0(usual)) (TRIMP units), ratio \(f2(ratio)), \(word)."
    }

    // MARK: - WODs

    /// The user's recent logged WODs, newest first, at most `limit`, from the last `windowDays` days (counted on the
    /// "yyyy-MM-dd" strings). Free-text notes are never included.
    public static func wodBlock(_ wods: [WodLogRow], today: String, limit: Int = 5, windowDays: Int = 30) -> String? {
        let recent = wods
            .filter { w in
                guard let diff = dayDifference(from: w.day, to: today) else { return false }
                return diff >= 0 && diff <= windowDays
            }
            .sorted { ($0.ts, $0.day) > ($1.ts, $1.day) }
            .prefix(max(0, limit))
        guard !recent.isEmpty else { return nil }
        var lines = ["RECENT WODS (newest first):"]
        for w in recent { lines.append("- " + wodLine(w)) }
        return lines.joined(separator: "\n")
    }

    static func wodLine(_ w: WodLogRow) -> String {
        var head = "\(w.day) \(w.title)"
        var kind: [String] = []
        if !w.type.trimmingCharacters(in: .whitespaces).isEmpty { kind.append(w.type) }
        if let f = w.format, !f.trimmingCharacters(in: .whitespaces).isEmpty { kind.append(f) }
        if !kind.isEmpty { head += " (" + kind.joined(separator: ", ") + ")" }

        var facts: [String] = []
        if let r = resultText(w) { facts.append("result \(r)") }
        if let rpe = w.rpe { facts.append("RPE \(fTrim(rpe))") }
        if let rx = w.rx { facts.append(rx ? "RX" : "scaled") }
        var line = head
        if !facts.isEmpty { line += ": " + facts.joined(separator: ", ") }
        let moves = w.movements.map(movementText)
        if !moves.isEmpty { line += "; movements: " + moves.joined(separator: ", ") }
        return line
    }

    static func resultText(_ w: WodLogRow) -> String? {
        switch w.resultKind {
        case .time:
            guard let s = w.resultSeconds, s >= 0 else { return nil }
            return String(format: "%d:%02d", s / 60, s % 60)
        case .roundsReps:
            switch (w.resultRounds, w.resultReps) {
            case let (r?, x?): return "\(r) rounds + \(x) reps"
            case let (r?, nil): return "\(r) rounds"
            case let (nil, x?): return "\(x) reps"
            default: return nil
            }
        case .reps:
            guard let r = w.resultReps else { return nil }
            return "\(r) reps"
        case .weight:
            guard let k = w.resultWeightKg else { return nil }
            return "\(fTrim(k)) kg"
        case .none:
            return nil
        }
    }

    static func movementText(_ m: WodMovement) -> String {
        var s = m.name
        if let sc = m.scheme, !sc.trimmingCharacters(in: .whitespaces).isEmpty { s += " \(sc)" }
        else if let r = m.reps { s += " \(r) reps" }
        if let w = m.weightKg {
            s += " @ \(fTrim(w)) kg"
            if let rx = m.rxWeightKg { s += " (RX \(fTrim(rx)) kg)" }
        } else if let rx = m.rxWeightKg {
            s += " (RX \(fTrim(rx)) kg)"
        }
        return s
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Whole days from `a` to `b` ("yyyy-MM-dd"); positive when `b` is later. nil when either is unparseable.
    static func dayDifference(from a: String, to b: String) -> Int? {
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-")
            guard p.count == 3, p[0].count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
            return utcCalendar.date(from: DateComponents(year: y, month: m, day: d))
        }
        guard let da = date(a), let db = date(b) else { return nil }
        return utcCalendar.dateComponents([.day], from: da, to: db).day
    }

    // MARK: - Language, safety, daily line

    /// "Reply in Italian." (or "Reply in the user's language." for an unknown code).
    public static func languageLine(languageCode: String) -> String {
        let code = languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let names = ["it": "Italian", "en": "English", "de": "German", "es": "Spanish", "fr": "French",
                     "pt": "Portuguese", "zh": "Chinese", "ru": "Russian", "nl": "Dutch", "ja": "Japanese",
                     "ko": "Korean", "pl": "Polish", "tr": "Turkish"]
        if let n = names[code] { return "Reply in \(n)." }
        return "Reply in the user's language."
    }

    public static let safetyLine: String =
        "Safety rules: never give insulin doses, never suggest changes to basal rates, carb ratio or insulin sensitivity, "
        + "and never diagnose. Carbohydrate ranges come from the app's plan and are general sports nutrition, not "
        + "treatment advice. Anything about diabetes treatment goes to the user's diabetes team."

    /// "2026-11-12: charge 71, effort 43.2, sleep 7.2h, rest 84, HRV 62ms, RHR 51bpm" (missing parts left out).
    public static func dayLine(_ d: DailyMetric, restScore: Double?) -> String {
        var parts: [String] = []
        if let c = d.recovery { parts.append("charge \(f0(c))") }
        if let s = d.strain { parts.append("effort \(f1(s))") }
        if let m = d.totalSleepMin, m > 0 { parts.append("sleep \(hours(m))h") }
        if let r = restScore { parts.append("rest \(f0(r))") }
        if let h = d.avgHrv { parts.append("HRV \(f0(h))ms") }
        if let r = d.restingHr { parts.append("RHR \(r)bpm") }
        return parts.isEmpty ? d.day : "\(d.day): " + parts.joined(separator: ", ")
    }
}
