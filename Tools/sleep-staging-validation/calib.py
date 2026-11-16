"""Score each staging configuration against polysomnography and pick the V2 calibration.

Usage: python3 calib.py results.jsonl   (rows written by SleepAccelHarness: config, subject, 4x4 confusion
matrix PSG rows x NOOP columns, classes wake/light/deep/rem). Prints pooled Cohen's kappa, accuracy, the deep
and REM shares of sleep against PSG and per-class recall; then, for three objectives (kappa minus lambda x the
deep/REM share errors), the in-sample best settings and a leave-one-subject-out result: the setting is chosen on
30 nights and scored on the 31st, for every subject, and only those held-out scores are pooled.
"""
import json, sys, collections, statistics
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = collections.defaultdict(dict)
for r in rows: by[r['config']][r['id']] = r['cm']
ids = sorted(next(iter(by.values())).keys())
def add(a, b): return [x+y for x, y in zip(a, b)]
def pool(cfg, subset):
    t = [0]*16
    for i in subset: t = add(t, by[cfg][i])
    return t
def kappa(cm):
    n = sum(cm); po = sum(cm[i*4+i] for i in range(4)) / n
    pe = sum(sum(cm[i*4+j] for j in range(4)) * sum(cm[j*4+i] for j in range(4)) for i in range(4)) / n / n
    return (po - pe) / (1 - pe)
def shares(cm):
    ts = sum(cm[i*4+j] for i in range(1,4) for j in range(4)); ps = sum(cm[i*4+j] for i in range(4) for j in range(1,4))
    return (sum(cm[8+j] for j in range(4))/ts, sum(cm[i*4+2] for i in range(4))/ps,
            sum(cm[12+j] for j in range(4))/ts, sum(cm[i*4+3] for i in range(4))/ps)
def obj(cm, lam):
    td, pd, tr, pr = shares(cm)
    return kappa(cm) - lam * (abs(pd-td) + abs(pr-tr))
def line(name, cm):
    td, pd, tr, pr = shares(cm); n = sum(cm)
    acc = sum(cm[i*4+i] for i in range(4))/n
    rec = [cm[c*4+c]/max(1,sum(cm[c*4+j] for j in range(4))) for c in range(4)]
    return (f"{name:<44} k={kappa(cm):.3f} acc={acc:.3f} deep {pd*100:4.1f}% (psg {td*100:4.1f}) "
            f"rem {pr*100:4.1f}% (psg {tr*100:4.1f}) recall w/l/d/r={'/'.join(f'{x:.2f}' for x in rec)}")
cfgs = [c for c in by if c.startswith('V2 ')]
for name in ['V1-shipped', 'V2-shipped', 'V2 thr=0.2 slope=5 deep=0.18 rem=0.22']:
    print(line(name, pool(name, ids)))
for lam in [0.0, 0.5, 1.0]:
    print(f'--- in-sample top by objective lambda={lam}')
    for c in sorted(cfgs, key=lambda c: -obj(pool(c, ids), lam))[:5]: print(line(c, pool(c, ids)))
    # leave-one-subject-out: pick on 30, score the held-out one
    held = [0]*16; picks = collections.Counter(); per_k = []
    for out in ids:
        train = [i for i in ids if i != out]
        best = max(cfgs, key=lambda c: obj(pool(c, train), lam))
        picks[best] += 1; held = add(held, by[best][out])
        if sum(by[best][out]): per_k.append(kappa(by[best][out]))
    print(line(f'LOSO lambda={lam}', held), f'| per-subject k median {statistics.median(per_k):.3f}')
    print('   picks:', picks.most_common(3))
