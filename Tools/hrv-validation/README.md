# HRV artefact-correction validation

Reproducible check of NOOP's RR-interval artefact correction
(`Packages/StrandAnalytics/Sources/StrandAnalytics/RRArtefactCorrection.swift`), an implementation of

> Lipponen JA, Tarvainen MP. *A robust algorithm for heart rate variability time series artefact
> correction using novel beat classification.* J Med Eng Technol 2019;43(3):173–181.
> doi:10.1080/03091902.2019.1640306

the automatic correction Kubios HRV applies by default. The scripts rerun the paper's own evaluation on
the same public database it used, and compare against the open-source reference implementation
(NeuroKit2 `signal_fixpeaks(method="Kubios")`).

## Run

```sh
./fetch_fantasia.sh            # PhysioNet Fantasia beat annotations (~0.6 MB)
./build_cli.sh                 # builds the corrector from the app's own source (needs swiftc)
pip install numpy pandas neurokit2==0.2.13
./validate_lt2019.py table1    # detection per artefact type (paper Table 1)
./validate_lt2019.py table3    # RMSSD error of 5-min samples (paper Table 3)
./validate_lt2019.py agree     # beat-level agreement with NeuroKit2
./validate_lt2019.py table1 --threshold abs   # the |x| threshold reading, for comparison
```

## Protocol (paper §3)

- Recordings with at most six non-normal beats: f1o01, f1o05, f1o10, f1y01, f1y03, f1y08, f1y09, f1y10
  (61,437 normal intervals; the paper reports 9 recordings and 61,757 normal beats).
- Missed beats: the detections at k = 100n removed. Extra detections: a beat inserted halfway through the
  interval after k = 100n. Misaligned beats: detections at k = 100n moved by ±q·RMSSD, q = 2, 4, 8.
- Table 3: six 5-min samples per recording (48), artefacts at k = 100n inside each sample.

## Results (NOOP as shipped: quartile deviation of the signed series)

| Beats | Detected (paper) | Classified (paper) |
|---|---|---|
| Normal, kept as normal | 99.837% (99.963%) | |
| Missed | 100.0% (100%) | 97.5% (100%) |
| Extra | 99.2% (100%) | 97.1% (99.8%) |
| Misaligned q = 2 | 61.0% (53.9%) | 60.7% (53.3%) |
| Misaligned q = 4 | 99.0% (99.3%) | 98.2% (98.8%) |
| Misaligned q = 8 | 100.0% (100%) | 100.0% (100%) |

RMSSD of 5-min samples, mean error vs the original series:

| Case | Uncorrected | Corrected |
|---|---|---|
| Clean (no artefact) | 0% | −2.8% |
| Missed | +427% | −3.0% |
| Extra | +181% | −2.7% |
| Misaligned q = 2 / 4 / 8 | +9% / +34% / +105% | +0.8% / −2.8% / −2.6% |

With the threshold read as QD(|x|), as NeuroKit2 does, only 98.92% of normal beats are kept, 89% of q = 2
displacements are detected (far above the paper's 54%) and clean RMSSD drops by 6.4%. The signed reading
is also the only one under which the paper's statement that α = 5.2 "covers 99.95% of all beats if [the]
series is normally distributed" holds (5.2 × 0.674σ = 3.5σ). With the same threshold reading, NOOP's labels
match NeuroKit2 0.2.13 on 99.9996% of 245,259 intervals.

Known limit: in the one recording with very high HRV (f1y01, RMSSD ≈ 92 ms) 5 of 87 extra detections go
undetected; they cost that recording's RMSSD a few percent, against +181% uncorrected.

## Data

Fantasia Database, PhysioNet (doi:10.13026/C2RG61), Open Data Commons Attribution License v1.0.
Iyengar N, Peng C-K, Morin R, Goldberger AL, Lipsitz LA. Age-related alterations in the fractal scaling
of cardiac interbeat interval dynamics. Am J Physiol 1996;271:R1078–R1084.
