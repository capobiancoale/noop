"""A synthetic very fit sleeper: strong respiratory sinus arrhythmia (RSA), for false-alarm checks.

No recording of a fit sleeper's night was available, so this is a MODEL, not data. The intervals are

    R-R = mean + A(t) sin(phase(t)) + 0.15 A0 sin(2 pi 0.05 t + 1) + noise

where the breathing rate (the phase's frequency) and the amplitude A(t) wander as Ornstein-Uhlenbeck processes
(rate +-0.04 Hz and amplitude +-25 % over about 20 s), the way a real sleeper's breathing does. `fit_sleeper()`
draws heart rate 43-60 bpm (mean R-R 1000-1400 ms), amplitude 60-120 ms (RMSSD about 65-150 ms), breathing
0.18-0.32 Hz (11-19 a minute) and 5-20 ms of timing noise.
"""
import math
import random


def beats(n, mean, rsa, jitter, rng, f0=0.25, fsd=0.04, asd=0.25, tau=20.0):
    """n R-R intervals (ms) of one stretch of respiratory sinus arrhythmia."""
    t = 0.0
    phase = rng.uniform(0, 2 * math.pi)
    f_dev = a_dev = 0.0
    out = []
    for _ in range(n):
        dt = mean / 1000
        f_dev += (-f_dev / tau) * dt + fsd * math.sqrt(2 * dt / tau) * rng.gauss(0, 1)
        a_dev += (-a_dev / tau) * dt + asd * math.sqrt(2 * dt / tau) * rng.gauss(0, 1)
        f = max(0.12, f0 + f_dev)
        amp = rsa * max(0.2, 1 + a_dev)
        phase += 2 * math.pi * f * dt
        rr = (mean + amp * math.sin(phase) + 0.15 * rsa * math.sin(2 * math.pi * 0.05 * t + 1)
              + jitter * rng.gauss(0, 1))
        v = int(round(rr))
        out.append(v)
        t += v / 1000
    return out


def fit_sleeper(rng, n=128):
    """One 128-beat segment of the fit-sleeper model."""
    mean = rng.uniform(1000, 1400)
    amp = rng.uniform(60, 120)
    f0 = rng.uniform(0.18, 0.32)
    jitter = rng.uniform(5, 20)
    return beats(n, mean, amp, jitter, rng, f0=f0)


def fit_sleeper_segments(count, seed=33):
    rng = random.Random(seed)
    return [fit_sleeper(rng) for _ in range(count)]
