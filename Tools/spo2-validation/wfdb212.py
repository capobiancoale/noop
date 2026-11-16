"""Minimal WFDB format-212 reader (no wfdb dependency)."""
import re
import numpy as np

def read_header(path):
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f]
    name, nsig, fs, nsamp = lines[0].split()[:4]
    nsig, fs, nsamp = int(nsig), float(fs), int(nsamp)
    sigs = []
    for l in lines[1:1 + nsig]:
        p = l.split()
        m = re.match(r"([-\d.eE]+)\(([-\d]+)\)/?(.*)", p[2])
        gain, base = float(m.group(1)), int(m.group(2))
        sigs.append({"gain": gain, "baseline": base, "name": p[-1]})
    meta = {}
    for l in lines[1 + nsig:]:
        for k, v in re.findall(r"<(\w+)>:\s*([^<]+)", l):
            meta[k] = v.strip()
    return {"fs": fs, "nsamp": nsamp, "sigs": sigs, "meta": meta}

def read_212(dat_path, hdr):
    nsig = len(hdr["sigs"])
    raw = np.fromfile(dat_path, dtype=np.uint8)
    raw = raw[: (len(raw) // 3) * 3].reshape(-1, 3).astype(np.int32)
    s0 = raw[:, 0] | ((raw[:, 1] & 0x0F) << 8)
    s1 = raw[:, 2] | ((raw[:, 1] & 0xF0) << 4)
    flat = np.empty(len(raw) * 2, dtype=np.int32)
    flat[0::2], flat[1::2] = s0, s1
    flat[flat > 2047] -= 4096
    n = len(flat) // nsig
    d = flat[: n * nsig].reshape(n, nsig).astype(np.float64)
    out = {}
    for i, s in enumerate(hdr["sigs"]):
        out[s["name"]] = (d[:, i] - s["baseline"]) / s["gain"]
    return out
