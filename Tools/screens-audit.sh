#!/bin/bash
# Screen audit: installs the Debug simulator build and captures every screen in Italian, dark and light, with the
# synthetic demo data (--demo-seed), one screenful at a time (--demo-page), into ./shots. Run by
# .github/workflows/screens-audit.yml after the build; also runs on a Mac with a booted simulator.
set -uo pipefail
APP=$(find build/dd/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "::error::no simulator .app under build/dd"; exit 1; }
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
echo "app=$APP bundle=$BUNDLE"

# The newest iOS runtime, preferring a base-model iPhone (the size most people hold).
UDID=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    for d in devices:
        name = d["name"]
        if not name.startswith("iPhone"):
            continue
        score = ((int(m.group(1)), int(m.group(2))), 1 if re.fullmatch(r"iPhone \d+", name) else 0, name)
        if best is None or score > best[0]:
            best = (score, d["udid"])
print(best[1] if best else "")
')
[ -n "$UDID" ] || { echo "::error::no iPhone simulator available"; exit 1; }
xcrun simctl list devices | grep "$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

mkdir -p shots
launch() {
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages "(it)" -AppleLocale it_IT --demo-seed "$@" >/dev/null 2>&1 \
    || echo "launch failed: $*"
}
shot() {
  xcrun simctl io "$UDID" screenshot --type=png "shots/$1.png" >/dev/null 2>&1 \
    && sips -Z 1400 "shots/$1.png" >/dev/null 2>&1 || echo "screenshot failed: $1"
}

# The first launch seeds 120 days of synthetic data; give it time.
xcrun simctl ui "$UDID" appearance dark
launch
sleep 45
shot "00-first-launch"

SCREENS="liquidtoday trends sleep workouts wodlog coach intelligence insightshub insights explore compare health stress \
applehealth vo2max weeklydigest settings devices datasources fullday scoringguide labbook coupled breathing intervals \
smartalarm automations storage backup today hraccuracy wodimport"

for appearance in dark light; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for tab in 0 1 2 3; do
    launch --demo-tab "$tab"; sleep 9; shot "$appearance-tab$tab"
  done
  pages="0 1 2 3"
  [ "$appearance" = light ] && pages="0 1"
  for s in $SCREENS; do
    for page in $pages; do
      launch --demo-screen "$s" --demo-page "$page"; sleep 7; shot "$appearance-$s-$page"
    done
  done
done
ls shots | wc -l
