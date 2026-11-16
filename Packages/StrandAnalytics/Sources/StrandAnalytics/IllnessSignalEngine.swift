import Foundation

// IllnessSignalEngine.swift — multi-signal "Heads-Up" early-warning with explicit false-positive
// suppression. Pure, deterministic, DB-free.
//
// INDEPENDENT implementation of the published multi-parameter pre-symptomatic signature documented
// across the wearable literature (e.g. the Stanford/Snyder resting-HR-elevation work and successor
// studies): resting HR ↑, skin temperature ↑, HRV (RMSSD) ↓ and respiration ↑ tend to move TOGETHER,
// days before symptoms. NOOP re-derives the PATTERN, transparently, against the user's OWN rolling
// baseline — never a population cutoff.
//
// This replaces the blunt 2-of-4 threshold rule in AppModel.evaluateIllness with:
//   • a calibrated 0–100 composite anomaly score (so the surface can read "mild" vs "strong"),
//   • a minimum-corroboration gate (≥ 2 signals) so a single noisy night never fires,
//   • EXPLICIT confounder suppression cross-checked against the same-day journal tags
//     (alcohol / stress / sauna / late-or-intense workout / travel), which is the differentiating
//     part — alcohol elevates RHR + skin temp and crushes HRV exactly like early illness, so a night
//     out must NOT cry wolf,
//   • a visible "why" (which signals fired) AND "what was ruled out" (which confounders were present),
//   • honest gating: a trusted baseline is required; below that the engine is silent.
//
// A LOW GLUCOSE AT NIGHT is a confounder too. Nocturnal hypoglycaemia is a physiological stress that
// activates the sympatho-adrenal system and disturbs the heart's autonomic control (Cryer, N Engl J Med
// 2013;369:362–372; Seaquist et al., Diabetes Care 2013;36:1384–1395), and in people with type 1
// diabetes recorded with a CGM and an ECG the night's heart rate and heart-rate variability do change
// during spontaneous nocturnal lows (Koivikko et al., Diabetes Care 2012;35:1585–1590: LF power of HRV
// down, read as sympathetic activation; Koivikko et al., Acta Diabetol 2017;54:251–256: heart rate
// 65 → 85 bpm; Novodvorsky et al., Diabetes Care 2017;40:655–662: more bradycardia and a longer QTc).
// The direction of the heart-rate change is not uniform across those studies, which is exactly why a
// night low is surfaced as "a plainer explanation exists" and not as proof either way. A "low" is
// level 1 hypoglycaemia, a glucose below 70 mg/dL (Battelino et al., Diabetes Care 2019;42:1593–1603;
// Lancet Diabetes Endocrinol 2023;11:42–57).
//
// The raise threshold can be personalised (never below the shipped 50) by `IllnessCalibration`, which
// fixes the FALSE-ALARM rate on the user's own healthy days. That is a Neyman–Pearson style choice (fix
// the false-alarm rate, keep the detector), as in Temple et al., J Infect Dis 2023;227:864–872, who set
// the alarm threshold so that no alarm fired on the healthy baseline days. The detector's SENSITIVITY to
// a real illness cannot be calibrated on one person's data (a few illnesses a year); it comes from the
// published studies.
//
// WELLNESS ONLY — APPROXIMATE, NOT A DIAGNOSIS. The engine never names a condition, illness, infection
// or fever; the copy is always "a heads-up to rest" / "consider taking it easy" (see the shipped
// IllnessNotifier copy: "On-device estimate (approximate) — not a diagnosis").
public enum IllnessSignalEngine {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Composite score (0–100) at/above which the heads-up is RAISED. Below this it is "mild" — surfaced
    /// only in a detail view, never a notification (keeps the banner from re-introducing noise).
    public static let raiseThreshold: Double = 50.0
    /// Score floor below which there is nothing worth saying at all (engine returns `.quiet`).
    public static let mildThreshold: Double = 25.0
    /// Minimum number of signals pointing the illness way before anything can raise — guards against a
    /// single noisy night driving the score on its own.
    public static let minCorroboratingSignals: Int = 2

    /// A signal's |z| must reach this to count as "firing" toward the score. Roughly the user's own ~95th
    /// percentile night (matches VitalBands.sigmaK), so normal night-to-night wobble doesn't register.
    public static let signalZThreshold: Double = 2.0
    /// Per-signal sub-score is `min(perSignalCap, kZToScore · max(0, zIllnessward − signalZThreshold))`,
    /// then the composite is their sum clamped to 100. Each strong signal caps so no single one saturates.
    public static let kZToScore: Double = 22.0
    public static let perSignalCap: Double = 40.0

