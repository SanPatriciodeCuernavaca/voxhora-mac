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
    if cap and sp>=cap: bad.append(f"{t.get(\"attorney_name\")} ${sp:.2f}/${cap:.0f}")
    elif cap and sp>=0.8*cap: near.append(f"{t.get(\"attorney_name\")} ${sp:.2f}/${cap:.0f}")
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

# 1f. TestFlight build status + expiry (needs the ASC .p8)
if [ -f "$HOME/.private_keys/AuthKey_Q462G5J3Q4.p8" ]; then
  TF=$(cd "$IOS" && TO 60 python3 tools/testflight_admin.py status 2>&1)
  if echo "$TF" | grep -q "Recent builds"; then
    echo "$TF" | sed 's/^/    /' >> "$REPORT"
    # latest build line (first after the header); flag if it's expired
    LATEST=$(echo "$TF" | grep -A1 "Recent builds" | tail -1)
    if echo "$LATEST" | grep -q "expired=True"; then
      fail "Latest TestFlight build is EXPIRED → external testers can't install. Upload a fresh build."
    else
      pass "TestFlight reachable; latest build not expired ($(echo "$LATEST" | sed 's/  */ /g' | cut -c1-60))"
      warn "  (Claude routine: compute days-to-expiry from the uploaded date above; TestFlight builds lapse 90 days after upload — warn if <14 left.)"
    fi
  else
    warn "TestFlight status check failed (ASC API). Output: $(echo "$TF" | tail -1)"
  fi
else
  warn "TestFlight check skipped — ASC key ~/.private_keys/AuthKey_Q462G5J3Q4.p8 not found"
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
say ""; say "## 3. Builds (both flag states)"
build() { # label  workdir  xcodebuild-args...
  local label="$1"; shift; local wd="$1"; shift
  local r
  r=$(cd "$wd" && TO 1200 xcodebuild "$@" build 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" | tail -3)
  if echo "$r" | grep -q "BUILD SUCCEEDED"; then pass "build $label"
  else fail "build $label: $(echo "$r" | grep error: | head -2 | tr '\n' ' ')"; fi
}
SIM='generic/platform=iOS Simulator'
build "Mac Debug (flags on)"   "$MAC" -project Voxhora-Mac.xcodeproj -scheme Voxhora-Mac -configuration Debug   -destination 'platform=macOS'
build "Mac Release (flags off)" "$MAC" -project Voxhora-Mac.xcodeproj -scheme Voxhora-Mac -configuration Release -destination 'platform=macOS'
build "iOS Debug (flags on)"   "$IOS" -project Voxhora.xcodeproj -scheme Voxhora -configuration Debug   -destination "$SIM"
build "iOS Release (flags off)" "$IOS" -project Voxhora.xcodeproj -scheme Voxhora -configuration Release -destination "$SIM"

# ---------------------------------------------------------------- SUMMARY
say ""; say "==================================================================="
say "SUMMARY: $PASS passed · $WARN warnings · $FAIL FAILED"
say "==================================================================="
echo "RESULT=$([ $FAIL -eq 0 ] && echo OK || echo FAIL) PASS=$PASS WARN=$WARN FAIL=$FAIL REPORT=$REPORT"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
