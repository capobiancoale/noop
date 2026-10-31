#!/bin/sh
# Run NOOP's sleep stagers on the prepared nights and print the comparison with polysomnography.
#   ./fetch.sh && python3 prep.py data prep && ./run.sh
# Copies the Swift packages to a temporary directory, makes the calibrated V2 constants settable there (the
# shipped sources are untouched), runs SleepAccelHarness as the package's only test, then calib.py.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
cp -R "$REPO/Packages" "$WORK/Packages"
V2="$WORK/Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift"
sed -i.bak 's/    static let baseLogPrior: \[String: Double\] = \[/    static var baseLogPrior: [String: Double] = [/; s/    static let deepGateThresh = /    static var deepGateThresh = /; s/    static let deepGateSlope = /    static var deepGateSlope = /' "$V2"
TESTS="$WORK/Packages/StrandAnalytics/Tests/StrandAnalyticsTests"
find "$TESTS" -name '*.swift' -delete
cp "$HERE/SleepAccelHarness.swift" "$TESTS/"
cd "$WORK/Packages/StrandAnalytics"
SLEEPACCEL_PREP="$HERE/prep" SLEEPACCEL_OUT="$HERE/results.jsonl" swift test --filter SleepAccelHarness
python3 "$HERE/calib.py" "$HERE/results.jsonl"
