#!/usr/bin/env python3
"""Check the assumptions behind NOOP's exercise VO2max estimate on 992 laboratory treadmill tests.

Data: "Treadmill Maximal Exercise Tests from the Exercise Physiology and Human Performance Lab of the
University of Malaga" (PhysioNet, v1.0.1) — breath-by-breath VO2 and ECG heart rate during maximal ramp
tests (a walk at ~5 km/h, then +1 km/h per minute to exhaustion). Fetch it with ./fetch_malaga.sh.
Licence CC BY-NC-SA 4.0: nothing from it is committed to the repository, only these aggregate results.

NOOP estimates VO2max from a steady walk or run: the ACSM oxygen cost of the pace, and the fraction of heart-
rate reserve, which equals the fraction of VO2 reserve (Swain & Leutholtz 1997; Swain et al. 1998), so
VO2max = 3.5 + (VO2 - 3.5) / %HRR. A ramp test never holds a steady state, so it cannot replay that session
end to end; it can check each assumption separately:

  hrmax    age-predicted HRmax (Tanaka 2001, Nes 2013, 220 - age) against the measured peak
  line     does the HR–VO2 line of submaximal exercise reach VO2max at HRmax? (measured VO2, so the only
           assumption tested is the linear extrapolation), with the measured and the age-predicted HRmax
  twopoint the same with just two points, the end of the steady warm-up walk and one running point
  cost     the ACSM walking equation at the end of the steady 5 km/h warm-up, and the ACSM running equation
           along the ramp (speed lagged to allow for the VO2 response time)

Usage: ./validate_vo2max.py [hrmax|line|twopoint|cost|all]
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

DATA = Path(__file__).resolve().parent / "malaga"


def tanaka(age):
    return 208 - 0.7 * age


def acsm_walk(kmh, grade=0.0):
    s = kmh * 1000 / 60
    return 3.5 + 0.1 * s + 1.8 * s * grade


def acsm_run(kmh, grade=0.0):
    s = kmh * 1000 / 60
    return 3.5 + 0.2 * s + 0.9 * s * grade


def trailing_mean(t, x, window):
    """Mean over the trailing `window` seconds at every sample (time-based, breath-by-breath safe)."""
    out = np.empty(len(x))
    j, acc = 0, 0.0
    for i in range(len(x)):
        acc += x[i]
        while t[i] - t[j] >= window:
            acc -= x[j]
            j += 1
        out[i] = acc / (i - j + 1)
    return out


def lagged(t, v, tau):
    """v as it was `tau` seconds earlier."""
    idx = np.clip(np.searchsorted(t, t - tau, side="right") - 1, 0, len(v) - 1)
    return v[idx]


def agreement(diffs):
    d = np.asarray([x for x in diffs if np.isfinite(x)])
    sd = d.std(ddof=1)
    return f"n={len(d):4d}  bias {d.mean():+6.2f}  SD {sd:5.2f}  95% LoA {d.mean() - 1.96 * sd:+6.2f} … {d.mean() + 1.96 * sd:+6.2f}"


def load():
    info = pd.read_csv(DATA / "subject-info.csv").set_index("ID_test")
    measures = pd.read_csv(DATA / "test_measure.csv")
    tests = []
    for tid, d in measures.groupby("ID_test", sort=False):
        d = d.sort_values("time")
        if d.VO2.isna().all():          # 30 tests carry no gas exchange
            continue
        row = info.loc[tid]
        t = d.time.to_numpy(float)
        speed = d.Speed.to_numpy(float)
        hr = d.HR.to_numpy(float)
        hr[hr < 30] = np.nan            # ECG drop-outs
        hr = pd.Series(hr).interpolate(limit_direction="both")
        hr = hr.rolling(7, center=True, min_periods=1).median().to_numpy()   # rejects single-breath spikes
        vo2 = d.VO2.to_numpy(float) / row.Weight
        vo2[vo2 <= 0] = np.nan
        vo2 = pd.Series(vo2).interpolate(limit_direction="both").to_numpy()
        end = int(np.flatnonzero(speed >= speed.max() - 1e-9)[-1])         # last sample at peak speed
        vo2_30, hr_30 = trailing_mean(t, vo2, 30), trailing_mean(t, hr, 30)
        test = dict(id=tid, age=row.Age, female=row.Sex == 1, weight=row.Weight, t=t, speed=speed,
                    hr=hr_30, vo2=vo2_30, end=end,
                    vo2max=np.nanmax(vo2_30[: end + 1]),       # highest 30-s mean (Robergs et al. 2010)
                    hrmax=np.nanmax(hr[: end + 1]))
        # Warm-up: the first walking block (3–5.5 km/h) after any standing start.
        i0 = int(np.argmax(speed >= 3)) if (speed >= 3).any() else len(speed)
        i1 = i0
        while i1 < len(speed) and 3 <= speed[i1] <= 5.5:
            i1 += 1
        test["ramp_start"] = i1
        if i1 > i0 and t[i1 - 1] - t[i0] >= 150:                          # long enough to be steady
            last = (t >= t[i1 - 1] - 60) & (np.arange(len(t)) < i1)
            test["walk"] = dict(speed=np.median(speed[last]), hr=hr[last].mean(), vo2=vo2[last].mean())
        tests.append(test)
    return tests


def submax(test, lo=0.60, hi=0.85):
    idx = np.arange(len(test["t"]))
    return ((idx > test["ramp_start"]) & (idx <= test["end"])
            & (test["hr"] >= lo * test["hrmax"]) & (test["hr"] <= hi * test["hrmax"]))


def report_hrmax(tests):
    print("HRmax: measured peak minus age-predicted (adults)")
    adults = [x for x in tests if x["age"] >= 18]
    for name, f in (("Tanaka 2001   208 - 0.7 age", tanaka),
                    ("Nes 2013      211 - 0.64 age", lambda a: 211 - 0.64 * a),
                    ("Fox           220 - age", lambda a: 220 - a)):
        print(f"  {name:30s} {agreement([x['hrmax'] - f(x['age']) for x in adults])} bpm")


def report_line(tests):
    print("Linear HR–VO2 extrapolation to HRmax (measured VO2, 60–85% HRmax), estimate minus measured VO2max")
    meas, pred = [], []
    for x in tests:
        sel = submax(x)
        if sel.sum() < 20 or np.ptp(x["hr"][sel]) < 15:
            continue
        slope, intercept = np.polyfit(x["hr"][sel], x["vo2"][sel], 1)
        meas.append(intercept + slope * x["hrmax"] - x["vo2max"])
        pred.append(intercept + slope * tanaka(x["age"]) - x["vo2max"])
    print(f"  measured HRmax         {agreement(meas)} mL/kg/min")
    print(f"  Tanaka-predicted HRmax {agreement(pred)} mL/kg/min")


def report_twopoint(tests, frac=0.80):
    print(f"Two points (steady warm-up walk, first running point at {frac:.0%} HRmax) extrapolated to measured HRmax")
    out = []
    for x in tests:
        w = x.get("walk")
        if not w:
            continue
        hit = np.flatnonzero(submax(x, frac, 1.0) & (x["speed"] >= 8))
        if len(hit) == 0:
            continue
        hr, vo2 = x["hr"][hit[0]], x["vo2"][hit[0]]
        if hr - w["hr"] <= 20:
            continue
        out.append(vo2 + (x["hrmax"] - hr) * (vo2 - w["vo2"]) / (hr - w["hr"]) - x["vo2max"])
    print(f"  measured VO2 at both   {agreement(out)} mL/kg/min")


def report_cost(tests, tau=45):
    print("ACSM oxygen cost, measured minus predicted")
    walks = [x["walk"] for x in tests if x.get("walk")]
    print(f"  walking, end of the steady ~5 km/h warm-up, level  {agreement([w['vo2'] - acsm_walk(w['speed']) for w in walks])} mL/kg/min")
    at10, at12 = [], []
    for x in tests:
        speed = lagged(x["t"], x["speed"], tau)
        idx = np.arange(len(speed))
        sel = ((idx > x["ramp_start"]) & (idx <= x["end"]) & (speed >= 8) & (speed <= 14)
               & (x["hr"] < 0.85 * x["hrmax"]))
        if sel.sum() < 15 or np.ptp(speed[sel]) < 2:
            continue
        slope, intercept = np.polyfit(speed[sel], x["vo2"][sel], 1)
        at10.append(intercept + slope * 10 - acsm_run(10))
        at12.append(intercept + slope * 12 - acsm_run(12))
    print(f"  running 10 km/h on the ramp (speed lagged {tau} s)     {agreement(at10)} mL/kg/min")
    print(f"  running 12 km/h on the ramp (speed lagged {tau} s)     {agreement(at12)} mL/kg/min")


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    tests = load()
    print(f"{len(tests)} tests with gas exchange; median age {np.median([x['age'] for x in tests]):.1f}, "
          f"VO2max {np.median([x['vo2max'] for x in tests]):.1f} mL/kg/min, "
          f"{sum(x['female'] for x in tests)} women\n")
    for name, fn in (("hrmax", report_hrmax), ("line", report_line), ("twopoint", report_twopoint),
                     ("cost", report_cost)):
        if what in (name, "all"):
            fn(tests)
            print()


if __name__ == "__main__":
    main()
