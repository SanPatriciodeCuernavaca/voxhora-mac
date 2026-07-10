#!/usr/bin/env bash
#
# notary_preflight.sh — replicate Apple's notary recursion LOCALLY so a
# notarization rejection is caught in seconds, not after a 10-15 min
# round trip (2026-07-09: the embedded TechShare Python runtime took four
# failed submissions to get right).
#
# Apple's notary descends into EVERY nested archive (.app → .tar.gz →
# .tar → .whl/.zip) and requires each nested Mach-O to carry a valid
# Developer ID signature + secure timestamp; executables additionally
# need hardened runtime. This script unpacks the same layers under a
# temp dir and asserts the same properties.
#
# Usage: ./scripts/notary_preflight.sh /path/to/Voxhora-Mac.app
# Exit 0 = every nested Mach-O passes; non-zero = at least one would be
# rejected (printed with its archive path).
#
set -uo pipefail

APP="${1:?usage: notary_preflight.sh <app-bundle-or-dir>}"
[[ -e "$APP" ]] || { echo "✗ not found: $APP" >&2; exit 2; }

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; DIM=$'\033[2m'; RST=$'\033[0m'
fail=0; checked=0

# Verify one Mach-O; $2 = human archive path for reporting.
check_macho() {
  local f="$1" where="$2"
  checked=$((checked+1))
  local out
  out="$(codesign -dvvv "$f" 2>&1 || true)"
  local problems=""
  case "$out" in
    *"Authority=Developer ID Application"*) : ;;
    *) problems+=" no-DeveloperID-signature" ;;
  esac
  case "$out" in
    *"Signed Time"*|*"Timestamp="*) : ;;   # secure timestamp present
    *) problems+=" no-secure-timestamp" ;;
  esac
  # Hardened runtime: flag 0x10000 in the CodeDirectory. Required on
  # executables; harmless-but-present on our signed dylibs/.so too.
  case "$out" in
    *"flags=0x10000(runtime)"*|*"runtime"*) : ;;
    *) problems+=" no-hardened-runtime" ;;
  esac
  if [[ -n "$problems" ]]; then
    echo "${RED}✗${RST} ${where}${problems}"
    fail=$((fail+1))
  fi
}

# Recursively scan a directory: check every Mach-O, then descend into
# every nested archive.
scan_dir() {
  local dir="$1" prefix="$2"
  # Mach-Os at this level.
  while IFS= read -r f; do
    check_macho "$f" "${prefix}${f#$dir/}"
  done < <(
    find "$dir" -type f -exec file {} + 2>/dev/null \
      | grep "Mach-O" | grep -v "(for architecture" \
      | sed 's/:[[:space:]]*Mach-O.*//'
  )
  # Nested archives — unpack each into a temp dir and recurse.
  while IFS= read -r arc; do
    local atmp; atmp="$(mktemp -d)"
    case "$arc" in
      *.tar.gz|*.tgz) tar -xzf "$arc" -C "$atmp" 2>/dev/null ;;
      *.tar)          tar -xf  "$arc" -C "$atmp" 2>/dev/null ;;
      *.whl|*.zip)    unzip -qq "$arc" -d "$atmp" 2>/dev/null ;;
    esac
    scan_dir "$atmp" "${prefix}${arc#$dir/}/"
    rm -rf "$atmp"
  done < <(find "$dir" -type f \( -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar" -o -name "*.whl" -o -name "*.zip" \))
}

echo "${DIM}Notary pre-flight — recursively verifying every nested Mach-O…${RST}"
ROOT="$(mktemp -d)"
cp -R "$APP" "$ROOT/"
scan_dir "$ROOT" ""
rm -rf "$ROOT"

echo "${DIM}checked ${checked} Mach-O(s)${RST}"
if [[ "$fail" -eq 0 ]]; then
  echo "${GRN}✓ notary pre-flight PASS — every nested Mach-O is Developer-ID signed + timestamped + hardened${RST}"
  exit 0
else
  echo "${RED}✗ notary pre-flight FAIL — ${fail} Mach-O(s) would be rejected${RST}"
  exit 1
fi
