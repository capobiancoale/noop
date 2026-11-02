#!/bin/bash
# Download the PhysioNet Fantasia beat annotations (.ecg) and headers (.hea) into ./fantasia.
# Open Data Commons Attribution License v1.0 — cite Iyengar et al. 1996 and PhysioNet (see README).
set -u
cd "$(dirname "$0")" && mkdir -p fantasia && cd fantasia || exit 1
base=https://physionet.org/files/fantasia/1.0.0
curl -fsS --retry 4 -o RECORDS "$base/RECORDS" || exit 1
for attempt in 1 2 3 4 5; do
  missing=0
  while read -r rec; do
    for ext in ecg hea; do
      [ -s "$rec.$ext" ] && continue
      missing=1
      curl -fsS --retry 2 -o "$rec.$ext" "$base/$rec.$ext" || rm -f "$rec.$ext"
    done
  done < RECORDS
  [ "$missing" -eq 0 ] && exit 0
  sleep $((attempt * 2))
done
echo "some files could not be downloaded" >&2
exit 1
