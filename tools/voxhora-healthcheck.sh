#!/bin/bash
#
# voxhora-healthcheck.sh — daily Voxhora health + regression sweep (2026-06-08).
#
# Runs the FULL sweep Patrick asked for: live services + code gates + builds.
# Writes a structured PASS/FAIL/WARN report to ~/Voxhora_Logs/healthcheck/ and
# exits non-zero if anything FAILED (so the daily Claude routine can triage).
#
# Each check is independent + defensive: a missing prerequisite (e.g. the admin
# secret or the ASC key) is a WARN (skipped), not a hard failure.
#
#   PASS = healthy   WARN = couldn't check / approaching a limit   FAIL = broken
#
# Run manually:  bash ~/voxhora-mac/tools/voxhora-healthcheck.sh
#
set -uo pipefail

IOS=~/voxhora-ios
MAC=~/voxhora-mac
PROXY="https://voxhora-llm-proxy.fly.dev"
SITE="https://voxhora.app"
ADMIN_SECRET_FILE="$HOME/.voxhora_admin_secret"
LOGDIR="$HOME/Voxhora_Logs/healthcheck"
mkdir -p "$LOGDIR"
STAMP=$(date +%Y%m%d_%H%M%S)
REPORT="$LOGDIR/healthcheck_$STAMP.txt"

# Portable timeout: macOS has no GNU `timeout`. Prefer gtimeout (coreutils),
# then timeout, else run directly (drop the duration arg) — no-op fallback.
if command -v gtimeout >/dev/null 2>&1; then TO() { gtimeout "$@"; }
elif command -v timeout  >/dev/null 2>&1; then TO() { timeout "$@"; }
else TO() { shift; "$@"; }
fi

PASS=0; WARN=0; FAIL=0
say()  { echo "$1" | tee -a "$REPORT"; }
pass() { PASS=$((PASS+1)); say "[PASS] $1"; }
warn() { WARN=$((WARN+1)); say "[WARN] $1"; }
fail() { FAIL=$((FAIL+1)); say "[FAIL] $1"; }

say "==================================================================="
say "Voxhora health check — $(date)"
say "Report: $REPORT"
say "==================================================================="

# ----------------------------------------------------------- 1. LIVE SERVICES
say ""; say "## 1. Live services"

# 1a. Proxy /health — up + Anthropic key present + token count
H=$(curl -s -m 20 "$PROXY/health" 2>/dev/null)
if echo "$H" | grep -q '"ok":true'; then
  if echo "$H" | grep -q '"anthropic_key_set":true'; then
    pass "Proxy /health OK ($(echo "$H" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("active_tokens="+str(d.get("active_tokens")),"ver="+str(d.get("version")))' 2>/dev/null))"
  else
    fail "Proxy up but ANTHROPIC key NOT set — all AI features down."
  fi
else
  fail "Proxy /health unreachable or unhealthy → voice/synopsis/VoxHelp are down. Body: ${H:0:120}"
fi

# 1b. Synthetic claim round-trip — a bogus code must be cleanly rejected (404)
C=$(curl -s -m 20 -o /dev/null -w "%{http_code}" -X POST "$PROXY/v1/claim" -H "content-type: application/json" -d '{"code":"healthcheck-bogus"}' 2>/dev/null)
if [ "$C" = "404" ]; then pass "Claim endpoint live (bogus code → 404 as expected)"
else fail "Claim endpoint misbehaving (bogus code returned HTTP $C, expected 404)"; fi

# 1c. Account-status endpoint reachable (missing token → 401)
A=$(curl -s -m 20 -o /dev/null -w "%{http_code}" "$PROXY/v1/account" 2>/dev/null)
if [ "$A" = "401" ]; then pass "Account-status endpoint live (no token → 401)"
else warn "Account-status endpoint returned HTTP $A (expected 401 with no token)"; fi