    /// When a confounder is present, the composite is multiplied by this and the level is downgraded —
    /// the signals are real, but a plainer explanation exists, so we soften rather than scream.
    public static let confounderDampen: Double = 0.45

    /// A night counts as having had a low when the lowest CGM reading between 00:00 and 06:00 local is
    /// below this (mg/dL): level 1 hypoglycaemia, Battelino et al., Diabetes Care 2019;42:1593–1603.
    public static let nocturnalLowMgdl: Double = 70.0
    /// Skin-temperature deviation (°C) that counts as one personal spread (matches the `skin_temp`
    /// floorSpread in `Baselines.metricCfg`): the stored value is already a deviation, so it is z-scored
    /// against this zero-centred spread.
    public static let skinTempSpreadC: Double = 0.3

    // MARK: - Inputs

    /// One signal's recent-vs-baseline reading, already z-scored against the personal baseline by the
    /// caller (reusing `Baselines.deviation`). `zIllnessward` is the deviation ORIENTED so that a
    /// positive value always means "more illness-like": RHR ↑, skin-temp ↑, respiration ↑ pass their raw
    /// z; HRV ↓ passes the NEGATED z (a drop is illness-ward). `present == false` means the signal had no
    /// usable data this window and is skipped (not counted as corroboration).
    public struct SignalReading: Equatable, Sendable {
        public let zIllnessward: Double
        public let present: Bool
        public init(zIllnessward: Double, present: Bool = true) {
            self.zIllnessward = zIllnessward
            self.present = present
        }
    }

    /// All four signal readings for the recent window. Any may be absent (sparse 5/MG nights).
    public struct Inputs: Equatable, Sendable {
        public var restingHR: SignalReading?   // z of recent RHR vs baseline (↑ illness-ward)
        public var skinTemp: SignalReading?    // z of recent skin-temp deviation vs baseline (↑ illness-ward)
        public var hrv: SignalReading?         // NEGATED z of recent HRV vs baseline (drop = illness-ward)
        public var respiration: SignalReading? // z of recent respiration vs baseline (↑ illness-ward)
        public init(restingHR: SignalReading? = nil, skinTemp: SignalReading? = nil,
                    hrv: SignalReading? = nil, respiration: SignalReading? = nil) {
            self.restingHR = restingHR; self.skinTemp = skinTemp
            self.hrv = hrv; self.respiration = respiration
        }
    }

    /// Same-day behaviour context that can explain an anomaly away. All default-false / nil so a caller
    /// with no journal still gets the raw signal read. `travelPhaseJump` is the cross-feature hook — the
    /// CircadianEngine can flag a detected body-clock jump (jet lag), which itself shifts temp + RHR.
    public struct Context: Equatable, Sendable {
        public var alcohol: Bool
        public var stress: Bool
        public var sauna: Bool
        public var hardOrLateWorkout: Bool
        public var travelPhaseJump: Bool
        public var alreadyUnwell: Bool
        /// True iff the caller's baseline for the anomaly is `trusted` (≥ 14 valid nights, not stale).
        /// Below this the engine stays silent — we don't warn off a cold-start baseline.
        public var baselineTrusted: Bool
        /// True iff the lowest CGM glucose between 00:00 and 06:00 on one of the recent nights was below
        /// `nocturnalLowMgdl`. A night low disturbs the heart's autonomic control, so the night's heart
        /// rate / HRV (and sweating, hence skin temperature) have a plainer explanation than illness.
        /// Default false: no glucose data keeps the behaviour exactly as it was.
        public var nocturnalLow: Bool
        /// The user's own raise threshold from `IllnessCalibration`, or nil when not calibrated. The
        /// raise check uses `max(raiseThreshold, personalRaiseThreshold ?? raiseThreshold)`, so a
        /// personal value can only make the alert stricter, never more sensitive than the default.
        public var personalRaiseThreshold: Double?
        public init(alcohol: Bool = false, stress: Bool = false, sauna: Bool = false,
                    hardOrLateWorkout: Bool = false, travelPhaseJump: Bool = false,
                    alreadyUnwell: Bool = false, baselineTrusted: Bool = true,
                    nocturnalLow: Bool = false, personalRaiseThreshold: Double? = nil) {
            self.alcohol = alcohol; self.stress = stress; self.sauna = sauna
            self.hardOrLateWorkout = hardOrLateWorkout; self.travelPhaseJump = travelPhaseJump
            self.alreadyUnwell = alreadyUnwell; self.baselineTrusted = baselineTrusted
            self.nocturnalLow = nocturnalLow; self.personalRaiseThreshold = personalRaiseThreshold
        }
    }

