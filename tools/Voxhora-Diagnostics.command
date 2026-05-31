#!/bin/bash
#
# Voxhora-Diagnostics.command
# ---------------------------
# Double-click this file. It gathers a small, PRIVACY-REDACTED diagnostic
# bundle about Voxhora-Mac onto your Desktop as a .zip, then reveals it in
# Finder. Email that .zip to Patrick when Voxhora is misbehaving.
#
# What it collects: app version, whether the app is running + a stack
# "sample" if it's frozen (this is the single most useful thing and
# contains NO client data), watched-folder PDF counts, preferences-file
# size, last update check, recent crash reports, and the last few days of
# the Voxhora agent log WITH CLIENT NAMES REDACTED.
#
# Privacy: client names in quotes and "SURNAME, First" filename patterns
# are replaced with <redacted> before the log is copied. The bundle is a
# plain folder + zip you can open and inspect before sending. Nothing is
# uploaded anywhere — it only writes to your Desktop.
#
set -u

TS="$(date +%Y-%m-%d_%H%M%S)"
OUT="$HOME/Desktop/Voxhora_Diagnostics_$TS"
REPORT="$OUT/report.txt"
mkdir -p "$OUT"

say() { printf "  • %s\n" "$*"; }
log() { printf "%s\n" "$*" >> "$REPORT"; }

echo ""
echo "Voxhora Diagnostics — collecting (this takes ~10 seconds)…"
echo ""

# ── System ────────────────────────────────────────────────────────────
log "Voxhora Diagnostics — $TS"
log "macOS:    $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
log "Hardware: $(sysctl -n hw.model 2>/dev/null)"
log "Free disk: $(df -h / | awk 'NR==2{print $4}')"
log ""

# ── App version + signature ─────────────────────────────────────────────
APP="/Applications/Voxhora-Mac.app"
PLIST="$APP/Contents/Info.plist"
if [ -d "$APP" ]; then
  VER="$(defaults read "$PLIST" CFBundleShortVersionString 2>/dev/null)"
  BUILD="$(defaults read "$PLIST" CFBundleVersion 2>/dev/null)"
  log "App: Voxhora-Mac $VER (build $BUILD)"
  log "Gatekeeper / notarization:"
  spctl -a -vv "$APP" >> "$REPORT" 2>&1
  say "app version $VER (build $BUILD)"
else
  log "Voxhora-Mac.app NOT FOUND in /Applications."
  say "WARNING: Voxhora-Mac.app not found in /Applications"
fi
log ""

# ── Running instances + stack sample (the key one) ──────────────────────
PIDS="$(pgrep -f "Voxhora-Mac.app/Contents/MacOS/Voxhora-Mac" 2>/dev/null)"
COUNT="$(printf "%s\n" "$PIDS" | grep -c . )"
log "Running instances: $COUNT"
if [ "$COUNT" -gt 0 ]; then
  log "Per-process CPU / memory / uptime:"
  for PID in $PIDS; do
    ps -o pid,%cpu,%mem,rss,etime -p "$PID" >> "$REPORT" 2>&1
  done
  log ""
  for PID in $PIDS; do
    say "sampling process $PID (3s)…"
    sample "$PID" 3 -file "$OUT/sample_$PID.txt" >/dev/null 2>&1 \
      && log "Captured stack sample → sample_$PID.txt" \
      || log "Could not sample $PID."
  done
else
  say "app is not currently running"
fi
log ""

# ── Watched-folder PDF counts ───────────────────────────────────────────
log "Watched / intake folder PDF counts:"
for d in \
  "$HOME/Downloads" \
  "$HOME/Dropbox/Voxhora/Bulk_Inbox" \
  "$HOME/Dropbox (Personal)/Voxhora/Bulk_Inbox" \
  "$HOME/Library/CloudStorage"/Dropbox*/Voxhora/Bulk_Inbox ; do
  if [ -d "$d" ]; then
    n=$(ls "$d"/*.pdf 2>/dev/null | wc -l | tr -d ' ')
    log "  $d : $n PDFs"
  fi
done
log ""

# ── Preferences file (watch for bloat) ──────────────────────────────────
PL="$HOME/Library/Preferences/com.patrickfagerberg.voxhora.mac.plist"
if [ -f "$PL" ]; then
  SZ=$(stat -f%z "$PL" 2>/dev/null)
  log "Preferences file size: $SZ bytes  ($PL)"
  KEYS=$(python3 -c "import plistlib;print(len(plistlib.load(open('$PL','rb'))))" 2>/dev/null)
  [ -n "${KEYS:-}" ] && log "Preferences key count: $KEYS  (normal ~70-100; thousands = window-state bloat)"
  log "Last update check: $(defaults read "$PL" SULastCheckTime 2>/dev/null)"
fi
log ""

# ── Crash reports ───────────────────────────────────────────────────────
CR="$HOME/Library/Logs/DiagnosticReports"
if [ -d "$CR" ]; then
  CRASHES=$(ls "$CR" 2>/dev/null | grep -i -E "voxhora" )
  if [ -n "$CRASHES" ]; then
    mkdir -p "$OUT/crashes"
    log "Voxhora crash reports found:"
    printf "%s\n" "$CRASHES" | while read -r c; do
      [ -n "$c" ] && cp "$CR/$c" "$OUT/crashes/" 2>/dev/null && log "  $c"
    done
  else
    log "No Voxhora crash reports (good)."
  fi
fi
log ""

# ── Agent log (REDACTED) ────────────────────────────────────────────────
LOGDIR="$HOME/Voxhora_Logs"
if [ -d "$LOGDIR" ]; then
  mkdir -p "$OUT/logs_redacted"
  # newest 3 day-logs, last 800 lines each, with client PII stripped:
  #  - any quoted value  → "<redacted>"   (rawBookingName="…", filenames)
  #  - "SURNAME, First"  → <name redacted> (unquoted filename names)
  for f in $(ls -t "$LOGDIR"/agent_*.log 2>/dev/null | head -3); do
    base="$(basename "$f")"
    tail -n 800 "$f" \
      | sed -E 's/"[^"]*"/"<redacted>"/g' \
      | sed -E 's/[A-Z][A-Z]+, [A-Z][a-z]+/<name redacted>/g' \
      > "$OUT/logs_redacted/$base"
  done
  say "copied recent agent logs (client names redacted)"
  log "Recent agent logs copied to logs_redacted/ (client names stripped)."
else
  log "No ~/Voxhora_Logs found."
fi

# ── Zip + reveal ────────────────────────────────────────────────────────
cd "$HOME/Desktop" || exit 1
ZIP="Voxhora_Diagnostics_$TS.zip"
zip -r -q "$ZIP" "Voxhora_Diagnostics_$TS"

echo ""
echo "✅  Done."
echo "    Created:  ~/Desktop/$ZIP"
echo "    Email that file to Patrick. Client names are redacted; you can"
echo "    open the folder next to it and review everything first."
echo ""
open -R "$HOME/Desktop/$ZIP" 2>/dev/null
# keep the Terminal window readable
echo "(You can close this window.)"
