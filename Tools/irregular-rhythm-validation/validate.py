#!/usr/bin/env python3
"""Choose and check the thresholds of IrregularRhythm.swift on PhysioNet ECG databases.

  ./validate.py sweep                      grid search: best sensitivity with every non-AF set above a specificity
  ./validate.py cv                         the same selection on half the records, tested on the other half
  ./validate.py report [rmssd entropy zlo zhi acf]   sensitivity / specificity per database for one set of thresholds

Positives are segments whose majority rhythm is AF ("(AFIB" in the AF database). Negatives are the AF database's
"(N" and "(J" segments, the whole Normal Sinus Rhythm Database, the Fantasia database (young and elderly healthy
volunteers) and a synthetic very fit sleeper (athlete_rsa.py: a model, not data). Atrial flutter is left out of
both classes. The Arrhythmia database is only used by `report`, to check, never to choose. Needs numpy.
"""
import math
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import athlete_rsa  # noqa: E402
import segments as seg  # noqa: E402

REAL_GROUPS = ["afdb_non", "nsrdb", "fan_young", "fan_old"]
NEG_GROUPS = REAL_GROUPS + ["sim_athlete"]
# RMSSD/mean, entropy, turning-point z low, z high, largest |autocorrelation| (IrregularRhythm.swift)
CHOSEN = (0.10, 0.87, -5.0, 6.0, 0.35)
REAL_TARGET, SIM_TARGET = 0.989, 0.98     # minimum specificity of every real set / of the synthetic set
SIM_SEGMENTS = 3000


