# NOOP Analytics

On-device analytics for **NOOP** — a standalone, fully offline companion app for WHOOP straps (4.0 and 5.0/MG). NOOP talks to *your own* strap over Bluetooth, stores everything locally in SQLite, and computes its three daily scores plus HRV and sleep staging on-device. There is no cloud and no account involved in any of the math described here.

## NOOP's three daily scores — Charge / Effort / Rest

NOOP gives you **three daily scores, each on a 0–100 scale**:

| Score | Answers | Engine | Internal key | Was called |
|---|---|---|---|---|
| **Charge** | How recovered are you? | `RecoveryScorer` | `recovery` | Recovery |
| **Effort** | How hard did your heart work? | `StrainScorer` | `strain` | Strain (0–21) |
| **Rest** | How restorative was your sleep? | Rest composite (`AnalyticsEngine`) | `sleep_performance` | Sleep Performance |

Each score is built from your strap's raw signals using **published, peer-reviewed sport science** (Task Force 1996 HRV, Karvonen %HRR, Edwards/Banister TRIMP, Tanaka HRmax — all cited in full below) and computed **entirely on your device**.

They are **NOT WHOOP's scores.** We don't have WHOOP's private algorithms and don't pretend to. NOOP's scores aim at the same three questions using open science, so they'll usually track WHOOP's *in direction*, but won't match number-for-number — and that's the point.

Every score also carries a small **confidence tier — Solid / Building / Calibrating** (`ScoreConfidence`) so a sparse day reads truthfully instead of faking a number. When NOOP can't compute a score honestly, it shows nothing rather than a fabricated value.

> **Naming & continuity.** The *display* names changed (Recovery→Charge, Strain→Effort, Sleep Performance→Rest) and Effort was **rescaled from 0–21 to 0–100**, but the **internal data keys are unchanged** (`recovery`, `strain`, `sleep_performance`) so years of stored history, imports, and the metric-series substrate keep working. You'll still see the old engine names (`RecoveryScorer`, `StrainScorer`) and internal keys throughout the source and in this document — they back the new scores.

> **Not affiliated with WHOOP.** NOOP interoperates with hardware and data you already own. The scores and metrics below are **independent approximations** of common exercise-physiology and HRV methods, derived from published literature — they are **not** reproductions of any proprietary scoring model, and they are **not a medical device**. Nothing here is medical advice.

All analytics live in the cross-platform `StrandAnalytics` Swift package. Every entry point is a **pure, deterministic, DB-free** function over its inputs — no I/O, no global state, no network. Persistence and BLE are wired in elsewhere (`WhoopStore`, the app target). This makes the whole package straightforward to unit-test against fixed vectors.

- Package: `Packages/StrandAnalytics/Sources/StrandAnalytics/`
- Top-level index: `StrandAnalytics.swift` (`StrandAnalytics.version == "0.1.0"`)
- App reference implementation: `Strand/` (SwiftUI, macOS + iOS). The same `StrandAnalytics` code backs both Swift app targets, and Android (Room/Kotlin) runs equivalent analytics — the number-crunching is shared, so results match across platforms.

---

## What is actually wired into the app

The package contains more analytics than the app currently surfaces. This section is the honest map of **library-only** vs **live**, verified against the app sources. The status below is shared across the Swift targets (macOS + iOS); Android runs the equivalent code through its own Kotlin/Room layer.

| Engine | File | Status in the app |
|---|---|---|
| `HRVAnalyzer` | `HRVAnalyzer.swift` | **Library-only** as a type. The app computes RMSSD inline via `AppModel.rmssd(_:)` (same Task-Force formula) for the live stress nudge. |
| `RecoveryScorer` | `RecoveryScorer.swift` | **Live.** Computes the **Charge** score. Runs inside `AnalyticsEngine.analyzeDay` via `Strand/Data/IntelligenceEngine.swift`; computed values are persisted under the `"<deviceId>-noop"` source and merged **under** any imported `recovery_score_pct` (imports always win). APPROXIMATE. |
| `StrainScorer` | `StrainScorer.swift` | **Live.** Computes the **Effort** score (0–100). Day load is computed on-device for nights the strap offloaded; the imported `day_strain` column still wins for imported days. APPROXIMATE. |
| `SleepStager` | `SleepStager.swift` | **Live.** Stages each offloaded night inside `analyzeDay`; the per-night stages feed the **Rest** composite. Computed sessions are persisted under the `"-noop"` source, with imported sleeps taking precedence. APPROXIMATE. |
| `Baselines` | `Baselines.swift` | **Live.** Seeds the recovery baseline in `IntelligenceEngine.analyzeRecent` (two-pass cold-start). The illness early-warning in `AppModel` still uses its own trailing-window baseline math inline (see below). |
| `WorkoutDetector` / `Calories` | `WorkoutDetector.swift` | **Live.** Runs inside `AnalyticsEngine.analyzeDay`; detected bouts are persisted as `workout` rows under the computed `"<deviceId>-noop"` source (sport `"detected"`), de-duplicated against imported WHOOP workouts. All intensity/calorie fields are APPROXIMATE. Not yet surfaced in the Workouts screen. |
| `AnalyticsEngine` | `AnalyticsEngine.swift` | **Live orchestrator.** `analyzeDay(...)` is called by `Strand/Data/IntelligenceEngine.swift` — every 15 minutes while connected, and from the Intelligence screen — and its `DailyMetric`, sleep sessions and detected workouts are persisted under the `"-noop"` source. |
| `HRZones` | `HRZones.swift` | **Library-only** (display zone model). The app's live zone coaching computes `%HRmax` inline in `AppModel.coachZone(_:)`. |
| `CorrelationEngine` | `CorrelationEngine.swift` | **Live.** Used by `InsightsView`, `CompareView`, `MetricExplorerView`. |
| `BehaviorInsights` | `BehaviorInsights.swift` | **Live.** Used by `InsightsView` (`rank` + `sentence`). |
| `ComparisonEngine` | `ComparisonEngine.swift` | **Live.** Used by `MetricExplorerView`. |

**In short:** the *interactive data-interrogation* engines (correlation, behavior effects, period comparison) are wired into screens, and the *recompute-from-raw-streams* engines that produce the three daily scores — Charge (recovery), Effort (strain), Rest (sleep), plus workout detection — run live too: `IntelligenceEngine` calls `analyzeDay` for every night the strap offloaded and persists the APPROXIMATE results under the `"-noop"` source, merged under any imported rows — a WHOOP export still wins wherever it covers a day. The live BLE app additionally runs four small inline analytics in `AppModel`: HR smoothing, RMSSD, HR-zone coaching, an illness/strain early-warning, and a resting-stress nudge.

---

## Live analytics in `AppModel`

Source: `Strand/App/AppModel.swift`. These run against the live BLE stream and the daily history, on the main actor.

### 1. Heart-rate smoothing (`ingestHR`)

Every screen shows a **smoothed** bpm (`AppModel.bpm`), never the raw per-beat value (which swings with HRV). The smoother:

1. Prefers the strap's reported HR; falls back to `60000 / RR` (last R-R interval) if needed.
2. Clamps to a plausible `30…220` bpm range — rejects `0` and garbage spikes.
3. Keeps a ~10-second sliding window (max 40 samples) and **publishes the window median**.

```swift
hrWindow.append((now, inst))
hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10 s window
if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
let vals = hrWindow.map(\.v).sorted()
bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
```

Median (not mean) is deliberate: it rejects single-beat outliers without lagging the signal.

### 2. RMSSD for the stress nudge (`rmssd` + `evaluateStress`)

The live RMSSD uses the classic Task-Force successive-difference formula over a rolling R-R buffer:

```swift
static func rmssd(_ rr: [Int]) -> Double {
    guard rr.count >= 2 else { return 0 }
    var sum = 0.0, n = 0
    for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); sum += d * d; n += 1 }
    return n > 0 ? (sum / Double(n)).squareRoot() : 0
}
```

`evaluateStress()` is an **experimental, off-by-default** resting-stress nudge:

- Only runs when `behavior.stressNudge` is on **and** the strap is bonded **and** worn.
- Filters R-R to plausible beats (`300 < rr < 2000` ms, i.e. 30–200 bpm), keeps the last 60, needs ≥ 20.
- Tracks a **slow HRV baseline** as an EWMA: `hrvBaseline = hrvBaseline * 0.98 + rmssd * 0.02`.
- Only fires when HR is in a **resting band** (`55…100` bpm — not a workout) and current RMSSD has dropped **below 60% of baseline**.
- Rate-limited to **once per 15 minutes** (`> 900` s). On fire it buzzes the strap once and logs "take a paced breath."

It is intentionally conservative so it rarely false-fires.

### 3. HR-zone haptic coaching (`coachZone`)

Watches the smoothed `bpm`, computes `%HRmax` from `profile.hrMax`, and buckets into 5 zones at `0.6 / 0.7 / 0.8 / 0.9` of max:

```swift
let pct = Double(hr) / maxHR
let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
```

On crossing **into zone 5** it buzzes three times ("ease off"); on dropping back **to zone ≤ 1** it buzzes once ("recovered"). Gated on `behavior.zoneCoaching`, bonded, worn, and a valid `hrMax`.

### 4. Illness / strain early-warning (`evaluateIllness`)

The live heads-up is the confounder-suppressed `IllnessSignalEngine` (StrandAnalytics; the Android twin
`IllnessSignalEngine.kt` mirrors its constants). `AppModel.evaluateIllness` re-runs it whenever the daily history
changes (`repo.$days`); it needs `behavior.illnessWatch` on and at least 14 days of history, and everything stays
on-device. Approximate and informational: it never names a condition and is never a diagnosis.

