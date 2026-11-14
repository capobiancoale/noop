#!/usr/bin/env python3
"""Night-by-night view of WHOOP 5.0 v18 history records: the strap's own SpO2 (byte 82) and the tail bytes.

Reads the app's day logs of full history records (`history-yyyyMMdd.bin`: u16 little-endian length, then the
frame) and/or raw-capture JSON files (`puffin-*.json`, `noop-raw-capture-*.json`) and keeps the v18 records
(type 0x2f, layout 18, 124-byte frames).

BYTE 82 IS THE STRAP'S OWN SpO2. It is 0 nearly always. While the band scores the wearer asleep (sleep state 2)
the strap takes a 30 s reading about every 20 minutes, and during it the byte holds either a percentage
(70...100) or a status code (1, 2, 8, 16, 32, 128, 160 and sums; bit-7 values are sentinels). The script
applies the recipe NOOP uses (Packages/StrandAnalytics/.../StrapSpo2.swift):

  1. group the seconds into windows: a new window starts when a second is more than 30 s after the previous
     one, or 60 s or more after the window's first second;
  2. a window counts only with at least 5 in-range (70...100) seconds;
  3. the window's value is the median of its in-range seconds (the LOWER middle for an even count);
  4. the night's value is the mean of the window medians, rounded to one decimal;
  5. a night needs at least 8 usable windows, otherwise there is no value.

It prints one line per night (noon to noon, labelled by the morning it ends on) and the list of windows behind
it: local time, seconds, in-range count, median and the status codes seen. This is the strap's own computation,
not a medical measurement; compare it with the WHOOP app's nightly SpO2 for the same nights.

BYTES 106-109 ARE NOT SpO2. Bytes 108 and 109 read about 37-61 only while the wearer is still and 0x80 (128)
while moving, and they follow heart rate and motion; an earlier note guessed they were a red/infrared ratio and
that guess was wrong. The per-hour and per-night summary of them is kept below the SpO2 part for anyone checking.

    python3 -I v18_tail.py history-20261027.bin puffin-*.json
    python3 -I v18_tail.py --tz 1 --csv out.csv history-*.bin
"""
import argparse
import csv
import datetime as dt
import json
import math
import statistics as st
import struct
import sys
from collections import defaultdict

INVALID = 0x80

# The SpO2 recipe (kept in step with StrapSpo2.swift).
VALID_PCT = range(70, 101)   # 70...100 inclusive
MAX_GAP_SEC = 30             # a new window starts when a second is MORE than this after the previous one
MAX_SPAN_SEC = 60            # ... or this many seconds or more after the window's first second
MIN_SECONDS = 5              # in-range seconds a window needs
MIN_WINDOWS = 8              # usable windows a night needs


def frames_from(path):
    if path.endswith(".bin"):
        data = open(path, "rb").read()
        i = 0
        while i + 2 <= len(data):
            n = data[i] | (data[i + 1] << 8)
            if i + 2 + n > len(data):
                break
            yield data[i + 2:i + 2 + n]
            i += 2 + n
    else:
        for rec in json.load(open(path)):
            yield bytes.fromhex(rec["hex"])


def v18_rows(paths):
    rows = {}
    for p in paths:
        for b in frames_from(p):
            if len(b) != 124 or b[8] != 0x2F or b[9] != 18:
                continue
            unix = struct.unpack_from("<I", b, 15)[0]
            if unix in rows:      # a repeated second keeps its first record, like the app
                continue
            rows[unix] = {
                "unix": unix,
                "hr": b[22],
                "dyn_g": struct.unpack_from("<f", b, 41)[0],
                "sleep": (b[81] >> 4) & 3,
                "b82": b[82],
                "b106": b[106], "b107": b[107], "b108": b[108], "b109": b[109],
            }
    return [rows[u] for u in sorted(rows)]


def med(xs):
    return round(st.median(xs), 1) if xs else None


def group(samples):
    """Split ascending (ts, raw) pairs into windows by the gap/span rule."""
    out = []
    for ts, raw in samples:
        if out and ts - out[-1][-1][0] <= MAX_GAP_SEC and ts - out[-1][0][0] < MAX_SPAN_SEC:
            out[-1].append((ts, raw))
        else:
            out.append([(ts, raw)])
    return out


