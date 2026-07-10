#!/usr/bin/env bash
#
# release.sh — Voxhora-Mac release pipeline
#
# Usage:
#   ./release.sh <version>            # e.g., ./release.sh 0.2.0
#
# What it does:
#   1.  Bump CFBundleShortVersionString + CFBundleVersion in Info.plist
#   2.  xcodebuild archive (Release, Developer ID Application)
#   3.  xcodebuild -exportArchive → .app
#   4.  ditto -c -k → .zip
#   5.  xcrun notarytool submit --wait  (uses keychain profile "voxhora-notarytool")
#   6.  xcrun stapler staple  → ticket inside .app
#   7.  hdiutil create  → .dmg (UDZO compressed)
#   8.  codesign --force --sign "Developer ID Application" → signed .dmg
#   9.  sign_update (Sparkle EdDSA)  → captures sparkle:edSignature + length
#  10.  gh release create  → DMG uploaded to GitHub Release
#  11.  generate_appcast  → appcast.xml regenerated
#  12.  git add appcast.xml + Info.plist; git commit; git push
#
# Pre-flight requirements (script aborts loudly if missing):
#   - Developer ID Application cert installed (Step 1)
#   - notarytool keychain profile "voxhora-notarytool" (Step 2)
#   - Sparkle EdDSA private key in macOS Keychain (Step 3)
#   - Sparkle tools at $SPARKLE_TOOLS (Step 3)
#   - gh CLI authenticated for SanPatriciodeCuernavaca/voxhora-mac
#   - Clean git working tree (no uncommitted changes)
#
# After-action: Matt's Mac (and every Voxhora-Mac user's Mac) checks
# the appcast URL within 24h, sees the new version, downloads the
# DMG, verifies Apple notarization + Sparkle EdDSA, applies the
# update silently on next launch.
#

set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────
SPARKLE_TOOLS="/Users/patrickfagerberg/Documents/Documents - patrick’s MacBook Air/Voxhora_Backups/sparkle-tools"
NOTARY_PROFILE="voxhora-notarytool"
SIGNING_IDENTITY="Developer ID Application: Richard Patrick Fagerberg (S4GM27H6N5)"
DEV_ID_TEAM="S4GM27H6N5"
# Developer ID Direct provisioning profile (gitignored). As of macOS 26.4+,
# AMFI refuses to launch a direct-codesigned Mac app carrying RESTRICTED
# entitlements (iCloud / app-groups / aps-environment / keychain-access-
# groups) UNLESS a provisioning profile is embedded. We copy this into
# Contents/embedded.provisionprofile before the final codesign so the seal
# covers it. Create it at developer.apple.com → Profiles → Developer ID
# (type "Direct") for the Voxhora-Mac App ID, download, and save here.
PROVISION_PROFILE="profiles/voxhora-mac.provisionprofile"
SCHEME="Voxhora-Mac"
PROJECT="Voxhora-Mac.xcodeproj"
INFOPLIST="Voxhora-Mac/Info.plist"
RELEASES_DIR="releases"
REPO_OWNER="SanPatriciodeCuernavaca"
REPO_NAME="voxhora-mac"
APPCAST_URL_PREFIX="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download"

