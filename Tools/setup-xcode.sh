#!/bin/bash
# Set up this Mac to build NOOP for your iPhone from Xcode, under your own Apple Developer team.
#
#   Tools/setup-xcode.sh <TEAMID>
#
# Writes Config/Local.xcconfig (git-ignored) with your Team ID and the identifiers the TestFlight build
# uses (com.<TEAMID>.noopapp.noop, group.com.<TEAMID>.noopapp.noop …), so an Xcode build and a TestFlight
# build are the same app. Then generates Strand.xcodeproj with XcodeGen and opens it.
# Re-run it after pulling changes that add or remove files (it only regenerates the project).
set -euo pipefail
cd "$(dirname "$0")/.."

TEAMID=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
if [[ ! "$TEAMID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Usage: Tools/setup-xcode.sh <TEAMID>" >&2
  echo "TEAMID is your 10-character Apple Team ID (developer.apple.com → Account → Membership details)," >&2
  echo "the same one as the TEAMID secret of the TestFlight build." >&2
  exit 1
fi

cat > Config/Local.xcconfig <<XCCONFIG
// Written by Tools/setup-xcode.sh. Git-ignored: only this Mac uses it.
DEVELOPMENT_TEAM = $TEAMID
NOOP_BUNDLE_PREFIX = com.$TEAMID.noopapp
XCCONFIG
echo "Wrote Config/Local.xcconfig for team $TEAMID (app id com.$TEAMID.noopapp.noop)."

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
open Strand.xcodeproj
