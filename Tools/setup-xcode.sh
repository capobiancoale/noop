#!/bin/bash
# Set up this Mac to build NOOP for your iPhone from Xcode, under your own Apple Developer team.
#
#   Tools/setup-xcode.sh <TEAMID>                  first time, and after pulling changes (Tools/update-noop.sh
#                                                  does both)
#   Tools/setup-xcode.sh <TEAMID> --app-id <id>    build the NOOP installed on the iPhone under <id>
#   Tools/setup-xcode.sh <TEAMID> --app-id default back to com.<TEAMID>.noopapp.noop
#
# Writes Config/Local.xcconfig (git-ignored) with your Team ID and the app's identifiers, then generates
# Strand.xcodeproj with XcodeGen and opens it.
#
# The app id decides whether Xcode UPDATES the NOOP on your iPhone (its data stays) or installs a SECOND,
# empty NOOP next to it: iOS keeps an app's data only when an install has the same id and team. So the id
# is kept from one run to the next, and when the iPhone is connected the script looks at the NOOP on it
# (Tools/noop-on-iphone.sh): if the only NOOP there is signed by your team under another id (installed with
# AltStore/SideStore, com.noopapp.noop.<TEAMID>, or by an earlier build), it builds that one.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAMID=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
if [[ ! "$TEAMID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Usage: Tools/setup-xcode.sh <TEAMID> [--app-id <id>|default]" >&2
  echo "TEAMID is your 10-character Apple Team ID (developer.apple.com → Account → Membership details," >&2
  echo "or Xcode → Settings → Accounts), the same one as the TEAMID secret of the TestFlight build." >&2
  exit 1
fi
shift

APP_ID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app-id) APP_ID_ARG="${2:-}"; shift 2 || { echo "--app-id needs a value" >&2; exit 1; } ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

LOCAL=Config/Local.xcconfig
PREFIX="com.$TEAMID.noopapp"
DEFAULT_APP_ID="$PREFIX.noop"
PINNED=""
if [ -f "$LOCAL" ]; then
  PINNED=$(sed -n 's/^NOOP_APP_ID = //p' "$LOCAL" | tr -d '[:space:]')
fi
case "$APP_ID_ARG" in
  "") APP_ID="${PINNED:-$DEFAULT_APP_ID}" ;;
  default) APP_ID="$DEFAULT_APP_ID" ;;
  *) APP_ID="$APP_ID_ARG" ;;
esac
if [[ ! "$APP_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "Not a valid app id: $APP_ID" >&2
  exit 1
fi

# Which NOOP is on the iPhone? The app this Mac builds must be that one, or its data isn't the new app's.
echo "Looking at the NOOP on your iPhone…"
INSTALLED=$(Tools/noop-on-iphone.sh) && CHECKED=1 || CHECKED=0
IDS=$(printf '%s\n' "$INSTALLED" | cut -f1 | sed '/^$/d' | sort -u)
if [ "$CHECKED" = 1 ]; then
  if [ -z "$IDS" ]; then
    echo "NOOP isn't on this iPhone yet: Xcode will install it as $APP_ID."
  elif printf '%s\n' "$IDS" | grep -qxF "$APP_ID"; then
    echo "OK: Xcode will UPDATE the NOOP on your iPhone ($APP_ID). Its data stays."
    OTHERS=$(printf '%s\n' "$IDS" | grep -vxF "$APP_ID" || true)
    if [ -n "$OTHERS" ]; then
      echo "Also on the iPhone, each a separate NOOP with its own data:"
      printf '  %s\n' $OTHERS
      echo "To keep only one: in the one with the data, More → Backup & Sync → Back up now; in the other,"
      echo "Restore from a backup. Or build one of those instead: Tools/setup-xcode.sh $TEAMID --app-id <id>"
    fi
  elif [ -z "$APP_ID_ARG" ] && [ "$(printf '%s\n' "$IDS" | wc -l | tr -d ' ')" = 1 ] \
       && printf '%s' "$IDS" | grep -q "$TEAMID"; then
    APP_ID="$IDS"
    echo "The NOOP on your iPhone is $APP_ID (installed with AltStore/SideStore or an earlier build, signed"
    echo "by your team). Xcode will build that same app, so it UPDATES it and keeps its data."
  else
    echo
    echo "WARNING: the NOOP on your iPhone is not the app this Mac builds ($APP_ID):"
    printf '  %s\n' $IDS
    echo "Running from Xcode now would install a SECOND, empty NOOP next to it (the data stays in the old"
    echo "one). Before you press ▶︎:"
    echo "  • if one of those ids contains your Team ID ($TEAMID), build that one instead:"
    echo "      Tools/setup-xcode.sh $TEAMID --app-id <that id>"
    echo "  • otherwise it comes from another developer or Apple ID (App Store, TestFlight, another account),"
    echo "    and only they can update it. Move your data: in the old NOOP, More → Backup & Sync → Back up"
    echo "    now; after installing, in the new one, Restore from a backup."
    echo
  fi
else
  echo "(Couldn't check. With the iPhone connected and unlocked this script checks that Xcode updates the"
  echo " NOOP already on it instead of installing a second, empty one.)"
fi

cat > "$LOCAL" <<XCCONFIG
// Written by Tools/setup-xcode.sh. Git-ignored: only this Mac uses it.
DEVELOPMENT_TEAM = $TEAMID
NOOP_BUNDLE_PREFIX = $PREFIX
// The iPhone app's id: keep it, or Xcode installs a second, empty NOOP instead of updating yours.
NOOP_APP_ID = $APP_ID
XCCONFIG
echo "Wrote $LOCAL for team $TEAMID (app id $APP_ID)."

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen with Homebrew…"
    brew install xcodegen
  else
    echo "XcodeGen is missing. Install Homebrew (https://brew.sh), then run: brew install xcodegen" >&2
    exit 1
  fi
fi

xcodegen generate
echo
echo "Done. In Xcode: pick the NOOPiOS scheme and your iPhone at the top, then Product → Run (⌘R)."
echo "To update later: Tools/update-noop.sh, then ⌘R. Never delete NOOP from the iPhone to update it:"
echo "that deletes its data."
open Strand.xcodeproj
