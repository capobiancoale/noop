"""Quality-gated 128-beat segments with the three Dash et al. (2009) features, from PhysioNet annotations.

This is the Python twin of Packages/StrandAnalytics/Sources/StrandAnalytics/IrregularRhythm.swift: the same gates
and the same four features, so the thresholds swept by validate.py are the ones the app uses. Beats are given the way
the strap delivers them: an integer-millisecond R-R and a timestamp truncated to whole seconds (several beats can
share one second).
"""
import math
import os
import pickle
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wfdb_annotations as wfdb  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

SEG = 128                      # beats per segment
RR_MIN, RR_MAX = 300, 2000     # ms, physiologic
MAX_GAP_S = 5                  # a hole between consecutive timestamps ends a stretch
COV_MIN, COV_MAX = 0.90, 1.10  # sum(R-R) / wall-clock span of the segment
TRIM = 8                       # longest and shortest R-R removed from each end
BINS = 16                      # entropy histogram

# (database, annotation extension, beat-annotation extension or None)
DATABASES = {
    "afdb": ("atr", "qrs"),
    "nsrdb": ("atr", None),
    "mitdb": ("atr", None),
    "fantasia": ("ecg", None),
}


def strap_samples(beat_samples, fs, t0=1_700_000_000):
    """[(ts, rrMs, beat_index)] for beats 1..n: integer-ms R-R, timestamp in whole seconds."""
    out = []
    prev = None
    for i, s in enumerate(beat_samples):
        sec = s / fs
        if prev is not None:
            out.append((t0 + int(math.floor(sec)), int(round((sec - prev) * 1000.0)), i))
        prev = sec
    return out


def features(rr):
    """(RMSSD / mean R-R, normalised Shannon entropy, turning-point z, turning-point ratio) of one segment."""
    n = len(rr)
    turning = sum(1 for i in range(1, n - 1) if (rr[i] - rr[i - 1]) * (rr[i + 1] - rr[i]) < 0)
    z = (turning - 2.0 * (n - 2) / 3.0) / math.sqrt((16.0 * n - 29.0) / 90.0)
    # Trim the 8 longest and 8 shortest (ties by position), keep the order of the rest.
    order = sorted(range(n), key=lambda i: (rr[i], i))
    drop = set(order[:TRIM]) | set(order[-TRIM:])
    kept = [rr[i] for i in range(n) if i not in drop]
    m = len(kept)
    mean = sum(kept) / m
    rmssd = math.sqrt(sum((kept[i] - kept[i - 1]) ** 2 for i in range(1, m)) / (m - 1))
    lo, hi = min(kept), max(kept)
    entropy = 0.0
    if hi > lo:
        counts = [0] * BINS
        width = (hi - lo) / BINS
        for v in kept:
            counts[min(int((v - lo) / width), BINS - 1)] += 1
        entropy = -sum(c / m * math.log(c / m) for c in counts if c) / math.log(BINS)
    return rmssd / mean, entropy, z, turning / (n - 2)


def max_acf(rr, lags=range(2, 11)):
    """Largest |autocorrelation| of the mean-removed intervals at lags 2..10 (biased estimator, whole-segment variance)."""
    n = len(rr)
    mean = sum(rr) / n
    x = [v - mean for v in rr]
    var = sum(v * v for v in x)
    if var <= 0:
        return 0.0
    return max(abs(sum(x[i] * x[i + k] for i in range(n - k)) / var) for k in lags)


def segments(samples):
    """Non-overlapping 128-beat blocks of the stretches of physiologic, gap-free beats; coverage-gated."""
    n = len(samples)
    out = []
    i = 0
    while i < n:
        if not RR_MIN <= samples[i][1] <= RR_MAX:
            i += 1
            continue
        j = i + 1
        while j < n and RR_MIN <= samples[j][1] <= RR_MAX and samples[j][0] - samples[j - 1][0] <= MAX_GAP_S:
            j += 1
        k = i
        while k + SEG <= j:
            block = samples[k:k + SEG]
            span = block[-1][0] - block[0][0]
            rrs = [b[1] for b in block]
            coverage = sum(rrs[1:]) / 1000.0 / span if span > 0 else 0.0
            ok = COV_MIN <= coverage <= COV_MAX
            seg = {"start": block[0][0], "end": block[-1][0], "dur": sum(rrs) / 1000.0, "ok": ok,
                   "i0": block[0][2], "i1": block[-1][2]}
            if ok:
                seg["nrm"], seg["she"], seg["z"], seg["tpr"] = features(rrs)
                seg["acf"] = max_acf(rrs)
            out.append(seg)
            k += SEG
        i = j
    return out


def label(seg, beat_rhythm):
    """Majority rhythm over the segment's beats, and that majority's share."""
    c = Counter(beat_rhythm[seg["i0"]:seg["i1"] + 1])
    name, count = c.most_common(1)[0]
    return name, count / sum(c.values())


def build(db, force=False):
    """{record: {"segs": [...], ...}} for one database (cached in data/segs_<db>.pkl)."""
    cache = os.path.join(DATA, f"segs_{db}.pkl")
    if os.path.exists(cache) and not force:
        with open(cache, "rb") as f:
            return pickle.load(f)
    ann_ext, beat_ext = DATABASES[db]
    d = os.path.join(DATA, db)
    out = {}
    for rec in sorted({f.split(".")[0] for f in os.listdir(d) if f.endswith(".hea")}):
        beat_path = os.path.join(d, f"{rec}.{beat_ext}") if beat_ext else None
        fs, _, beats, rhythm = wfdb.beats_and_rhythms(os.path.join(d, f"{rec}.{ann_ext}"),
                                                      os.path.join(d, f"{rec}.hea"), beat_path)
        segs = segments(strap_samples(beats, fs))
        beat_rhythm = []
        r, current = 0, ""
        for s in beats:
            while r < len(rhythm) and rhythm[r][0] <= s:
                current = rhythm[r][1]
                r += 1
            beat_rhythm.append(current)
        for seg in segs:
            seg["rhythm"], seg["purity"] = label(seg, beat_rhythm)
        out[rec] = {"n_beats": len(beats), "segs": segs}
    with open(cache, "wb") as f:
        pickle.dump(out, f)
    return out
