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

# 4. Sparkle tools
for tool in sign_update generate_appcast; do
  [[ -x "$SPARKLE_TOOLS/$tool" ]] || die "Missing $SPARKLE_TOOLS/$tool — re-run Step 3."
done
done_ "Sparkle tools (sign_update, generate_appcast)"

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
done_ "CFBundleShortVersionString=$VERSION  CFBundleVersion=$BUILD"

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

# Strip the embedded development provisioning profile — irrelevant for
# Developer ID distribution and would confuse Gatekeeper.
rm -f "$APP_PATH/Contents/embedded.provisionprofile"

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
  --entitlements Voxhora-Mac/Voxhora-Mac.entitlements \
  "$APP_PATH" 2>&1 | tail -1

# Verify before notarization so we catch any seal issue locally.
codesign --verify --deep --strict "$APP_PATH" 2>&1 | tail -3 \
  || die "codesign verification failed"
done_ ".app codesigned + verified"

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
git add appcast.xml "$INFOPLIST"
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
