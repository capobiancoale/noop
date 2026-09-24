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

This is the live, app-side version of the baseline-comparison idea. It recomputes whenever the daily history changes (`repo.$days`). It compares the **last ~2 days** against a **~28-day baseline ending 3 days ago** (so the recent window doesn't contaminate its own baseline):

```swift
let recent = Array(days.suffix(2))
let base   = Array(days.suffix(31).dropLast(3))   // ~28 days ending 3 days ago
```

It then flags anomalies against simple, explainable thresholds using `DailyMetric` fields:

| Signal | Field(s) | Anomaly condition |
|---|---|---|
| Resting HR ↑ | `restingHr` | recent mean ≥ baseline mean **+ 5 bpm** |
| HRV ↓ | `avgHrv` | recent mean ≤ baseline mean **× 0.80** (−20%) |
| Skin temp ↑ | `skinTempDevC` | recent mean deviation **≥ +0.6 °C** |
| Respiration ↑ | `respRateBpm` | recent mean ≥ baseline mean **+ 1.5 bpm** |

A banner appears only when **two or more** anomalies fire together — the classic early-illness signature is *RHR up + HRV down + skin-temp up*. Requires `behavior.illnessWatch` on and at least 14 days of history. On-device only; the message is a plain-English summary like *"Your body looks strained — resting HR +6 bpm, HRV −22%. Consider taking it easy."*

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
- "Recorded for that session" is the detected workout that best overlaps it (within an hour either side), else
  the span the WOD could occupy whether its logged time marks the start or the end. A WOD imported with a date
  only (anchored to local noon) is matched to the day's detected workout, or counts in full if none exists.
- Never negative: a metcon the heart rate fully captured adds nothing, so nothing is counted twice. A day with
  no heart rate still has no Effort; a WOD alone never makes one.
- Duration is the result time, else the time cap; a WOD without RPE or duration adds nothing (the WOD screen
  says so). Saving, editing or deleting a WOD rescores the recent days; the WOD screen shows what it added.

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

## VO₂max (`VO2maxEngine`)

Source: `VO2maxEngine.swift`, screen `VO2maxView`; full method, validation and references in
[VO2MAX.md](VO2MAX.md). Four views side by side, never blended:

- **From runs and walks.** Each steady walk or run (10–90 min, ≥ 1 km, 50–85 % of heart-rate reserve, pace
  inside the equation's range) is a single-stage submaximal test: the ACSM oxygen cost of its pace
  (walking 3.5 + 0.1·S, running 3.5 + 0.2·S, S in m/min, level ground), extrapolated to HRmax through
  %HRR = %VO₂R (Swain & Leutholtz 1997; Swain et al. 1998): `VO₂max = 3.5 + (VO₂ − 3.5) / %HRR` — validated
  from one steady stage at r 0.89, SEE 4.0 mL/kg/min, no bias (Swain et al. 2004). Heart rate is the strap's
  per-minute mean after the first 3 minutes; resting HR the 14-night median; HRmax the user's setting, else the
  second-highest believable workout peak of the year, else Tanaka. The number is the median of the newest
  ≤ 5 sessions of 90 days, stored per session day as `vo2max_exercise`.
- **At rest.** The HUNT non-exercise model (Nes et al. 2011) ± its SEE, weekly as `vo2max_est` (Fitness Age).
  The waist it needs can be typed on the VO₂max screen.
- **From WODs.** Heart-rate ratio `PF · HRmax / HRrest` (PF 15.3 men, Uth et al. 2004; 14.5 women, Uth 2005)
  with the HRmax above and HRrest measured awake and supine after 15 min of rest (Castagna et al. 2022): a
  guided 15-minute capture with the strap, mean of the final 2 min (`supineRestingHR`), stored as
  `vo2max_rhr_supine`, valid 60 days. Without one it falls back on the nightly resting HR and is labelled
  provisional (reads high). Independent SEE 6.9–7.9 mL/kg/min (Esco et al. 2012).
- **Your values.** Entered by hand (`vo2max_manual`, source `manual-vo2max`), each compared with every estimate
  at that date.

`Tools/vo2max-validation` checks the assumptions on 981 laboratory treadmill tests (PhysioNet, Malaga): the
submaximal HR–VO₂ line reaches VO₂max at HRmax with bias +0.85, SD 5.5 mL/kg/min (SD 7.0 with an age-predicted
HRmax), and Tanaka's HRmax is unbiased there (−0.9 bpm, SD 9.1).

## `WorkoutDetector` + `Calories` — retroactive workout detection

Source: `WorkoutDetector.swift`. Finds workouts in the stored 1 Hz HR + gravity streams (no manual logging).

A workout is a **sustained window** (≥ `minExerciseMin = 5` min) where **both** gates hold per sample:

- **Elevated HR** — above `RHR + hrMarginBPM (15 bpm)`. RHR defaults to the day's 10th-percentile HR.
- **Sustained motion** — gravity-derived intensity (10-second trailing mean) above `motionThreshold = 0.20`.

Active samples are grouped into runs (merging gaps < `mergeGapS = 150 s`), then qualified by intensity: ≥ `minIntensityZ2Plus = 0.50` of the bout in Edwards zone 2+. Per bout it reports avg/peak HR, duration, Edwards zone-time %, mean `%HRR`, strain (via `StrainScorer`), and calories.

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