def dataset():
    rows = []
    for rec, v in seg.build("afdb").items():
        for s in v["segs"]:
            if not s["ok"]:
                continue
            if s["rhythm"] == "(AFIB":
                rows.append((1, "afdb_af", "afdb:" + rec) + (s["nrm"], s["she"], s["z"], s["acf"]))
            elif s["rhythm"] in ("(N", "(J"):
                rows.append((0, "afdb_non", "afdb:" + rec) + (s["nrm"], s["she"], s["z"], s["acf"]))
    for rec, v in seg.build("nsrdb").items():
        rows += [(0, "nsrdb", "nsrdb:" + rec, s["nrm"], s["she"], s["z"], s["acf"]) for s in v["segs"] if s["ok"]]
    for rec, v in seg.build("fantasia").items():
        group = "fan_young" if rec[2] == "y" else "fan_old"
        rows += [(0, group, "fan:" + rec, s["nrm"], s["she"], s["z"], s["acf"]) for s in v["segs"] if s["ok"]]
    for k, rr in enumerate(athlete_rsa.fit_sleeper_segments(SIM_SEGMENTS)):
        nrm, she, z, _ = seg.features(rr)
        rows.append((0, "sim_athlete", "sim:%d" % (k // 100), nrm, she, z, seg.max_acf(rr)))
    lab = np.array([r[0] for r in rows])
    grp = np.array([r[1] for r in rows])
    rec = np.array([r[2] for r in rows])
    x = np.array([[r[3], r[4], r[5], r[6]] for r in rows])
    return lab, grp, rec, x


def grid():
    return (np.round(np.arange(0.06, 0.161, 0.01), 3), np.round(np.arange(0.80, 0.961, 0.01), 3),
            np.round(np.arange(-7.0, -1.99, 0.5), 2), np.array([0.30, 0.35, 0.40, 0.45, 0.50, 0.60, 0.70, 9.0]))


def evaluate(lab, grp, x, groups=NEG_GROUPS):
    """Positives called and false calls per negative set, for every point of the grid (z high fixed at +6)."""
    nr, sh, zl, ac = grid()
    nrm, she, z, acf = x[:, 0], x[:, 1], x[:, 2], x[:, 3]
    shape = (len(nr), len(sh), len(zl), len(ac))
    tp = np.zeros(shape, dtype=np.int32)
    fp = {g: np.zeros(shape, dtype=np.int32) for g in groups}
    pos = lab == 1
    members = {g: grp == g for g in groups}
    z_ok = (z[:, None] >= zl[None, :]) & (z[:, None] <= CHOSEN[3])
    a_ok = acf[:, None] <= ac[None, :]
    both = z_ok[:, :, None] & a_ok[:, None, :]
    for i, a in enumerate(nr):
        for j, b in enumerate(sh):
            m = (nrm >= a) & (she >= b)
            if not m.any():
                continue
            bb = both[m]
            tp[i, j] = bb[pos[m]].sum(axis=0)
            for g in groups:
                fp[g][i, j] = bb[members[g][m]].sum(axis=0)
    return tp, fp


def pick(lab, grp, x, real_target=REAL_TARGET, sim_target=SIM_TARGET, groups=NEG_GROUPS):
    nr, sh, zl, ac = grid()
    tp, fp = evaluate(lab, grp, x, groups)
    sens = tp / int((lab == 1).sum())
    ok = np.ones_like(sens, dtype=bool)
    specs = {}
    for g in groups:
        n = int((grp == g).sum())
        if n:
            specs[g] = 1 - fp[g] / n
            ok &= specs[g] >= (sim_target if g == "sim_athlete" else real_target)
    if not ok.any():
        return None
    best = np.unravel_index(np.argmax(np.where(ok, sens, -1)), sens.shape)
    return {"rmssd": float(nr[best[0]]), "entropy": float(sh[best[1]]), "zlo": float(zl[best[2]]),
            "acf": float(ac[best[3]]), "sens": round(float(sens[best]), 4),
            "specs": {g: round(float(specs[g][best]), 4) for g in specs}}


def wilson(k, n):
    if n == 0:
        return float("nan"), float("nan")
    p, z = k / n, 1.96
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return c - h, c + h


def line(name, k, n, what):
    lo, hi = wilson(k, n)
    print(f"{name:38s} {what} {k}/{n} = {100 * k / n:.1f}% (95% CI {100 * lo:.1f}-{100 * hi:.1f})")


def cmd_sweep():
    lab, grp, _, x = dataset()
    print({g: int((grp == g).sum()) for g in ["afdb_af"] + NEG_GROUPS})
    for target in (0.985, 0.987, 0.989, 0.99):
        print(target, pick(lab, grp, x, target))


def cmd_cv():
    lab, grp, rec, x = dataset()
    rng = np.random.default_rng(5)
    real = sorted(set(r for r in rec if not r.startswith("sim:")))
    rows = []
    for _ in range(20):
        half = set(real[i] for i in rng.permutation(len(real))[:len(real) // 2])
        mask = np.array([(r in half) or (r.startswith("sim:") and int(r.split(":")[1]) % 2 == 0) for r in rec])
        for train, test in ((mask, ~mask), (~mask, mask)):
            best = pick(lab[train], grp[train], x[train])
            if best is None:
                continue
            call = ((x[test, 0] >= best["rmssd"]) & (x[test, 1] >= best["entropy"]) & (x[test, 2] >= best["zlo"])
                    & (x[test, 2] <= CHOSEN[3]) & (x[test, 3] <= best["acf"]))
            lt, gt = lab[test], grp[test]
            rows.append([call[lt == 1].mean()] + [1 - call[gt == g].mean() if (gt == g).any() else np.nan
                                                  for g in NEG_GROUPS])
    rows = np.array(rows)
    print(f"{len(rows)} folds (records split in halves, thresholds chosen on one half, tested on the other)")
    print("sensitivity %.3f +- %.3f" % (np.nanmean(rows[:, 0]), np.nanstd(rows[:, 0])))
    for k, g in enumerate(NEG_GROUPS):
        print("specificity %-12s %.3f +- %.3f" % (g, np.nanmean(rows[:, k + 1]), np.nanstd(rows[:, k + 1])))


def cmd_report(th):
    def irregular(s):
        return (s["ok"] and s["nrm"] >= th[0] and s["she"] >= th[1] and th[2] <= s["z"] <= th[3]
                and s["acf"] <= th[4])

    def count(db, positive, negative=None, exclude=(), pure=False, only=None):
        """(called positives, positives, called negatives, negatives) over a database's usable segments."""
        tp = pos = fp = neg = 0
        for rec, v in seg.build(db).items():
            if only and not only(rec):
                continue
            for s in v["segs"]:
                if not s["ok"] or (pure and s["purity"] < 0.999) or s["rhythm"] in exclude:
                    continue
                if s["rhythm"] in positive:
                    pos += 1
                    tp += irregular(s)
                elif negative is None or s["rhythm"] in negative:
                    neg += 1
                    fp += irregular(s)
        return tp, pos, fp, neg

    print("thresholds: RMSSD/mean >= %.2f, entropy >= %.2f, turning-point z in [%.1f, %.1f], |autocorrelation| <= %.2f" % th)
    a = count("afdb", {"(AFIB"}, {"(N", "(J"})
    line("AF database, AF segments", a[0], a[1], "sensitivity")
    line("AF database, (N and (J segments", a[3] - a[2], a[3], "specificity")
    n = count("nsrdb", set())
    line("Normal Sinus Rhythm database", n[3] - n[2], n[3], "specificity")
    young = count("fantasia", set(), only=lambda r: r[2] == "y")
    old = count("fantasia", set(), only=lambda r: r[2] == "o")
    line("Fantasia, young 21-34 y", young[3] - young[2], young[3], "specificity")
    line("Fantasia, elderly 68-85 y", old[3] - old[2], old[3], "specificity")
    m = count("mitdb", {"(AFIB"}, exclude={"(AFL"})
    line("Arrhythmia database, AF segments", m[0], m[1], "sensitivity")
    line("Arrhythmia database, non-AF segments", m[3] - m[2], m[3], "specificity")
    mp = count("mitdb", {"(AFIB"}, exclude={"(AFL"}, pure=True)
    line("Arrhythmia db, single-rhythm non-AF", mp[3] - mp[2], mp[3], "specificity")
    rng = random.Random(77)
    called = 0
    for _ in range(SIM_SEGMENTS):
        rr = athlete_rsa.fit_sleeper(rng)
        nrm, she, z, _ = seg.features(rr)
        called += (nrm >= th[0] and she >= th[1] and th[2] <= z <= th[3] and seg.max_acf(rr) <= th[4])
    line("Synthetic fit sleeper (a model)", SIM_SEGMENTS - called, SIM_SEGMENTS, "specificity")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "report"
    if command == "sweep":
        cmd_sweep()
    elif command == "cv":
        cmd_cv()
    else:
        cmd_report(tuple(float(v) for v in sys.argv[2:7]) if len(sys.argv) >= 7 else CHOSEN)
