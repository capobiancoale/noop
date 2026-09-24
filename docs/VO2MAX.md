# VO₂max

NOOP shows maximal oxygen uptake three ways, side by side on the **VO₂max** screen (Health → Fitness Age →
VO₂max; macOS sidebar *Body → VO₂max*; iPhone *More → VO₂max*):

1. **From your runs and walks**: estimated during exercise, from the strap's heart rate and the pace of each
   steady walk or run. This is the more accurate kind of estimate.
2. **At rest**: the HUNT non-exercise model, from age, sex, waist, resting heart rate and activity.
3. **Your values**: VO₂max you measured or read elsewhere (a lab test, a field test, another device), entered
   by hand. The estimates are never blended with them; the screen shows how far each estimate was from each
   value you entered, at that date.

Apple Health VO₂max (e.g. Apple Watch "Cardio Fitness") is plotted too when present. None of this is a medical
test: it is a fitness estimate.

Code: `Packages/StrandAnalytics/Sources/StrandAnalytics/VO2maxEngine.swift` (maths, unit-tested),
`Strand/Data/Repository+VO2max.swift` (data), `Strand/Screens/VO2maxView.swift` (screen),
`IntelligenceEngine` (stores the trend).

## 1. From runs and walks

Every steady walk or run with a distance, a duration and a heart rate is used as a single-stage submaximal
exercise test.

**Oxygen cost of the pace.** The ACSM metabolic equations (ACSM's Guidelines for Exercise Testing and
Prescription, 11th ed., 2021), S = speed in m/min, G = fractional grade:

| Gait | VO₂ (mL·kg⁻¹·min⁻¹) | Valid for |
|---|---|---|
| Walking | 3.5 + 0.1·S + 1.8·S·G | 50–100 m/min (3–6 km/h) |
| Running | 3.5 + 0.2·S + 0.9·S·G | > 134 m/min (8 km/h), or ≥ 80 m/min when truly jogging |

Sessions carry no elevation, so G = 0: level ground is assumed.

**Intensity.** The fraction of heart-rate reserve equals the fraction of VO₂ reserve: intercept −0.1 and
slope 1.00 on the cycle ergometer (Swain & Leutholtz 1997, n = 63), 1.5 and 1.03 on the treadmill (Swain et
al. 1998, n = 50). Hence

    %HRR  = (HR − HRrest) / (HRmax − HRrest)
    VO₂max = 3.5 + (VO₂ − 3.5) / %HRR

This is the VO₂-reserve method. From one steady stage at a mean 64% HRR it estimated measured VO₂max with
r = 0.89, SEE 4.0 mL/kg/min and no over- or underestimation (36.7 vs 36.9; Swain et al. 2004, n = 50, pilot
n = 49: r = 0.91, SEE 3.4). Estimates of this family (exercise-based) are the more accurate ones on consumer
wearables: across 14 validation studies, bias −0.09 mL/kg/min with 95% limits of agreement −9.9…+9.7, against
+2.17 and −13.1…+17.4 for resting-based ones (INTERLIVE meta-analysis, Molina-Garcia et al. 2022).

**Which sessions count** (each gate keeps the session inside the conditions the method was validated in):

| Gate | Rule | Why |
|---|---|---|
| Sport | name contains "run"/"jog" (running) or "walk" (walking); hikes, trail runs, rucks and climbs are left out | the level-ground equations cannot see climbing |
| Duration | 10–90 min and ≥ 1 km | a steady state needs a few minutes (Swain read minutes 5–6); past 90 min cardiovascular drift raises HR at the same pace |
| Pace | walking 3.0–6.5 km/h, running 7–22 km/h | inside each equation's validated range; the walk–run transition is ≈ 7.2 km/h |
| Intensity | 50–85% of heart-rate reserve | below 50% the extrapolation gets long (a few bpm of error move the result > 5%); above 85% the effort is no longer steady |
| Heart rate | the strap's per-minute means from minute 3 to the end, covering ≥ 80% of that span (else the workout's own average) | skips the rise to steady state; SQL-aggregated, no raw samples loaded |
| Resting HR | median of the nightly resting HR of the 14 days up to the session | one short or feverish night does not shift it |

