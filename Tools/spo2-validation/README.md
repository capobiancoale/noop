# SpO2: ratio-of-ratios check on open data, and the WHOOP 5.0 channel question

Reproducible check of the ratio-of-ratios SpO2 method behind `Spo2RatioOfRatios` (StrandAnalytics), and a tool
that looks for the red and infrared channels in a WHOOP 5.0 raw capture. Described in `docs/ANALYTICS.md`,
"SpO2 from red and infrared light".

## The method

A pulse oximeter shines red (about 660 nm) and infrared (about 880-940 nm) light into the skin. Each heartbeat
adds a little arterial blood, so each signal has a small pulsing part (AC) on top of a steady level (DC).
Oxyhaemoglobin absorbs little red light and deoxyhaemoglobin a lot, so the ratio of ratios

    R = (AC_red / DC_red) / (AC_ir / DC_ir)

falls as saturation rises: about 0.4-0.5 at 97-100 %, about 1 near 85 %. Dividing each AC by its own DC cancels
the LED brightness, skin tone and how tightly the sensor sits, to first order. R is turned into a percentage
with a curve that has to be measured for each sensor design against arterial blood samples (Webster JG, *Design
of Pulse Oximeters*, 1997; Mendelson Y, Clin Chem 1992;38:1601). Without that calibration only a textbook
line (110 - 25 R) or a chip maker's curve (Maxim's -45.060 R^2 + 30.354 R + 94.845) is available.

NOOP's recipe: band-pass both signals at 0.5-5 Hz (2nd-order Butterworth, forward and backward), cut them into
10 s windows every 5 s, take AC as the standard deviation of the filtered window and DC as the mean of the raw
window, keep a window only when the filtered red and infrared signals correlate at 0.9 or better (a true pulse
moves both together; motion and noise do not) and the infrared perfusion is 0.02-10 %, and report the median
R of the kept windows.

## Data

PhysioNet **Pulse Transit Time PPG** 1.1.0 (Mehrgardt P, Khushi M, Poon S, Withana A. Pulse Transit Time PPG
Dataset, version 1.1.0. PhysioNet; Goldberger AL et al., Circulation 2000;101:e215-e220): 22 healthy adults, 66 records of
about 8 minutes (sitting, walking on the spot, running on the spot), two MAX30101 sensors on one finger
recording red, infrared and green at 500 Hz, and a reference SpO2 from a commercial finger oximeter at the start
and end of each record (94-99 %). `fetch.sh` downloads the 66 records (about 420 MB) from PhysioNet's open-data
mirror into `./data` and checks their SHA-256 sums; the data are git-ignored and never committed or shipped.

**The red and infrared labels in the dataset's README are swapped.** It names `pleth_1`/`pleth_4` infrared and
`pleth_2`/`pleth_5` red, but in all 22 subjects the channel it calls red pulses more (median AC/DC 0.25 %) than
the one it calls infrared (0.11 %), which cannot happen at 94-99 % saturation; with that mapping R comes out at
2.3, a physically impossible value. The MAX30101's slot order is LED1 = red, LED2 = infrared, LED3 = green, so
`pleth_1`/`pleth_4` are red and `pleth_2`/`pleth_5` infrared (green, `pleth_3`/`pleth_6`, pulses most,
1.2 %). The scripts use the corrected mapping; `--as-labelled` reproduces the impossible one.

## Run

```sh
pip install numpy scipy
./fetch.sh
python3 -I eval_ptt.py data          # accuracy against the reference, both sensors, by activity
python3 -I subsample_ptt.py data     # does R survive 25 Hz and one-sample-a-second recording?
python3 -I sweep_ptt.py data         # window length and correlation gate
```

## Results

Each record's R against the mean of its start and end reference (sensor A = `pleth_1`/`pleth_2`, sensor B =
`pleth_4`/`pleth_5`; ARMS = root-mean-square error, the figure regulators use):

| Sensor, activity | Records | Median R | Bias, 110 - 25 R | ARMS, 110 - 25 R | ARMS, Maxim curve |
|---|---|---|---|---|---|
| A, sitting | 22 | 0.43 | +2.1 | 2.4 | 2.4 |
| A, walking | 22 | 0.44 | +1.0 | 2.4 | 2.4 |
| A, running | 21 | 0.47 | +1.3 | 2.6 | 2.7 |
| B, sitting | 22 | 0.47 | +1.1 | 2.2 | 2.1 |
| B, walking | 22 | 0.62 | -2.9 | 4.5 | 4.2 |
| B, running | 22 | 0.56 | -1.7 | 4.0 | 4.2 |

- R lands where physiology puts it (0.43-0.47 at rest), and 84-99 % of windows pass the quality gate, depending on sensor and activity.
- The same person's R barely moves between sitting, walking and running on sensor A (median spread 0.03, about
  0.7 points); sensor B drifts in motion (1.8 points), which is why the motion rows of B are worse.
- With an uncalibrated curve the error at rest is 2.1-2.4 points ARMS. For comparison, ISO 80601-2-61 asks a
  pulse oximeter for ARMS of 4 % or better over 70-100 % and the FDA's 2013 guidance 3 % (3.5 % for
  reflectance sensors), both measured against arterial blood.
- Window length (5, 10, 20 s), the correlation gate (0.8, 0.9, 0.95) and outlier trimming change these figures by
  less than 0.2 points.
- R measured on a 25 Hz copy equals R at 500 Hz (median difference 0.03 points). From one sample a second (as a
  strap that banks one red/infrared pair a second would give) the 60 s R differs by a median 0.7 points (90th
  percentile 3.2); from one-second averages by 1.6 (5.4). That figure is a best case: a slow wobble shared by both
  channels (breathing, 0.1-0.5 Hz) survives the one-a-second baseline removal and pulls R towards 1 while the
  two residuals still correlate (the Swift tests pin this), so a one-sample-a-second R is only rough.

**What this does not show.** The references only span 94-99 %, so the check cannot show that R tracks a real
fall in saturation: a model that always answers 97 % scores ARMS 0.9 on this set, and a linear fit trained on
21 subjects and tested on the 22nd does no better (0.9). The finger and the MAX30101 are not a wrist strap, and
the reference is a finger oximeter, not arterial blood. The open dataset that would settle the slope
(OpenOximetry, UCSF Hypoxia Lab, arterial blood down to 70 %; Sci Data 2025) needs PhysioNet credentialed
access.

## WHOOP 5.0: which channel is which?

The WHOOP 4.0 history record carries two values it names red and infrared (`spo2_red`/`spo2_ir`, one pair a
second). The WHOOP 5.0 records that NOOP decodes do not: v26 has one 24 Hz optical channel (used for heart
rate), and the bulk v20/v21 records carry three (v21) or up to ten (v20) optical waveforms with no LED
labels. So no SpO2 can be computed for a 5.0 until the red and infrared channels are found.

`identify_channels.py` runs the physics check that caught the swapped labels above on a NOOP raw capture: it
finds the channels that carry a heartbeat, measures each one's AC/DC, correlates every pair, and lists the pairs
that behave like red + infrared (correlation of 0.9 or better, R between 0.3 and 1.0; green pulses most). With
the raw-capture toggle on, NOOP keeps up to 1,200 v20/v21 history records per capture file for this. Two
outcomes are possible: a pair is found (then a capture made while wearing a finger oximeter can fix the
offset), or no pair behaves, for example because the strap's front end subtracts the steady level, in which case
AC/DC, and SpO2 with it, cannot be recovered from these records.

```sh
python3 -I identify_channels.py noop-raw-capture-....json
```
