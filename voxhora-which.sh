#!/bin/bash
#
# voxhora-which.sh — "which Voxhora app is which?" doctor
#
# Lists every Voxhora .app bundle on disk (Applications, Desktop, Downloads,
# and Xcode DerivedData build products), with the facts you need to tell a
# fresh build from a stale one and a real app from a Safari web-shortcut:
#
#   • marketing version + build number
#   • bundle identifier
#   • code-signing authority, classified by whether Finder/`open` can launch it
#   • main-binary AND debug-dylib modification time (the real "how fresh" signal
#     for Debug builds, whose code lives in Voxhora-Mac.debug.dylib)
#   • whether it is running right now
#
# Read-only. Touches nothing. Created 2026-05-28 to end the recurring
# "multiple Voxhora apps, can't tell which is the latest" confusion.
#

set -o pipefail

SCAN_DIRS=(
  "/Applications"
  "$HOME/Applications"
  "$HOME/Desktop"
  "$HOME/Downloads"
)
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'; red=$'\033[31m'; rst=$'\033[0m'

plist() {
  # Mac bundles keep Info.plist in Contents/; iOS bundles keep it at the root.
  local p="$1/Contents/Info.plist"
  [ -f "$p" ] || p="$1/Info.plist"
  [ -f "$p" ] || return
  /usr/libexec/PlistBuddy -c "Print :$2" "$p" 2>/dev/null
}

classify_sign() {
  # $1 = app path. Echoes a human verdict about launchability.
  local out auth
  out=$(codesign -dvv "$1" 2>&1)
  auth=$(echo "$out" | grep "^Authority=" | head -1 | sed 's/^Authority=//')
  if echo "$out" | grep -q "linker-signed"; then echo "ad-hoc/linker (local only)"; return; fi
  case "$auth" in
    "Developer ID Application"*) echo "${grn}Developer ID — Finder-launchable${rst}" ;;
    "Apple Development"*)        echo "${ylw}Apple Development — Debug build; Gatekeeper blocks Finder/open, run from Xcode (⌘R)${rst}" ;;
    "Apple Distribution"*)       echo "Apple Distribution (App Store)" ;;
    "")                          echo "${red}unsigned / ad-hoc${rst}" ;;
    *)                           echo "$auth" ;;
  esac
}

mtime() { stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$1" 2>/dev/null; }

report_app() {
  local app="$1"
  [ -e "$app" ] || return
  local bid ver bld bin dylib running
  bid=$(plist "$app" CFBundleIdentifier)
  ver=$(plist "$app" CFBundleShortVersionString)
  bld=$(plist "$app" CFBundleVersion)

  echo "${bold}$app${rst}"

  # Safari "web app" shortcut, not a real build.
  if [[ "$bid" == com.apple.Safari.WebApp* ]]; then
    echo "  ${dim}↳ Safari web-app shortcut (NOT a real Voxhora build) — bundle id $bid${rst}"
    echo
    return
  fi

  echo "  version : v${ver:-?} (build ${bld:-?})   bundle id: ${bid:-?}"
  echo "  signing : $(classify_sign "$app")"

  local exe; exe=$(plist "$app" CFBundleExecutable)
  bin="$app/Contents/MacOS/$exe"           # Mac layout
  [ -e "$bin" ] || bin="$app/$exe"          # iOS layout
  [ -e "$bin" ] && echo "  binary  : $(mtime "$bin")   ($bin)"
  dylib="$app/Contents/MacOS/$(plist "$app" CFBundleExecutable).debug.dylib"
  [ -e "$dylib" ] && echo "  ${bold}code    : $(mtime "$dylib")   ← real freshness (Debug dylib)${rst}"

  running=$(ps aux | grep -F "$bin" | grep -v grep | awk '{print $2}' | head -1)
  [ -n "$running" ] && echo "  status  : ${grn}RUNNING (pid $running)${rst}" || echo "  status  : not running"
  echo
}

echo "==================== Voxhora app inventory ===================="
echo

# Installed / desktop / downloads locations
for d in "${SCAN_DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r app; do report_app "$app"; done \
    < <(find "$d" -maxdepth 1 -iname "Voxhora*.app" 2>/dev/null)
done

# Xcode build products (these are the dev builds you compile)
echo "${dim}---- Xcode DerivedData build products ----${rst}"
echo
if [ -d "$DERIVED" ]; then
  while IFS= read -r app; do report_app "$app"; done \
    < <(find "$DERIVED" -path "*/Build/Products/*/Voxhora*.app" -not -path "*/Index.noindex/*" -maxdepth 6 -prune 2>/dev/null)
fi

echo "==============================================================="
echo "Tip: the build with the newest ${bold}code${rst} (debug dylib) timestamp is your latest work."
echo "     Debug builds (Apple Development) only launch via Xcode ⌘R until the"
echo "     Developer ID provisioning profile is embedded (queued Sparkle Fix)."
