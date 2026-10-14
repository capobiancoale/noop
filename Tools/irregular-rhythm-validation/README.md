# Irregular-rhythm screening: threshold selection and validation

Reproducible choice and check of the thresholds in
`Packages/StrandAnalytics/Sources/StrandAnalytics/IrregularRhythm.swift` (described in `docs/ANALYTICS.md`,
"Irregular rhythm screening"): RMSSD / mean R-R, normalised Shannon entropy and the turning-point z-score of
128-beat segments of beat-to-beat intervals (Dash S, Chon KH, Lu S, Raeder EA. Ann Biomed Eng 2009;37:1701-1709),
plus a check of NOOP's own that the intervals do not repeat (largest absolute autocorrelation at lags 2 to 10),
which keeps a fit sleeper's strong respiratory sinus arrhythmia from being called irregular.

`segments.py` is a Python twin of the Swift engine (same quality gates, same features); the Swift engine itself was
run on the same data and agrees on every segment's features and call (25 195 segments). R-R is rounded to whole
milliseconds and timestamps to whole seconds, like the strap delivers them.

## Data

Annotation files (not ECG signals; a few megabytes) of four open-access PhysioNet databases:

| Folder | Database | Used for |
|---|---|---|
| `afdb` | MIT-BIH Atrial Fibrillation Database (Moody GB, Mark RG, Comput Cardiol 1983;10:227-230), 25 records, beats from the unaudited `.qrs` detector | AF segments (positives), "(N" and "(J" segments (negatives) |
| `nsrdb` | MIT-BIH Normal Sinus Rhythm Database, 18 healthy adults | negatives |
| `fantasia` | Fantasia Database (Iyengar N et al., Am J Physiol 1996;271:R1078-R1084), 20 young and 20 elderly healthy volunteers, 2 h supine at rest | negatives |
| `mitdb` | MIT-BIH Arrhythmia Database (Moody GB, Mark RG, IEEE Eng Med Biol Mag 2001;20(3):45-50), many ectopic beats | checking only |

PhysioNet: Goldberger AL et al., Circulation 2000;101:e215-e220. The data are downloaded into `./data`
(git-ignored) and never committed or shipped.

`athlete_rsa.py` is a **model**, not data: 3000 synthetic segments of a very fit sleeper's respiratory sinus
arrhythmia (heart rate 43-60, a swing of 60-120 ms, breathing 11-19 a minute with a wandering rate and amplitude).
No recording of a real fit sleeper's night was available. It is one more negative set in the sweep.

## Run

```sh
./fetch_physionet.py            # annotations only
pip install numpy
./validate.py sweep             # best sensitivity with every non-AF set above a target specificity
./validate.py cv                # thresholds chosen on half the records, tested on the other half
./validate.py report            # per-database numbers for the thresholds in IrregularRhythm.swift
./validate.py report 0.10 0.88 -4.0 6.0 9   # or any other set: RMSSD/mean, entropy, z low, z high, autocorrelation cap
```

## Results (RMSSD/mean >= 0.10, entropy >= 0.87, turning-point z -5.0 to +6.0, |autocorrelation| <= 0.35)

| Set | Result |
|---|---|
| AF database, AF segments | sensitivity 90.0 % (3441/3824) |
| AF database, non-AF segments | specificity 98.9 % (5059/5115) |
| Normal Sinus Rhythm database | specificity 99.7 % (13158/13194) |
| Fantasia, young 21-34 y | specificity 99.6 % (1133/1138) |
| Fantasia, elderly 68-85 y | specificity 99.9 % (1048/1049) |
| Arrhythmia database, AF segments (check) | sensitivity 92.4 % (73/79) |
| Arrhythmia database, non-AF segments (check) | specificity 98.3 % (687/699); 99.8 % (490/491) for single-rhythm segments |
| Synthetic fit sleeper (a model) | specificity 99.9 % (2998/3000) |

The three paper features alone (0.10, 0.88, -4.0 to +6.0; `./validate.py report 0.10 0.88 -4.0 6.0 9`) give
sensitivity 89.9 % and specificity 98.7 % / 99.7 % / 98.5 % / 99.9 % on the first four negative sets, but 93.0 % on
the Arrhythmia database and only 92.3 % on the synthetic fit sleeper (43 % of segments are called irregular at heart
rate 50 with a +-120 ms swing). Choosing the thresholds on half of the records and testing on the other half
(`cv`, 40 folds): sensitivity 82.5 % +- 9.9; specificity 98.1 % +- 1.7 (AF database), 99.6 % (normal sinus
rhythm), 99.4 % (young Fantasia), 99.9 % (elderly Fantasia). Dash et al. reported 94.4 % / 95.1 % on the AF
database and 90.2 % / 91.2 % on the Arrhythmia database.

Sensitivity and specificity are per 128-beat segment, labelled by the rhythm that covers most of the segment.
The 30-minute episode rule (not simulated by these scripts) is what keeps isolated irregular segments from being
a verdict. None of this was measured on a wrist strap.
