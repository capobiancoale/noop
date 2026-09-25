#!/bin/bash
# Update NOOP on this Mac and get Xcode ready to install it OVER the NOOP on your iPhone, keeping its data:
#
#   Tools/update-noop.sh
#
# then ⌘R in Xcode. It pulls the latest code, then reruns Tools/setup-xcode.sh with the Team ID and app id
# this Mac already uses (so the app on the iPhone stays the same app) and regenerates the project.
# Never delete NOOP from the iPhone to update it: that deletes its data.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL=Config/Local.xcconfig
TEAMID=""
if [ -f "$LOCAL" ]; then
  TEAMID=$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$LOCAL" | tr -d '[:space:]')
fi
if [ -z "$TEAMID" ]; then
  echo "Run this once first: Tools/setup-xcode.sh <TEAMID>" >&2
  exit 1
fi

# Xcode rewrites the string catalogs and the package lockfile when it builds. Those edits come back by
# themselves at the next build, but they stop `git pull`, so put the files back as they were.
git ls-files -m -- '*.xcstrings' 'Strand.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved' |
  while IFS= read -r f; do git checkout -- "$f"; done
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Setting your other local changes aside with git stash (get them back with: git stash pop):"
  git status --short --untracked-files=no
  git stash push -m "update-noop $(date '+%Y-%m-%d %H:%M')"
fi

git pull --ff-only
exec Tools/setup-xcode.sh "$TEAMID"
