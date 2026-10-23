#!/bin/bash
# Build the RR artefact-correction CLI from the app's own source (signed quartile deviation, as shipped),
# plus an `abs` variant that reads eqs. 2 and 6 as QD(|x|) — the NeuroKit2 reading — for comparison.
set -eu
cd "$(dirname "$0")"
src=../../Packages/StrandAnalytics/Sources/StrandAnalytics/RRArtefactCorrection.swift
mkdir -p build
swiftc -O -module-name ltcli "$src" main.swift -o build/ltcli
sed 's/let w = x\[lo...hi\].sorted()/let w = x[lo...hi].map { abs($0) }.sorted()/' "$src" > build/rr_abs.swift
grep -q 'map { abs($0) }.sorted()' build/rr_abs.swift
swiftc -O -module-name ltcli build/rr_abs.swift main.swift -o build/ltcli_abs
