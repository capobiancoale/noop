import Foundation

// MARK: - Why a metric can be empty, and how to get it
//
// Explore lists every metric NOOP knows, but most depend on something the user may not have: a device
// that records it, a file imported in Data Sources, a few nights of history, a profile entry. This is
// the one pure place that says so, per (source, key), so an empty metric explains itself instead of
// showing a bare chart, and the Explore list can tuck the empty ones away.
//
// Honesty rules baked in here: a metric NOOP cannot measure from the user's hardware is said to be
// unavailable, never estimated; the text states what the metric NEEDS, not what the user did wrong.
// Blood oxygen on a WHOOP 5.0/MG: the strap's historical records carry no SpO2 channel NOOP decodes
// (the red/infrared samples exist only in the WHOOP 4.0 layout, and even there WHOOP computes the
// percentage server-side), so there is nothing to show; NOOP leaves it empty rather than guess.

/// Why one metric may have no values, and what would fill it. Both strings are already localized.
struct MetricAvailabilityNote: Equatable {
    /// One sentence: why this metric can be empty.
    let reason: String
    /// One sentence: how to get it.
    let howTo: String
}

enum MetricAvailability {

    /// The note for a catalog metric. Always returns something: an unknown (source, key) gets the generic
    /// "import your history" text, so a new catalog entry never shows an empty explanation.
    static func note(for metric: MetricDescriptor) -> MetricAvailabilityNote {
        note(key: metric.key, source: metric.source)
    }

    static func note(key: String, source: String) -> MetricAvailabilityNote {
        switch source {
        case "apple-health":  return appleHealth(key)
        case "xiaomi-band":   return xiaomi
        case "nutrition-csv": return nutrition
        case "noop-mood":     return mood
        case "manual-vo2max": return manualVO2max
        default:              return strap(key)
        }
    }

    /// Metrics Explore keeps listed even while they have no data: the ones the user can fill in right there.
    /// Measured blood pressure has an "Add a reading" button on its detail, so hiding it behind the "without
    /// data" switch would hide the only way in.
    static func isAlwaysListed(_ metric: MetricDescriptor) -> Bool {
        Repository.isBloodPressureKey(metric.key)
    }

    // MARK: Apple Health

