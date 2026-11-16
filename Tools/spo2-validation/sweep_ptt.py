"""Sweep the window length and the red/IR correlation gate. Usage: python3 -I sweep_ptt.py <data dir>"""
import sys, os, glob, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from scipy.signal import butter, sosfiltfilt
import wfdb212 as w

D = sys.argv[1]; FS = 500.0
SITES = {"A": ("pleth_1", "pleth_2"), "B": ("pleth_4", "pleth_5")}
SOS = butter(2, [0.5, 5.0], btype="band", fs=FS, output="sos")
cache = []
for hp in sorted(glob.glob(os.path.join(D, "*.hea"))):
    h = w.read_header(hp); x = w.read_212(hp[:-4] + ".dat", h)
    rec = os.path.basename(hp)[:-4]; subj, act = rec.split("_")
    ref = (float(h["meta"]["spo2_start"]) + float(h["meta"]["spo2_end"])) / 2
    for site, (rk, ik) in SITES.items():
        red, ir = x[rk], x[ik]
        cache.append((subj, act, site, ref, red, ir, sosfiltfilt(SOS, red), sosfiltfilt(SOS, ir)))

def run(win, cmin, outlier):
    res = []
    for subj, act, site, ref, red, ir, ar, ai in cache:
        n, s = int(win * FS), int(win * FS / 2)
        Rs = []
        for i in range(0, len(red) - n + 1, s):
            r, ii = ar[i:i + n], ai[i:i + n]
            pi = ii.std() / ir[i:i + n].mean()
            if np.corrcoef(r, ii)[0, 1] < cmin or not (2e-4 <= pi <= 0.1):
                continue
            Rs.append((r.std() / red[i:i + n].mean()) / pi)
        if outlier and len(Rs) >= 4:
            m = np.median(Rs); mad = np.median(np.abs(np.array(Rs) - m)) * 1.4826
            Rs = [v for v in Rs if abs(v - m) <= 3 * max(mad, 1e-6)]
        if len(Rs) >= 3:
            res.append((subj, act, site, ref, float(np.median(Rs))))
    out = {"win": win, "corr_gate": cmin, "outlier": outlier, "n": len(res)}
    for site in "AB":
        for grp, acts in [("rest", ["sit"]), ("motion", ["walk", "run"])]:
            sel = [r for r in res if r[2] == site and r[1] in acts]
            d = np.array([110 - 25 * r[4] - r[3] for r in sel])
            out[f"{site}_{grp}_ARMS"] = round(float(np.sqrt((d ** 2).mean())), 2) if len(d) else None
        sds = []
        for sj in {r[0] for r in res}:
            v = [r[4] for r in res if r[0] == sj and r[2] == site]
            if len(v) >= 2: sds.append(np.std(v))
        out[f"{site}_within_subj_pts"] = round(float(25 * np.median(sds)), 2)
    return out

for win in [5, 10, 20]:
    for cmin in [0.8, 0.9, 0.95]:
        for outlier in [False, True]:
            print(json.dumps(run(win, cmin, outlier)))