# ─── HELPERS ───────────────────────────────────────────────────────────
say()  { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
done_() { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ─── ARGS ──────────────────────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  die "Usage: ./release.sh <version>   e.g.,  ./release.sh 0.2.0"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "Version must be semver-shaped (X.Y.Z), got: $VERSION"
fi

# ─── PRE-FLIGHT ────────────────────────────────────────────────────────
say "Pre-flight checks…"

cd "$(dirname "$0")"
[[ -f "$INFOPLIST" ]] || die "Run from voxhora-mac repo root. Missing $INFOPLIST."

# 1. Clean working tree
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  die "Working tree dirty. Commit or stash before releasing."
fi
done_ "Git working tree clean"

# 2. Developer ID cert
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
  die "Developer ID Application cert not in keychain. Re-run Step 1 of Sparkle setup."
fi
done_ "Developer ID Application cert present"

# 3. notarytool keychain profile — `history` returns exit-0 with either
# a submission list OR "No submission history" if the profile is valid;
# any other failure means the profile is missing/corrupted.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "notarytool profile '$NOTARY_PROFILE' missing or invalid. Re-run Step 2 of Sparkle setup."
fi
done_ "Notarization profile '$NOTARY_PROFILE' present"

# 4. Developer ID Direct provisioning profile (macOS 26.4+ AMFI requirement
# for restricted entitlements). Fail fast HERE — before the long archive —
# rather than producing a build that won't launch on the target Mac.
if [ ! -f "$PROVISION_PROFILE" ]; then
  die "Provisioning profile not found at '$PROVISION_PROFILE'.
       Create a Developer ID (Direct) profile for the Voxhora-Mac App ID at
       developer.apple.com → Certificates, IDs & Profiles → Profiles, download
       it, and save it to that path. Without it the signed build will not
       launch on macOS 26.4+ (AMFI rejects restricted entitlements without an
       embedded profile)."
fi
# Sanity-check the profile actually belongs to this team — a profile from the
# wrong team embeds cleanly but AMFI still rejects it at launch.
if ! security cms -D -i "$PROVISION_PROFILE" 2>/dev/null | grep -q "$DEV_ID_TEAM"; then
  die "Profile '$PROVISION_PROFILE' does not reference team $DEV_ID_TEAM.
       Re-download the Developer ID (Direct) profile for the correct team."
fi
done_ "Developer ID Direct provisioning profile present (team $DEV_ID_TEAM)"

# 4. Sparkle tools
for tool in sign_update generate_appcast; do
  [[ -x "$SPARKLE_TOOLS/$tool" ]] || die "Missing $SPARKLE_TOOLS/$tool — re-run Step 3."
done
done_ "Sparkle tools (sign_update, generate_appcast)"

# 4b. VoxHelp knowledge freshness — VoxHelp answers from the bundled USER
# MANUAL + slim architecture summary, NOT the full architecture JSON. If the
# JSON has newer commits than either of those two, the in-app assistant would
# ship answering from a stale picture of the app (the exact failure found
# 2026-07-10: the 07-09 "bundle refresh" updated only the JSON while the two
# files actually in VoxHelp's prompt sat a month behind). Update the manual +
# summary — or, if the JSON change truly had no user-facing impact, override
# once with VOXHELP_STALE_OK=1 ./release.sh <version>.
IOS_REPO="../voxhora-ios"
VOXHELP_JSON_TS="$(git -C "$IOS_REPO" log -1 --format=%ct -- Voxhora/Resources/VoxhoraArchitecture.json 2>/dev/null || echo 0)"
VOXHELP_MANUAL_TS="$(git -C "$IOS_REPO" log -1 --format=%ct -- Voxhora/Resources/VoxhoraUserManual.md 2>/dev/null || echo 0)"
VOXHELP_SUMMARY_TS="$(git -C "$IOS_REPO" log -1 --format=%ct -- Voxhora/Resources/VoxhoraArchitectureSummary.md 2>/dev/null || echo 0)"
if [[ "${VOXHELP_STALE_OK:-0}" != "1" ]] && { [[ "$VOXHELP_MANUAL_TS" -lt "$VOXHELP_JSON_TS" ]] || [[ "$VOXHELP_SUMMARY_TS" -lt "$VOXHELP_JSON_TS" ]]; }; then
  die "VoxHelp knowledge is STALE: VoxhoraArchitecture.json has commits newer than
       VoxhoraUserManual.md and/or VoxhoraArchitectureSummary.md (the files VoxHelp
       actually answers from). Refresh those two in voxhora-ios, commit, then release.
       Truly no user-facing change? Override once: VOXHELP_STALE_OK=1 ./release.sh $VERSION"
fi
done_ "VoxHelp knowledge sources fresh (manual + summary ≥ architecture JSON)"

# 5. gh CLI authenticated for our repo
if ! gh auth status >/dev/null 2>&1; then
  die "gh CLI not authenticated. Run: gh auth login"
fi
done_ "gh CLI authenticated"

# 6. Branch == main
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "Releases cut from main only (currently on '$BRANCH')."
done_ "On main branch"

# ─── VERSION BUMP ──────────────────────────────────────────────────────
say "Bumping version → $VERSION"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFOPLIST")"
BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFOPLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$INFOPLIST"
# HARD RULE 2026-05-21 — also bump project.yml's pinned version so
# the next xcodegen regen doesn't roll back the shipped values.
# project.yml is the canonical xcodegen source; Info.plist is its
# regenerated output. Both must move together. See:
#   ~/.claude/projects/.../memory/feedback_mac_version_pinned_in_projectyml.md
PROJECT_YML="project.yml"
[[ -f "$PROJECT_YML" ]] || die "Missing $PROJECT_YML — must run from voxhora-mac repo root."
/usr/bin/sed -i '' "s/^        CFBundleShortVersionString: \".*\"$/        CFBundleShortVersionString: \"$VERSION\"/" "$PROJECT_YML"
/usr/bin/sed -i '' "s/^        CFBundleVersion: \"[0-9]*\"$/        CFBundleVersion: \"$BUILD\"/" "$PROJECT_YML"
done_ "CFBundleShortVersionString=$VERSION  CFBundleVersion=$BUILD (Info.plist + project.yml)"

# Regenerate the Xcode project from project.yml so the GENERATED
# Info.plists (main app AND the Share appex) re-emit the bumped version.
# Without this step the appex archives with whatever Info.plist was on
# disk from the last manual regen — the recurring stale-appex bug
# (0.2.49 appex shipped inside the 0.2.51 app; root-caused in the
# 2026-07-02 codebase analysis). release_ios.sh has always done this,
# which is why iOS versions never skew.
command -v xcodegen >/dev/null 2>&1 || die "xcodegen not installed (brew install xcodegen)"
xcodegen generate >/dev/null
done_ "xcodegen regenerated project — app + Share appex Info.plists now $VERSION/$BUILD"

# ─── ARCHIVE ───────────────────────────────────────────────────────────
say "Archiving Release build…"
# Standard 2-stage Apple Developer ID pattern:
#   ARCHIVE  with Automatic signing (Apple Development cert; project default).
#            This satisfies Xcode's "iCloud + Push Notifications need a
#            provisioning profile" check via the existing auto-managed
#            development profile.
#   EXPORT   with method=developer-id in ExportOptions.plist below — this
#            re-signs the .app with the Developer ID Application cert,
#            stripping the development provisioning profile in the process.
# Forcing CODE_SIGN_STYLE=Manual at archive time without an explicit
# Developer ID provisioning profile fails archive — that's why we let
# Automatic signing handle this phase.
BUILD_DIR="/tmp/voxhora-mac-release"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ARCHIVE_PATH="$BUILD_DIR/Voxhora-Mac.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  -quiet \
  || die "xcodebuild archive FAILED"
done_ "Archive at $ARCHIVE_PATH"

# ─── EXTRACT + DIRECT CODESIGN ─────────────────────────────────────────
# xcodebuild -exportArchive with method=developer-id requires either a
# pre-existing Developer ID provisioning profile (manual portal step) OR
# a working Xcode auth to developer.apple.com (which can break transiently).
# Both routes have failure modes outside our control. Instead, copy the
# .app out of the archive and codesign each nested binary directly with
# Developer ID + Hardened Runtime. This is the canonical recipe Sparkle's
# own docs describe.
say "Extracting .app from archive + direct Developer ID codesign…"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/Voxhora-Mac.app" "$EXPORT_DIR/"
APP_PATH="$EXPORT_DIR/Voxhora-Mac.app"

# Embed the Developer ID Direct provisioning profile. As of macOS 26.4+,
# AMFI rejects a direct-codesigned app with restricted entitlements unless a
# profile is embedded (supersedes the pre-2026-05-27 "strip the profile"
# step, which produced builds that wouldn't launch). xcodebuild's export may
# have left a development profile here — overwrite it with the Dev ID Direct
# one. This MUST happen BEFORE the inside-out codesign below so the main
# app's signature seals the embedded profile.
cp "$PROVISION_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
done_ "Embedded Developer ID Direct provisioning profile"

# Clean .cstemp leftovers from any previous interrupted codesign attempts.
find "$APP_PATH" -name "*.cstemp" -delete 2>/dev/null || true

# Inside-out codesign order (Sparkle Hardened Runtime recipe):
#   1. Sparkle XPC services (Downloader.xpc, Installer.xpc)
#   2. Updater.app inner binary
#   3. Updater.app wrapper
#   4. Autoupdate helper
#   5. Sparkle.framework
#   6. Voxhora-Mac-Share.appex (with its own entitlements)
#   7. Voxhora-Mac.app (top-level, with its own entitlements)
SPARKLE_VER="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_VER/XPCServices/Downloader.xpc" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_VER/XPCServices/Installer.xpc" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_VER/Updater.app/Contents/MacOS/Updater" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_VER/Updater.app" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  "$SPARKLE_VER/Autoupdate" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  "$APP_PATH/Contents/Frameworks/Sparkle.framework" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  --entitlements Voxhora-Mac-Share/Voxhora-Mac-Share.entitlements \
  "$APP_PATH/Contents/PlugIns/Voxhora-Mac-Share.appex" 2>&1 | tail -1
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
  --entitlements Voxhora-Mac/Voxhora-Mac-Release.entitlements \
  "$APP_PATH" 2>&1 | tail -1

# Verify before notarization so we catch any seal issue locally.
codesign --verify --deep --strict "$APP_PATH" 2>&1 | tail -3 \
  || die "codesign verification failed"
# AMFI launch guard (2026-05-29): the signed main app MUST carry
# com.apple.application-identifier, or macOS 26.4+ AMFI can't bind the embedded
# provisioning profile → restricted entitlements (keychain-access-groups) go
# unauthorized → SIGKILL at launch. Catch a regression here, not on the user's Mac.
codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | grep -q "application-identifier" \
  || die "Main app entitlements missing com.apple.application-identifier — AMFI will SIGKILL at launch. Fix Voxhora-Mac/Voxhora-Mac.entitlements."
done_ ".app codesigned + verified (+ application-identifier present)"

# Notary pre-flight (2026-07-09) — replicate Apple's recursive descent
# into every nested archive (tar.gz → tar → whl/zip, the embedded
# TechShare agent kit) and assert each nested Mach-O is Developer-ID
# signed + timestamped + hardened, LOCALLY. Catches a kit-signing
# regression in seconds instead of after a 10-15 min notary round trip
# (that saga is why this gate exists).
say "Notary pre-flight (recursive nested-Mach-O audit)…"
"$(dirname "$0")/scripts/notary_preflight.sh" "$APP_PATH" \
  || die "Notary pre-flight failed — a nested Mach-O would be rejected. Re-run scripts/bundle_techshare_agent.sh (kit signing) before releasing."

# ─── NOTARIZE ──────────────────────────────────────────────────────────
say "Submitting to Apple notarization (typically 2–5 min)…"
ZIP_PATH="$BUILD_DIR/Voxhora-Mac.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Network-resilient submit: don't use --wait (its long-poll fails on transient
# network blips and loses the submission). Instead, submit, capture the ID,
# then poll separately with short queries that survive blips.
SUBMIT_OUTPUT="$(xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json 2>&1)"
SUBMISSION_ID="$(echo "$SUBMIT_OUTPUT" | grep -oE '"id":"[a-f0-9-]+"' | head -1 | cut -d'"' -f4)"
[[ -n "$SUBMISSION_ID" ]] || { echo "$SUBMIT_OUTPUT"; die "Notarization submit failed"; }
echo "  submission id: $SUBMISSION_ID"

# Poll every 30s until final state. notarytool info is a short HTTP call
# (~1s) so transient network blips lose only that single poll — the next
# poll picks up where we left off. Total wait is unaffected.
until current_status="$(xcrun notarytool info "$SUBMISSION_ID" \
  --keychain-profile "$NOTARY_PROFILE" 2>/dev/null \
  | grep -E '^\s*status:' | awk '{print $2}')" \
  && [[ "$current_status" =~ ^(Accepted|Invalid|Rejected)$ ]]; do
  printf "  %s  status: %s\n" "$(date '+%H:%M:%S')" "${current_status:-network-blip-retrying}"
  sleep 30
done

if [[ "$current_status" != "Accepted" ]]; then
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -40
  die "Notarization $current_status — see log above."
fi
done_ "Notarization Accepted"

say "Stapling notarization ticket…"
xcrun stapler staple "$APP_PATH" || die "stapler failed"
done_ "Ticket stapled"

# ─── DMG ───────────────────────────────────────────────────────────────
say "Building DMG…"
mkdir -p "$RELEASES_DIR"
DMG_NAME="Voxhora-Mac-$VERSION.dmg"
DMG_PATH="$RELEASES_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

# Build a temp folder so the DMG has a clean Applications shortcut.
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "Voxhora-Mac $VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

done_ "DMG built at $DMG_PATH"

say "Code-signing DMG with Developer ID…"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
done_ "DMG signed"

# ─── SPARKLE EDDSA SIGNATURE ───────────────────────────────────────────
say "Signing DMG with Sparkle EdDSA (for appcast)…"
SPARKLE_SIG_RAW="$("$SPARKLE_TOOLS/sign_update" "$DMG_PATH")"
echo "  $SPARKLE_SIG_RAW"
done_ "EdDSA signature captured"

# ─── GITHUB RELEASE ────────────────────────────────────────────────────
say "Creating GitHub Release v$VERSION…"
RELEASE_TAG="v$VERSION"
RELEASE_NOTES="Voxhora-Mac $VERSION (build $BUILD). Auto-updates via Sparkle."

gh release create "$RELEASE_TAG" \
  --repo "$REPO_OWNER/$REPO_NAME" \
  --title "Voxhora-Mac $VERSION" \
  --notes "$RELEASE_NOTES" \
  "$DMG_PATH" \
  || die "gh release create FAILED"
done_ "GitHub Release published"

# ─── APPCAST ───────────────────────────────────────────────────────────
say "Regenerating appcast.xml…"
"$SPARKLE_TOOLS/generate_appcast" \
  --download-url-prefix "$APPCAST_URL_PREFIX/$RELEASE_TAG/" \
  --maximum-deltas 0 \
  "$RELEASES_DIR" \
  || die "generate_appcast FAILED"

# generate_appcast writes appcast.xml INTO $RELEASES_DIR. Promote to repo root.
mv "$RELEASES_DIR/appcast.xml" appcast.xml
done_ "appcast.xml at repo root"

# ─── COMMIT + PUSH ─────────────────────────────────────────────────────
say "Committing version bump + appcast.xml…"
# Voxhora-Mac-Share/Info.plist is regenerated by the xcodegen step above
# (2026-07-02 stale-appex fix) — commit it too or every release leaves a
# dirty tree.
git add appcast.xml "$INFOPLIST" "$PROJECT_YML" Voxhora-Mac-Share/Info.plist
git commit -m "Release Voxhora-Mac $VERSION (build $BUILD)" \
  -m "Auto-generated by release.sh: bumped Info.plist version + regenerated appcast.xml after GitHub Release $RELEASE_TAG."
git push
done_ "Pushed to main"

# ─── SUMMARY ───────────────────────────────────────────────────────────
say "🚀  Released Voxhora-Mac $VERSION (build $BUILD)"
printf "  DMG:      %s\n" "$DMG_PATH"
printf "  Release:  https://github.com/%s/%s/releases/tag/%s\n" "$REPO_OWNER" "$REPO_NAME" "$RELEASE_TAG"
printf "  Appcast:  https://raw.githubusercontent.com/%s/%s/main/appcast.xml\n" "$REPO_OWNER" "$REPO_NAME"
printf "\n  Matt's Mac auto-checks within 24h. To force immediate check on any\n"
printf "  installed Voxhora-Mac, open the app menu → Check for Updates…\n\n"