    // MARK: - Output

    /// How loud the heads-up is. `.quiet` shows nothing; `.alreadyUnwell` is the "rest up" path when the
    /// user has already logged feeling ill; `.suppressed` is "signals up, but a confounder explains it".
    public enum Level: String, Equatable, Sendable, Codable {
        case quiet           // nothing worth saying (below mild, or not enough corroboration, or untrusted baseline)
        case mild            // some signals up — detail view only, no notification
        case raised          // clear multi-signal anomaly, no confounder — surface + notify
        case suppressed      // anomaly present but a behaviour tag / travel explains it — quietly informative
        case alreadyUnwell   // user logged feeling unwell — "rest up", not a scare
    }

    public struct Result: Equatable, Sendable {
        /// 0–100 composite anomaly score (post-dampening for the suppressed level so the surface matches).
        public let score: Double
        public let level: Level
        /// Human-readable reasons a signal fired, e.g. "RHR +6", "HRV −22%", "skin temp +0.7 °C". The
        /// caller supplies the rendered phrases; the engine decides which to include (only firing ones).
        public let firedSignals: [String]
        /// Named confounders that were present and damped/explained the score, e.g. "alcohol", "travel".
        public let suppressedBy: [String]
        /// Count of signals over the firing threshold (corroboration), regardless of level.
        public let signalCount: Int
        /// One-line non-clinical copy, terminating in the shipped not-a-diagnosis framing where it raises.
        public let copy: String

        public init(score: Double, level: Level, firedSignals: [String], suppressedBy: [String],
                    signalCount: Int, copy: String) {
            self.score = score; self.level = level; self.firedSignals = firedSignals
            self.suppressedBy = suppressedBy; self.signalCount = signalCount; self.copy = copy
        }
    }

    /// Standing not-a-diagnosis tail reused verbatim from the shipped IllnessNotifier copy.
    public static let disclaimerTail = "On-device estimate - not a diagnosis."

    // MARK: - Evaluate

    /// Score the recent window and decide the heads-up level + copy.
    ///
    /// `firedLabels` maps a signal key to the caller-rendered phrase to show when that signal fires
    /// (e.g. ["restingHR": "RHR +6", "hrv": "HRV −22%"]). Only keys for signals that clear
    /// `signalZThreshold` are surfaced. Keeping the rendering in the caller keeps the engine free of
    /// number-formatting locale concerns and identical across platforms.
    public static func evaluate(_ inputs: Inputs, context: Context,
                                firedLabels: [String: String] = [:]) -> Result {
        let (score, firedKeys) = composite(inputs)
        let signalCount = firedKeys.count
        let firedSignals = firedKeys.compactMap { firedLabels[$0] }

        // Gate 0: untrusted baseline → silent (don't warn off a cold-start). Score still reported for a
        // detail view, but never raised.
        if !context.baselineTrusted {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Still learning your baseline - keeping an eye out.")
        }

        // Already-unwell path: the user told us. Switch from "early warning" to a gentle "rest up" and
        // never scare — regardless of score (their log is the ground truth).
        if context.alreadyUnwell {
            let agreeing = score >= mildThreshold && signalCount >= 1
            let copy = agreeing
                ? "Rest up - you logged feeling unwell, and your numbers agree. \(disclaimerTail)"
                : "Rest up - you logged feeling unwell. Take it easy today. \(disclaimerTail)"
            return Result(score: score, level: .alreadyUnwell, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy)
        }

        // Corroboration + magnitude gate: need ≥ 2 firing signals and a mild-or-better composite, else quiet.
        guard signalCount >= minCorroboratingSignals, score >= mildThreshold else {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Nothing notable - your signals look like your normal range.")
        }

        // Confounder suppression — the differentiating part. Collect every present behaviour/travel tag
        // that offers a plainer explanation; if any are present, dampen the score and downgrade.
        var suppressedBy: [String] = []
        if context.alcohol { suppressedBy.append("alcohol") }
        if context.stress { suppressedBy.append("stress") }
        if context.sauna { suppressedBy.append("sauna") }
        if context.hardOrLateWorkout { suppressedBy.append("a hard or late workout") }
        if context.travelPhaseJump { suppressedBy.append("travel") }
        if context.nocturnalLow { suppressedBy.append("a low glucose at night") }

        let signalsPhrase = firedSignals.isEmpty ? "Some signals are up" : firedSignals.joined(separator: ", ")

        if !suppressedBy.isEmpty {
            let dampened = score * confounderDampen
            let reason = joinReasons(suppressedBy)
            let copy = "Some signals are up (\(signalsPhrase)), but you logged \(reason) - likely that, "
                + "not illness. \(disclaimerTail)"
            return Result(score: dampened, level: .suppressed, firedSignals: firedSignals,
                          suppressedBy: suppressedBy, signalCount: signalCount, copy: copy)
        }

        // No confounder. Mild stays in the detail view; a strong composite raises.
        if score < effectiveRaiseThreshold(personal: context.personalRaiseThreshold) {
            let copy = "A few signals are mildly up (\(signalsPhrase)). Nothing alarming - worth a calmer "
                + "day. \(disclaimerTail)"
            return Result(score: score, level: .mild, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount, copy: copy)
        }

        let ruledOut = "no alcohol or travel logged"
        let copy = "Heads-up - your body looks strained. \(signalsPhrase). With \(ruledOut), consider "
            + "taking it easy. \(disclaimerTail)"
        return Result(score: score, level: .raised, firedSignals: firedSignals,
                      suppressedBy: [], signalCount: signalCount, copy: copy)
    }

