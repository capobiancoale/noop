"""Minimal WFDB annotation (.atr / .qrs / .ecg) and header (.hea) reader. Pure Python, no dependencies.

Format (WFDB Applications Guide, "annotation file format"): a stream of little-endian 16-bit words.
Top 6 bits = annotation type code, low 10 bits = time delta in samples since the previous annotation.
Special codes: SKIP (59) is followed by a 32-bit delta (high word first), NUM (60) / SUB (61) / CHN (62)
are modifiers, AUX (63) carries an auxiliary string of `delta` bytes (padded to an even length) that belongs to
the previous annotation. A zero word ends the file.
"""
import struct

SKIP, NUM, SUB, CHN, AUX = 59, 60, 61, 62, 63
RHYTHM = 28
# WFDB isqrs(): the annotation codes that mark a QRS complex.
BEAT_CODES = set(range(1, 14)) | {34, 35, 37, 38, 41}


def read_annotations(path):
    """Return a list of (sample, code, aux_string_or_None)."""
    with open(path, "rb") as f:
        data = f.read()
    out = []
    pos = 0
    t = 0
    n = len(data)
    while pos + 2 <= n:
        (w,) = struct.unpack_from("<H", data, pos)
        pos += 2
        if w == 0:
            break
        code = w >> 10
        delta = w & 0x3FF
        if code == SKIP:
            hi, lo = struct.unpack_from("<HH", data, pos)
            pos += 4
            skip = (hi << 16) | lo
            if skip & 0x80000000:
                skip -= 1 << 32
            t += skip
            continue
        if code in (NUM, SUB, CHN):
            continue
        if code == AUX:
            raw = data[pos:pos + delta]
            pos += delta + (delta & 1)
            if out:
                sample, c, _ = out[-1]
                out[-1] = (sample, c, raw.decode("latin-1").rstrip("\x00"))
            continue
        t += delta
        out.append((t, code, None))
    return out


def read_header(path):
    """Return (sampling_frequency_hz, n_samples) from the first line of a .hea file."""
    with open(path, "r", errors="replace") as f:
        first = f.readline().split()
    # record_name n_signals [fs[/counter_freq[(base)]] [n_samples ...
    fs = float(first[2].split("/")[0])
    nsamp = int(first[3]) if len(first) > 3 else 0
    return fs, nsamp


def beats_and_rhythms(ann_path, hea_path, beat_path=None):
    """Beats (sample indices) and rhythm changes [(sample, label)] of one record.

    `beat_path` (the AF database's .qrs) overrides where the beat annotations come from; the rhythm changes always
    come from `ann_path`.
    """
    fs, nsamp = read_header(hea_path)
    ann = read_annotations(ann_path)
    rhythm = [(s, (a or "").strip()) for s, c, a in ann if c == RHYTHM]
    source = read_annotations(beat_path) if beat_path else ann
    beats = [s for s, c, a in source if c in BEAT_CODES]
    return fs, nsamp, beats, rhythm
