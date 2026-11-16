"""Convert PhysioNet sleep-accel (Walch 2019) into NOOP-shaped streams.

Usage: python3 prep.py data prep
Per subject writes prep/<id>.txt with lines:
  W <start_ts> <end_ts>            labeled window (unix s, base 1_700_000_000 + PSG time)
  L <ts> <stage>                   PSG label every 30 s (0 wake, 1 N1, 2 N2, 3 N3, 4 N4, 5 REM, -1 unscored)
  H <ts> <bpm>                     heart rate samples within [start-3600, end]
  G <ts> <x> <y> <z>               1 Hz mean acceleration (g) within [start-3600, end]
"""
import sys, os, math, collections
data, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
BASE = 1_700_000_000
ids = sorted(f.split('_')[0] for f in os.listdir(os.path.join(data, 'labels')))
for sid in ids:
    labels = []
    with open(os.path.join(data, 'labels', f'{sid}_labeled_sleep.txt')) as f:
        for line in f:
            p = line.split()
            if len(p) >= 2: labels.append((float(p[0]), int(p[1])))
    t0, t1 = labels[0][0], labels[-1][0] + 30
    lo = t0 - 3600
    hr = []
    with open(os.path.join(data, 'heart_rate', f'{sid}_heartrate.txt')) as f:
        for line in f:
            p = line.strip().split(',')
            if len(p) != 2: continue
            t = float(p[0])
            if lo <= t <= t1: hr.append((int(math.floor(t)) + BASE, int(round(float(p[1])))))
    sec = collections.OrderedDict()
    with open(os.path.join(data, 'motion', f'{sid}_acceleration.txt')) as f:
        for line in f:
            p = line.split()
            if len(p) != 4: continue
            t = float(p[0])
            if t < lo or t > t1: continue
            k = int(math.floor(t))
            s = sec.get(k)
            if s is None: sec[k] = [float(p[1]), float(p[2]), float(p[3]), 1]
            else: s[0] += float(p[1]); s[1] += float(p[2]); s[2] += float(p[3]); s[3] += 1
    with open(os.path.join(out, f'{sid}.txt'), 'w') as o:
        o.write(f'W {int(t0)+BASE} {int(t1)+BASE}\n')
        for t, s in labels: o.write(f'L {int(t)+BASE} {s}\n')
        for t, b in sorted(hr): o.write(f'H {t} {b}\n')
        for k, s in sorted(sec.items()):
            n = s[3]; o.write(f'G {k+BASE} {s[0]/n:.5f} {s[1]/n:.5f} {s[2]/n:.5f}\n')
    hr_in = [h for h in hr if h[0]-BASE >= t0]
    gap = (t1 - t0) / max(1, len(hr_in))
    print(sid, f'hours={(t1-t0)/3600:.1f}', f'hr_n={len(hr_in)}', f'hr_every={gap:.1f}s', f'grav_s={len(sec)}',
          'stages=' + ','.join(f'{k}:{v}' for k, v in sorted(collections.Counter(s for _, s in labels).items())))
