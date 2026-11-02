#!/bin/sh
# Download the PhysioNet sleep-accel files this check needs (heart rate, labels, motion; ~2.2 GB) into ./data,
# from PhysioNet's open-data mirror, and verify their checksums. The data are never committed.
set -eu
cd "$(dirname "$0")"
BASE=https://physionet-open.s3.amazonaws.com/sleep-accel/1.0.0
mkdir -p data/heart_rate data/labels data/motion
curl -sS --fail -o data/SHA256SUMS.txt "$BASE/SHA256SUMS.txt"
grep -E " (heart_rate|labels|motion)/" data/SHA256SUMS.txt | awk '{print $2}' | while read -r f; do
  [ -s "data/$f" ] || curl -sS --fail -o "data/$f" "$BASE/$f"
done
cd data && grep -E " (heart_rate|labels|motion)/" SHA256SUMS.txt | sha256sum -c --quiet