**Window.** `IllnessSignalEngine.inputs(history:endingAt:)` is the single place the window is built (the live alert
and the calibration replay below both call it, so they cannot disagree). It uses only days up to the one being
scored: the **last 2 entries** are the recent window and the baseline is the **~28 entries ending 3 entries earlier**
(so the recent window doesn't contaminate its own baseline):

```swift
let recent = Array(history.suffix(2))
let base   = Array(history.suffix(31).dropLast(3))   // ~28 days ending 3 days ago
```

**Signals.** Each signal is z-scored against the personal baseline (`Baselines.foldHistory` + `Baselines.deviation`,
z = (value − baseline) / (1.253 × spread)) and oriented illness-ward: resting HR, respiration and skin temperature
pass their z, HRV passes the **negated** z. Skin temperature is already a stored deviation (°C), so it is z-scored
against a zero-centred 0.3 °C spread. A signal **fires** at z ≥ 2 and adds min(40, 22 × (z − 2)) to the composite
score; the composite is the sum, clamped to 0–100. The pattern (resting HR ↑, HRV ↓, respiration ↑, skin
temperature ↑ moving together before symptoms) is the published multi-parameter signature; NOOP re-derives it
against the user's own baseline, never a population cut-off.

| Gate | Value |
|---|---|
| Corroboration | at least **2** signals fire (one noisy night never raises) |
| Mild | score ≥ 25: detail view only, no banner |
| Raise | score ≥ **50**, or the user's own calibrated threshold when that is higher (see below): banner and one notification per day |
| Baseline | resting-HR or HRV baseline trusted (≥ 14 valid nights), else the engine stays silent |
| Already unwell | the user logged feeling unwell: a gentle "rest up", whatever the score |
| Confounder | score × 0.45 and the level drops to *suppressed* ("probably not illness") |

**Confounders.** Same-day (last two days) journal answers: alcohol, a workout, and, for the last two nights, **a low
glucose at night**. A confounder doesn't hide the signals; it adds a named reason ("Explained by: alcohol") and
dampens the score.

*Night low.* Nocturnal hypoglycaemia activates the sympatho-adrenal system (neurogenic symptoms such as sweating
and palpitations; Cryer PE, N Engl J Med 2013;369:362–372; Seaquist ER et al., Diabetes Care 2013;36:1384–1395)
and changes the heart's autonomic control while the strap is recording the night's heart rate and HRV. In adults
with type 1 diabetes recorded with a CGM and an ECG, spontaneous nocturnal lows lowered the low-frequency power of
HRV, read as sympathetic activation (Koivikko ML et al., Diabetes Care 2012;35:1585–1590), raised the heart rate
from 65 to 85 bpm in a small series (Koivikko ML et al., Acta Diabetol 2017;54:251–256), and produced more
bradycardia and a longer QTc (Novodvorsky P et al., Diabetes Care 2017;40:655–662). The direction of the heart-rate
change is therefore not the same in every study; what is consistent is that the night's heart-rate and HRV readings
are perturbed by the low, so illness is not the only, or the plainest, explanation for a deviation. A night counts as
having a low when the Apple Health metric `glucose_overnight_min` (the lowest CGM reading between 00:00 and 06:00
local, `DiabetesMetrics`) is **below 70 mg/dL**, level 1 hypoglycaemia (Battelino T et al., Diabetes Care
2019;42:1593–1603; Battelino T et al., Lancet Diabetes Endocrinol 2023;11:42–57). No glucose data means no flag and
the behaviour is exactly as before. Sweating is a classic part of that response (Seaquist 2013 lists it among the
autonomic symptoms), but no study was found that measures the skin-temperature change in a spontaneous night low, so
no direction is claimed for it.

**Wording.** The engine's own English `copy` is never shown. The card, the banner and the notification build one
sentence in the app (`IllnessCopy`) from the level, the fired signals and the suppression reasons, so it follows
the UI language.

#### Personal false-alarm calibration (`IllnessCalibration`)

What can be calibrated on one person's data is the **false-alarm rate** (the specificity); the **sensitivity** to a
real illness cannot be: a person is ill one to three times a year, far too few events to estimate how often a
detector catches one. Every healthy day, on the other hand, is a data point on how often it would have cried wolf.
So NOOP fixes the false-alarm rate on the user's own history and keeps the detector: a Neyman–Pearson style choice
(Neyman J, Pearson ES, Philos Trans R Soc A 1933;231:289–337), and the same logic as Temple DS et al. (J Infect Dis
2023;227:864–872), who set the alarm threshold so that no alarm fired on the 170 healthy baseline days of a wearable
influenza-challenge study.

1. **Replay** every past day that has the full 31-entry window behind it (day *d* uses only days ≤ *d*; no
   look-ahead), with the same `inputs(history:endingAt:)` and `composite` the live alert runs.
2. **Healthy days** are replayed days with a trusted baseline, at least 2 of the 4 signals present, no confounder on
   the day or the one before it (alcohol, a workout, a night low: the confounders the live alert itself reads), and
   not within ±7 calendar days of a day the user logged feeling unwell.
3. An **alarm episode** is a run of consecutive calendar days that would each raise (≥ 2 firing signals and a score at
   or above the threshold). Episodes are counted, not days.
4. Choose the **smallest personal raise threshold T in [50, 100]** (1-point grid, **never below the shipped 50**)
   whose episode rate on the healthy days is **at most 1 per 60 days**. If even T = 100 misses that target, 100 is
   used and the achieved rate is reported as it is.
5. Report the number of healthy days *N*, the episodes *k* at T, the empirical rate *k / N* and the **95 % one-sided
   Clopper–Pearson upper bound** of the per-day alarm rate (Clopper CJ, Pearson ES, Biometrika 1934;26:404–413): the
   *p* with P(X ≤ *k* | *N*, *p*) = 0.05, i.e. the 95th percentile of Beta(*k* + 1, *N* − *k*); for *k* = 0 that is
   1 − 0.05^(1/*N*) ≈ 3 / *N* (170 healthy days and no episode: at most about 1 alarm every 57 days). Days are treated as independent trials,
   which neighbouring days are not quite, so the bound is approximate.
6. **Active only with at least 120 healthy replayable days.** Before that the shipped thresholds apply and the card
   says how many days are still missing.

The engine takes the result as `Context.personalRaiseThreshold`; the raise check uses
`max(raiseThreshold, personalRaiseThreshold ?? raiseThreshold)`, so calibration can only make the alert stricter. The
app recomputes it off the main actor when the history has grown by 30+ days or a month has passed, from the full
journal (`repo.journalEntries()`) and the full `glucose_overnight_min` history, and persists it in UserDefaults with
its date (never computed in `body`). The card states the limit in one line: whether it catches a real illness can't
be calibrated on your data; that comes from published studies.

---

## Heart-rate accuracy check (`HeartRateAccuracy`)

Source: `HeartRateAccuracy.swift`, behind the **Heart-rate accuracy** screen (Today → Heart rate card →
*Check accuracy*, and Settings → Profile). A wrist strap reads the pulse optically (PPG), and nothing in a phone
can prove its absolute accuracy: only a chest strap or an ECG can. What the data does allow, and what the
engine computes:

- **Strap against its own beat timing (`rrConsistency`).** For each second with a heart-rate sample, take the
  R-R intervals within ±5 s, keep those of 300–2000 ms, drop any that differs by more than 20 % from the median
  of its neighbours (the Malik et al. 1989 rule, `HRVAnalyzer.rejectEctopic`), and require at least 3 left.
  The comparison rate is 60000 / median(R-R); the strap's bpm minus that is the difference. The result is the
  number of seconds compared, the mean difference (positive: the strap reads higher than its beats), the mean
  absolute difference and the share within 5 bpm; nil under 30 comparisons. Both numbers come from the same
  optical signal, so this is a **consistency** check: it exposes seconds where motion or a loose fit disturbed
  the signal, not a bias common to both. The median (not the mean) keeps one missed or extra beat from moving
  the rate.
- **Manual pulse count (`palpation`).** Counting the pulse at the wrist or neck for 30 s and doubling it is the
  standard bedside method and is independent of the sensor. Counted rate = beats × 60 / seconds; the strap's
  value is the mean of its samples inside the same window, and the comparison is refused when the strap
  reported fewer than half of the window's seconds (a disconnect makes no valid comparison) or when the count
  is not a plausible pulse (20–250 bpm). A difference within ±5 bpm is "matches": one counted beat in 30 s is
  already 2 bpm, so a smaller tolerance would flag a normal counting error.
- **Your own baseline (`sleeping`, `waking`).** "My heart rate is always high" is judged against the person's own
  numbers. Sleeping floor = the lowest 5-minute mean of the night (`RecoveryScorer.restingHR`), night average =
  the mean of the night's samples. Waking range = the 10th / 50th / 90th percentile of 5-minute mean heart rates
  over 7 days outside every sleep block (percentiles, not min/max, so one odd window cannot define "resting" or
  "high"; at least 2 hours of windows). The screen also shows the max heart rate the zones and Effort use (a
  setting, else Tanaka et al., J Am Coll Cardiol 2001: 208 − 0.7 × age), because a maximum set too low makes
  hard efforts look harder than they are.

Optical wrist heart rate is accurate at rest and degrades with intense, rhythmic arm movement, when the sensor can
lock onto the movement cadence instead of the pulse (Shcherbina et al., J Pers Med 2017;7:3; Bent et al., npj Digit
Med 2020;3:18). That is a property of the sensor, not the app, and the screen says so. Informational only, not
medical advice.

### Why Charge is empty (`NightCoverage`)

Source: `NightCoverage.swift`, behind the note under the Today scores (*Why there's no Charge yet*). Charge needs
last night's HRV, which comes from the R-R intervals stored during sleep; on a WHOOP 5.0/MG they arrive over the
live heart-rate stream while the phone is connected. For last night's main sleep (the longest session that ended in
the last 18 hours) it counts, from the stored samples, the hours of heart rate, the number of R-R beats, the share
of the night with at least one beat, and how many 5-minute windows the nightly HRV would accept. The window rule
is exactly the nightly one (`SleepStager.sessionAvgHRV` → `HRVAnalyzer.windowQuality`: ≥ 120 s of clean beats,
Munoz et al. 2015; ≤ 5 % corrected beats, Kubios; ≤ 36 % lost, Sheridan et al. 2020), so "usable" here means what
the score uses. The verdict is *no heart rate* (under 20 % of the night recorded), *no beat-to-beat* (under 20
beats), *too sparse* (no usable window) or *enough*, and the fixes shown follow from it: keep NOOP connected
overnight, charge the strap, wear it snugly. It also counts the nights in the last 7 days whose nightly HRV is
inside the baseline's plausibility bounds (the same predicate as `RecoveryScorer.calibrationNights`) against the 4
that Charge needs. Nothing is estimated and no score changes.

---

## `HRVAnalyzer` — RMSSD / SDNN with cleaning

Source: `HRVAnalyzer.swift`. Reproduces the **Task Force (1996)** definitions over R-R / NN intervals (ms), with a deterministic cleaning pipeline.

### Formulas

```
RMSSD = sqrt( (1/(N-1)) · Σ (NN[i+1] − NN[i])² )    (Task Force 1996)
SDNN  = sample standard deviation of NN, ddof = 1     (Task Force 1996)
pNN50 = 100 · (count of |ΔNN| > 50 ms) / (N − 1)
```

`rmssdRaw(_:)` and `sdnnRaw(_:)` are the raw primitives (no filtering, return `nil` for fewer than 2 values).

### Cleaning pipeline (`clean` / `cleanTimed`)

1. **Hard plausibility split** — values outside `[150, 3000]` ms are not heartbeats (dropouts, noise): they are
   removed and split the series. With timestamps, a time gap longer than the interval (+2 s of 1-s stamp
   slack) also splits it. Successive differences are never taken across a split.
2. **Artefact correction — Lipponen & Tarvainen (2019)**, the automatic correction Kubios HRV applies by
   default (`RRArtefactCorrection.swift`). Adaptive thresholds (5.2 quartile deviations over 91 beats) and a
   decision flow classify each beat as ectopic, missed, extra or long/short; extra detections are merged,
   missed beats split in two, ectopic and misplaced beats re-estimated with a cubic spline. Correcting
   instead of deleting keeps every successive difference between truly adjacent beats.
3. **Physiological range** — corrected values outside `[300, 2000]` ms (≈ 200–30 bpm) are removed and split.
4. **Sufficiency gate** — at least `minBeats = 20` clean intervals, otherwise `HRVResult.empty(...)`.

This replaces the earlier Malik (1989) 20%-of-local-median deletion. A fixed 20% rule cannot adapt to the
person's own variability: on a real five-minute stretch of large sinus arrhythmia from PhysioNet Fantasia
(f1y01, every beat annotated normal) it deletes 22 of 300 genuine beats and cuts RMSSD by more than a third,
while Lipponen–Tarvainen flags none (pinned in `RRArtefactCorrectionTests`).

**Validation.** `Tools/hrv-validation` reruns the paper's own evaluation on the same public database
(Fantasia, 8 recordings, 61,437 normal intervals, 611 simulated artefacts per class):

| Beats | Detected — NOOP (paper) |
|---|---|
| Normal, kept as normal | 99.84% (99.96%) |
| Missed / extra | 100% / 99.2% (100% / 100%) |
| Misaligned by 2 / 4 / 8 × RMSSD | 61% / 99.0% / 100% (54% / 99.3% / 100%) |

On 48 five-minute samples, RMSSD errors of +427% (missed), +181% (extra) and +34% (misaligned, q = 4) become
−3.0%, −2.7% and −2.8% after correction; clean samples move by −2.8%. With the same threshold reading the
labels match NeuroKit2's open implementation on 99.9996% of 245,259 intervals.

One interpretation is documented in the source: eqs. 2 and 6 print the quartile deviation of |x|, but the
paper's own justification of α = 5.2 ("covers 99.95% of all beats if normally distributed") only holds for
the signed series (5.2 × 0.674σ = 3.5σ). The signed reading is the one that reproduces the paper's Table 1;
the |x| reading (NeuroKit2's) flags 1.1% of normal beats and detects 89% of the smallest displacements.

### Nightly window quality (`windowQuality`)

`SleepSession.avgHRV` is the mean RMSSD of the 5-min windows that pass three evidence-based gates:

- **≥ 120 s of clean beats** — RMSSD from 2 minutes tracks a 5-minute reference at r = 0.986
  (Munoz et al., PLoS One 2015, n = 3,387);
- **≤ 5% corrected beats** — Kubios' default acceptance threshold ("the number of corrected beats should not be
  too high (preferably <5%) not to cause significant distortion", Kubios HRV Scientific User's Guide);
- **≤ 36% of delivered intervals lost** — RMSSD stayed within 5% with up to 36% of intervals removed
  (Sheridan et al., Psychiatry Investig 2020).

A window that needed too much repair is excluded rather than averaged in; a night with no accepted window
has no HRV rather than an inflated one.

### API

```swift
HRVAnalyzer.analyze(_ rr: [RRInterval], windowStart: Int?, windowEnd: Int?) -> HRVResult
HRVAnalyzer.analyze(rawRR: [Double]) -> HRVResult
```

`HRVResult` carries `rmssd`, `sdnn`, `meanNN`, `pnn50`, plus `nInput`, `nClean`, `nDropped` and `nCorrected` for transparency. A spot reading can also pass `maxRejectedFraction` (default 0.35) to refuse a capture where too many beats were lost or corrected.

---

## `RecoveryScorer` — the **Charge** score (transparent 0–100 recovery composite)

Source: `RecoveryScorer.swift`. Produces **Charge** — *"how recovered are you?"* A **z-score + logistic** composite, **led by your heart-rate variability (HRV) measured against your own personal baseline**, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness / overreach flag). It is explicitly **approximate** and makes no claim to reproduce WHOOP's proprietary Recovery % model — same core idea (HRV-led recovery), but our weighting and baseline maths are our own and openly documented here.

### Weighting

Higher HRV versus your baseline means more Charge. Skin-temp folds in as a symmetric penalty: the further from baseline (in either direction), the less Charge, since a large deviation flags possible illness or overreach.

| Driver | Direction | Weight |
|---|---|---|
| HRV vs baseline | higher → more Charge | `wHRV = 0.55` (dominant) |
| Resting HR vs baseline | lower → more | `wRHR = 0.20` |
| Rest quality (sleep) | higher → more | `wSleep = 0.15` |
| Respiration vs baseline | lower → more | `wResp = 0.05` |
| Skin-temp deviation | further from baseline → less | `wSkinTemp = 0.05` |

The skin-temp term uses the absolute deviation already computed as `DailyMetric.skinTempDevC` (a z-like ±°C), entered as a symmetric penalty `−|dev|/scale`. SpO₂ folds in **only when real** (imported) as a small penalty below ~95%; it's never fabricated and never applied on a bare 5/MG day. HRV's weight dropped from `0.60` to `0.55` to make room for skin-temp; when skin-temp is absent the weights renormalize, so the score matches the older HRV-led composite.

Each metric is standardized to a **robust z-score** against the personal baseline (EWMA spread):

```
z = (value − mean) / (1.253 · spread)
```

The `1.253` converts an EWMA mean-absolute-deviation into an approximate Gaussian σ (`E[|X−μ|] = σ·√(2/π) ≈ σ/1.253`). For "lower is better" drivers (RHR, resp) the z is inverted by swapping value and mean. The sleep term is centered directly: `(sleepPerf − 0.85) / 0.12`.

Missing terms are dropped and weights renormalized. The weighted-mean z is squashed:

```
score = 100 / (1 + exp(−logisticK · (z − logisticZ0)))
        logisticK  = 1.6     (±2 z ≈ the full red–green band)
        logisticZ0 = −0.20   (anchors z = 0 → ~58 %)
```

The `58%` anchor matches WHOOP's published population-average recovery (`populationMean = 58.0`).

### Cold-start ("Calibrating")

HRV is the dominant driver, and NOOP needs a few nights to learn your personal baseline first. If that baseline isn't usable yet (`BaselineState.usable == false`, i.e. fewer than `minNightsSeed` valid nights), `recovery(...)` returns `nil` and the UI shows **"Calibrating"** — more honest than fabricating a number. Callers may fall back to `populationMean` but should flag it.

### Bands (`band(_:)`)

| Band | Range |
|---|---|
| red | `< 34` |
| yellow | `34 … 67` |
| green | `≥ 67` |

### Resting HR (`restingHR`)

"Lowest sustained HR" during the in-bed window = the **minimum of 5-minute non-overlapping bin means** of HR samples in `[start, end]`. This rejects single-beat dips while capturing the night's true floor.

---

## `StrainScorer` — the **Effort** score (0–100 logarithmic cardiovascular load)

Source: `StrainScorer.swift`. Produces **Effort** — *"how hard did your heart work?"* Your day's cardiovascular load: an **independent** implementation of published exercise-physiology methods (WHOOP-*like*, not a reproduction). NOOP turns every second of heart rate into a training-impulse using heart-rate-reserve zones (Karvonen), weights time in harder zones more heavily (Edwards / Banister), and places it on a logarithmic 0–100 scale — so easy days sit low and an all-out day approaches 100, which stays genuinely rare.

> **Scale change (0–21 → 0–100).** Effort is the same cardiovascular-load idea as WHOOP's Day Strain (0–21). We rescaled the **top of the ladder** from 21 to 100 (`maxStrain 21.0 → 100.0`) so all three NOOP scores share one 0–100 scale. The denominator `D = 7201` is **unchanged**, so the log curve and its saturation point are preserved — the rungs didn't move, a 100 is as rare as a 21.0 was.

### Pipeline

1. **Heart-Rate Reserve (Karvonen 1957):** `HRR = HRmax − RHR`.
2. **Per-sample intensity** as `%HRR = (HR − RHR) / HRR × 100`, clamped `[0, 100]`.
3. **TRIMP accumulation** over the window, by one of two methods:
   - **Edwards (1993) 5-zone summation (default):** each sample contributes its zone weight (`1…5` at the `50 / 60 / 70 / 80 / 90 %HRR` cut-offs) × duration.
   - **Banister (1991) exponential:** each sample contributes `duration × x × 0.64 × e^(b·x)`, where `x = %HRR/100` and `b = 1.92` (men) / `1.67` (women).
4. **Logarithmic compression** onto `[0, 100]`:

```
Effort = 100 · ln(TRIMP + 1) / ln(D),    D = strainDenominator = 7201
```

`D = 7201` is calibrated so the Edwards daily ceiling — top zone weight 5 sustained for 24 h = `5 × 1440 = 7200` — maps to exactly the maximum (`ln(7201)/ln(7201) = 1`, so `Effort = 100`). The old 0–21 scale used the identical denominator and curve; only the `maxStrain` multiplier changed from `21.0` to `100.0`.

### Steps / active-energy floor

A long walk with little cardio still counts: when cardio TRIMP is low but step / active-kcal load is high, Effort is raised to a movement-derived floor so non-cardio activity still registers. (5/MG continuity: Effort already reads `COALESCE(measured HR, ppg_hr)` via hrBuckets, so 5-series users get Effort from live + PPG HR.)

### HRmax estimation (`estimateHRmax`)

- With ≥ `hrmaxMinSamples = 600` HR samples, use the observed `99.5th` percentile (`"observed"`), unless a Tanaka estimate is higher.
- **Tanaka (2001):** `HRmax = 208 − 0.7 × age` (gender-independent), used as the floor / fallback (`"tanaka"`).
- No data and no age → `(0, "unknown")`.

### Guards & gates

- Returns `nil` with fewer than `minReadings = 600` samples (≈ 10 min at 1 Hz) or when `HRmax ≤ RHR` (invalid HRR).
- Per-sample duration is inferred from the first two timestamps, falling back to `1 s`.

### Denominator calibration (`fitStrainDenominator`)

Given `(TRIMP, reference_strain)` pairs, fits `D` via a through-origin least-squares line in log-space: `ln(D) = maxStrain · Σx² / Σ(x·strain)`, `x = ln(TRIMP+1)`, where `maxStrain` is the full-scale value (now `100`, formerly `21`). Throws on fewer than 2 usable pairs.

### Logged WODs: session-RPE muscular load (`LoggedSession`)

Heart rate under-reads resistance and mixed-modal training: heavy sets, short maximal efforts and the rest
between them load the muscles far more than the pulse shows (and wrist PPG reads low during lifting). A logged
WOD with an RPE and a time adds its **session-RPE load** — Borg CR-10 rating × minutes (Foster et al., J
Strength Cond Res 2001; reliable in resistance training, Day et al. 2004; review Haddad et al., Front Neurosci
2017) — where the heart rate did not already record it:

```
expected TRIMP = 0.52 × RPE × minutes                 (Tibana et al., Sports 2018: Edwards TRIMP / session-RPE
                                                        in CrossFit WODs — Fran 0.56, Fight Gone Bad 0.48)
added TRIMP    = max(0, expected − Edwards TRIMP the heart rate recorded for that session)
Effort         = 100 · ln(heart-rate TRIMP + added TRIMP + 1) / ln(D)
```

- The comparison uses the classic Edwards zones (50–90 % of HRmax), the scale the 0.52 ratio was measured on.
- "Recorded for that session" is the session the user timed (start and end, e.g. an hour of warm-up, skill
  and a 15-minute AMRAP), else the detected workout that best overlaps it (within an hour either side), else
  the span the WOD could occupy whether its logged time marks the start or the end. A WOD imported with a date
  only (anchored to local noon) is matched to the day's detected workout, or counts in full if none exists.
- Never negative: a metcon the heart rate fully captured adds nothing, so nothing is counted twice. A day with
  no heart rate still has no Effort; a WOD alone never makes one.
- Duration is the timed session's length (Foster's session-RPE rates the whole session and multiplies by its
  full duration, so the RPE then rates the whole session), else the result time, else the time cap; a WOD
  without RPE or duration adds nothing (the WOD screen says so). Saving, editing or deleting a WOD rescores the recent days; the WOD screen shows what it added.

### Glucose and heart rate on one clock (`WodTimeWindow`, `GlucoseTrace`, `TimelineTicks`, `TimelineEvents`)

The WOD screen and Today's "Heart & Glucose" card show glucose (Apple Health), heart rate (the strap) and carbs /
boluses in lanes on one clock, zoomable like the Deep Timeline. Informational only: it never suggests carbs or
insulin.

- **Where a WOD sat.** When the user set the session's start and end (Log WOD → Session end), exactly that
  span, whatever the strap recorded (at most 4 h). Otherwise the recorded workout (strap or Apple Health)
  overlapping most with
  `[logged − duration, logged + duration]` is the WOD, since the logged time may mark its start or its end
  (nearest within an hour if none overlaps; longer than 4 h never counts). Without one, the logged time is the
  start. Duration is the result time, else the time cap, else 20 min. The screen says which source it used.
- **Lanes, not a second axis.** Each measure keeps its own lane and scale; one crosshair reads all of them at
  the same moment. The old Today chart drew heart rate and glucose on one plot with two y-axes; it is gone.
- **Zoom.** Pinch (about the fingers), − / +, or "zoom to the WOD"; drag sideways to move; double-tap to zoom
  out. The narrowest window is one minute. Heart rate is re-read for the window on screen at about 360 points
  (about one per point of the chart's width), so zoomed in it is the strap's raw per-second signal
  (`Repository.timelineSeries`, as on the Deep Timeline).
- **Drawing.** Each lane's chart is drawn from plain values and redrawn only when they change: not when the
  screen around it redraws, and not while a finger reads the lanes (the reading is a layer drawn over them).
  A pinch or drag moves the window inside the chart and hands it to the screen when it ends.
- **Axis.** Clock time on Today. Around a WOD, the ticks count back from its start (−1h, −30′), run as a
  workout clock during it (0:00, 5:00) and count on from its end (+15′, +2h); ticks closer than 0.6 steps
  where the three runs meet are dropped. The step keeps five ticks or fewer (15 s up to 6 h).
- **Trace.** A gap of more than 15 min between readings breaks the line; each reading is drawn as a dot once
  40 or fewer are on screen.
- **Below 70 mg/dL** (level 1 hypoglycaemia, Battelino et al. 2019). Each low reading counts until the next
  reading of its segment (5 min for the last one before a gap), clipped to the window on screen. The shaded
  area ends where the line crosses 70, interpolated linearly between readings.
- **Scale.** Glucose: at least 50–200 mg/dL and the target range, widened to every reading so a low is never
  clipped, and fixed while zooming. Heart rate: fitted to the window on screen.
- **Carbs and boluses.** Entries within about a 24th of the window on screen (at least a minute) of a group's
  first entry share one marker, their amounts summed, so labels never pile up; zoomed in, each entry is its
  own. Basal is left out.
- **Settings** (saved on the device, shared by every timeline): which lanes show, workout / WOD shading, the
  target range (default 70–180 mg/dL; 70 is always marked), heart-rate zones (50–100 % of max heart rate in
  10 % steps, `HRZones`), figures for the stretch on screen, lane size, and the window around a WOD (default
  2 h before, 4 h after; up to 3 h and 6 h). The WOD screen's figures keep their own 2 h / 4 h window.

---

## `SleepStager` — sleep/wake detection + approximate 4-class staging (feeds **Rest**)

Source: `SleepStager.swift`. Detects in-bed sessions from gravity/HR/RR/respiration and produces a 30-second hypnogram of `{wake, light, deep, rem}`. These stages and the AASM roll-up below are the raw material the **Rest** score composite consumes (see *The Rest score composite* immediately after this section).

> **Honest hedging.** These stages are **approximations**, not PSG-validated, not medical advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019). **Light/deep separation is the weakest link — deep-minute estimates are the least reliable output.**

### Stage 0 — gravity-stillness sleep/wake spine (`detectSleep`)

- Per-record movement proxy = L2 magnitude of the gravity-vector change vs the previous record (`gravityDeltas`).
- A sample is "still" if its delta < `gravityStillThresholdG = 0.01 g`. A rolling window (`stillWindowMin = 15` min) calls its center "sleep" when ≥ `stillFraction = 0.70` of samples are still.
- Contiguous runs are built, breaking on a class change or a data gap > `maxGapMin = 20` min; runs shorter than `mergeMin = 15` min are absorbed into neighbours.
- A run must exceed `minSleepMin = 60` min to count, and is **HR-confirmed**: mean HR over the run must be ≤ `hrSleepBaselineMult = 1.05 ×` the day's median HR (skipped when fewer than 30 HR samples — gravity is trusted alone).
- A citable **te Lindert 30 s Cole–Kripke** index (`SI = 0.001 · Σ wᵢ·Aᵢ`, sleep iff `SI < 1`, weights `[106, 54, 58, 76, 230, 74, 67]`) is computed per epoch as a cross-check and to find onset / final-wake.

### Stage 1 — per-epoch cardiorespiratory features

Over a rolling 5-minute window per 30 s epoch:

- mean HR;
- **Walch difference-of-Gaussians HR variability** (`σ1 = 120 s` minus `σ2 = 600 s`, reflect-padded convolution; NaNs linearly interpolated);
- **RMSSD / SDNN** from range-filtered R-R (`HRVAnalyzer.rmssdRaw` / `sdnnRaw`);
- **respiration rate + RRV** from the raw 1 Hz resp channel via a simple peak detector (detrend → local-maxima peaks ≥ 2 s apart → breath intervals 1.5–12 s → rate = `60 / median interval`, RRV = std of intervals).

> Frequency-domain HRV (HF, LF/HF) is **omitted** — there is no neurokit2/scipy on-device — so the parasympathetic-tone signal is **RMSSD only**. The respiration peak-finder is a faithful port (the reference derived these "robustly ourselves" too, without neurokit).

### Stage 2 — percentile-band classifier (`classifyOne`)

Reference distributions are taken over the session's **sleep-period** epochs (Cole–Kripke = sleep). A motion fraction and the per-epoch features are compared against session-relative percentiles:

| Class | Rule |
|---|---|
| **wake** | sustained motion (`moveFrac ≥ 0.15`) **and** activated cardiac (high HR or high DoG-HR variability), or no HR to vet the motion |
| **deep** | still (`moveFrac ≤ 0.10`) **and** high parasympathetic tone (RMSSD ≥ 70th pct) **and** low HR (≤ 25th pct) **and** regular respiration |
| **rem** | still body **and** activated cardiac **and** irregular respiration (RRV ≥ 65th pct); a fallback requires both cardiac signals when respiration is unavailable |
| **light** | everything else (the default) |

### Stage 3 — smoothing + physiology re-imposition

- 5-epoch **median smoothing** of the label sequence (`smoothLabels`).
- **No REM in the first 15 min** after onset (`reimposePhysiology` → demote to light).
- **No deep after the first third** of the night (deep is biased early) → demote to light.
- Pre-onset and post-final-wake epochs are forced to `wake`.

Consecutive same-stage epochs are merged into `StageSegment`s tiling `[start, end]`.

### Outputs

- `SleepSession` — `start`, `end`, `efficiency` (AASM `asleep / in-bed`, where `asleep = in-bed − wake`), `stages`, per-session `restingHR` (lowest 5-min rolling-mean HR) and `avgHRV` (mean RMSSD over the quality-accepted 5-min tumbling windows, see `windowQuality`).
- `hypnogramMetrics(_:)` — AASM-style roll-up: TIB / TST / SPT / SOL / REM latency / WASO / efficiency / disturbances, plus deep/REM/light minutes and percentages.

---

## The **Rest** score composite — *"how restorative was your sleep?"*

Source: assembled in `AnalyticsEngine` from the `SleepStager` outputs above. Rest is a 0–100 composite that **replaces the older bare-efficiency proxy** for the `sleep_performance` key. It blends four components:

| Component | Weight | What it measures |
|---|---|---|
| Duration vs personal need | 0.50 (biggest factor) | how long you slept against your own sleep need |
| Efficiency (asleep / in-bed) | 0.20 | how efficiently you slept |
| Restorative share (deep + REM) / asleep | 0.20 | how much of the night was restorative |
| Consistency (sleep/wake regularity) | 0.10 | how consistent your sleep and wake timing is |

- **Personal sleep need:** 8 h default, refined by your recent average; the hours-vs-need term clamps at 100.
- Rest consumes whatever stages each device provides (v25 motion on 4.0; PPG/IMU on 5/MG as it unlocks) — the sleep-staging algorithm itself is unchanged.
- The `sleep_performance` key now stores this 0–100 composite. The **Charge** "Rest quality" driver reads it (÷100) instead of raw efficiency.

This composite is similar *in spirit* to WHOOP's Sleep Performance %, but the blend is our own.

---

## `Baselines` — personal rolling baselines

Source: `Baselines.swift`. Per-metric personal baselines that `RecoveryScorer` consumes. Two interchangeable paths produce the same `BaselineState` shape.

### 1. Winsorized EWMA (production model — `update` / `foldHistory`)

A robust, recency-weighted center with an EWMA-of-absolute-deviation spread tracker:

- **Half-life → smoothing factor:** `λ = 1 − 0.5^(1/halfLife)`. Center half-life 14 nights; spread half-life 21 (slower).
- **Sanity gate:** values outside `[minVal, maxVal]` (per-metric) → skip-and-hold.
- **Hard outlier rejection:** once seeded, a value > `hardOutlierK = 5 ×` spread away is seen but not folded.
- **Winsor clamp:** fold only within `± winsorK = 3 ×` spread of the current baseline, so a single big night can't yank the center; the **spread** uses the unclamped deviation so real change is still tracked.

```swift
let clamped = max(lo, min(hi, value))                       // ±3·spread
let newBaseline = lb * clamped + (1 - lb) * state.baseline
let newSpread   = max(cfg.floorSpread, ls * abs(value - newBaseline) + (1 - ls) * state.spread)
```

### 2. Trailing-window mean/SD (`rollingMeanSD`)

The simple, maximally auditable path: plain mean and sample SD (ddof = 1) over the trailing N (default 30) valid nights, with the σ floor applied and converted back into abs-dev space (`÷ 1.253`) so `deviation()` recovers the intended Gaussian σ unchanged.

### Status lifecycle (`BaselineStatus`)

| Status | Condition |
|---|---|
| `calibrating` | fewer than `minNightsSeed = 4` valid nights (no score yet) |
| `provisional` | `4 … 13` valid nights (usable, higher uncertainty) |
| `trusted` | ≥ `minNightsTrust = 14` valid nights |
| `stale` | usable but no update for > `staleDays = 14` nights |

### Per-metric config (`metricCfg`)

| Metric | min | max | floor spread | center / spread half-life |
|---|---|---|---|---|
| `hrv` | 5 | 250 | 5.0 | 14 / 21 |
| `resting_hr` | 30 | 120 | 2.0 | 14 / 21 |
| `resp` | 4 | 40 | 0.5 | 14 / 21 |
| `skin_temp` | 20 | 42 | 0.3 | 14 / 21 |

### Deviation

`deviation(_:state:)` returns a robust z-score, a signed physical-units delta, a fractional ratio (`value/baseline − 1`), and an `inNormalRange` flag (`|z| ≤ 1`).

---

## NOOP vs WHOOP — agreement report (`AgreementStats`)

Source: `AgreementStats.swift`, screen `BenchmarkView`. For every day that has both a WHOOP-imported value and
NOOP's own (HRV, resting HR, respiratory rate, sleep and its stages, efficiency, SpO₂, Charge vs Recovery,
Effort vs Day Strain), NOOP reports agreement the way the INTERLIVE consensus asks consumer wearables to be
validated (Mühlen et al., Br J Sports Med 2021) and the sleep-technology framework of Menghini et al. (Sleep
2021) implements:

- **Bias** (mean NOOP − WHOOP) and **95 % limits of agreement** (Bland & Altman 1986), each with its 95 %
  confidence interval — the limits by MOVER (Zou, Stat Methods Med Res 2013).
- **Correlated days.** Consecutive days are not independent. An AR(1) fit to the daily differences gives the
  effective number of days, the unbiased SD and the SE of the bias (Zięba, Metrol Meas Syst 2010, eqs. 10–12,
  24–25), using the real gaps between days.
- **Proportional bias and heteroscedasticity.** Differences, and then their absolute residuals, are regressed on
  the mean of the two methods (Bland & Altman 1999 — not on one method, which is misleading when it has error of
  its own, Bland & Altman 1995). When significant, the limits become `b0 + b1·A ± 2.46·(c0 + c1·A)`.
- **Error and concordance:** MAE, RMSE, MAPE, share of days within ±5 / ±10 %, Pearson, Spearman and Lin's
  concordance with its z-transform CI (Lin 1989, variance as corrected in 2000), labelled with McBride's bands
  (< 0.90 poor, 0.90–0.95 moderate, 0.95–0.99 substantial, > 0.99 almost perfect).

No universal "good enough" threshold is imposed, and WHOOP is the reference, not the truth: agreement is not
accuracy. Every statistic is tested against values computed independently with NumPy/SciPy.

## Night-time hypoglycaemia (`DiabetesMetrics.hypoEvents`)

Source: `DiabetesMetrics.swift` (StrandImport), shown under the scores on Today (iOS, CGM data from Apple
Health). Events follow the international consensus (Battelino et al., Lancet Diabetes Endocrinol 2023):

- **Level 1:** ≥ 15 consecutive minutes below 70 mg/dL; the event ends only after ≥ 15 consecutive minutes at or
  above 70 (shorter recoveries stay inside it). **Level 2:** ≥ 15 consecutive minutes below 54 mg/dL.
  **Extended:** more than 120 consecutive minutes below 70.
- The CGM trace is resampled to a 5-minute grid, interpolating across gaps of up to 45 minutes; a longer gap is
  missing data and closes an open event at its last known low (the iglu implementation, Broll et al. 2021).
- **Nocturnal** is 00:00–05:59 local (the consensus window); events during the main sleep also count.
- The daily `glucose_hypos` metric now counts these events instead of every dip below 70.

Heart rate and HRV often stay flat through a spontaneous night-time low (Koivikko et al., Diabetes Care 2012),
so an HRV-led recovery score — WHOOP's Recovery and NOOP's Charge alike — can read normal after one. Today
therefore flags Charge with the night's events (level, minutes, lowest value, time) and, after exercise, notes
that night-time lows are more likely then (EASD/ISPAD position statement, Moser et al., Diabetologia 2020).
The flag is informational: Charge itself is unchanged and nothing suggests carbs or insulin.

## Glucose now and around a workout (`GlucoseNow`, `WorkoutGlucose`)

Source: `GlucoseNow.swift` (StrandImport), shown in Today's "Glucose now" and "Today's workout" blocks (iOS, CGM
data from Apple Health). Apple Health keeps no CGM trend arrow, so it is worked out from the readings:

- **Rate:** the least-squares slope of the readings in the 15 minutes up to the latest one, in mg/dL per minute
  (a line through all of them, so one noisy reading doesn't flip the arrow). It needs at least 3 distinct
  readings spanning at least 8 minutes; the same reading written by two apps counts once.
- **Arrow:** steady within ±1 mg/dL per minute, then slowly (to 2), plainly (to 3) and fast (beyond 3), rising
  or falling: the steps CGM apps use.
- **Now:** a reading older than 15 minutes (the gap that also breaks the chart line) is shown as the last
  reading with its time, and without an arrow. Today re-reads Apple Health every two minutes while it is open.
- **Around a workout:** glucose at its start and at its end is the reading nearest each edge within 10 minutes;
  the lowest is taken from the start to an hour after the end (the acute window for a post-exercise low,
  Moser et al., Diabetologia 2020), and a value below 70 mg/dL is called out.

Informational only: Apple Health can lag the CGM, the CGM app and Loop stay the source of truth, and nothing
suggests carbs or insulin.

## VO₂max (`VO2maxEngine`)

Source: `VO2maxEngine.swift`, screen `VO2maxView`; full method, validation and references in
[VO2MAX.md](VO2MAX.md). Four views side by side, never blended:

- **From runs and walks.** Each steady walk or run (10–90 min, ≥ 1 km, 50–85 % of heart-rate reserve, pace
  inside the equation's range) is a single-stage submaximal test: the ACSM oxygen cost of its pace
  (walking 3.5 + 0.1·S, running 3.5 + 0.2·S, S in m/min, level ground), extrapolated to HRmax through
  %HRR = %VO₂R (Swain & Leutholtz 1997; Swain et al. 1998): `VO₂max = 3.5 + (VO₂ − 3.5) / %HRR` — validated
  from one steady stage at r 0.89, SEE 4.0 mL/kg/min, no bias (Swain et al. 2004). Heart rate is the strap's
  per-minute mean after the first 3 minutes; resting HR the 14-night median; HRmax the user's setting, else the
  second-highest believable workout peak of the year, else Tanaka. A session whose extrapolated value falls
  outside 15–90 mL/kg/min is dropped as `implausible` (a distance or heart-rate error: a fast pace at a low
  share of the reserve can read 130; the top of the range sits just under the highest values ever measured,
  about 97, Joyner & Coyle 2008, Lundby & Robach 2015; the bottom above the ~14 of severe impairment,
  Mancini et al. 1991). The number is the median of the newest ≤ 5 sessions of 90 days, stored per session
  day as `vo2max_exercise`.
- **At rest.** The HUNT non-exercise model (Nes et al. 2011) ± its SEE (5.70 men, 5.14 women mL/kg/min), as a
  **daily series** `vo2max_est`: one point per day, the Nes estimate on the 7 calendar days ending that day
  (median nightly resting HR, at least 4 nights; PA-index from the window's strain, active day = strain ≥ 30, the
  rule the weekly Fitness Age uses). `FitnessAgeEngine.dailyVO2maxSeries`; the screen draws the dots with a 7-day
  rolling mean and a 30 days / 90 days / 1 year range. The waist it needs can be typed on the VO₂max screen;
  without it nothing is estimated (no fallback on another formula). Each day uses the waist measured by then
  (`FitnessAgeEngine.waistCm(on:from:)`: the latest Lab Book or Apple Health measurement on or before that day,
  the first one before any; a waist saved in the profile is filed in the Lab Book on the day it was saved), so a
  new measurement never rewrites the days before it. Re-evaluated every 10 minutes, see below.
- **From WODs.** Heart-rate ratio `PF · HRmax / HRrest` (PF 15.3 men, Uth et al. 2004; 14.5 women, Uth 2005)
  with the HRmax above and HRrest measured awake and supine after 15 min of rest (Castagna et al. 2022): a
  guided 15-minute capture with the strap, mean of the final 2 min (`supineRestingHR`), stored as
  `vo2max_rhr_supine`, valid 60 days. Without one it falls back on the nightly resting HR and is labelled
  provisional (reads high). Independent SEE 6.9–7.9 mL/kg/min (Esco et al. 2012).
- **Your values.** Entered by hand (`vo2max_manual`, source `manual-vo2max`), each compared with every estimate
  at that date.

**Why a daily series re-evaluated every 10 minutes, and not a value per 10 minutes.** VO₂max is an aerobic
capacity: it moves over weeks of training or detraining. No validated method turns a wrist strap's heart rate into
a new VO₂max every few minutes without an external workload (speed or power), and a CrossFit class has none; a
value per 10-minute window would be invented noise, far below the model's own SEE of about 5–6 mL/kg/min. What can
honestly be done is to re-evaluate the estimate as soon as there is new evidence, trained or not, and keep the
history at the resolution the quantity has. So `IntelligenceEngine.refreshVO2maxEstimate` (a 10-minute timer in
`AppModel`, no raw heart-rate reads) recomputes today's and yesterday's point from the cached daily rows and the
profile and stores it when it changed, and every scoring pass (after each sync, import or edit) rewrites the last
120 days and evicts stored days that no longer have a point (never days whose 7-day window is not loaded). A
change of age, sex or waist rewrites the whole window at the next refresh. The screen shows the latest value,
"Updated at HH:mm" (the time of the last re-evaluation) and ± SEE. `fitness_age` stays weekly (Saturday key). The
estimate at rest is not replaced by the heart-rate-ratio formula when the waist is missing: that formula expects a
resting HR measured awake and lying down, and the nightly floor reads high for it (see From WODs).

`Tools/vo2max-validation` checks the assumptions on 981 laboratory treadmill tests (PhysioNet, Malaga): the
submaximal HR–VO₂ line reaches VO₂max at HRmax with bias +0.85, SD 5.5 mL/kg/min (SD 7.0 with an age-predicted
HRmax), and Tanaka's HRmax is unbiased there (−0.9 bpm, SD 9.1).

## Heart-rate recovery after a workout (`HeartRateRecovery`)

Source: `HeartRateRecovery.swift` (`HeartRateRecoveryEngine.compute`), data in `Repository+Recovery.swift`, shown
by `HeartRateRecoveryCard` on a workout's and a WOD's detail screen and as one line in Today's workout block.
It answers two questions: how fast the heart rate falls once you stop, and how long it takes to get back near
resting. It reads the strap's heart rate from the last 3 minutes of the session to up to an hour after it.

- **Peak.** The highest 15-second median in the last 2 minutes of the session (the whole session when it is
  shorter), never a single raw spike, so one glitchy sample cannot make the drop look bigger.
- **HRR1 and HRR2.** Peak − HR at +60 s and at +120 s after the end, each the median of the samples within
  ±10 s of that moment. HRR1 is the measure of Cole CR, Blackstone EH, Pashkow FJ, Snader CE, Lauer MS (N Engl J
  Med 1999;341:1351–7): a fall of 12 beats/min or less in the first minute was the abnormal range in their
  treadmill test. Shetler K et al. (J Am Coll Cardiol 2001;38:1980–7) compared recovery taken at several minute
  marks and showed it depends on the protocol (cool-down walking vs sitting or lying down), so NOOP reports the
  2-minute drop but does not grade it.
- **Label for HRR1.** Slow (12 bpm or less), typical (13–24), fast (25 or more, common in trained people). It is
  informational, measured in free living and not a clinical test, and it moves with how you cool down.
  NOOP's bands are a plain reading of Cole's cut-off, not separately validated limits.
- **Checkpoints.** HR at +1, +2, +5, +10, +30 and +60 minutes: the median within ±10 s (+1, +2 min) or ±30 s
  (+5 min and later). With no sample inside the tolerance the checkpoint is left out (and HRR1 or HRR2 is
  empty): nothing is interpolated across a gap.
- **Back near resting.** The threshold is `resting + 0.2 × (peak − resting)`, i.e. 80 % of the drop from peak to
  resting is done; the time is the first moment the median of the trailing 60 seconds is at or under it. This is
  NOOP's own descriptive measure, not a published cut-off. Resting HR is the median of the last 7 nights. With
  no resting HR, a peak less than 10 bpm above it, or a threshold not reached inside the observed window, no
  time is shown (the card says the heart rate was still recovering, or how long it was observed).
- **Window.** The observed window ends at the last sample, never later than now or 60 minutes after the end. It
  counts as complete from 30 minutes observed; while the 60 minutes have not passed, more heart rate can still
  arrive and the card says to check back.
- **Nothing is made up.** Samples outside 30–230 bpm are dropped; with no heart rate after the end, or fewer than
  2 samples in the last 2 minutes of the session, there is no result and the card says why.
- **Recent sessions.** The small trend chart plots HRR1 of the newest sessions (5 minutes or longer, ended more
  than 2 minutes ago), reading only the first 3 minutes after each.

Informational only, not medical advice.

## `WorkoutDetector` + `Calories` — retroactive workout detection

Source: `WorkoutDetector.swift`. Finds workouts in the stored 1 Hz HR + gravity streams (no manual logging).

A workout is a **sustained window** (≥ `minExerciseMin = 5` min) where **both** gates hold per sample:

- **Elevated HR** — above `RHR + hrMarginBPM (15 bpm)`. RHR defaults to the day's 10th-percentile HR.
- **Sustained motion** — gravity-derived intensity (10-second trailing mean) above `motionThreshold = 0.20`.

Active samples are grouped into runs (merging gaps < `mergeGapS = 150 s`), then qualified by intensity: ≥ `minIntensityZ2Plus = 0.50` of the bout in Edwards zone 2+. Per bout it reports avg/peak HR, duration, Edwards zone-time %, mean `%HRR`, strain (via `StrainScorer`), and calories.

**Mixed sessions.** A CrossFit class (warm-up, strength with rests, the WOD, cool-down) keeps moving and keeps HR above the floor from start to end, so it is one long run, mostly below zone 2 as a whole: the intensity gate used to reject all of it, and such sessions were never detected. A run that fails the gate is searched for its intense cores (`intenseCores`: stretches in zone 2+, samples under `mergeGapS` apart joined), and each core of at least `minExerciseMin` that passes the same gate is a workout (the WOD). A run that passes the gate is unchanged; an easy hour with a 3-minute sprint still yields nothing (the core is too short).

### Calories (`Calories.estimateBoutCalories`)

Per-second blend of **Keytel (2005)** active expenditure and **revised Harris–Benedict** BMR (resting), with sex-specific coefficients (`male` / `female` / `nonbinary`). Below a `RHR + 0.30 × HRR` threshold the resting rate is used; above it, the HR-driven active rate. Returns `(kcal, kJ)`. **Approximate** — not laboratory calorimetry.

---

## Interactive engines (wired into screens)

These are the **live** data-interrogation engines, used by `InsightsView`, `CompareView`, and `MetricExplorerView`.

### `CorrelationEngine`

Source: `CorrelationEngine.swift`. Pearson r, OLS regression, and an approximate two-sided p-value between two daily series.

```
r         = Σ(x−x̄)(y−ȳ) / sqrt( Σ(x−x̄)² · Σ(y−ȳ)² )
slope     = Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²          (OLS, y on x)
intercept = ȳ − slope·x̄
t         = r · sqrt( (n−2) / (1−r²) )
p         = 2·(1 − Φ(|t|))                  (normal approximation)
```

- Returns `nil` for fewer than 3 pairs or zero variance in either variable.
- Φ uses the Abramowitz & Stegun 7.1.26 `erf` approximation. The normal approximation slightly **understates** p for small n (true Student-t tails are heavier) but is fully deterministic with no special-function tables.
- `alignByDay(...)` inner-joins two `yyyy-MM-dd`-keyed series; `lagged(x:y:lagDays:)` shifts y forward by `lagDays` (UTC day arithmetic) to probe directional/delayed effects — e.g. *today's strain vs tomorrow's recovery*.

#### Significance-tested association (`associationTest`)

`pearson` / `lagged` are descriptive. A raw r between two **day-by-day health series** is a poor basis for a conclusion, for two reasons: (1) most series drift slowly together (fitness, season, a new strap), so two unrelated drifting series correlate (spurious correlation, Yule 1926); (2) consecutive days resemble each other, so *n* paired days hold fewer than *n* independent observations and a plain t-test is far too eager. `associationTest(x:y:lagDays:minDays:)` returns a `CorrelationTest` that handles both:

```
1. detrend      each series: OLS line over the CALENDAR day index (gaps count as their real length);
                keep the residuals. One value per day (repeated days are averaged).
2. pair         x[day] with y[day + lagDays]            (lagDays = 1: "today → tomorrow")
3. r            Pearson r of the residual pairs
4. n_eff        n · (1 − ρx·ρy) / (1 + ρx·ρy), clamped to [3, n]
                ρx, ρy = lag-1 autocorrelations of the paired residual series
                (Bretherton et al., J. Climate 12, 1999)
5. p            exact two-sided Student-t, df = n_eff − 2:
                p = I_x(df/2, 1/2),  x = df / (df + t²),  t = r·sqrt(df / (1 − r²))
                (regularised incomplete beta, Numerical Recipes betai/betacf; Lanczos ln Γ)
6. 95 % CI      Fisher z: tanh( atanh(r) ± 1.96 / sqrt(n_eff − 3) ), only when n_eff > 3
```

- Returns `nil` for fewer than `minDays` paired days (default **14**) or when either residual series has no variance (including a series that is exactly its own trend).
- `studentTwoSidedP(t:df:)` is public and accepts fractional df (an effective *n*). Checked against numerically integrated reference values (t = 2.0, df = 10 → 0.0734; t = 2.228, df = 10 → 0.0500; t = 1.96, df = 1000 → 0.0503).
- Also public: `detrended(_:)` and `lag1Autocorrelation(_:)`.
- The existing `pearson` / `pApprox` are unchanged; `InsightsView`, `MetricExplorerView`, `MindSection`, `LabBookView` and the dose-response engine still use them.
- Tests (`CorrelationEngineTests`): two independent series on a shared trend give raw r > 0.85 but a small, non-significant detrended r; a true day-to-day relation survives detrending; a next-day relation is found at `lagDays = 1` and not at 0; AR(1) noise gives `effectiveN` well below *n* and a Monte-Carlo run over 200 independent persistent pairs flags far fewer at p < 0.05 than the naive test; fewer than 14 days → `nil`.

**How Compare uses it** (`CompareView`, section "How They Move Together"). Each selected pair gets one card, built from the real per-day values of each series (the overlay's min–max scaling is display-only):

1. **Structural pairs** (one metric is calculated from the other or they overlap by definition: asleep time vs time in bed, restorative min vs %, `sleep_*` vs the Rest score, HR zones vs Effort, TIR vs TAR/TBR, systolic vs diastolic, steps vs estimated steps, VO₂max variants and fitness age, and the same metric from two sources) are **not tested**. The card says "One is calculated from the other … Not an insight." and shows no r.
2. Otherwise the same-day test is run. If exactly one metric is a **load** (`strain`, HR-zone minutes, `strength_min`, kcal, steps, `avg_hr`, `max_hr`) and the other a **next-morning** metric (`recovery`, `hrv`, `rhr`, `resp_rate`, `skin_temp`, `stress`, `sleep_*`, overnight glucose), the load is also tested against the next day (`lagDays = 1`); whichever is significant with the larger |r| is kept.
3. **Verdict:** *clear* when p < 0.05 and |r| ≥ 0.3; *possible* when p < 0.05 and |r| < 0.3; otherwise *no reliable link*. Pairs with fewer than 14 overlapping days (or no variation left after detrending) say so instead of showing a number.
4. **Wording** states an association ("On days when X is higher, Y tends to be lower" / "After days with more X, Y the next day tends to be lower"), never a cause. Only a *clear* link gets a value judgement, and only from the **outcome** metric's own "higher is better" flag. Colours carry no good/bad meaning (accent for clear links, tertiary otherwise): a negative r such as HRV vs resting HR is normal and healthy.
5. The footer shows `r`, `p`, the paired days and the effective independent days, e.g. `r = +0.42 · p = 0.01 · 38 days (≈ 21 independent)`. Cards sort clear → possible → none → unmeasurable → structural, strongest |r| first.

Limits worth knowing: the next-day pairs run two tests and keep the better one, so their false-positive rate is somewhat above the nominal 5 %; gaps in a series are tolerated but shorten the paired sample; a linear detrend does not remove seasonality or step changes, and an association between two wearable-derived signals can still reflect a shared sensor or confounder.

### `BehaviorInsights`

Source: `BehaviorInsights.swift`. The headline "does this behavior move an outcome?" feature. Splits days where a behavior was logged (e.g. *Alcohol*, *Late meal*, *Meditation*) from days it was not, and compares an outcome metric between the groups.

For each behavior/outcome it reports group means, signed `delta`, `pctChange`, **Cohen's d** (pooled SD), and a **Welch t-test** p-value (unequal variances, Welch–Satterthwaite df, normal-approx tail):

```
sp = sqrt( ((n1−1)·s1² + (n2−1)·s2²) / (n1+n2−2) )     d = (m1 − m2) / sp
t  = (m1 − m2) / sqrt(s1²/n1 + s2²/n2)
```

- `significant` requires `p < 0.05` **and** `min(nWith, nWithout) ≥ 5` (guards against spurious "significance" from a handful of days).
- `rank(...)` orders effects by `|d|` descending, significant first.
- `sentence(_:)` renders plain English, e.g. *"On days you logged 'Alcohol', Charge was 12% lower (avg 61 vs 69, n=140 vs 498)."*

### `ComparisonEngine`

Source: `ComparisonEngine.swift`. Period-over-period comparison of one daily metric.

- `stat(_:)` → `SeriesStat`: mean, median, min, max, sample SD (ddof = 1), n, and least-squares slope-per-day (OLS against the 0-based index).
- `compare(current:previous:)` → `PeriodComparison`: signed `delta` on the means, `pctChange` (nil when the previous mean is 0/empty), and a coarse `direction` (`-1/0/+1`).
- `monthOverMonth(byDay:referenceDay:)` splits a `yyyy-MM-dd` series on the `yyyy-MM` prefix (locale/timezone-free) into the reference month vs the immediately preceding calendar month.

---

## Blood pressure and the metrics NOOP can't measure

### Blood pressure is measured, never estimated

NOOP shows blood pressure only when it was **measured**: a cuff that writes to Apple Health, or a reading typed into the Lab Book. It does not estimate it from the strap. Cuffless blood pressure from a wrist optical sensor is not validated without a cuff calibration: the European Society of Hypertension's statement on cuffless devices (Stergiou et al., *J Hypertens* 2022; 40:1449-1460) and ISO 81060-3:2022 (continuous non-invasive devices) both require calibration and dedicated validation protocols. And the strap does not give NOOP what such an estimate would need: it sends heart rate and beat-to-beat (R-R) intervals, not a calibrated optical waveform. A number produced from those would look precise and be wrong, so the metric stays empty instead.

- **Sources.** `bp_systolic` / `bp_diastolic` read the Apple Health daily mean (the iOS bridge reads the two quantity types as a daily average) and every Lab Book reading of the same key (`labMarker` rows, one per measurement). `Repository+Vitals.swift` merges them to **one value per local day**: the mean of that day's readings. Apple Health's value is already a daily mean, so it counts as one reading in that average (the number of cuff readings behind it is not stored). The merge (`BloodPressure.mergeDaily`) is pure and tested; `exploreSeries` and `resolvedSeries` route only these two keys through it, so Explore, the metric detail and Compare all see the same series; the Apple Health page keeps reading the Apple-only series.
- **Category.** `BloodPressure.classify(systolic:diastolic:)` returns the category of the 2023 ESH hypertension guidelines (Mancia et al., *J Hypertens* 2023; 41:1874-2071, office blood pressure):

  | Category | Systolic | | Diastolic |
  |---|---|---|---|
  | Optimal | < 120 | and | < 80 |
  | Normal | 120-129 | and/or | 80-84 |
  | High-normal | 130-139 | and/or | 85-89 |
  | Grade 1 hypertension | 140-159 | and/or | 90-99 |
  | Grade 2 hypertension | 160-179 | and/or | 100-109 |
  | Grade 3 hypertension | >= 180 | and/or | >= 110 |
  | Isolated systolic hypertension | >= 140 | and | < 90 |

  When the two values fall in different rows, the higher category wins. Values are rounded to whole mmHg first (cuffs report whole numbers, and a daily mean of 129.5 is shown, and so classified, as 130). The word names where the number sits in the guideline's table; one day's mean, or an average of readings taken in different conditions, is not a diagnosis. Informational only, not medical advice.
- **Card.** The metric detail of both keys shows the latest day with both values ("128/82 mmHg"), its category word, the mean of the daily values over the last 30 days, an "Add a reading" button that opens the Lab Book editor on the blood-pressure pair, and the note that NOOP only shows measured blood pressure.

### Why a metric can be empty (`MetricAvailability`)

Most of the Explore catalog depends on something the user may not have. `Strand/Data/MetricAvailability.swift` is the one pure mapping from a metric to **why it can be empty and how to fill it**; the metric detail shows it in place of an empty chart, and Explore hides metrics with no data at all behind "Show metrics without data (N)" (blood pressure stays listed, because its detail has the button that fills it). The N and the hiding reuse the emptiness probe Explore already runs, so they cost no extra reads. The groups:

| Metric(s) | Comes from | Empty when |
|---|---|---|
| Charge (`recovery`) | HRV and resting HR while asleep, vs your own baseline | fewer than 4 nights of baseline (`Baselines.minNightsSeed`) |
| `hrv`, `rhr`, `resp_rate` | nightly R-R intervals (breathing rate by respiratory sinus arrhythmia) | no detected night of sleep with clean beat data |
| `skin_temp` | wrist temperature vs your own baseline | fewer than 4 nights of temperature; shown as a deviation, not an absolute |
| `spo2` (WHOOP) | WHOOP export only | always, for a strap-only user: a WHOOP 5.0/MG sends no blood-oxygen value NOOP can read, and the raw optical signal cannot be turned into a reliable percentage without WHOOP's own calibration, so NOOP leaves it empty instead of guessing |
| `avg_hr`, `max_hr` | strap heart rate over the local day | under one hour of strap heart rate that day |
| sleep stages, efficiency, `in_bed_min`, restorative | a night detected from the strap | no detected night |
| `hours_vs_needed_pct`, `sleep_need_min`, `sleep_debt_min`, `sleep_consistency`, HR-zone minutes, `strength_min`, Day Stress | WHOOP export (NOOP shows its own sleep need/debt/consistency and zone times on the Sleep and Workout screens) | no export imported |
| `fitness_age`, `vo2max_est`, `vitality`, `body_age` | weekly roll-ups | missing age/sex/waist in Settings, or under 4 nights of resting HR |
| `vo2max_exercise` | walks and runs of at least 10 minutes and 1 km, with distance and heart rate | none recorded or imported |
| `steps`, `active_kcal` | Apple Health; the strap's own daily total fills the days Apple Health lacks | neither has data |
| `steps_est` | motion volume calibrated against phone steps | fewer than 3 days with both |
| `vo2max` (Apple Health) | an Apple Watch | no Apple Watch writing it |
| weight, body fat, lean mass, BMI, waist, water | Apple Health | nothing writes them there |
| glucose, insulin, carbs | a CGM or automated insulin app (like Loop) writing to Apple Health | not shared with Apple Health / not allowed for NOOP to read |
| nutrition keys | a nutrition CSV | none imported |
| Mi Band keys | a Xiaomi band export | no Xiaomi band |

### Daily values derived from what is already stored

A few catalog metrics had no on-device producer even though their inputs were stored. They are now derived, always as the lowest-priority layer (an imported WHOOP value for the same day still wins):

- `avg_hr`, `max_hr`: mean and maximum of the strap's heart-rate samples over the local calendar day, written by `IntelligenceEngine` under the computed source when the day has at least an hour of samples (3 600 at 1 Hz).
- `in_bed_min`: asleep time divided by efficiency (the identity efficiency = asleep / in bed, also used by `Rest.composite(daily:)`), when the efficiency is plausible (above 0.3).
- `restorative_min`, `restorative_pct`: deep + REM, in minutes and as a share of the night asleep.
- `sleep_efficiency` is shown as a percent whichever scale the row was stored in (the on-device engine stores a 0-1 fraction).
- `steps` and `active_kcal` in Explore fall back to the strap's daily total on days Apple Health has none, the same precedence Today and Compare already use.

---

## The library orchestrator: `AnalyticsEngine`

Source: `AnalyticsEngine.swift`. A pure function that ties the recompute engines together for one day, producing the three daily scores — **Charge** (recovery), **Effort** (strain), **Rest** (sleep). **Live:** `analyzeDay` is wired in via `Strand/Data/IntelligenceEngine.swift` — it runs every ~15 minutes while connected and on demand from the Intelligence screen, persisting the computed Charge/Effort/Rest/workouts under the `"<deviceId>-noop"` source and **merged under** imports. Where a WHOOP export covers a day, its own per-day numbers still win; the recompute fills in the days the strap offloaded but no export covers.

`analyzeDay(day:hr:rr:resp:gravity:profile:baselines:maxHROverride:)` runs, in order:

1. `SleepStager.detectSleep` → keep sessions whose `end` falls on `day` (UTC) — a night ending that morning.
2. Daily sleep aggregates (in-bed-weighted efficiency; deep/REM/light minutes; disturbances) via `hypnogramMetrics`.
3. Daily resting HR = lowest per-session resting HR; daily avg HRV = in-bed-weighted mean of per-session HRV.
4. **Rest** — the four-component sleep composite (duration vs need / efficiency / restorative share / consistency), stored under `sleep_performance`.
5. **Charge** — `RecoveryScorer.recovery(...)` with the personal HRV/RHR/resp/skin-temp baselines and the Rest score as the sleep input, stored under `recovery`.
6. **Effort** — `StrainScorer.strain(...)` over the full day's HR window (Tanaka HRmax from age unless overridden), on the 0–100 scale, stored under `strain`.
7. `WorkoutDetector.detect(...)`.

Each score is also tagged with its **confidence tier** (`ScoreConfidence`: Solid / Building / Calibrating — see below). It assembles a `DailyMetric` (the `WhoopStore` cache shape) plus rich `SleepSession`s and `CachedSleepSession` cache rows. Every derived value is **approximate** by construction.

### Score confidence (`ScoreConfidence`)

Each score carries a small honesty label so a sparse day reads truthfully:

| Tier | Meaning |
|---|---|
| **Calibrating** | NOOP is still learning your baseline, or doesn't have enough data yet (baseline not usable for Charge; no in-bed data for Rest; no HR window for Effort). |
| **Building** | Enough to show, but thin (e.g. fewer than ~7 nights of baseline, or a 5/MG day backed mostly by PPG-derived HR). |
| **Solid** | Full inputs present. |

When NOOP can't compute a score honestly it shows **nothing** rather than a fake number.

### Imported-strain rescale

Imported WHOOP "Day Strain" is on WHOOP's 0–21 scale. To keep the Effort axis consistent, the importer (`WhoopExportImporter`) **rescales at import**: an imported Day Strain is multiplied by `100/21` when writing the `strain` metric series, so everything stored under `strain` is on the 0–100 Effort scale (a lossless round-trip — the CSV export down-converts back to 0–21).

---

## Data flow summary

```
WHOOP strap (BLE) ─┐
                   ├─► WhoopProtocol (frame decode) ─► WhoopStore (SQLite, 1 Hz streams)
WHOOP CSV export ──┤                                         │
Apple Health XML ──┘                                         │
                                                             ▼
   importers copy per-day recovery / strain / sleep ──► DailyMetric (metrics cache)
                                                             │
                          ┌──────────────────────────────────┤
                          ▼                                   ▼
   IntelligenceEngine ─► AnalyticsEngine.analyzeDay   Repository.days ─► TodayView,
   (live recompute: HRV + Charge/Effort/Rest +        InsightsView (CorrelationEngine,
   workouts from raw streams, every ~15 min +         BehaviorInsights), CompareView,
   Intelligence screen; persisted under the           MetricExplorerView (ComparisonEngine)
   "<deviceId>-noop" source, merged UNDER imports)

   live BLE stream ─► AppModel: HR smoothing · RMSSD · zone coaching ·
                       illness early-warning · resting-stress nudge
```

---

## Conventions & honesty notes

- **Approximate by design.** Charge, Effort, Rest (and sleep stages, workout intensity, calories) are transparent approximations of published methods — not reproductions of any proprietary algorithm. They're **independent approximations from a consumer strap, built on open science — not medical advice, and not WHOOP's official scores.** Each engine's source header states exactly where it approximates (e.g. RMSSD-only parasympathetic tone; normal-approx p-values).
- **One scale, honest about certainty.** All three scores are 0–100 and each rides a Solid / Building / Calibrating confidence tier; a score that can't be computed honestly shows nothing rather than a number.
- **Deterministic.** No randomness, no wall-clock dependence inside the math, no DB/network access. Same inputs → same outputs, which makes the package unit-testable against fixed vectors.
- **Robust statistics.** z-scores use EWMA mean-absolute-deviation (`× 1.253` to a Gaussian σ); resting HR uses 5-minute bin minima; HR display uses windowed medians — all chosen to resist single-sample outliers.
- **Cold-start honesty.** When a baseline isn't trustworthy yet, the recovery scorer returns `nil` rather than a fabricated number.
- **Not a medical device.** None of this is diagnostic or medical advice. The illness early-warning is a wellness nudge from your own baselines, not a clinical screen.
- **Not affiliated with WHOOP.** NOOP interoperates with hardware and exports you already own, entirely on-device. Protocol decoding builds on community reverse-engineering of the WHOOP 4.0 (project *my-whoop*, `johnmiddleton12/my-whoop`) and WHOOP 5.0 (project *goose*, `b-nnett/goose`) protocols.

---

## Irregular rhythm screening

Source: `IrregularRhythm.swift` (`IrregularRhythm.screen`), data in `Repository+IrregularRhythm.swift`, the nightly
Explore series in `IntelligenceEngine+IrregularRhythm.swift`, shown by `HeartRhythmCard` in the Health tab and on
the Heart-rate accuracy screen. It screens the strap's beat-to-beat (R-R) intervals during sleep for a rhythm that
is **irregularly irregular**, the way atrial fibrillation (AF) is, and reports how much of the night it covered.
It is a **screen, never a diagnosis**: only an ECG can confirm AF, NOOP is not a medical device, the wording says
"irregular rhythm" and "a pattern like atrial fibrillation", and a night without enough clean beats says so
instead of showing a reassuring zero.

Wrist-sensor studies showed this kind of screen is worth doing: Apple Heart Study (Perez et al., N Engl J Med
2019;381:1909–1917: 84 % of notifications concordant with AF on a simultaneous ECG patch, positive predictive
value 0.84, 95 % CI 0.76–0.92), Huawei Heart Study (Guo et al., J Am Coll Cardiol 2019;74:2365–2375: PPV 91.6 %)
and the Fitbit Heart Study (Lubitz et al., Circulation 2022;146:1415–1424: overlapping 5-minute tachograms, a
notification only after 11 consecutive irregular ones, about 30 minutes, PPV 98.2 %, 95 % CI 95.5–99.5).
Accuracy still differs between devices and inconclusive tracings are common (Mannhart et al., JACC Clin
Electrophysiol 2023;9:232–242, BASEL Wearable Study: sensitivity 58–85 %, specificity 69–79 %, 17–26 %
inconclusive).

### Segments and quality gates

A false alarm is worse than a miss here, and beats from an optical sensor are noisier than an ECG's, so:

- **Physiologic R-R only**: 300–2000 ms (the range `HRVAnalyzer` accepts). An interval outside it ends the stretch
  of beats it sits in. A gap of more than 5 s between consecutive beats' timestamps ends a stretch too.
- **A segment is 128 consecutive beats of one stretch** (Dash et al. 2009), cut from the start of the stretch
  without overlap; fewer than 128 left over are not analysed.
- **Coverage**: the R-R inside a segment must add up to 90–110 % of the wall-clock time between its first and last
  beat. Dropped beats or a hole in the recording break that, so the intervals would no longer be neighbours: the
  segment is rejected. (Timestamps are whole seconds and several beats can share one, so the ratio is only exact
  to about a second per segment.)

### Features and the rule

Three features come from Dash S, Chon KH, Lu S, Raeder EA. Automatic real time detection of atrial fibrillation.
Ann Biomed Eng 2009;37(9):1701–1709, and a fourth is NOOP's own addition:

1. **RMSSD / mean R-R**, after the 8 longest and 8 shortest intervals of the segment are removed (as in the paper).
2. **Shannon entropy** of the same trimmed intervals on a 16-bin histogram, normalised to 0–1.
3. **Turning-point ratio**: the share of interior beats that are a local maximum or minimum of the interval series.
   A random series has 2(N−2)/3 turning points with variance (16N−29)/90 (Kendall), so it is expressed as a
   z-score. A smooth series (respiratory sinus arrhythmia) has fewer turning points than chance, a strict
   long-short alternation (bigeminy) has more, AF looks like chance.
4. **No repeating pattern** (not in the paper): the largest absolute autocorrelation of the mean-removed intervals
   at lags 2 to 10 beats. An irregularly irregular rhythm has none; breathing does.

A segment is **irregular only when all four hold**: RMSSD/mean ≥ 0.10, entropy ≥ 0.87, turning-point z-score between
−5.0 and +6.0 (for 128 beats: 61 to 112 turning points out of 126, a TPR of 0.48–0.89) and largest |autocorrelation|
≤ 0.35. The AND is what keeps regular patterns out: bigeminy and trigeminy (regular patterns of ectopic beats) have
a high RMSSD but only a few distinct interval values, hence a low entropy and a turning-point count far from random;
a fit sleeper's respiratory sinus arrhythmia has a high RMSSD but a smooth, wave-like series.

**Why the fourth check.** At about three beats per breath (a heart rate of 50 and 15 breaths a minute) a smooth
respiratory wave has as many turning points as a random series, and a strong one has a high RMSSD and a high
entropy, so the three paper features alone call it irregular for as long as it lasts, night after night. A
synthetic fit sleeper (heart rate 43–60, a swing of ±60–120 ms, breathing 11–19 a minute with a wandering rate and
amplitude; no recording of a real fit sleeper's night was available here) was called irregular in about 7 % of segments
by the three features alone (up to 43 % at heart rate 50 and ±120 ms), and in 0.1 % with the fourth check:

| Mean R-R | Respiratory swing | RMSSD (median) | Three paper features | With the fourth check |
|---|---|---|---|---|
| 1000 ms | ±90 ms | 93 ms | 2.4 % | 0.0 % |
| 1000 ms | ±120 ms | 123 ms | 21.5 % | 0.0 % |
| 1000 ms | ±150 ms | 154 ms | 30.8 % | 0.0 % |
| 1200 ms | ±90 ms | 106 ms | 0.2 % | 0.0 % |
| 1200 ms | ±120 ms | 140 ms | 43.4 % | 0.0 % |
| 1200 ms | ±150 ms | 176 ms | 89.6 % | 0.2 % |
| 1400 ms | ±90 ms | 116 ms | 0.0 % | 0.0 % |
| 1400 ms | ±120 ms | 152 ms | 13.4 % | 1.0 % |
| 1400 ms | ±150 ms | 191 ms | 78.1 % | 4.1 % |

It also helped on real ECG recordings (below): fewer false alarms in the Arrhythmia database's ectopic-beat
segments, and room to relax the entropy and turning-point bounds, so it costs no sensitivity there.

### How the thresholds were chosen

Not guessed. PhysioNet ECG databases (Goldberger AL et al., Circulation 2000;101:e215–e220) were cut into 128-beat
segments with the gates above, R-R rounded to whole milliseconds and timestamps to whole seconds as the strap
delivers them, and labelled by the rhythm that covers most of the segment's beats. A grid over the four thresholds
picked the best **sensitivity** (AF segments of the MIT-BIH Atrial Fibrillation Database called irregular) that
keeps **every** non-AF set at **98.9 % specificity or better** (the AF database's "(N" and "(J" segments, the
MIT-BIH Normal Sinus Rhythm Database, and the young and the elderly volunteers of the Fantasia database) and the
synthetic fit sleeper at 98 % or better. (A 98.5 % target would give 91.9 % sensitivity but leave 0.01 point of
margin on the AF database.) The MIT-BIH Arrhythmia Database was used only to check, not to choose. The numbers below come from running the Swift engine
itself on the databases (25 195 segments; the Python twin used for the sweep agrees on every segment's features
and call).

| Database | What | Result (95 % Wilson interval) |
|---|---|---|
| MIT-BIH Atrial Fibrillation (Moody GB, Mark RG, Comput Cardiol 1983;10:227–230), 25 records, beats from the automatic detector | AF segments | **sensitivity 90.0 %** (3441/3824; 89.0–90.9) |
| same | non-AF segments | **specificity 98.9 %** (5059/5115; 98.6–99.2) |
| MIT-BIH Normal Sinus Rhythm, 18 healthy adults, 24 h | all segments | specificity 99.7 % (13158/13194) |
| Fantasia (Iyengar N et al., Am J Physiol 1996;271:R1078–R1084), 2 h supine at rest | young 21–34 y | specificity 99.6 % (1133/1138) |
| same | elderly 68–85 y | specificity 99.9 % (1048/1049) |
| MIT-BIH Arrhythmia (Moody GB, Mark RG, IEEE Eng Med Biol Mag 2001;20(3):45–50), 30 min per record, many ectopic beats; check only | AF segments | sensitivity 92.4 % (73/79; 84.4–96.5) |
| same | non-AF segments | specificity 98.3 % (687/699); 99.8 % (490/491) counting only segments of a single rhythm |

For comparison Dash et al. reported 94.4 % / 95.1 % (sensitivity / specificity) on the AF database and
90.2 % / 91.2 % on the Arrhythmia database. None of the 25 Arrhythmia-database segments of bigeminy, trigeminy and
similar regular ectopic or tachycardic rhythms was called irregular. Atrial flutter, which this screen is not meant
for: 0 of 88 segments flagged in the AF database, 5 of 9 in the Arrhythmia database.

Choosing and testing on the same data overstates performance. Choosing the thresholds on half of the records and
testing on the other half (40 folds) gave sensitivity 82.5 % ± 9.9 and specificity 98.1 % ± 1.7 (AF database),
99.6 % (normal sinus rhythm), 99.4 % (young Fantasia) and 99.9 % (elderly Fantasia): expect the in-sample numbers
to be a little optimistic.

**Frequent ectopic beats can still cause irregular segments** (premature atrial or ventricular beats in a few
records of the Arrhythmia database), which is why a single irregular segment is never a verdict.

### Episodes and the nightly result

Irregular segments that follow one another with no regular segment between them form an **episode** when together
they span **30 minutes or more** (the Fitbit Heart Study's persistence idea). A rejected, low-quality segment
neither breaks nor extends an episode, but an episode needs at least 80 % of its span analysed; a run that is
mostly holes is split at its biggest hole and each half is judged alone. Each sleep window is analysed on its own
(an episode never bridges two sleeps). At this level, running the engine over the databases, it found **no
30-minute episode in 374 h of normal sinus rhythm, 78 h of Fantasia, 22 h of Arrhythmia-database recordings, or in
the non-AF stretches of the AF database**, and **18 of the 20 AF stretches of 45 minutes or more** overlapped one.

A night gives: analysed minutes, irregular minutes, **burden %** (irregular / analysed), longest episode, episode
count and a verdict: `notEnoughData` (under 60 analysed minutes: no verdict), `regular`, `someIrregularSegments`
(irregular segments but no episode; usually ectopic beats, movement or noise) or `irregularEpisode`.

### In the app

- **Night**: the longest sleep session of each wake day, 2 hours or more (a nap is not a night), over the last 14
  days. The beats inside the session's window are read from the store and screened off the main actor.
- **Explore / Compare**: `irregular_rhythm_pct` ("Irregular rhythm (night)", %, Heart), the night's burden, stored
  under the "-noop" source. A night under 60 analysed minutes has no value (not a zero). The last two nights are
  re-screened on every scoring pass; an older night only when it has no stored value.
- **Card**: last night's verdict, clean beats analysed, irregular share, longest irregular stretch, and a 14-night
  strip (a bar per night with an irregular share, a dot for a regular night, an open circle for a night without
  enough clean beats; nights with an episode carry an icon and a legend line, not colour alone). On
  `irregularEpisode` it says to talk to a doctor if it happens again or with palpitations, breathlessness or
  dizziness, and to call emergency services with severe symptoms such as chest pain or fainting. On
  `notEnoughData` it says why (strap not worn at night, too many noisy beats) and what to change (snug fit, worn
  overnight). No notification is sent.

### Limits

- **Not measured on this strap.** The thresholds come from ECG R-R intervals. Optical beat timing is noisier,
  movement and a loose fit can mimic irregularity, and a missed beat looks like an irregular interval. The
  coverage gate and the 30-minute rule are the guard rails, not a guarantee.
- **The fit-sleeper check is a model.** No recording of a very fit sleeper's night was available; the false-alarm
  figures for respiratory sinus arrhythmia above come from a synthetic series, not from measured data.
- **Frequent ectopic beats** (premature atrial or ventricular beats) can look like AF in R-R alone and cause false
  alarms; brief episodes (under 30 minutes) are missed on purpose.
- **Sleep only.** Resting beats are the cleanest; the awake day is not screened.
- **Not a diagnosis.** Only an ECG can confirm atrial fibrillation. Informational only, not medical advice.

The existing `RhythmScreener` (the Poincaré view) is separate and descriptive: it makes no screening call.

Reproduce the threshold sweep and the numbers above with `Tools/irregular-rhythm-validation`.
