"""Minimal reader for PhysioNet WFDB MIT-format annotation files (no wfdb dependency)."""
import struct, collections

def read_ann(path):
    data = open(path, 'rb').read()
    words = struct.unpack('<%dH' % (len(data) // 2), data[:len(data) // 2 * 2])
    t, i, out = 0, 0, []
    while i < len(words):
        w = words[i]; a, iv = w >> 10, w & 0x3FF; i += 1
        if a == 0 and iv == 0:
            break
        if a == 59:                      # SKIP: 32-bit interval, PDP-11 order (high word first)
            hi, lo = words[i], words[i + 1]; i += 2
            val = (hi << 16) | lo
            if val & 0x80000000: val -= 1 << 32
            t += val
            continue
        if a in (60, 61, 62):            # NUM / SUB / CHN modifiers
            continue
        if a == 63:                      # AUX string, iv bytes, padded to even
            i += (iv + 1) // 2
            continue
        t += iv
        out.append((t, a))
    return out

def fs_of(hea_path):
    return float(open(hea_path).readline().split()[2])

if __name__ == '__main__':
    import sys, glob, os
    d = sys.argv[1]
    for rec in sorted(open(os.path.join(d, 'RECORDS')).read().split()):
        ann = read_ann(os.path.join(d, rec + '.ecg'))
        fs = fs_of(os.path.join(d, rec + '.hea'))
        c = collections.Counter(a for _, a in ann)
        nonN = sum(v for k, v in c.items() if k != 1)
        print(rec, fs, len(ann), dict(c), 'nonN=', nonN)
