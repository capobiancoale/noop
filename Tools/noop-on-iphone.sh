#!/bin/bash
# List the NOOP apps installed on the iPhone(s) connected to this Mac, one per line on stdout:
#
#   <bundle id><TAB><name>
#
# Tools/setup-xcode.sh uses it to build the same app as the NOOP already on the iPhone: iOS keeps an app's
# data only when an install has the same bundle id (and team), and installs anything else as a second,
# empty app. Uses Xcode's devicectl (Xcode 15 or later). Read-only: it never changes anything on the iPhone.
# Exits 2, saying why on stderr, when it cannot look (no devicectl, no iPhone connected, iPhone locked).
set -uo pipefail

if ! xcrun --find devicectl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "Can't look at the iPhone from this Mac (it needs Xcode 15 or later)." >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1
DEVICES=$(python3 - "$TMP/devices.json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    platform = (d.get("hardwareProperties") or {}).get("platform", "iOS")
    if platform == "iOS" and d.get("identifier"):
        print(d["identifier"])
PY
)

if [ -z "$DEVICES" ]; then
  echo "No iPhone found: connect it with the cable and unlock it." >&2
  exit 2
fi

READ_ANY=0
for DEVICE in $DEVICES; do
  # A paired iPhone that isn't connected right now just fails here; the connected one answers.
  xcrun devicectl device info apps --device "$DEVICE" --json-output "$TMP/apps.json" >/dev/null 2>&1 || continue
  READ_ANY=1
  python3 - "$TMP/apps.json" <<'PY'
import json, sys
try:
    apps = json.load(open(sys.argv[1]))["result"]["apps"]
except Exception:
    sys.exit(0)
for a in apps:
    bundle_id = a.get("bundleIdentifier") or ""
    name = (a.get("name") or "").strip()
    if bundle_id.endswith((".watch", ".widgets", ".complications")):
        continue
    if name.lower() == "noop" or "noopapp" in bundle_id.lower():
        print(f"{bundle_id}\t{name}")
PY
done

if [ "$READ_ANY" = 0 ]; then
  echo "Couldn't read the apps on the iPhone: unlock it (tap Trust if it asks) and try again." >&2
  exit 2
fi
