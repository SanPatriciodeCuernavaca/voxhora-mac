#!/usr/bin/env bash
#
# check_appcast.sh — is the Sparkle update feed actually serving installable
# updates?
#
# Written 2026-08-08, during the voxhora.app feed migration. Until now NOTHING
# watched this path: the healthcheck covered the proxy, AASA, /connect and
# TestFlight expiry, but never the appcast. That gap is why two of the three
# feed entries (0.2.83, 0.2.82) had been dead 404s for days with nobody
# noticing — Sparkle's BACKGROUND checks swallow network errors silently, so a
# broken feed produces no dialog, no badge, and no log an attorney would see.
#
# It checks the two things that must BOTH be true for an update to land:
#   1. the feed itself resolves and parses, and
#   2. every <enclosure url> in it is actually fetchable.
# A feed that parses perfectly while pointing at dead DMGs looks green from
# Patrick's seat and delivers nothing.
#
# Usage:
#   ./check_appcast.sh                 # the URL baked into the shipped Info.plist
#   ./check_appcast.sh <feed-url>      # an explicit feed (post-migration checks)
#   ./check_appcast.sh --self-test     # prove the probe can detect failure
#
# Exit: 0 all good · 1 feed or an enclosure is broken · 2 self-test failed.
#
# Enclosures are probed with a 1-byte Range request, not a full GET: these are
# ~58 MB DMGs and a daily healthcheck must not pull 170 MB. Servers that ignore
# Range simply return 200 and we accept that too.
#
# bash-3.2 safe (macOS system bash).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INFOPLIST="$HERE/../Voxhora-Mac/Info.plist"

red()   { printf '\033[1;31m%s\033[0m\n' "$1"; }
green() { printf '\033[1;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

# Resolve the feed URL the SHIPPED app actually polls, so this probe can never
# drift from the binary's real behaviour by testing a URL nobody uses.
feed_from_plist() {
  /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFOPLIST" 2>/dev/null
}

# HTTP status for a URL, following redirects, without downloading the payload.
http_status() {
  curl -sS -L -m 45 -o /dev/null -w '%{http_code}' -r 0-0 "$1" 2>/dev/null || echo "000"
}

check_feed() {
  FEED="$1"
  echo "feed: $FEED"

  BODY=$(curl -sS -L -m 45 "$FEED" 2>/dev/null)
  case "$FEED" in
    # file:// is only ever used by --self-test, which needs to reach the
    # ENCLOSURE check. curl reports http_code 000 for file://, which would
    # abort at the feed stage and let the self-test "pass" without ever
    # exercising the code path it claims to test.
    file://*) CODE=$([ -n "$BODY" ] && echo 200 || echo 000) ;;
    *)        CODE=$(curl -sS -L -m 45 -o /dev/null -w '%{http_code}' "$FEED" 2>/dev/null || echo "000") ;;
  esac

  if [ "$CODE" != "200" ]; then
    red "  FEED UNREACHABLE — HTTP $CODE"
    red "  Every existing install has silently stopped receiving updates."
    return 1
  fi

  # Parse with a real XML parser; a feed that 200s with an HTML error page or
  # truncated XML is exactly the failure this is here to catch.
  PARSED=$(printf '%s' "$BODY" | python3 -c '
import sys, xml.etree.ElementTree as ET
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
try:
    root = ET.fromstring(sys.stdin.read())
except Exception as e:
    print("PARSE_ERROR|%s" % e); sys.exit(0)
items = root.findall("./channel/item")
if not items:
    print("NO_ITEMS|feed parsed but advertises zero versions"); sys.exit(0)
for it in items:
    ver = (it.findtext("title") or "?").strip()
    enc = it.find("enclosure")
    url = enc.get("url") if enc is not None else ""
    sv  = enc.get(SP + "shortVersionString") if enc is not None else ""
    print("ITEM|%s|%s|%s" % (ver, sv or "", url))
' 2>/dev/null)

  case "$PARSED" in
    PARSE_ERROR*) red "  FEED IS NOT VALID XML — ${PARSED#PARSE_ERROR|}"; return 1 ;;
    NO_ITEMS*)    red "  FEED HAS NO VERSIONS — ${PARSED#NO_ITEMS|}";     return 1 ;;
    "")           red "  FEED PARSE PRODUCED NOTHING (python3 missing?)";  return 1 ;;
  esac

  BAD=0; N=0; NEWEST=""
  while IFS='|' read -r tag ver sv url; do
    [ "$tag" = "ITEM" ] || continue
    N=$((N+1))
    [ -n "$NEWEST" ] || NEWEST="$ver"
    S=$(http_status "$url")
    case "$S" in
      200|206) dim  "  ok    $ver  ($S)  $url" ;;
      *)       red  "  DEAD  $ver  (HTTP $S)  $url"; BAD=$((BAD+1)) ;;
    esac
  done <<EOF
$PARSED
EOF

  echo "  newest advertised: $NEWEST   entries: $N   dead: $BAD"
  if [ "$BAD" -gt 0 ]; then
    red "  $BAD of $N enclosure(s) unreachable — those versions cannot install."
    return 1
  fi
  green "  feed healthy — all $N enclosure(s) fetchable"
  return 0
}

# --- self-test -------------------------------------------------------------
# Patrick's standing rule: a probe is not believed until it has fired on a
# known-positive AND stayed quiet on a known-negative. A checker that only
# ever returns "fine" is indistinguishable from one that is broken.
if [ "${1:-}" = "--self-test" ]; then
  echo "=== self-test: the probe must FAIL on a feed that does not exist ==="
  if check_feed "https://voxhora.app/definitely-not-a-real-appcast.xml" >/dev/null 2>&1; then
    red "SELF-TEST FAILED: probe passed a nonexistent feed."; exit 2
  fi
  green "  known-negative: correctly rejected a missing feed"

  echo "=== self-test: the probe must FAIL on a feed with a dead enclosure ==="
  TMP=$(mktemp -t appcastselftest)
  cat > "$TMP" <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
 <channel><title>t</title><item><title>9.9.9</title>
 <enclosure url="https://voxhora.app/downloads/this-dmg-does-not-exist.dmg" length="1" type="application/octet-stream"/>
 </item></channel></rss>
XML
  if check_feed "file://$TMP" >/dev/null 2>&1; then
    red "SELF-TEST FAILED: probe passed a feed whose DMG is missing."; rm -f "$TMP"; exit 2
  fi
  green "  known-negative: correctly rejected a dead enclosure"
  rm -f "$TMP"
  echo "=== self-test: the probe must PASS the live production feed ==="
  if check_feed "$(feed_from_plist)"; then
    green "SELF-TEST PASSED (fires on failure, quiet on health)"; exit 0
  fi
  red "SELF-TEST: live feed is currently BROKEN (or the probe is wrong) — see above."
  exit 2
fi

FEED="${1:-$(feed_from_plist)}"
if [ -z "$FEED" ]; then
  red "No feed URL: could not read SUFeedURL from $INFOPLIST"; exit 1
fi
check_feed "$FEED"
