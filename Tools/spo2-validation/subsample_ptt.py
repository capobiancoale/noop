"""Does ratio-of-ratios survive a wearable's sampling? Compare R from the 500 Hz signal with R from the same
60 s window resampled to 25 Hz, to 1 Hz point samples, and to 1 Hz one-second means (what a strap that banks
one red/IR value per second might store). Usage: python3 -I subsample_ptt.py <data dir>"""
import sys, os, glob, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from scipy.signal import butter, sosfiltfilt, decimate
import wfdb212 as w

D = sys.argv[1]
FS = 500
WIN = 60
SITES = {"A": ("pleth_1", "pleth_2"), "B": ("pleth_4", "pleth_5")}  # (red, ir), see eval_ptt.py

def r_bandpass(red, ir, fs, lo=0.5, hi=5.0):
    hi = min(hi, 0.45 * fs)
    sos = butter(2, [lo, hi], btype="band", fs=fs, output="sos")
    ar, ai = sosfiltfilt(sos, red), sosfiltfilt(sos, ir)
    return (ar.std() / red.mean()) / (ai.std() / ir.mean()), np.corrcoef(ar, ai)[0, 1]

def r_1hz(red, ir, k=5):
    # 1 Hz: the pulse aliases anywhere in 0-0.5 Hz, so no band-pass can isolate it. Remove the slow baseline
    # with a centred moving median (k s) and take the ratio of the residual spreads.
    def resid(v):
        pad = np.pad(v, k // 2, mode="edge")
        med = np.array([np.median(pad[i:i + k]) for i in range(len(v))])
        return v - med
    rr, ri = resid(red), resid(ir)
    return (rr.std() / red.mean()) / (ri.std() / ir.mean()), np.corrcoef(rr, ri)[0, 1]

out = {k: [] for k in ["25Hz", "1Hz_point", "1Hz_mean"]}
for hp in sorted(glob.glob(os.path.join(D, "*.hea"))):
    h = w.read_header(hp); x = w.read_212(hp[:-4] + ".dat", h)
    for site, (rk, ik) in SITES.items():
        red, ir = x[rk], x[ik]
        n = WIN * FS
        for i in range(0, len(red) - n + 1, n):
            r, ii = red[i:i + n], ir[i:i + n]
            R0, c0 = r_bandpass(r, ii, FS)
            if c0 < 0.9:
                continue
            # Decimate the zero-mean signal (a DC of ~70k counts would otherwise ring at the edges), then restore it.
            r25 = decimate(r - r.mean(), 20, ftype="fir") + r.mean()
            i25 = decimate(ii - ii.mean(), 20, ftype="fir") + ii.mean()
            out["25Hz"].append((R0, *r_bandpass(r25, i25, 25)))
            out["1Hz_point"].append((R0, *r_1hz(r[::FS], ii[::FS])))
            out["1Hz_mean"].append((R0, *r_1hz(r.reshape(-1, FS).mean(1), ii.reshape(-1, FS).mean(1))))

for k, v in out.items():
    a = np.array(v)
    R0, R1, c = a[:, 0], a[:, 1], a[:, 2]
    pts = 25 * np.abs(R1 - R0)   # SpO2 points on the 110-25R line
    print(json.dumps({"rate": k, "windows": len(a), "r_vs_500Hz": round(float(np.corrcoef(R0, R1)[0, 1]), 2),
                      "median_abs_err_points": round(float(np.median(pts)), 2),
                      "p90_abs_err_points": round(float(np.percentile(pts, 90)), 2),
                      "median_bias_R": round(float(np.median(R1 - R0)), 3),
                      "median_red_ir_corr": round(float(np.median(c)), 2)}))
