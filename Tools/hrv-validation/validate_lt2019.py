#!/usr/bin/env python3
"""Validate NOOP's Lipponen–Tarvainen (2019) RR artefact correction on PhysioNet Fantasia.

Reproduces the paper's own protocol (J Med Eng Technol 2019;43:173–181, §3): recordings with at most six
non-normal beats; missed beats (detections at k = 100n removed), extra detections (a beat inserted halfway
through the interval after k = 100n) and misaligned beats (moved by ±q·RMSSD, q = 2, 4, 8).

  table1  detection / classification per artefact type and normal-beat specificity (paper Table 1)
  table3  RMSSD error of 5-min samples with and without correction (paper Table 3)
  agree   beat-level agreement with NeuroKit2's signal_fixpeaks(method="Kubios"), same threshold reading

Requires numpy and pandas; `agree` and the NeuroKit2 columns need neurokit2 (0.2.13 was used).
Run ./fetch_fantasia.sh and ./build_cli.sh first.
"""
import argparse, collections, json, os, subprocess, sys
import numpy as np
from wfdb_ann import read_ann, fs_of

HERE = os.path.dirname(os.path.abspath(__file__))
FAN = os.path.join(HERE, 'fantasia')
BEATS = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 25, 30, 34, 35, 37, 38, 41}   # MIT beat codes; 1 = normal
PAPER_T1 = {'missed': (100, 100), 'extra': (99.8, 100), 'misaligned q=2': (53.3, 53.9),
            'misaligned q=4': (98.8, 99.3), 'misaligned q=8': (100, 100)}

def load(rec):
    fs = fs_of(os.path.join(FAN, rec + '.hea'))
    b = [(t, a) for t, a in read_ann(os.path.join(FAN, rec + '.ecg')) if a in BEATS]
    return np.array([t for t, _ in b]) / fs * 1000.0, np.array([a for _, a in b])

def records():
    out = []
    for rec in open(os.path.join(FAN, 'RECORDS')).read().split():
        _, c = load(rec)
        if (c != 1).sum() <= 6:
            out.append(rec)
    return out

def run_cli(cli, series):
    inp = '\n'.join(','.join('%.3f' % v for v in s) for s in series) + '\n'
    out = subprocess.run([cli], input=inp, capture_output=True, text=True, check=True).stdout
    return [json.loads(line) for line in out.strip().split('\n')]

def rmssd(x):
    return float(np.sqrt(np.mean(np.diff(x) ** 2)))

def clean_site(codes, k, r=2):
    return bool(np.all(codes[max(0, k - r):k + r + 1] == 1))

def simulate(t, c, kind, q=None):
    """New beat times and, per artefact, (interval indices it touches, expected class)."""
    ks = [k for k in range(100, len(t) - 3, 100) if clean_site(c, k)]
    sites = []
    if kind == 'missed':
        keep = np.ones(len(t), bool); keep[ks] = False
        pos = np.cumsum(keep) - 1
        return t[keep], [([pos[k - 1]], 'M') for k in ks]
    if kind == 'extra':
        new, add = [], set(ks)
        for i in range(len(t)):
            new.append(t[i])
            if i in add:
                new.append((t[i] + t[i + 1]) / 2)
                sites.append(([len(new) - 2], 'X'))
        return np.array(new), sites
    new = t.copy()
    dt = q * rmssd(np.diff(t))
    for n, k in enumerate(ks):
        new[k] += dt if n % 2 == 0 else -dt
        sites.append(([k - 1, k], 'EL'))
    return new, sites

def nk_module(signed):
    import neurokit2  # noqa: F401
    import pandas as pd
    fp = sys.modules['neurokit2.signal.signal_fixpeaks']
    if signed:
        def thr(signal, alpha, window_width):
            df = pd.DataFrame({'signal': signal})
            q1 = df.rolling(window_width, center=True, min_periods=1).quantile(0.25).signal.values
            q3 = df.rolling(window_width, center=True, min_periods=1).quantile(0.75).signal.values
            return alpha * ((q3 - q1) / 2)
        fp._compute_threshold = thr
    return fp

def nk_labels(fp, times):
    art, _ = fp._find_artifacts(np.round(times).astype(int), sampling_rate=1000)
    lab = ['.'] * (len(times) - 1)
    for key, ch in (('ectopic', 'E'), ('missed', 'M'), ('extra', 'X'), ('longshort', 'L')):
        for i in art[key]:
            if 1 <= i <= len(lab):
                lab[i - 1] = ch
    return ''.join(lab)