    // MARK: - Scoring helpers (shared by `evaluate` and the calibration replay)

    /// The composite 0–100 score and the keys of the signals over the firing threshold, in the fixed
    /// order restingHR, skinTemp, hrv, respiration. The ONE place the score is computed, so the live
    /// alert and `IllnessCalibration`'s replay can never disagree.
    static func composite(_ inputs: Inputs) -> (score: Double, firedKeys: [String]) {
        // Order is fixed so firedSignals is deterministic across platforms.
        let ordered: [(key: String, reading: SignalReading?)] = [
            ("restingHR", inputs.restingHR),
            ("skinTemp", inputs.skinTemp),
            ("hrv", inputs.hrv),
            ("respiration", inputs.respiration),
        ]

        var rawScore = 0.0
        var firedKeys: [String] = []
        for (key, reading) in ordered {
            guard let r = reading, r.present else { continue }
            let over = r.zIllnessward - signalZThreshold
            guard over > 0 else { continue }
            firedKeys.append(key)
            rawScore += min(perSignalCap, kZToScore * over)
        }
        return (min(100.0, rawScore), firedKeys)
    }

    /// The threshold the raise check actually uses: the shipped `raiseThreshold`, or the user's own
    /// calibrated value when that is stricter. Never below the shipped default.
    static func effectiveRaiseThreshold(personal: Double?) -> Double {
        max(raiseThreshold, personal ?? raiseThreshold)
    }

    /// True iff a day with no confounder, a trusted baseline and this composite would RAISE: at least
    /// `minCorroboratingSignals` firing signals, a mild-or-better score, and a score at or above the
    /// effective raise threshold. `evaluate` reaches `.raised` under exactly these conditions (pinned by
    /// a test), and the calibration replay counts its false alarms with this same predicate.
    static func wouldRaise(score: Double, signalCount: Int, personalRaiseThreshold: Double?) -> Bool {
        signalCount >= minCorroboratingSignals
            && score >= mildThreshold
            && score >= effectiveRaiseThreshold(personal: personalRaiseThreshold)
    }

    // MARK: - Window inputs (the live alert and the calibration replay share this one code path)

    /// One day's overnight vitals as the engine reads them (plain numbers, no storage types).
    public struct DayVitals: Equatable, Sendable {
        public let day: String            // YYYY-MM-DD
        public let restingHR: Double?
        public let hrv: Double?
        public let respiration: Double?
        /// Stored skin-temperature DEVIATION in °C (not an absolute temperature).
        public let skinTempDevC: Double?
        public init(day: String, restingHR: Double? = nil, hrv: Double? = nil,
                    respiration: Double? = nil, skinTempDevC: Double? = nil) {
            self.day = day; self.restingHR = restingHR; self.hrv = hrv
            self.respiration = respiration; self.skinTempDevC = skinTempDevC
        }
    }

