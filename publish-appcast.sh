#!/usr/bin/env bash
#
# publish-appcast.sh — finish a HOLD_APPCAST release: regenerate the Sparkle
# feed and push it, which is the moment EXISTING users (Matt) begin updating.
# Split out 2026-08-07 so a build can reach new attorneys immediately while
# existing users wait out the 24h soak.
#
set -euo pipefail
SPARKLE_TOOLS="/Users/patrickfagerberg/Documents/Documents - patrick’s MacBook Air/Voxhora_Backups/sparkle-tools"
RELEASES_DIR="releases"
REPO_OWNER="SanPatriciodeCuernavaca"
REPO_NAME="voxhora-mac"
TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: ./publish-appcast.sh <release-tag>   e.g. ./publish-appcast.sh v0.2.85"; exit 1; }

echo "Regenerating appcast for $TAG …"
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${TAG}/" \
  --maximum-deltas 0 \
  "$RELEASES_DIR"
mv "$RELEASES_DIR/appcast.xml" appcast.xml
git add appcast.xml
git commit -m "Publish appcast for $TAG — existing users now update"
git push
echo
echo "DONE — every Voxhora-Mac user picks this up within 24h."
