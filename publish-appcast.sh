#!/usr/bin/env bash
#
# publish-appcast.sh — finish a HOLD_APPCAST release: publish the Sparkle feed,
# which is the moment EXISTING users (Matt) begin updating.
# Split out 2026-08-07 so a build can reach new attorneys immediately while
# existing users wait out the 24h soak.
#
# REWRITTEN 2026-08-08 for the voxhora.app feed migration. What changed and why:
#
#   1. The DMG is served from voxhora.app, NOT from GitHub Releases. The old
#      prefix pointed into voxhora-mac, the repo that is going private; a
#      private repo returns 404 to an unauthenticated Sparkle, so every
#      enclosure would have died the moment the repo flipped — silently, since
#      background update checks surface no error to the user.
#
#   2. The feed is published to voxhora-public FIRST and VERIFIED before the
#      old GitHub feed is touched. The old feed is what Matt's 0.2.84 still
#      polls, so it must never be pointed at something unreachable. Publish
#      the new home, prove it works, and only then redirect the old one.
#
#   3. The feed carries ONE item (the release being published), not every DMG
#      in releases/. generate_appcast stamps a single --download-url-prefix
#      onto every archive it scans, which is why the live feed's 0.2.83 and
#      0.2.82 entries pointed at the v0.2.84 tag and had been 404 for days.
#      Listing only what we actually host makes that class of bug impossible.
#      Sparkle only ever offers the newest applicable item, so nothing is lost.
#
#   4. Both feed locations serve the SAME bytes. Installs on 0.2.87+ poll
#      voxhora.app; anything older still polls the GitHub URL, which is kept
#      alive by a public shell repo containing nothing but appcast.xml. Old
#      installs therefore migrate on their own schedule instead of being
#      stranded by a deadline they never knew about.
#
# Usage: ./publish-appcast.sh v0.2.87
#
set -euo pipefail

SPARKLE_TOOLS="/Users/patrickfagerberg/Documents/Documents - patrick’s MacBook Air/Voxhora_Backups/sparkle-tools"
RELEASES_DIR="releases"
PUBLIC_REPO="/Users/patrickfagerberg/voxhora-public"
REPO_OWNER="SanPatriciodeCuernavaca"
REPO_NAME="voxhora-mac"

# Where the DMG actually lives now. Trailing slash is REQUIRED: generate_appcast
# builds each URL as prefix + basename, so dropping it yields
# ".../downloadsVoxhora-Mac.dmg".
DOWNLOAD_PREFIX="https://voxhora.app/downloads/"
NEW_FEED="https://voxhora.app/appcast.xml"
OLD_FEED="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/appcast.xml"

# TWO filenames, deliberately, because they have opposite requirements:
#
#   Voxhora-Mac-<version>.dmg  — what Sparkle's enclosure points at. MUST be
#     immutable. The feed commits to an exact length + EdDSA signature, so if
#     the bytes behind that URL ever change the download fails. A single stable
#     name looks tidy and is a trap: HOLD_APPCAST mode publishes a new DMG for
#     new installs while the previous feed is still live, which would overwrite
#     the file the live feed describes and break updates for everyone.
#
#   Voxhora-Mac.dmg  — what the website button hands a human. Overwritten every
#     release on purpose; no signature is involved in a person clicking Download.
#
# Cost: ~117 MB per release in voxhora-public git history, which is unreclaimable
# without a history rewrite. To keep the PUBLISHED site (hard 1 GB Pages limit)
# small, this script deletes superseded versioned DMGs from the working tree.
# History growth still needs a real answer within a few weeks — see the handoff.
DMG_STABLE="Voxhora-Mac.dmg"
# DMG_VERSIONED is set after TAG is parsed, below.

