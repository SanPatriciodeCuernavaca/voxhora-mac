#!/bin/bash
#
# voxhora-mac/deploy.sh — canonical "build + deploy to /Applications" script
#
# WHY THIS EXISTS (2026-05-28):
#   Tonight Patrick discovered three Voxhora-Mac.app bundles in three
#   places (~/voxhora-mac/build/, ~/Library/Developer/.../DerivedData/,
#   /Applications/), and Launchpad/Finder/the OS LaunchServices DB
#   were picking different ones at different times. Patrick saw an
#   OLD May 26 build running and assumed the calendar fix hadn't
#   shipped — it had, just in a different .app bundle than the one
#   he double-clicked. Plus an earlier `mv -f /tmp/Voxhora-Mac.app
#   /Applications/Voxhora-Mac.app` created a nested
#   /Applications/Voxhora-Mac.app/Voxhora-Mac.app/ mess (mv with a
#   directory target moves source INTO destination, not over it).
#
# WHAT THIS DOES:
#   1. Quits any running Voxhora-Mac (osascript first, pkill backup)
#   2. Builds Mac via xcodebuild to STANDARD DerivedData path only
#   3. Archives any stale build output (~/voxhora-mac/build/) to a
#      timestamped folder in ~/voxhora-mac/build_archive/ — keeps it
#      for recovery without leaving it where the OS can pick it
#   4. Archives the existing /Applications/Voxhora-Mac.app to the
#      same timestamped folder (so you can roll back if needed)
#   5. ditto (atomic overwrite, NOT mv) the fresh build into
#      /Applications/Voxhora-Mac.app
#   6. lsregister + open the canonical version
#   7. Prints the running PID + path so you can confirm
#
# HOW TO USE:
#   cd ~/voxhora-mac
#   ./deploy.sh
#
# AFTER THIS, ALWAYS LAUNCH VOXHORA-MAC FROM /Applications OR
# LAUNCHPAD — do NOT double-click ~/voxhora-mac/build/...app or
# ~/Library/Developer/.../DerivedData/...app directly.
#

set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/Voxhora-Mac-dxivwltvzknexfdltdvfumotxxvn"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Voxhora-Mac.app"
APPS_DEST="/Applications/Voxhora-Mac.app"
LEGACY_BUILD="$REPO_ROOT/build/Build/Products/Debug/Voxhora-Mac.app"
ARCHIVE_DIR="$REPO_ROOT/build_archive/$(date +%Y%m%d_%H%M%S)"

cyan()  { printf "\033[36m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }

cyan "==> Quitting any running Voxhora-Mac instances..."
osascript -e 'tell application "Voxhora-Mac" to quit' 2>/dev/null || true
sleep 2
# Belt-and-suspenders: kill survivors from non-/Applications launches
# (osascript only quits the frontmost-bundle-id instance; orphaned
# launches from different paths need direct pkill).
pkill -f "Voxhora-Mac.app/Contents/MacOS/Voxhora-Mac" 2>/dev/null || true
sleep 1
RUNNING=$(pgrep -f "Voxhora-Mac.app/Contents/MacOS/Voxhora-Mac" || true)
if [ -n "$RUNNING" ]; then
  red "ERROR: Voxhora-Mac still running after quit attempt (PIDs: $RUNNING)"
  red "Manually quit + re-run this script."
  exit 1
fi

cyan "==> Building Voxhora-Mac (Debug, standard DerivedData)..."
cd "$REPO_ROOT"
xcodebuild \
  -project Voxhora-Mac.xcodeproj \
  -scheme Voxhora-Mac \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  2>&1 | tail -5

if [ ! -d "$BUILT_APP" ]; then
  red "ERROR: Build did not produce $BUILT_APP"
  exit 1
fi

cyan "==> Archiving stale build output (if any)..."
mkdir -p "$ARCHIVE_DIR"
ARCHIVED_ANYTHING=false

if [ -d "$LEGACY_BUILD" ]; then
  echo "  - Moving stale $LEGACY_BUILD"
  echo "    → $ARCHIVE_DIR/legacy-build-output/"
  mv "$LEGACY_BUILD" "$ARCHIVE_DIR/legacy-build-output"
  ARCHIVED_ANYTHING=true
fi

if [ -d "$APPS_DEST" ]; then
  echo "  - Moving existing $APPS_DEST"
  echo "    → $ARCHIVE_DIR/previous-applications-install/"
  mv "$APPS_DEST" "$ARCHIVE_DIR/previous-applications-install"
  ARCHIVED_ANYTHING=true
fi

if [ "$ARCHIVED_ANYTHING" = false ]; then
  echo "  (nothing to archive — first deploy or already clean)"
  rmdir "$ARCHIVE_DIR" 2>/dev/null || true
fi

cyan "==> Deploying via ditto (atomic overwrite) to $APPS_DEST..."
ditto "$BUILT_APP" "$APPS_DEST"

cyan "==> Re-registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$APPS_DEST"

cyan "==> Launching $APPS_DEST..."
open "$APPS_DEST"
sleep 2

PID=$(pgrep -f "Voxhora-Mac.app/Contents/MacOS/Voxhora-Mac" | head -1)
RUNNING_PATH=$(ps -p "$PID" -o command= 2>/dev/null | head -1)

echo ""
green "✓ DEPLOY COMPLETE"
echo "  Canonical install: $APPS_DEST"
echo "  Running PID: $PID"
echo "  Running path: $RUNNING_PATH"
if [ "$ARCHIVED_ANYTHING" = true ]; then
  echo "  Stale builds archived to: $ARCHIVE_DIR"
  echo "  (delete that folder manually if no rollback needed in 1-2 weeks)"
fi
echo ""
echo "GOING FORWARD: launch Voxhora-Mac from /Applications or Launchpad."
echo "DO NOT double-click ~/voxhora-mac/build/ or DerivedData .app bundles directly."