**HRmax** is the one input that moves the estimate most (an HRmax 10 bpm too high reads ≈ 7% high). In
order: your own setting (Settings → Max heart rate, e.g. from a test); else the **second-highest workout peak
of the last year** (the second discards a single optical spike), provided at least three peaks lie within
3 SD of the age prediction and it is no more than 2 SD below it (lower means no maximal effort was recorded
yet); else Tanaka's 208 − 0.7·age (Tanaka et al. 2001). The SD is the 10.8 bpm standard error of an
age-predicted HRmax (Nes et al. 2013, n = 3,320 with a verified maximal effort).

**The number** is the median of the newest ≤ 5 qualifying sessions of the last 90 days, shown with the lowest
and highest of them. With fewer than 3 sessions the screen says the number can still move a lot. Every
session is listed with its pace, heart rate, %HRR and VO₂max, and the ones not counted are summarised by
reason.

**Stored as** `vo2max_exercise` (mL/kg/min) under the computed `-noop` source: one point per session day,
the value the estimate read after that day's last session, recomputed over the last year on every analytics
pass (days that lose their session are removed).

### Validation on 981 laboratory tests

`Tools/vo2max-validation` re-checks the assumptions on the public University of Malaga treadmill dataset
(PhysioNet, 992 maximal ramp tests with breath-by-breath VO₂ and ECG heart rate; 981 carry gas exchange;
median age 27, VO₂max 47 mL/kg/min, 145 women). A ramp (+1 km/h per minute) never holds a steady state, so it
cannot replay a session end to end; it tests each assumption on its own:

| Check | Result (estimate − measured) |
|---|---|
| HR–VO₂ line of submaximal exercise (60–85% HRmax, measured VO₂) extended to the measured HRmax | bias +0.85, SD 5.5 mL/kg/min (n = 970) |
| same, extended to Tanaka's age-predicted HRmax | bias +1.39, SD 7.0 |
| two points only (end of the steady 5 km/h warm-up walk, first running point at 80% HRmax) | bias −0.84, SD 5.5 (n = 781) |
| HRmax: Tanaka 2001 / Nes 2013 / 220 − age (adults, measured − predicted) | −0.9 / −5.8 / −3.5 bpm, SD 9.1 / 9.0 / 9.8 (n = 838) |
| ACSM walking cost at the end of the steady 5 km/h warm-up (measured − predicted) | +3.7, SD 2.9 mL/kg/min |
| ACSM running cost along the ramp at 10 / 12 km/h (speed lagged 45 s) | −2.4 / −3.9, SD 3.9 / 4.9 |

What this says: the physiological core holds (a straight HR–VO₂ line reaches VO₂max at HRmax without bias);
a personal HRmax is worth having (the spread grows from 5.5 to 7.0 with an age-predicted one); and Tanaka is
the better age formula for these athletes. The oxygen cost of a given pace varies between people by about
3–5 mL/kg/min (running economy); in these trained athletes the ACSM running equation over-reads the cost and
the walking one under-reads it. The ramp's running comparison is only indicative, since VO₂ lags a ramp; the
end-to-end accuracy of the single-stage method is Swain et al. 2004's (SEE 4.0, no bias).

### Known limits

- **Level ground and no wind** are assumed; hills and headwind make a session look harder than its pace, so
  they read low.
- **Nightly resting HR** is lower than the seated resting HR of the lab studies. That makes the estimate
  slightly conservative: for a 10 bpm lower resting HR, about 1 mL/kg/min lower at 75–80% HRR and up to about
  2.5 at 55% (the reserve changes on both sides of the ratio, so the effect shrinks as intensity rises).
- **Heat, dehydration, fatigue, caffeine or a strap locked on to running cadence** raise the heart rate at a
  given pace and pull the estimate down; the median over sessions damps single cases.
- **Beta-blockers** or anything else that blunts heart rate invalidate heart-rate-based estimates.
- Running economy differs between people by several percent: the estimate cannot know yours. Entering a lab
  value shows how far off it is for you.

## 2. At rest

The HUNT non-exercise model (Nes et al. 2011: 4,637 adults with measured VO₂peak; models fitted on 2,067 men
and 2,193 women; 61% and 56% of the variance explained), waist variant — see
[FITNESS_AGE.md](FITNESS_AGE.md):

    men:   100.27 − 0.296·age + 0.226·PA − 0.369·waist − 0.155·RHR    (SEE 5.70)
    women:  74.74 − 0.247·age + 0.198·PA − 0.259·waist − 0.114·RHR    (SEE 5.14)