def lower_median(values):
    v = sorted(values)
    return v[(len(v) - 1) // 2]


def spo2_night(samples):
    """The recipe over one night's nonzero byte-82 seconds, as (ascending unique) (ts, raw) pairs.

    Returns the usable windows, the windows of ANY nonzero seconds (the strap's attempts, status codes
    included), the in-range second count and the nightly value (None under MIN_WINDOWS usable windows)."""
    in_range = [(t, r) for t, r in samples if r in VALID_PCT]
    usable = []
    for g in group(in_range):
        if len(g) >= MIN_SECONDS:
            usable.append({"start": g[0][0], "end": g[-1][0], "seconds": len(g),
                           "median": lower_median([r for _, r in g])})
    pct = None
    if len(usable) >= MIN_WINDOWS:
        mean = sum(w["median"] for w in usable) / len(usable)
        pct = math.floor(mean * 10 + 0.5) / 10     # half away from zero, like the app
    return {"usable": usable, "attempts": group(samples), "readings": len(in_range), "pct": pct}


def night_label(unix, local):
    """A night runs from noon to noon, labelled by the morning it ends on."""
    return (local(unix) + dt.timedelta(hours=12)).strftime("%Y-%m-%d")


def report_byte82(rows, local):
    by_night = defaultdict(list)
    for r in rows:
        if r["b82"] != 0:
            by_night[night_label(r["unix"], local)].append((r["unix"], r["b82"]))
    if not by_night:
        print("no nonzero byte 82 in these records (a strap that is not scoring sleep, or no 5.0 v18 data)\n")
        return
    results = {n: spo2_night(s) for n, s in sorted(by_night.items())}

    print("strap SpO2 (byte 82), night by night")
    print("night (morning)  windows(usable/attempted)  readings  nightly")
    for n, res in results.items():
        value = f"{res['pct']:.1f} %" if res["pct"] is not None else f"none (needs {MIN_WINDOWS} windows)"
        counts = f"{len(res['usable'])}/{len(res['attempts'])}"
        print(f"{n}       {counts:<25}  {res['readings']:8d}  {value}")

    print("\nwindows (local time): every attempt, with the codes the strap gave")
    print("night       start     seconds  in-range  median  used  status codes seen")
    for n, res in results.items():
        used_starts = {w["start"] for w in res["usable"]}
        for g in res["attempts"]:
            vals = [raw for _, raw in g]
            in_range = [v for v in vals if v in VALID_PCT]
            codes = sorted({v for v in vals if v not in VALID_PCT})
            used = any(g[0][0] <= s <= g[-1][0] for s in used_starts)
            median = lower_median(in_range) if len(in_range) >= MIN_SECONDS else None
            shown = f"{median:6d}" if median is not None else f"{'-':>6}"
            print(f"{n}  {local(g[0][0]):%H:%M:%S}  {len(g):7d}  {len(in_range):8d}  {shown}  "
                  f"{'yes' if used else 'no':>4}  {','.join(str(c) for c in codes) or '-'}")
    print()


def report_tail(rows, local):
    valid = [r for r in rows if r["b108"] != INVALID and r["b109"] != INVALID]
    print(f"bytes 106-109 (NOT SpO2: they follow heart rate and motion): {len(valid)} of {len(rows)} v18 records "
          f"have 108/109 valid")
    if not valid:
        return
    by_hour = defaultdict(list)
    for r in valid:
        by_hour[local(r["unix"]).strftime("%m-%d %H")].append(r)
    print("\nhour      n     b108  b109  b106  b107  hr    asleep%")
    for h, rs in sorted(by_hour.items()):
        asleep = 100 * sum(r["sleep"] == 2 for r in rs) / len(rs)
        print(f"{h}  {len(rs):5d}  {med([r['b108'] for r in rs]):5}  {med([r['b109'] for r in rs]):5}  "
              f"{med([r['b106'] for r in rs]):5}  {med([r['b107'] for r in rs]):5}  {med([r['hr'] for r in rs]):5}  {asleep:5.0f}")

    by_night = defaultdict(list)
    for r in valid:
        if r["sleep"] == 2:
            by_night[night_label(r["unix"], local)].append(r)
    print("\nnight (morning)  asleep-valid  b108  b109  mean(108,109)")
    for n, rs in sorted(by_night.items()):
        m = [(r["b108"] + r["b109"]) / 2 for r in rs]
        print(f"{n}       {len(rs):7d}  {med([r['b108'] for r in rs]):5}  {med([r['b109'] for r in rs]):5}  {med(m):5}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--tz", type=float, default=1.0, help="hours to add to UTC for local time (default 1)")
    ap.add_argument("--csv", help="also write every v18 row to this CSV")
    a = ap.parse_args()

    rows = v18_rows(a.files)
    if not rows:
        sys.exit("no v18 records found")
    utc = dt.timezone.utc
    local = lambda u: dt.datetime.fromtimestamp(u, utc) + dt.timedelta(hours=a.tz)
    print(f"{len(rows)} v18 records ({local(rows[0]['unix']):%d %b %H:%M} to {local(rows[-1]['unix']):%d %b %H:%M})\n")

    report_byte82(rows, local)
    report_tail(rows, local)

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)


if __name__ == "__main__":
    main()
