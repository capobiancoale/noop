"""Which WHOOP 5.0 optical channel is red and which is infrared? A physics check on a NOOP raw capture.

The strap's bulk history records (type 47, layouts v20 and v21) carry several optical waveforms whose LEDs are
not labelled. SpO2 needs the red (about 660 nm) and infrared (about 880-940 nm) pair. At normal saturation
oxyhaemoglobin barely absorbs red light, so the red channel pulses LESS, relative to its own level, than the
infrared one: R = (AC/DC red) / (AC/DC infrared) sits around 0.4-0.7. Green pulses the most. This script finds
the channels that carry a heartbeat, measures each one's perfusion (AC/DC), correlates every pair and lists the
pairs that behave like red + infrared. It is the same check that caught the swapped red/IR labels in the
PhysioNet set (see README.md).

Input: a capture exported from NOOP (Settings > raw capture > "Export frames..."), a JSON array of objects with
a "hex" key. With the capture toggle on, NOOP keeps up to 1,200 v20/v21 history records per capture file.

Usage: python3 -I identify_channels.py <capture.json> [--fs <samples per second>]
"""
import argparse, sys, json
import numpy as np
from scipy.signal import butter, sosfiltfilt

V20_BLOCKS = [(0x1a, 0x2f, 0xf7), (0x1c0, 0x1d5, 0x29d), (0x366, 0x37b, 0x443),
              (0x50c, 0x521, 0x5e9), (0x6b2, 0x6c7, 0x78f)]


def u32(b, o):
    return int.from_bytes(b[o:o + 4], "little")


def decode(frame):
    """(record_index, unix, version, {channel name: samples}) for a v20/v21 record, else None.
    Offsets mirror decodeWhoop5HistoricalV2021 in Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift."""
    if len(frame) < 30 or frame[0] != 0xAA or frame[8] != 0x2F or frame[9] not in (20, 21):
        return None
    v = frame[9]
    ch = {}
    if v == 21:
        for i, start in enumerate((28, 228, 428)):
            if len(frame) >= start + 200:
                ch[f"v21_ch{i}"] = np.frombuffer(bytes(frame[start:start + 200]), dtype="<i2").astype(float)
    else:
        for b, (present, c0, c1) in enumerate(V20_BLOCKS):
            if len(frame) <= present or frame[present] == 0:
                continue
            for half, start in enumerate((c0, c1)):
                if len(frame) >= start + 200:
                    ch[f"v20_b{b}_{half}"] = np.frombuffer(bytes(frame[start:start + 200]), dtype="<i4").astype(float)
    return u32(frame, 11), u32(frame, 15), v, ch


def runs(records):
    """Split records into runs of consecutive record indices with the same version and channel set."""
    out, cur = [], []
    for r in records:
        if cur and (r[0] != cur[-1][0] + 1 or r[2] != cur[-1][2] or r[3].keys() != cur[-1][3].keys()):
            out.append(cur); cur = []
        cur.append(r)
    if cur:
        out.append(cur)
    return out


def analyse(run, fs_override=None):
    n_per = len(next(iter(run[0][3].values())))
    span = run[-1][1] - run[0][1]
    fs = fs_override or (n_per * (len(run) - 1) / span if span > 0 else None)
    head = {"version": run[0][2], "records": len(run), "samples_per_record": n_per,
            "seconds_by_unix": span, "sample_rate_hz": round(fs, 2) if fs else None}
    if not fs or fs < 4 or len(run) * n_per < 30 * fs:
        head["verdict"] = "too short or no usable timing (need >= 30 s of consecutive records; try --fs)"
        return head
    sos = butter(2, [0.5, min(5.0, 0.45 * fs)], btype="band", fs=fs, output="sos")
    sig = {k: np.concatenate([r[3][k] for r in run]) for k in run[0][3]}
    ac = {k: sosfiltfilt(sos, v - v.mean()) for k, v in sig.items()}
    chans = {}
    for k, v in sig.items():
        a = ac[k]
        spec = np.abs(np.fft.rfft(a * np.hanning(len(a)))) ** 2
        f = np.fft.rfftfreq(len(a), 1 / fs)
        band = (f >= 0.6) & (f <= 3.5)
        peak = f[band][np.argmax(spec[band])] if band.any() and spec[band].sum() > 0 else 0.0
        near = band & (np.abs(f - peak) <= 0.15)
        pulse_share = float(spec[near].sum() / spec[band].sum()) if spec[band].sum() > 0 else 0.0
        dc = float(v.mean())
        chans[k] = {"dc": round(dc, 1), "ac_rms": round(float(a.std()), 2),
                    "perfusion": round(float(a.std() / dc), 5) if dc > 0 else None,
                    "pulse_hz": round(float(peak), 2), "pulse_share": round(pulse_share, 2)}
    head["channels"] = chans
    pulsing = [k for k, c in chans.items() if c["pulse_share"] >= 0.3 and c["ac_rms"] > 0]
    pairs = []
    for i, a in enumerate(pulsing):
        for b in pulsing[i + 1:]:
            pa, pb = chans[a]["perfusion"], chans[b]["perfusion"]
            corr = float(np.corrcoef(ac[a], ac[b])[0, 1])
            if pa is None or pb is None:
                pairs.append({"pair": [a, b], "corr": round(corr, 3), "note": "a DC <= 0: offset-subtracted, AC/DC unusable"})
                continue
            red, ir = (a, b) if pa < pb else (b, a)
            r = min(pa, pb) / max(pa, pb)
            pairs.append({"red?": red, "ir?": ir, "corr": round(corr, 3), "R": round(r, 3),
                          "plausible_red_ir": bool(corr >= 0.9 and 0.3 <= r <= 1.0)})
    head["pairs"] = pairs
    good = [p for p in pairs if p.get("plausible_red_ir")]
    head["verdict"] = (f"{len(good)} pair(s) behave like red + infrared" if good else
                       "no pair behaves like red + infrared (or the strap subtracts the DC level)")
    return head


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--fs", type=float, default=None, help="samples per second, when the record clock is unusable")
    opt = ap.parse_args()
    fs = opt.fs
    recs = {}
    for item in json.load(open(opt.capture)):
        d = decode(list(bytes.fromhex(item.get("hex", ""))))
        if d:
            recs[d[0]] = d
    if not recs:
        sys.exit("no v20/v21 optical history records in this capture (turn the raw capture on before a sync)")
    for run in runs([recs[k] for k in sorted(recs)]):
        print(json.dumps(analyse(run, fs), indent=1))


if __name__ == "__main__":
    main()
