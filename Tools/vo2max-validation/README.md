# VO₂max assumption checks

Reproducible checks of the assumptions behind NOOP's VO₂max estimate from walks and runs
(`Packages/StrandAnalytics/Sources/StrandAnalytics/VO2maxEngine.swift`, described in `docs/VO2MAX.md`): the
ACSM oxygen cost of a pace, extrapolated to HRmax through the heart-rate reserve (%HRR = %VO₂R; Swain &
Leutholtz 1997, Swain et al. 1998), the single-stage VO₂-reserve method of Swain et al. (Med Sci Sports Exerc
2004), with a personal or age-predicted HRmax.

## Data

"Treadmill Maximal Exercise Tests from the Exercise Physiology and Human Performance Lab of the University of
Malaga" (Mongin, García Romero, Alvero Cruz; PhysioNet 2021, v1.0.1, doi:10.13026/7ezk-j442): 992 maximal
treadmill tests of 857 amateur and professional athletes aged 10–63, with breath-by-breath VO₂ (MedGraphics
CPX) and ECG heart rate. A walk at ~5 km/h, then a ramp of about +1 km/h per minute to exhaustion.

Licence **CC BY-NC-SA 4.0**: the data are downloaded into `./malaga` (git-ignored) and never committed or
shipped; only the aggregate results below are reported.

## Run

```sh
./fetch_malaga.sh              # ~23 MB, checked against the published SHA-256 sums
pip install numpy pandas
./validate_vo2max.py all       # or: hrmax | line | twopoint | cost
```

## Results (981 tests with gas exchange; median age 27.1, VO₂max 47.1 mL/kg/min, 145 women)

VO₂max is the highest 30-s mean (Robergs et al. 2010); HRmax the highest 7-breath median heart rate.

| Check | Estimate − measured |
|---|---|
| **line**: HR–VO₂ line of submaximal exercise (60–85% HRmax, measured VO₂) extended to the measured HRmax | bias **+0.85**, SD 5.50, 95% LoA −9.9…+11.6 mL/kg/min (n = 970) |
| same, extended to Tanaka's age-predicted HRmax | bias +1.39, SD 6.98, LoA −12.3…+15.1 |
| **twopoint**: end of the steady warm-up walk + first running point at 80% HRmax, extended to the measured HRmax | bias **−0.84**, SD 5.50, LoA −11.6…+9.9 (n = 781) |
| **hrmax** (adults, measured − predicted): Tanaka 208 − 0.7·age | bias **−0.90**, SD 9.08 bpm (n = 838) |
| Nes 211 − 0.64·age | −5.78, SD 9.02 |
| 220 − age | −3.54, SD 9.84 |
| **cost** (measured − ACSM): walking, end of the steady ~5 km/h warm-up | +3.71, SD 2.90 mL/kg/min (n = 797) |
| running at 10 km/h along the ramp (speed lagged 45 s) | −2.36, SD 3.87 (n = 653) |
| running at 12 km/h | −3.93, SD 4.86 |

**Reading.** The physiological core holds: a straight HR–VO₂ line through submaximal exercise reaches the
measured VO₂max at HRmax without bias, from many points or from two. Replacing the measured HRmax with an
age prediction widens the spread from 5.5 to 7.0 mL/kg/min, hence NOOP's preference for the user's own setting
or observed peaks; among age formulas Tanaka's is the unbiased one here. The ACSM oxygen cost of a pace varies
between people by 3–5 mL/kg/min; for these trained athletes it under-reads walking and over-reads running.

**What this cannot test.** A ramp never reaches a steady state, so the heart rate at a given speed is lower
than in a steady session: speed-based single points taken from the ramp are biased high and are not a fair
test of the steady-session estimate. Nor does the dataset carry a resting heart rate for the rest-anchored
form. The end-to-end accuracy of the single steady stage is Swain et al. 2004's: r = 0.89, SEE 4.0 mL/kg/min,
no bias (n = 50; pilot n = 49: r = 0.91, SEE 3.4).
