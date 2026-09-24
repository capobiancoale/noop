#!/bin/bash
# Download the University of Malaga treadmill CPET dataset (PhysioNet treadmill-exercise-cardioresp 1.0.1,
# ~23 MB) into ./malaga and verify it against the published SHA-256 sums.
# Licence CC BY-NC-SA 4.0 (see README): used here for validation only, never committed.
set -u
cd "$(dirname "$0")" && mkdir -p malaga && cd malaga || exit 1
base=https://physionet.org/files/treadmill-exercise-cardioresp/1.0.1
for f in SHA256SUMS.txt subject-info.csv test_measure.csv LICENSE.txt; do
  [ -s "$f" ] || curl -fsS --retry 4 -o "$f" "$base/$f" || { rm -f "$f"; echo "download failed: $f" >&2; exit 1; }
done
sha256sum -c --ignore-missing SHA256SUMS.txt
