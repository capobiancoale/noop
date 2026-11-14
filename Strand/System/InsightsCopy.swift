import Foundation
import StrandAnalytics

/// The wording of the Insights cards, built in the app so it follows the UI language. The engines
/// (`BehaviorInsights`, `EffectRanker`, `DoseResponse`) keep their plain-English sentences: the coach
/// prompt reads them and the Android twin shares them, so they are never shown as they are. The cards
/// read each sentence from here, from the numbers the engine measured.
///
/// Every sentence is a whole key (one per direction and basis) with positional placeholders, so a
/// translation is free to reorder the parts. Association, never cause: nothing here says a behaviour
/// "made" a number move.
enum InsightsCopy {

    /// The engines name an outcome in English ("Charge", "Rest", "HRV", "Resting HR"); this is the name
    /// to show. An unknown name is shown as it is.
    static func displayOutcome(_ engineName: String) -> String {
        switch engineName {
        case "Charge":     return String(localized: "Charge")
        case "Rest":       return String(localized: "Rest")
        case "Resting HR": return String(localized: "Resting HR")
        default:           return engineName
        }
    }

    // MARK: - Lead / lag

    /// "same day" / "next morning" / "2 mornings later": when the strongest effect showed up.
    static func leadLag(_ lag: Int) -> String {
        switch lag {
        case 0: return String(localized: "same day")
        case 1: return String(localized: "next morning")
        default: return String(localized: "\(lag) mornings later")
        }
    }

    // MARK: - Behaviour effect

    /// "On days you logged ‘…’, Charge was 9% lower (avg 37 vs 41, n=9 vs 111)." The behaviour is a
    /// journal question; a built-in one is shown translated, an imported or custom one as written.
    static func effectSentence(_ e: BehaviorEffect) -> String {
        let behavior = JournalCatalogStore.displayLabel(forQuestion: e.behavior)
        let outcome = e.outcome
        let avgWith = Int(e.meanWith.rounded())
        let avgWithout = Int(e.meanWithout.rounded())
        let nWith = e.nWith
        let nWithout = e.nWithout
        if e.delta == 0 {
            return String(localized: "On days you logged ‘\(behavior)’, \(outcome) was no different (avg \(avgWith) vs \(avgWithout), n=\(nWith) vs \(nWithout)).")
        }
        let higher = e.delta > 0
        if let pct = e.pctChange {
            let percent = Int(abs(pct).rounded())
            return higher
                ? String(localized: "On days you logged ‘\(behavior)’, \(outcome) was \(percent)% higher (avg \(avgWith) vs \(avgWithout), n=\(nWith) vs \(nWithout)).")
                : String(localized: "On days you logged ‘\(behavior)’, \(outcome) was \(percent)% lower (avg \(avgWith) vs \(avgWithout), n=\(nWith) vs \(nWithout)).")
        }
        let magnitude = DisplayNumber.decimal(abs(e.delta))
        return higher
            ? String(localized: "On days you logged ‘\(behavior)’, \(outcome) was \(magnitude) higher (avg \(avgWith) vs \(avgWithout), n=\(nWith) vs \(nWithout)).")
            : String(localized: "On days you logged ‘\(behavior)’, \(outcome) was \(magnitude) lower (avg \(avgWith) vs \(avgWithout), n=\(nWith) vs \(nWithout)).")
    }

    /// The ranked card's sentence: the effect, then when it showed up, "… (2 mornings later)."
    static func rankedSentence(_ r: RankedEffect) -> String {
        let base = effectSentence(r.effect)
        // Drop the sentence's own full stop, add the lead/lag clause, close it again.
        let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
        return "\(trimmed) (\(leadLag(r.lag)))."
    }

    // MARK: - Activity cost

    /// "Sessions like this usually cost you about 3 Charge points the next morning and take about 2 days
    /// to bounce back (n=6)." Built as a head (direction and points, singular or plural) plus a tail (the
    /// bounce-back clause, or just the sample size), each a whole key, so it reads right in both numbers.
    /// "Barely moves" below a point, either way.
    static func activityCostSentence(_ c: ActivityCost) -> String {
        let magnitude = abs(c.delta)
        let n = c.n
        if magnitude < ActivityCostEngine.barelyMovesPoints {
            return String(localized: "Sessions like this barely move your next-day Charge (n=\(n)).")
        }
        let points = Int(magnitude.rounded())
        let costs = c.delta >= 0
        let head: String
        switch (costs, points == 1) {
        case (true, true):   head = String(localized: "Sessions like this usually cost you about \(points) Charge point the next morning")
        case (true, false):  head = String(localized: "Sessions like this usually cost you about \(points) Charge points the next morning")
        case (false, true):  head = String(localized: "Sessions like this usually lift you by about \(points) Charge point the next morning")
        case (false, false): head = String(localized: "Sessions like this usually lift you by about \(points) Charge points the next morning")
        }
        guard let days = c.daysToBaseline else {
            return head + " " + String(localized: "(n=\(n)).")
        }
        let tail = days == 1
            ? String(localized: "and take about \(days) day to bounce back (n=\(n)).")
            : String(localized: "and take about \(days) days to bounce back (n=\(n)).")
        return head + " " + tail
    }

    // MARK: - Dose-response

    /// The dose-response card's read: still the typical pattern, contradicted by the user's data, or
    /// their own. `n` is how many of their days it rests on.
    static func doseSentence(_ r: DoseResponse) -> String {
        let magnitude = DisplayNumber.decimal(abs(r.perUnit))
        let outcome = displayOutcome(r.outcome)
        let n = r.nUser
        let lower = r.perUnit <= 0
        if r.priorDominated {
            return lower
                ? String(localized: "Each extra unit typically lines up with about \(magnitude) \(outcome) lower: typical patterns, not yet yours (n=\(n)).")
                : String(localized: "Each extra unit typically lines up with about \(magnitude) \(outcome) higher: typical patterns, not yet yours (n=\(n)).")
        }
        if r.contradictsPrior {
            return String(localized: "In your data so far, this doesn\u{2019}t move your \(outcome) the way it typically does (n=\(n)).")
        }
        return lower
            ? String(localized: "Each extra unit tends to line up with about \(magnitude) \(outcome) lower for you (n=\(n)).")
            : String(localized: "Each extra unit tends to line up with about \(magnitude) \(outcome) higher for you (n=\(n)).")
    }
}