die(){ printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
say(){ printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok(){  printf "  \033[1;32m✓\033[0m %s\n" "$*"; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: ./publish-appcast.sh <release-tag>   e.g. ./publish-appcast.sh v0.2.87"
VERSION="${TAG#v}"
DMG_VERSIONED="Voxhora-Mac-${VERSION}.dmg"

[ -d "$PUBLIC_REPO" ] || die "voxhora-public checkout not found at $PUBLIC_REPO"
[ -x "$SPARKLE_TOOLS/generate_appcast" ] || die "generate_appcast not found at $SPARKLE_TOOLS"

DMG_SRC="$RELEASES_DIR/Voxhora-Mac-${VERSION}.dmg"
[ -f "$DMG_SRC" ] || die "No DMG for $VERSION at $DMG_SRC — run ./release.sh $VERSION first."

# ─── 1. BUILD A ONE-ITEM FEED ──────────────────────────────────────────
say "Generating appcast for $VERSION (single item, voxhora.app enclosure)…"
STAGE="$(mktemp -d -t voxappcast)"
trap 'rm -rf "$STAGE"' EXIT
# generate_appcast builds each URL as prefix + basename, so the staged filename
# IS the published filename. Stage it under the immutable versioned name.
cp "$DMG_SRC" "$STAGE/$DMG_VERSIONED"

"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-deltas 0 \
  "$STAGE" || die "generate_appcast FAILED"

[ -f "$STAGE/appcast.xml" ] || die "generate_appcast produced no appcast.xml"

# Prove the generated feed says what we think before anything is published.
#
# 2026-08-08: the version was read as an ATTRIBUTE (shortVersionString="…").
# generate_appcast emits it as an ELEMENT:
#     <sparkle:shortVersionString>0.2.89</sparkle:shortVersionString>
# so grep matched nothing, exited 1, and `set -e` killed the script on the
# assignment — printing NOTHING. The run looked like it just stopped. The
# ordering saved us (neither feed had been touched yet), but a publish script
# that dies silently is exactly the kind of instrument that gets trusted while
# doing nothing. `|| true` keeps extraction failures from being fatal so the
# explicit checks below can report them in words.
GEN_URL=$(sed -n 's/.*<enclosure[^>]* url="\([^"]*\)".*/\1/p' "$STAGE/appcast.xml" | head -1 || true)
GEN_VER=$(sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*|\1|p' "$STAGE/appcast.xml" | head -1 || true)
[ -n "$GEN_URL" ] || die "generated appcast has no enclosure URL (parser out of step with generate_appcast's output?)"
[ -n "$GEN_VER" ] || die "could not read the version out of the generated appcast (parser out of step with generate_appcast's output?)"
case "$GEN_URL" in
  "${DOWNLOAD_PREFIX}${DMG_VERSIONED}") ok "enclosure URL: $GEN_URL" ;;
  *) die "enclosure URL is wrong: $GEN_URL (expected ${DOWNLOAD_PREFIX}${DMG_VERSIONED})" ;;
esac
[ "$GEN_VER" = "$VERSION" ] || die "generated appcast advertises $GEN_VER, expected $VERSION"
ok "advertised version: $GEN_VER"

# ─── 2. PUBLISH THE NEW HOME FIRST ─────────────────────────────────────
say "Publishing DMG + feed to voxhora-public (voxhora.app)…"
cp "$DMG_SRC"           "$PUBLIC_REPO/downloads/$DMG_VERSIONED"   # Sparkle (immutable)
cp "$DMG_SRC"           "$PUBLIC_REPO/downloads/$DMG_STABLE"      # website button
cp "$STAGE/appcast.xml" "$PUBLIC_REPO/appcast.xml"

# Drop superseded versioned DMGs from the working tree. GitHub Pages enforces a
# hard 1 GB limit on the PUBLISHED site, and at ~58 MB a build that arrives in
# weeks. Only the version the live feed advertises needs to remain fetchable —
# older entries are not in the feed, so nothing can request them. (This does not
# shrink git history; that needs a deliberate rewrite.)
for old in "$PUBLIC_REPO"/downloads/Voxhora-Mac-*.dmg; do
  [ -e "$old" ] || continue
  if [ "$(basename "$old")" != "$DMG_VERSIONED" ]; then
    git -C "$PUBLIC_REPO" rm -q --ignore-unmatch "downloads/$(basename "$old")" || rm -f "$old"
    ok "pruned superseded $(basename "$old") from the published site"
  fi
done

git -C "$PUBLIC_REPO" add "downloads/$DMG_VERSIONED" "downloads/$DMG_STABLE" appcast.xml
if git -C "$PUBLIC_REPO" diff --cached --quiet; then
  ok "voxhora-public already current"
else
  git -C "$PUBLIC_REPO" commit -q -m "Serve $VERSION: Sparkle feed + Mac download on voxhora.app" \
    -m "Feed moved off raw.githubusercontent so voxhora-mac can go private. Enclosure points at voxhora.app/downloads/."
  git -C "$PUBLIC_REPO" push -q
  ok "pushed voxhora-public"
fi

# ─── 3. VERIFY THE NEW HOME BEFORE REDIRECTING THE OLD ONE ─────────────
# GitHub Pages takes a moment to rebuild. Do NOT touch the old feed until the
# new one demonstrably serves the right version AND a fetchable DMG: the old
# feed is what every existing install is reading right now.
say "Waiting for GitHub Pages to serve $VERSION at $NEW_FEED …"
PAGES_OK=0
for i in $(seq 1 40); do
  # Same element-vs-attribute fix as above. A wrong pattern here would never
  # match, so this loop would spin its full 10 minutes and then abort claiming
  # Pages never served the version — while Pages was serving it correctly.
  LIVE=$(curl -sS -L -m 30 "$NEW_FEED" 2>/dev/null | sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*|\1|p' | head -1 || true)
  if [ "$LIVE" = "$VERSION" ]; then PAGES_OK=1; break; fi
  printf "  … not live yet (attempt %s/40, saw '%s')\n" "$i" "${LIVE:-nothing}"
  sleep 15
done
[ "$PAGES_OK" = "1" ] || die "voxhora.app/appcast.xml never served $VERSION. OLD FEED UNTOUCHED — existing users are unaffected. Investigate before retrying."
ok "voxhora.app/appcast.xml serves $VERSION"

say "Verifying every enclosure in the new feed is actually fetchable…"
./tools/check_appcast.sh "$NEW_FEED" || die "New feed has an unreachable DMG. OLD FEED UNTOUCHED. Fix before retrying."

# ─── 4. NOW REDIRECT THE OLD FEED ──────────────────────────────────────
# This is the moment existing users begin updating.
say "Publishing the same feed to the OLD GitHub URL (existing users update now)…"
cp "$STAGE/appcast.xml" appcast.xml
git add appcast.xml
if git diff --cached --quiet; then
  ok "old feed already current"
else
  git commit -q -m "Publish appcast for $TAG — existing users now update" \
    -m "Same bytes as voxhora.app/appcast.xml; enclosure points at voxhora.app so this keeps working after voxhora-mac goes private."
  git push -q
  ok "pushed voxhora-mac"
fi

say "Verifying the old feed too…"
# raw.githubusercontent serves `cache-control: max-age=300`. The first version
# of this waited 5 SECONDS against that 5-MINUTE cache, so it reported the old
# feed broken on a publish that had in fact succeeded — the push had landed and
# the repo already contained the new appcast. Poll until the CDN catches up
# rather than accusing a good release.
OLD_OK=0
for i in $(seq 1 30); do
  LIVEOLD=$(curl -sS -L -m 30 "$OLD_FEED" 2>/dev/null \
    | sed -n 's|.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*|\1|p' | head -1 || true)
  if [ "$LIVEOLD" = "$VERSION" ]; then OLD_OK=1; break; fi
  printf "  … CDN still caching (attempt %s/30, serving '%s')\n" "$i" "${LIVEOLD:-nothing}"
  sleep 20
done
[ "$OLD_OK" = "1" ] || die "Old feed still not serving $VERSION after 10 minutes. The commit may have landed — check the repo before re-running."
./tools/check_appcast.sh "$OLD_FEED" || die "Old feed serves $VERSION but an enclosure is unreachable — existing users would see an update they cannot install."

printf "\n\033[1;32m🚀 %s published on BOTH feeds.\033[0m\n" "$VERSION"
printf "  new: %s\n" "$NEW_FEED"
printf "  old: %s\n" "$OLD_FEED"
printf "\n\033[1;33m  NOT DONE YET: an update is not delivered until someone confirms it.\n"
printf "  Sparkle checks roughly every 24h and only while the app is running,\n"
printf "  and there is no telemetry anywhere that can tell you it landed.\n"
printf "  Ask Matt to read the version from Voxhora → About before you rely on it.\033[0m\n\n"
