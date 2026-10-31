# Sleep staging: check against polysomnography and V2 calibration

Reproducible check of NOOP's two sleep-staging recipes (`SleepStager`, V1, and `SleepStagerV2`, the default)
against laboratory sleep scoring, and the calibration of two `SleepStagerV2` constants (described in
`docs/ANALYTICS.md`, "Staging V2 and the PSG check").

## Data

PhysioNet **sleep-accel** (Walch O, Huang Y, Forger D, Goldstein C. Sleep tracking from the Apple Watch: an
analysis of motion and heart rate. *Sleep* 2019;42(12):zsz180; PhysioNet: Goldberger AL et al., Circulation
2000;101:e215-e220): 31 adults, one night each in the lab, polysomnography scored in 30 s epochs, plus the
heart rate (about one value every 5 s) and the 50 Hz accelerometer of a wrist-worn watch. `fetch.sh` downloads
the heart rate, label and motion files (about 2.2 GB) from PhysioNet's open-data mirror into `./data` and checks
their SHA-256 sums; the data are git-ignored and never committed or shipped.

`prep.py` turns each night into the streams NOOP stages from: the heart-rate samples as they are, and the
acceleration averaged to one value a second (the strap's gravity stream), from an hour before the first label to
the last. There is no R-R or respiration in this dataset, so the check covers the heart-rate + motion path.

## Run

```sh
./fetch.sh
python3 prep.py data prep
./run.sh
```

`run.sh` copies the Swift packages to a temporary directory, makes the calibrated V2 constants settable there
(the shipped sources are untouched), runs `SleepAccelHarness.swift` as the package's only test, then
`calib.py`. The harness stages every night over its labelled span with V1 and V2 as shipped and with a grid of
V2 settings (deep gate 0.06-0.20, gate slope 5-20, deep base rate 0.10-0.18, REM base rate 0.18-0.26), and
writes one 4x4 confusion matrix per setting and night (wake / light = N1+N2 / deep = N3+N4 / REM; unscored
epochs left out).

## Result (31 nights, pooled epochs)

| Staging | Cohen's kappa | Accuracy | Deep share of sleep | REM share of sleep |
|---|---|---|---|---|
| Polysomnography | | | 15.1 % | 24.2 % |
| V1 | 0.10 | 51 % | 11.2 % | 10.5 % |
| V2 as first shipped (gate 0.20, deep 0.18) | 0.32 | 55 % | 24.6 % | 28.1 % |
| V2 calibrated (gate 0.15, deep 0.14), leave-one-subject-out | 0.34 | 60 % | 14.9 % | 24.1 % |

The calibrated setting is the one the held-out folds picked 31 times out of 31 (objective: kappa minus the
deep and REM share errors). A grid over V1's percentile bands never passed kappa 0.12, so V1 was not tuned.
Per-class recall of calibrated V2: wake 0.32, light 0.70, deep 0.49, REM 0.54. Wake is the weakest class.

Limits: one lab night per person; a watch, not the strap (heart rate every ~5 s rather than the strap's
cadence, an accelerometer averaged to one value a second rather than the strap's gravity vector); no R-R, so
V2's respiration term is idle here. Four-class kappa of 0.3-0.5 is the usual range for consumer wearables
without EEG, so the stages stay estimates.