# 1d. Per-attorney spend vs cap (needs the admin secret)
if [ -f "$ADMIN_SECRET_FILE" ]; then
  SEC=$(tr -d '\r\n' < "$ADMIN_SECRET_FILE")
  TOK=$(curl -s -m 20 "$PROXY/admin/tokens" -H "X-Voxhora-Admin: $SEC" 2>/dev/null)
  SPEND=$(echo "$TOK" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("ERR"); sys.exit()
bad=[]; near=[]
for t in d.get("tokens",[]):
    if "env-seed" in (t.get("attorney_name") or ""): continue
    cap=t.get("monthly_cap_usd") or 0; sp=t.get("spent_this_month_usd") or 0
    nm=t.get("attorney_name") or "?"
    if cap and sp>=cap: bad.append(f"{nm} ${sp:.2f}/${cap:.0f}")
    elif cap and sp>=0.8*cap: near.append(f"{nm} ${sp:.2f}/${cap:.0f}")
print("BAD:"+";".join(bad)+"|NEAR:"+";".join(near))
' 2>/dev/null)
  if [ "$SPEND" = "ERR" ] || [ -z "$SPEND" ]; then warn "Could not read token spend (admin auth or API issue)"
  else
    BADS=$(echo "$SPEND" | sed -n 's/BAD:\(.*\)|NEAR:.*/\1/p')
    NEARS=$(echo "$SPEND" | sed -n 's/.*|NEAR:\(.*\)/\1/p')
    if [ -n "$BADS" ]; then fail "Attorney AT/OVER monthly cap (AI stopped for them): $BADS"
    elif [ -n "$NEARS" ]; then warn "Attorney approaching monthly cap (>80%): $NEARS"
    else pass "All attorneys under their monthly AI cap"; fi
  fi
else
  warn "Spend check skipped — no $ADMIN_SECRET_FILE (create it to enable: echo 'secret' > $ADMIN_SECRET_FILE && chmod 600 $ADMIN_SECRET_FILE)"
fi

# 1e. voxhora.app onboarding infra — AASA + /connect
AASA=$(curl -s -m 20 -o /dev/null -w "%{http_code}" "$SITE/.well-known/apple-app-site-association" 2>/dev/null)
if [ "$AASA" = "200" ]; then pass "AASA live (universal-link file reachable)"
else fail "AASA NOT reachable (HTTP $AASA) → setup links won't open the app"; fi
CONN=$(curl -s -m 20 -L -o /dev/null -w "%{http_code}" "$SITE/connect?code=healthcheck" 2>/dev/null)
if [ "$CONN" = "200" ]; then pass "voxhora.app/connect page reachable"
else warn "voxhora.app/connect returned HTTP $CONN"; fi

# 1f. TestFlight latest-build expiry (needs the ASC .p8). Builds lapse 90 days
#     after upload; an expired build locks external testers (e.g. Matt) out.
if [ -f "$HOME/.private_keys/AuthKey_Q462G5J3Q4.p8" ]; then
  TF=$(cd "$IOS" && TO 60 python3 tools/testflight_admin.py health 2>&1)
  echo "$TF" | sed 's/^/    /' >> "$REPORT"
  TF_EXP=$(echo "$TF"  | sed -n 's/TF_EXPIRED=//p')
  TF_DAYS=$(echo "$TF" | sed -n 's/TF_DAYS_TO_EXPIRY=//p')
  TF_BUILD=$(echo "$TF" | sed -n 's/TF_LATEST_BUILD=//p')
  if echo "$TF" | grep -q "TF_ERROR\|Traceback"; then
    warn "TestFlight check failed (ASC API): $(echo "$TF" | tail -1)"
  elif [ "$TF_EXP" = "True" ]; then
    fail "TestFlight build $TF_BUILD is EXPIRED → external testers can't install/open. Upload a fresh build now."
  elif [ -n "$TF_DAYS" ] && [ "$TF_DAYS" -le 14 ] 2>/dev/null; then
    fail "TestFlight build $TF_BUILD expires in $TF_DAYS days (<2 weeks) → refresh ASAP."
  elif [ -n "$TF_DAYS" ] && [ "$TF_DAYS" -le 30 ] 2>/dev/null; then
    warn "TestFlight build $TF_BUILD expires in $TF_DAYS days — plan a refresh soon (90-day limit)."
  elif [ -n "$TF_DAYS" ]; then
    pass "TestFlight build $TF_BUILD healthy ($TF_DAYS days to expiry)"
  else
    warn "TestFlight reachable but couldn't compute days-to-expiry"
  fi
else
  warn "TestFlight check skipped — ASC key ~/.private_keys/AuthKey_Q462G5J3Q4.p8 not found"
fi

# 1g. Discovery upload stragglers (2026-07-23, Patrick). Downloaded discovery
#     stages in ~/Library/Caches/Voxhora/DiscoveryStaging/<client>/ and must
#     reach Dropbox within hours (upload pass + orphan sweep). Anything still
#     staged after 24h means uploads are silently failing (bad filename,
#     token problem, dead network) and the Portal is missing files the
#     attorney thinks he has. 35GB of strandings accumulated invisibly over
#     2 months before this check existed.
STAGING="$HOME/Library/Caches/Voxhora/DiscoveryStaging"
if [ -d "$STAGING" ]; then
  STALE=$(find "$STAGING" -type f -mtime +1 -not -name ".DS_Store" 2>/dev/null)
  if [ -z "$STALE" ]; then
    pass "Discovery staging clean (no files older than 24h awaiting upload)"
  else
    # printf, NOT echo — staged filenames can contain literal backslashes
    # (Windows-zip artifacts) that echo would mangle into fake "clients".
    N=$(printf '%s\n' "$STALE" | grep -c .)
    SZ=$(printf '%s\n' "$STALE" | tr '\n' '\0' | xargs -0 du -ch 2>/dev/null | tail -1 | awk '{print $1}')
    CLIENTS=$(printf '%s\n' "$STALE" | sed "s|$STAGING/||" | cut -d/ -f1 | sort -u | paste -sd ', ' -)
    fail "Discovery upload stragglers: $N file(s) / $SZ staged >24h without reaching Dropbox — clients: $CLIENTS. Check the DISCOVERY_CLOUD_UPLOAD_FAILED audit rows for the error."
  fi
else
  pass "Discovery staging clean (no staging directory)"
fi

# ------------------------------------------------------------- 2. CODE GATES
say ""; say "## 2. Code gates (byte-identity / invariant tests)"
for gate in jurisdiction-golden-master custom-jurisdiction-gate travis-appellate-gate; do
  if [ -f "$IOS/tools/$gate/run.sh" ]; then
    OUT=$(cd "$IOS/tools/$gate" && TO 300 bash run.sh 2>&1); rc=$?
    if [ $rc -eq 0 ]; then pass "gate $gate: $(echo "$OUT" | tail -1)"
    else fail "gate $gate FAILED: $(echo "$OUT" | tail -3 | tr '\n' ' ')"; fi
  else warn "gate $gate not found"; fi
done

# ---------------------------------------------------------------- 3. BUILDS
# Compile-only. iOS uses a Simulator destination so no signing/devices needed.
# SKIPPED on days when no .swift / project.yml changed since the last green
# build (catches a compile regression only when there's new code to break) —
# so a normal "nothing changed" morning finishes in seconds instead of ~15 min.
say ""; say "## 3. Builds (both flag states)"
MARKER="$LOGDIR/.last-build-ok"
CHANGED=$(find "$IOS" "$MAC" \( -name '*.swift' -o -name 'project.yml' -o -name '*.entitlements' \) -newer "$MARKER" \
            -not -path '*/build-ios/*' -not -path '*/build/*' -not -path '*/build_archive/*' -not -path '*/.git/*' 2>/dev/null | head -1)
if [ -f "$MARKER" ] && [ -z "$CHANGED" ]; then
  pass "Builds skipped — no code change since the last green build ($(date -r "$MARKER" '+%b %d %H:%M'))"
else
  FAIL_BEFORE=$FAIL
  # 2026-06-10 — isolate the healthcheck builds in their OWN DerivedData, wiped
  # fresh each run, so a stale/corrupt shared cache (churned all day by
  # deploy.sh) can't cause a false linker FAIL like the 2026-06-10 06:04 flake.
  HC_DD="$LOGDIR/.dd-healthcheck"
  rm -rf "$HC_DD"
  build() { # label  workdir  xcodebuild-args...
    local label="$1"; shift; local wd="$1"; shift
    local r
    r=$(cd "$wd" && TO 1200 xcodebuild "$@" -derivedDataPath "$HC_DD" build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | tail -3)
    if echo "$r" | grep -q "BUILD SUCCEEDED"; then pass "build $label"
    else fail "build $label: $(echo "$r" | grep error: | head -2 | tr '\n' ' ')"; fi
  }
  SIM='generic/platform=iOS Simulator'
  build "Mac Debug (flags on)"   "$MAC" -project Voxhora-Mac.xcodeproj -scheme Voxhora-Mac -configuration Debug   -destination 'platform=macOS'
  build "Mac Release (flags off)" "$MAC" -project Voxhora-Mac.xcodeproj -scheme Voxhora-Mac -configuration Release -destination 'platform=macOS'
  build "iOS Debug (flags on)"   "$IOS" -project Voxhora.xcodeproj -scheme Voxhora -configuration Debug   -destination "$SIM"
  build "iOS Release (flags off)" "$IOS" -project Voxhora.xcodeproj -scheme Voxhora -configuration Release -destination "$SIM"
  # All four built clean → record the marker so tomorrow can skip if unchanged.
  [ $FAIL -eq $FAIL_BEFORE ] && touch "$MARKER"
fi

# ---------------------------------------------------------------- SUMMARY
say ""; say "==================================================================="
say "SUMMARY: $PASS passed · $WARN warnings · $FAIL FAILED"
say "==================================================================="
echo "RESULT=$([ $FAIL -eq 0 ] && echo OK || echo FAIL) PASS=$PASS WARN=$WARN FAIL=$FAIL REPORT=$REPORT"

# macOS notification with the green/red headline (works even when Claude is closed)
if [ $FAIL -eq 0 ]; then TITLE="🟢 Voxhora healthy"; else TITLE="🔴 Voxhora: $FAIL issue(s)"; fi
osascript -e "display notification \"$PASS passed · $WARN warn · $FAIL failed\" with title \"$TITLE\" subtitle \"$(date '+%b %d %-I:%M %p')\"" 2>/dev/null || true

exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
