#!/bin/sh
# Download the PhysioNet pulse-transit-time-ppg records this check needs (66 WFDB records, ~420 MB) into ./data,
# from PhysioNet's open-data mirror, and verify their checksums. The data are never committed.
set -eu
cd "$(dirname "$0")"
BASE=https://physionet-open.s3.amazonaws.com/pulse-transit-time-ppg/1.1.0
mkdir -p data
curl -sS --fail -o data/SHA256SUMS.txt "$BASE/SHA256SUMS.txt"
grep -E " s[0-9]+_(sit|walk|run)\.(hea|dat)$" data/SHA256SUMS.txt | awk '{print $2}' | while read -r f; do
  [ -s "data/$f" ] || curl -sS --fail -o "data/$f" "$BASE/$f"
done
cd data && grep -E " s[0-9]+_(sit|walk|run)\.(hea|dat)$" SHA256SUMS.txt | sha256sum -c --quiet
