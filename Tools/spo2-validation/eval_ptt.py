"""Ratio-of-ratios SpO2 check on PhysioNet pulse-transit-time-ppg (finger MAX30101, red 660 / IR 880 nm).

Usage: python3 -I eval_ptt.py <data dir>
"""
import sys, os, glob, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from scipy.signal import butter, sosfiltfilt
import wfdb212 as w

D = [a for a in sys.argv[1:] if not a.startswith("--")][0]
FS = 500.0
WIN, STEP = 10.0, 5.0
# (red, ir). The README lists pleth_1/4 as IR and pleth_2/5 as red, but in all 22 subjects the "red" channel
# pulses MORE (higher AC/DC) than the "IR" one, which is physically impossible at SpO2 >= 94% (oxyhaemoglobin
# barely absorbs 660 nm). The MAX30101 multi-LED slot order is LED1 = red, LED2 = IR, LED3 = green, so the
# labels are swapped: pleth_1/4 = red, pleth_2/5 = IR. Pass --as-labelled to use the README mapping.
SITES = ({"A": ("pleth_2", "pleth_1"), "B": ("pleth_5", "pleth_4")} if "--as-labelled" in sys.argv
         else {"A": ("pleth_1", "pleth_2"), "B": ("pleth_4", "pleth_5")})
SOS = butter(2, [0.5, 5.0], btype="band", fs=FS, output="sos")

def window_ratios(red, ir, fs=FS, win=WIN, step=STEP, sos=SOS):
    acr, aci = sosfiltfilt(sos, red), sosfiltfilt(sos, ir)
    n, s = int(win * fs), int(step * fs)
    out = []
    for i in range(0, len(red) - n + 1, s):
        r, ii = acr[i:i + n], aci[i:i + n]
        dr, di = red[i:i + n].mean(), ir[i:i + n].mean()
        if dr <= 0 or di <= 0:
            continue
        pr, pi = r.std() / dr, ii.std() / di
        c = np.corrcoef(r, ii)[0, 1]
        slope = np.dot(r, ii) / np.dot(ii, ii)
        out.append({"t": i / fs, "R_rms": pr / pi, "R_slope": slope * di / dr, "corr": c, "pi_ir": pi})
    return out

def accept(wnd, cmin=0.9, pimin=2e-4, pimax=0.1):
    return [x for x in wnd if x["corr"] >= cmin and pimin <= x["pi_ir"] <= pimax]

CURVES = {
    "linear_110_25": lambda R: 110.0 - 25.0 * R,
    "maxim_quadratic": lambda R: -45.060 * R * R + 30.354 * R + 94.845,
}

rows = []
for hp in sorted(glob.glob(os.path.join(D, "*.hea"))):
    h = w.read_header(hp)
    x = w.read_212(hp[:-4] + ".dat", h)
    rec = os.path.basename(hp)[:-4]
    subj, act = rec.split("_")
    ref = (float(h["meta"]["spo2_start"]) + float(h["meta"]["spo2_end"])) / 2
    for site, (rk, ik) in SITES.items():
        wnd = window_ratios(x[rk], x[ik])
        ok = accept(wnd)
        rows.append({
            "rec": rec, "subj": subj, "act": act, "site": site, "ref": ref,
            "n_win": len(wnd), "n_ok": len(ok),
            "R_rms": float(np.median([o["R_rms"] for o in ok])) if ok else None,
            "R_slope": float(np.median([o["R_slope"] for o in ok])) if ok else None,
            "R_rms_iqr": float(np.subtract(*np.percentile([o["R_rms"] for o in ok], [75, 25]))) if len(ok) > 3 else None,
            "pi_ir": float(np.median([o["pi_ir"] for o in ok])) if ok else None,
        })
json.dump(rows, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results_ptt.json"), "w"), indent=1)

def metrics(pred, ref):
    d = np.asarray(pred) - np.asarray(ref)
    return {"n": len(d), "bias": round(float(d.mean()), 2), "ARMS": round(float(np.sqrt((d ** 2).mean())), 2),
            "MAE": round(float(np.abs(d).mean()), 2), "within2": round(float(np.mean(np.abs(d) <= 2)), 2)}

print("records x sites:", len(rows), " with >=1 accepted window:", sum(r["R_rms"] is not None for r in rows))
for site in SITES:
    for act in ["sit", "walk", "run", "all"]:
        sel = [r for r in rows if r["site"] == site and (act == "all" or r["act"] == act) and r["R_rms"] is not None]
        if not sel:
            continue
        ref = np.array([r["ref"] for r in sel])
        acc = np.mean([r["n_ok"] / max(r["n_win"], 1) for r in [q for q in rows if q["site"] == site and (act == "all" or q["act"] == act)]])
        line = {"site": site, "act": act, "n": len(sel), "accepted_win_frac": round(float(acc), 2)}
        for est in ["R_rms", "R_slope"]:
            R = np.array([r[est] for r in sel])
            line[est + "_median"] = round(float(np.median(R)), 3)
            line[est + "_p10_p90"] = [round(float(v), 3) for v in np.percentile(R, [10, 90])]
            line[est + "_r_vs_ref"] = round(float(np.corrcoef(R, ref)[0, 1]), 2)
            for cn, cf in CURVES.items():
                line[est + ":" + cn] = metrics(cf(R), ref)
        print(json.dumps(line))

# Leave-one-subject-out linear calibration vs a constant baseline (site A, all activities, R_rms)
for site in SITES:
    sel = [r for r in rows if r["site"] == site and r["R_rms"] is not None]
    subs = sorted({r["subj"] for r in sel})
    pl, pc, rf = [], [], []
    for s in subs:
        tr = [r for r in sel if r["subj"] != s]; te = [r for r in sel if r["subj"] == s]
        A = np.vstack([np.ones(len(tr)), [r["R_rms"] for r in tr]]).T
        coef, *_ = np.linalg.lstsq(A, np.array([r["ref"] for r in tr]), rcond=None)
        for r in te:
            pl.append(coef[0] + coef[1] * r["R_rms"]); pc.append(np.mean([q["ref"] for q in tr])); rf.append(r["ref"])
    A = np.vstack([np.ones(len(sel)), [r["R_rms"] for r in sel]]).T
    full, *_ = np.linalg.lstsq(A, np.array([r["ref"] for r in sel]), rcond=None)
    print(json.dumps({"site": site, "LOSO_linear": metrics(pl, rf), "LOSO_constant_baseline": metrics(pc, rf),
                      "full_fit": [round(float(c), 2) for c in full]}))

# Within-subject stability: same subject, same site, across sit/walk/run (reference changes <= 2 points)
for site in SITES:
    sds = []
    for s in sorted({r["subj"] for r in rows}):
        v = [r["R_rms"] for r in rows if r["subj"] == s and r["site"] == site and r["R_rms"] is not None]
        if len(v) >= 2:
            sds.append(np.std(v))
    print(json.dumps({"site": site, "within_subject_R_sd_median": round(float(np.median(sds)), 3),
                      "as_spo2_points_linear25": round(float(25 * np.median(sds)), 2)}))