    private static func appleHealth(_ key: String) -> MetricAvailabilityNote {
        switch key {
        case "vo2max":
            return MetricAvailabilityNote(
                reason: String(localized: "Apple Health only has a VO₂ Max when an Apple Watch (or another app) measures and writes it."),
                howTo: String(localized: "It comes from an Apple Watch. NOOP's own estimates are VO₂ Max (at rest) and VO₂ Max (from runs and walks)."))
        case "steps":
            return MetricAvailabilityNote(
                reason: String(localized: "There are no steps in Apple Health yet, and the strap hasn't counted any."),
                howTo: String(localized: "Allow NOOP to read Steps in Apple Health. A WHOOP 5.0/MG also counts steps itself, so wear it and sync."))
        case "active_kcal":
            return MetricAvailabilityNote(
                reason: String(localized: "There is no Active Energy in Apple Health yet, and there is no strap heart rate to estimate it from."),
                howTo: String(localized: "Allow NOOP to read Active Energy in Apple Health, or wear the strap so NOOP can estimate it from heart rate."))
        case "weight", "body_fat", "lean_mass":
            return MetricAvailabilityNote(
                reason: String(localized: "NOOP has no body measurement from Apple Health yet."),
                howTo: String(localized: "Add them in Apple Health, or weigh in with a smart scale that writes to Apple Health."))
        case "bmi":
            return MetricAvailabilityNote(
                reason: String(localized: "BMI is read from Apple Health, which needs both your weight and your height."),
                howTo: String(localized: "Add your weight and height in Apple Health, or weigh in with a smart scale that writes to it."))
        case "waist":
            return MetricAvailabilityNote(
                reason: String(localized: "NOOP has no waist measurement from Apple Health yet."),
                howTo: String(localized: "Add your waist circumference in Apple Health."))
        case "water":
            return MetricAvailabilityNote(
                reason: String(localized: "NOOP has no water intake from Apple Health yet."),
                howTo: String(localized: "Log water in Apple Health, or in an app that writes it there."))
        case "bp_systolic", "bp_diastolic":
            return MetricAvailabilityNote(
                reason: String(localized: "NOOP shows measured blood pressure only. A wrist strap can't measure it reliably without a cuff, so NOOP doesn't estimate it."),
                howTo: String(localized: "Measure with a cuff that writes to Apple Health, or add a reading here."))
        case "glucose_postex_min", "glucose_postex_lows":
            return MetricAvailabilityNote(
                reason: String(localized: "This needs glucose readings during a workout or in the two hours after it."),
                howTo: String(localized: "Record a workout (strap or Apple Health) on a day your glucose sensor is writing to Apple Health."))
        case "glucose_cv", "glucose_overnight_avg", "glucose_overnight_min":
            return MetricAvailabilityNote(
                reason: String(localized: "This needs enough glucose readings in the day (overnight values need readings during the night)."),
                howTo: String(localized: "Needs a CGM writing to Apple Health, with NOOP allowed to read Blood Glucose."))
        case "insulin_total":
            return MetricAvailabilityNote(
                reason: String(localized: "Insulin comes from a pump or automated insulin app (like Loop) that writes insulin delivery to Apple Health."),
                howTo: String(localized: "Let that app share Insulin Delivery in Apple Health, and allow NOOP to read it."))
        case "insulin_basal", "insulin_bolus":
            return MetricAvailabilityNote(
                reason: String(localized: "Basal and bolus are split by the label the app that writes the doses gives each one; without it only the total is shown."),
                howTo: String(localized: "Let your insulin app share Insulin Delivery in Apple Health, and allow NOOP to read it."))
        case "carbs_g":
            return MetricAvailabilityNote(
                reason: String(localized: "Carbs come from an app (like Loop) that writes carbohydrates to Apple Health."),
                howTo: String(localized: "Let that app share Carbohydrates in Apple Health, and allow NOOP to read them."))
        default:
            if key.hasPrefix("glucose_") {
                return MetricAvailabilityNote(
                    reason: String(localized: "Glucose comes from a CGM or an automated insulin app (like Loop) that writes it to Apple Health."),
                    howTo: String(localized: "Needs a CGM writing to Apple Health, with NOOP allowed to read Blood Glucose."))
            }
            return generic
        }
    }

    // MARK: Other imported sources

    private static let xiaomi = MetricAvailabilityNote(
        reason: String(localized: "This comes from a Xiaomi / Mi Band."),
        howTo: String(localized: "Only with a Xiaomi band: import its Mi Fitness export in Data Sources."))

    private static let nutrition = MetricAvailabilityNote(
        reason: String(localized: "Nutrition comes from a food-tracker export."),
        howTo: String(localized: "Import a nutrition CSV in Data Sources."))

    private static let mood = MetricAvailabilityNote(
        reason: String(localized: "Mood is the daily check-in you log yourself."),
        howTo: String(localized: "Log how you feel in the Mind check-in; one entry a day is enough."))

    private static let manualVO2max = MetricAvailabilityNote(
        reason: String(localized: "These are VO₂ Max values you measured and entered yourself."),
        howTo: String(localized: "Add one on the VO₂ Max screen after a lab test, a field test or a reading from another device."))

    private static let generic = MetricAvailabilityNote(
        reason: String(localized: "There is no data for this metric yet."),
        howTo: String(localized: "Import your history in Data Sources, or wear the strap and sync."))

    // MARK: WHOOP strap (imported WHOOP export + what NOOP computes on-device)