    /// Everything the engine and the caller's wording need for one day's window: the four z-scored
    /// readings, whether the baseline is trusted, and the raw movements behind the "why" phrases.
    public struct Window: Equatable, Sendable {
        public let inputs: Inputs
        /// True iff the resting-HR or the HRV baseline is trusted (≥ 14 valid nights, not stale).
        public let baselineTrusted: Bool
        /// Recent mean resting HR minus the baseline mean (bpm), only when positive.
        public let restingHRRise: Double?
        /// Percentage by which recent HRV sits under the baseline mean, only when positive.
        public let hrvDropPercent: Double?
        /// Recent mean skin-temperature deviation (°C), only when positive.
        public let skinTempRiseC: Double?
        /// True iff recent mean respiration is above the baseline mean.
        public let respirationUp: Bool
    }

    /// Recent window: the last `recentDayCount` entries of the history.
    public static let recentDayCount = 2
    /// Baseline window: the last `baselineSpan` entries, less the final `baselineGap` (the recent two
    /// plus one buffer day), i.e. ~28 days ending 3 days before the last one.
    public static let baselineSpan = 31
    public static let baselineGap = 3

    /// Build the engine inputs for the day at `index` of `history` (oldest first), using ONLY entries
    /// up to and including that day. The recent window is the last two entries; the baseline is the
    /// ~28 entries ending three entries earlier, folded with `Baselines.foldHistory` (so a trusted
    /// baseline needs ≥ 14 valid nights). Every signal is oriented illness-ward: resting HR, respiration
    /// and skin temperature pass their z, HRV passes the NEGATED z. Returns nil when `index` is not in
    /// the history.
    public static func inputs(history: [DayVitals], endingAt index: Int) -> Window? {
        guard history.indices.contains(index) else { return nil }
        let upto = history[0...index]
        let recent = Array(upto.suffix(recentDayCount))
        let base = Array(upto.suffix(baselineSpan).dropLast(baselineGap))
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }
        func rm(_ kp: (DayVitals) -> Double?) -> Double? { mean(recent.compactMap(kp)) }

        // Each signal's illness-ward z against the personal baseline (Baselines.deviation). The baseline
        // is folded over the pre-recent history; a trusted baseline (≥14 nights) is the engine's gate
        // for actually raising.
        func signal(_ kp: (DayVitals) -> Double?, cfgKey: String,
                    illnessUp: Bool) -> (SignalReading, Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = rm(kp) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let z = illnessUp ? dev.z : -dev.z   // HRV drop is illness-ward → negate
            return (SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHR }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.hrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respiration }, cfgKey: "resp", illnessUp: true)
        // Skin-temp deviation: a stored °C delta, z-scored against a zero-centred personal spread so a
        // +0.6 °C reads as a meaningful z without needing a separate baseline column.
        var skin: SignalReading? = nil
        if let recentSkin = rm({ $0.skinTempDevC }) {
            skin = SignalReading(zIllnessward: recentSkin / skinTempSpreadC)
        }

        // Raw movements behind the caller's "why" phrases (only the firing ones are ever shown).
        var rhrRise: Double? = nil
        if let r = rm({ $0.restingHR }), let b = mean(base.compactMap { $0.restingHR }), r > b {
            rhrRise = r - b
        }
        var hrvDrop: Double? = nil
        if let r = rm({ $0.hrv }), let b = mean(base.compactMap { $0.hrv }), b > 0, r < b {
            hrvDrop = (1 - r / b) * 100
        }
        var skinRise: Double? = nil
        if let r = rm({ $0.skinTempDevC }), r > 0 { skinRise = r }
        var respUp = false
        if let r = rm({ $0.respiration }), let b = mean(base.compactMap { $0.respiration }), r > b {
            respUp = true
        }

        // baselineTrusted: require the HRV/RHR baselines to be trusted before the engine may raise.
        let trusted = (rhr?.1 ?? false) || (hrv?.1 ?? false)
        let inputs = Inputs(restingHR: rhr?.0, skinTemp: skin, hrv: hrv?.0, respiration: resp?.0)
        return Window(inputs: inputs, baselineTrusted: trusted, restingHRRise: rhrRise,
                      hrvDropPercent: hrvDrop, skinTempRiseC: skinRise, respirationUp: respUp)
    }

    // MARK: - Helpers

    /// Join named confounders into a natural list ("alcohol", "alcohol and stress", "a, b and c").
    static func joinReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "something"
        case 1: return reasons[0]
        case 2: return "\(reasons[0]) and \(reasons[1])"
        default:
            let head = reasons.dropLast().joined(separator: ", ")
            return "\(head) and \(reasons.last!)"
        }
    }
}
