#!/usr/bin/env python3
"""Summarise the unmapped tail of WHOOP 5.0 v18 history records, night by night.

Reads the app's day logs of full history records (`history-yyyyMMdd.bin`: u16 little-endian length, then the
frame) and/or raw-capture JSON files (`puffin-*.json`, `noop-raw-capture-*.json`), keeps the v18 records
(type 0x2f, layout 18, 124-byte frames), and prints per-hour and per-night medians of the candidate bytes
106-109 next to heart rate, motion and the band sleep state.

Bytes 108 and 109 read about 37-61 only while the wearer is still and read 0x80 (128) while moving; the
working hypothesis is that they carry a red/infrared ratio (R x 100, about 0.4-0.5 at normal saturation).
This script only describes them; it does not turn them into a percentage.

    python3 -I v18_tail.py history-20261027.bin puffin-*.json
    python3 -I v18_tail.py --tz 1 --csv out.csv history-*.bin
"""
import argparse
import csv
import datetime as dt
import json
import statistics as st
import struct
import sys
from collections import defaultdict

INVALID = 0x80


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
            rows[unix] = {
                "unix": unix,
                "hr": b[22],
                "dyn_g": struct.unpack_from("<f", b, 41)[0],
                "sleep": (b[81] >> 4) & 3,
                "b106": b[106], "b107": b[107], "b108": b[108], "b109": b[109],
            }
    return [rows[u] for u in sorted(rows)]


def med(xs):
    return round(st.median(xs), 1) if xs else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--tz", type=float, default=1.0, help="hours to add to UTC for local time (default 1)")
    ap.add_argument("--csv", help="also write every v18 row to this CSV")
    a = ap.parse_args()

    rows = v18_rows(a.files)
    if not rows:
        sys.exit("no v18 records found")
    local = lambda u: dt.datetime.utcfromtimestamp(u) + dt.timedelta(hours=a.tz)
    valid = [r for r in rows if r["b108"] != INVALID and r["b109"] != INVALID]
    print(f"{len(rows)} v18 records, {len(valid)} with 108/109 valid "
          f"({local(rows[0]['unix']):%d %b %H:%M} to {local(rows[-1]['unix']):%d %b %H:%M})")

    by_hour = defaultdict(list)
    for r in valid:
        by_hour[local(r["unix"]).strftime("%m-%d %H")].append(r)
    print("\nhour      n     b108  b109  b106  b107  hr    asleep%")
    for h, rs in sorted(by_hour.items()):
        asleep = 100 * sum(r["sleep"] == 2 for r in rs) / len(rs)
        print(f"{h}  {len(rs):5d}  {med([r['b108'] for r in rs]):5}  {med([r['b109'] for r in rs]):5}  "
              f"{med([r['b106'] for r in rs]):5}  {med([r['b107'] for r in rs]):5}  {med([r['hr'] for r in rs]):5}  {asleep:5.0f}")

    # A night runs from noon to noon, labelled by the morning it ends on.
    by_night = defaultdict(list)
    for r in valid:
        if r["sleep"] == 2:
            by_night[(local(r["unix"]) + dt.timedelta(hours=12)).strftime("%Y-%m-%d")].append(r)
    print("\nnight (morning)  asleep-valid  b108  b109  mean(108,109)")
    for n, rs in sorted(by_night.items()):
        m = [(r["b108"] + r["b109"]) / 2 for r in rs]
        print(f"{n}       {len(rs):7d}  {med([r['b108'] for r in rs]):5}  {med([r['b109'] for r in rs]):5}  {med(m):5}")

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)


if __name__ == "__main__":
    main()