    private static func strap(_ key: String) -> MetricAvailabilityNote {
        switch key {
        case "recovery":
            return MetricAvailabilityNote(
                reason: String(localized: "Charge compares you with your own baseline, which needs at least 4 nights of heart rate variability and resting heart rate first."),
                howTo: String(localized: "Wear the strap every night and sync it. Charge appears once the fourth night is in."))
        case "hrv", "rhr":
            return MetricAvailabilityNote(
                reason: String(localized: "Heart rate variability and resting heart rate are measured while you sleep."),
                howTo: String(localized: "Wear the strap overnight and sync it in the morning."))
        case "resp_rate":
            return MetricAvailabilityNote(
                reason: String(localized: "Breathing rate is estimated overnight from the time between heartbeats, so it needs a night of sleep with clean beat data."),
                howTo: String(localized: "Wear the strap overnight, snug against the skin, and sync it."))
        case "spo2":
            return MetricAvailabilityNote(
                reason: String(localized: "WHOOP 5.0/MG doesn't send blood oxygen to apps other than WHOOP's yet. NOOP shows no estimate rather than a guess."),
                howTo: String(localized: "A WHOOP export imported in Data Sources carries the value WHOOP computed, and a Xiaomi band reports its own."))
        case "skin_temp":
            return MetricAvailabilityNote(
                reason: String(localized: "Skin temperature is shown as the change from your own baseline, which needs at least 4 nights of wrist temperature."),
                howTo: String(localized: "Wear the strap overnight for 4 nights and sync it."))
        case "avg_hr", "max_hr":
            return MetricAvailabilityNote(
                reason: String(localized: "Average and maximum heart rate need at least an hour of strap heart rate on the day."),
                howTo: String(localized: "Wear the strap and sync it."))
        case "energy_kcal", "strain":
            return MetricAvailabilityNote(
                reason: String(localized: "Calories and Effort are built from the strap's heart rate over the day."),
                howTo: String(localized: "Wear the strap and sync it. Your age, sex and weight in Settings make them more accurate."))
        case "sleep_performance", "in_bed_min", "sleep_total_min", "sleep_efficiency", "sleep_deep_min",
             "sleep_rem_min", "sleep_light_min", "restorative_pct", "restorative_min":
            return MetricAvailabilityNote(
                reason: String(localized: "Rest figures come from a night of sleep detected from the strap."),
                howTo: String(localized: "Wear the strap to bed and sync it in the morning."))
        case "hours_vs_needed_pct", "sleep_consistency", "sleep_need_min", "sleep_debt_min":
            return MetricAvailabilityNote(
                reason: String(localized: "This figure comes from a WHOOP export. NOOP shows its own sleep need, debt and consistency on the Sleep screen."),
                howTo: String(localized: "Import your WHOOP export in Data Sources, or open Sleep."))
        case "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min":
            return MetricAvailabilityNote(
                reason: String(localized: "Zone and strength minutes come from the workouts in a WHOOP export."),
                howTo: String(localized: "Import your WHOOP export in Data Sources. Each workout's own detail shows its time in zones."))
        case "stress":
            return MetricAvailabilityNote(
                reason: String(localized: "Day Stress comes from a WHOOP export. NOOP shows its own stress readings on the Stress screen."),
                howTo: String(localized: "Import your WHOOP export in Data Sources, or open Stress."))
        case "steps_est":
            return MetricAvailabilityNote(
                reason: String(localized: "The step estimate is calibrated against steps your phone also counted, so it needs at least 3 days with both."),
                howTo: String(localized: "Allow NOOP to read Steps in Apple Health and carry your phone for a few days. A WHOOP 5.0/MG reports Steps directly."))
        case "fitness_age":
            return MetricAvailabilityNote(
                reason: String(localized: "Fitness Age needs your age and sex, and resting heart rate on at least 4 of the last 7 nights."),
                howTo: String(localized: "Set your age and sex in Settings, wear the strap overnight and sync. It updates weekly."))
        case "vo2max_est":
            return MetricAvailabilityNote(
                reason: String(localized: "This VO₂ Max is estimated from resting heart rate, your age and your waist, so it needs all three."),
                howTo: String(localized: "Add your waist circumference in Settings and wear the strap overnight. It updates weekly."))
        case "vo2max_exercise":
            return MetricAvailabilityNote(
                reason: String(localized: "This VO₂ Max needs a walk or run of at least 10 minutes and 1 km, with distance and heart rate."),
                howTo: String(localized: "Record one with the strap, or import runs and walks from Apple Health or a GPX, TCX or FIT file in Data Sources."))
        case "vitality", "body_age":
            return MetricAvailabilityNote(
                reason: String(localized: "Vitality and Body Age need your age and a week with at least three of: resting heart rate, sleep, heart rate variability and steps."),
                howTo: String(localized: "Set your age in Settings, then wear the strap day and night. They update weekly."))
        default:
            return generic
        }
    }
}