def table1(cli, recs):
    tot = fp = 0
    for rec in recs:
        t, c = load(rec)
        lab = run_cli(cli, [np.diff(t)])[0]['labels']
        for j in range(len(t) - 1):
            if clean_site(c, j + 1, 2) and clean_site(c, j, 1):
                tot += 1; fp += lab[j] != '.'
    print('normal beats kept: %.3f%% (%d of %d flagged)   [paper 99.963%%]' % (100 * (1 - fp / tot), fp, tot))
    print('%-16s %5s | class %%  detect %% | paper' % ('artefact', 'n'))
    for kind, q in (('missed', None), ('extra', None), ('misaligned', 2), ('misaligned', 4), ('misaligned', 8)):
        n = det = cls = 0
        for rec in recs:
            t, c = load(rec)
            new, sites = simulate(t, c, kind, q)
            lab = run_cli(cli, [np.diff(new)])[0]['labels']
            for idxs, want in sites:
                got = [lab[i] for i in idxs if 0 <= i < len(lab)]
                n += 1; det += any(g != '.' for g in got)
                cls += any(g in 'EL' for g in got) if want == 'EL' else got[0] == want
        name = kind + (' q=%d' % q if q else '')
        print('%-16s %5d | %7.1f  %8.1f | %5.1f / %5.1f' % ((name, n, 100 * cls / n, 100 * det / n) + PAPER_T1[name]))

def table3(cli, recs):
    segs = []
    for rec in recs:
        t, c = load(rec)
        t0 = t[0]
        while t0 + 300000 <= t[-1] and sum(1 for s in segs if s[0] == rec) < 6:
            m = (t >= t0) & (t < t0 + 300000)
            segs.append((rec, t[m], c[m])); t0 += 300000
    print('%d 5-min samples; RMSSD error vs the original series (mean, mean |.|)' % len(segs))
    for name, kind, q in (('clean', None, None), ('missed', 'missed', None), ('extra', 'extra', None),
                          ('misaligned q=2', 'misaligned', 2), ('misaligned q=4', 'misaligned', 4),
                          ('misaligned q=8', 'misaligned', 8)):
        news = [t if kind is None else simulate(t, c, kind, q)[0] for _, t, c in segs]
        outs = run_cli(cli, [np.diff(n) for n in news])
        raw = [100 * (rmssd(np.diff(n)) - rmssd(np.diff(t))) / rmssd(np.diff(t)) for n, (_, t, _) in zip(news, segs)]
        cor = [100 * (rmssd(np.array(o['nn'])) - rmssd(np.diff(t))) / rmssd(np.diff(t)) for o, (_, t, _) in zip(outs, segs)]
        print('%-16s uncorrected %+8.2f%% | corrected %+6.2f%% (|%.2f|)' % (name, np.mean(raw), np.mean(cor), np.mean(np.abs(cor))))

def agree(cli, recs, signed):
    fp = nk_module(signed)
    tot = same = 0
    for rec in recs:
        t, c = load(rec)
        for kind, q in ((None, None), ('missed', None), ('extra', None), ('misaligned', 4)):
            new = t if kind is None else simulate(t, c, kind, q)[0]
            ours = run_cli(cli, [np.diff(new)])[0]['labels']
            ref = nk_labels(fp, new)
            # NeuroKit2's first interval is synthetic and its last two are never classified; the interval
            # after an extra detection is merged by our correction and deliberately not labelled on its own.
            for j in range(1, len(ours) - 2):
                if ours[j - 1] == 'X':
                    continue
                tot += 1; same += (ours[j] != '.') == (ref[j] != '.')
    print('beat-level agreement with NeuroKit2: %.4f%% of %d intervals' % (100 * same / tot, tot))

if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('what', choices=['table1', 'table3', 'agree'])
    ap.add_argument('--threshold', choices=['signed', 'abs'], default='signed',
                    help='signed = as shipped; abs = QD(|x|), the NeuroKit2 reading')
    a = ap.parse_args()
    cli = os.path.join(HERE, 'build', 'ltcli' if a.threshold == 'signed' else 'ltcli_abs')
    recs = records()
    print('recordings:', ' '.join(recs))
    {'table1': lambda: table1(cli, recs), 'table3': lambda: table3(cli, recs),
     'agree': lambda: agree(cli, recs, a.threshold == 'signed')}[a.what]()