with RHR the median nightly resting heart rate of the last 7 nights (at least 4 needed) and PA the HUNT
activity index (0–15) rebuilt from the last 7 days' Effort. It needs a waist measurement (Settings). The
screen shows it ± its SEE. Resting estimates are the less accurate kind (INTERLIVE, above), and the model
overestimated in an independent US cohort (BALL ST: Peterman et al., J Am Heart Assoc 2020). Stored weekly
as `vo2max_est`.

## 3. Your values

Enter a value with the date and how it was measured (lab test with gas analysis, field test, another device
or app). Values from 10 to 95 mL/kg/min are accepted; one per day (a second one that day replaces it). They
are stored locally as `vo2max_manual` (and `vo2max_manual_method`: 1 lab, 2 field, 3 device) under the source
`manual-vo2max`, and appear in the metric explorer as *VO₂ Max (your entries)*.

For each value the screen shows the exercise estimate as it read at the end of that day (median of the
sessions of the previous 90 days) and the resting estimate of that week (within 14 days before), each with
the difference in mL/kg/min and in percent; within ±10% it is shown in green.

## Metric keys

| Key | Source | Meaning |
|---|---|---|
| `vo2max_exercise` | `<device>-noop` | estimate from runs and walks, per session day |
| `vo2max_est` | `<device>-noop` | estimate at rest (HUNT), weekly on Saturday |
| `vo2max_manual`, `vo2max_manual_method` | `manual-vo2max` | the values you enter |
| `vo2max` | `apple-health` | Apple Health's VO₂max, when imported |

## References

- American College of Sports Medicine. *ACSM's Guidelines for Exercise Testing and Prescription*, 11th ed.
  Wolters Kluwer, 2021 (metabolic equations; %HRR ≈ %VO₂R).
- Swain DP, Leutholtz BC. Heart rate reserve is equivalent to %VO₂ reserve, not to %VO₂max. *Med Sci Sports
  Exerc* 1997;29(3):410–414. doi:10.1097/00005768-199703000-00018
- Swain DP, Leutholtz BC, King ME, Haas LA, Branch JD. Relationship between % heart rate reserve and % VO₂
  reserve in treadmill exercise. *Med Sci Sports Exerc* 1998;30(2):318–321.
  doi:10.1097/00005768-199802000-00022
- Swain DP, Parrott JA, Bennett AR, Branch JD, Dowling EA. Validation of a new method for estimating VO₂max
  based on VO₂ reserve. *Med Sci Sports Exerc* 2004;36(8):1421–1426. doi:10.1249/01.mss.0000135774.28494.19
- Molina-Garcia P, Notbohm HL, Schumann M, et al. Validity of estimating the maximal oxygen consumption by
  consumer wearables: a systematic review with meta-analysis and expert statement of the INTERLIVE network.
  *Sports Med* 2022;52(7):1577–1597. doi:10.1007/s40279-021-01639-y
- Tanaka H, Monahan KD, Seals DR. Age-predicted maximal heart rate revisited. *J Am Coll Cardiol*
  2001;37(1):153–156. doi:10.1016/s0735-1097(00)01054-8
- Nes BM, Janszky I, Wisløff U, Støylen A, Karlsen T. Age-predicted maximal heart rate in healthy subjects:
  the HUNT Fitness Study. *Scand J Med Sci Sports* 2013;23(6):697–704. doi:10.1111/j.1600-0838.2012.01445.x
- Nes BM, Janszky I, Vatten LJ, et al. Estimating V̇O₂peak from a nonexercise prediction model: the HUNT
  Study, Norway. *Med Sci Sports Exerc* 2011;43(11):2024–2030. doi:10.1249/MSS.0b013e31821d3f6f
- Nauman J, Nes BM, Lavie CJ, et al. A prospective population study of resting heart rate and peak oxygen
  uptake (the HUNT Study, Norway). *PLoS One* 2012;7(9):e45021. doi:10.1371/journal.pone.0045021 (PA-index
  coding)
- Robergs RA, Dwyer D, Astorino T. Recommendations for improved data processing from expired gas analysis
  indirect calorimetry. *Sports Med* 2010;40(2):95–111. doi:10.2165/11319670-000000000-00000 (30-s averages)
- Mongin D, García Romero J, Alvero Cruz JR. Treadmill Maximal Exercise Tests from the Exercise Physiology and
  Human Performance Lab of the University of Malaga (v1.0.1). PhysioNet 2021. doi:10.13026/7ezk-j442
