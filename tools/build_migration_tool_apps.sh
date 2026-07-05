#!/usr/bin/env bash
#
# build_migration_tool_apps.sh — Phase 0 of the Matt→Production migration
# (Runbooks/Voxhora - RUNBOOK - Migrate Matt to Production 2026-06-15.md).
#
# Builds the TWO hand-installed tool apps from ONE Release archive:
#
#   EXPORT app — Development CloudKit env + VOXHORA_MIGRATION tool.
#                Installed on Matt's Mac first; exports his Development
#                data to a .voxbackup.
#   IMPORT app — Production CloudKit env + VOXHORA_MIGRATION tool.
#                Installed second (replaces EXPORT); imports the
#                .voxbackup into Production.
#
# The two apps are byte-identical binaries — they differ ONLY in the
# final codesign entitlements (com.apple.developer.icloud-container-
# environment=Production on the IMPORT app). Both are Developer-ID
# signed + notarized + stapled so they launch clean on Matt's Mac.
#
# DELIBERATE differences from release.sh:
#   - NO version bump (ships whatever version is pinned in the repo —
#     same as Matt's current Sparkle build, so drag-install replaces it).
#   - VOXHORA_MIGRATION injected via OTHER_SWIFT_FLAGS (the Release
#     config in project.yml is NOT touched — Matt's real Sparkle train
#     can never pick the tool up).
#   - Sparkle automatic update checks DISABLED in the tool Info.plists
#     (SUEnableAutomaticChecks=false) so the appcast can't replace a
#     tool app mid-migration.
#   - CFBundleName suffixed (menu bar shows which tool is running).
#   - DMGs land in migration-tools/ (gitignored), NEVER in releases/ —
#     generate_appcast scans releases/, and the tools must never reach
#     the appcast.
#   - NO GitHub release, NO appcast regen, NO git commit.
#
# The IMPORT entitlements are DERIVED at build time from
# Voxhora-Mac/Voxhora-Mac-Release.entitlements via PlistBuddy (which
# emits comment-free plain-ASCII XML — AMFI-safe by construction, see
# feedback_mac_entitlements_must_be_plain_ascii). The repo's Release
# entitlements file is not modified.
#
# Usage:  ./tools/build_migration_tool_apps.sh
#

set -euo pipefail

# ─── CONFIG (mirrors release.sh) ───────────────────────────────────────
NOTARY_PROFILE="voxhora-notarytool"
SIGNING_IDENTITY="Developer ID Application: Richard Patrick Fagerberg (S4GM27H6N5)"
DEV_ID_TEAM="S4GM27H6N5"
PROVISION_PROFILE="profiles/voxhora-mac.provisionprofile"
SCHEME="Voxhora-Mac"
PROJECT="Voxhora-Mac.xcodeproj"
RELEASE_ENTITLEMENTS="Voxhora-Mac/Voxhora-Mac-Release.entitlements"
SHARE_ENTITLEMENTS="Voxhora-Mac-Share/Voxhora-Mac-Share.entitlements"
OUT_DIR="migration-tools"
BUILD_DIR="/tmp/voxhora-mac-migration-tools"

say()  { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
done_() { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ─── PRE-FLIGHT ────────────────────────────────────────────────────────
say "Pre-flight checks…"
cd "$(dirname "$0")/.."
[[ -f "$RELEASE_ENTITLEMENTS" ]] || die "Run from voxhora-mac repo. Missing $RELEASE_ENTITLEMENTS."

if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  die "Working tree dirty. Commit or stash first — the tool build must be reproducible from a commit."
fi
done_ "Git working tree clean ($(git rev-parse --short HEAD))"

security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "Developer ID Application cert not in keychain."
done_ "Developer ID cert present"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' missing or invalid."
done_ "Notarization profile present"

[[ -f "$PROVISION_PROFILE" ]] || die "Missing $PROVISION_PROFILE (Developer ID Direct profile)."
security cms -D -i "$PROVISION_PROFILE" 2>/dev/null | grep -q "$DEV_ID_TEAM" \
  || die "Profile does not reference team $DEV_ID_TEAM."
# The profile must authorize the Production env value (verified live 2026-06-14;
# re-check so a regenerated profile can't silently regress this).
security cms -D -i "$PROVISION_PROFILE" 2>/dev/null \
  | grep -A3 'icloud-container-environment' | grep -q 'Production' \
  || die "Profile no longer authorizes icloud-container-environment=Production."
done_ "Developer ID Direct profile present + authorizes Production"

command -v xcodegen >/dev/null 2>&1 || die "xcodegen not installed."
xcodegen generate >/dev/null
done_ "xcodegen regenerated project (project.yml unchanged — no version bump)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Voxhora-Mac/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Voxhora-Mac/Info.plist)"
done_ "Tool apps will carry version $VERSION (build $BUILD)"

# ─── DERIVE THE IMPORT (Production) ENTITLEMENTS ───────────────────────
say "Deriving IMPORT entitlements (Release + Production env key)…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
IMPORT_ENTITLEMENTS="$BUILD_DIR/tool-import-production.entitlements"
# plutil round-trip strips the XML comments → plain-ASCII, AMFI-safe.
plutil -convert xml1 -o "$IMPORT_ENTITLEMENTS" "$RELEASE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c \
  "Add :com.apple.developer.icloud-container-environment string Production" \
  "$IMPORT_ENTITLEMENTS"
LC_ALL=C grep -q '[^[:print:][:space:]]' "$IMPORT_ENTITLEMENTS" \
  && die "IMPORT entitlements contain non-ASCII bytes — AMFI will reject."
plutil -lint "$IMPORT_ENTITLEMENTS" >/dev/null || die "IMPORT entitlements plist invalid."
done_ "IMPORT entitlements at $IMPORT_ENTITLEMENTS"

# ─── ARCHIVE (once — the flag is entitlement-independent) ──────────────
say "Archiving Release build with VOXHORA_MIGRATION (5–10 min)…"
ARCHIVE_PATH="$BUILD_DIR/Voxhora-Mac.xcarchive"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  OTHER_SWIFT_FLAGS='-DVOXHORA_MIGRATION' \
  -quiet \
  || die "xcodebuild archive FAILED"
done_ "Archive at $ARCHIVE_PATH"

# ─── SEAL ONE VARIANT ──────────────────────────────────────────────────
# seal_variant <name> <CFBundleName> <entitlements> <expect_production 0|1>
seal_variant() {
  local name="$1" bundle_name="$2" entitlements="$3" expect_prod="$4"
  say "Sealing $name variant…"
  local vdir="$BUILD_DIR/$name"
  mkdir -p "$vdir"
  cp -R "$ARCHIVE_PATH/Products/Applications/Voxhora-Mac.app" "$vdir/"
  local app="$vdir/Voxhora-Mac.app"

  # Tool-only Info.plist edits (BEFORE the seal so the signature covers them):
  # no self-updates mid-migration + a visible menu-bar label.
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_name" "$app/Contents/Info.plist"

  # Embed the Developer ID Direct profile (AMFI requirement, macOS 26.4+).
  cp "$PROVISION_PROFILE" "$app/Contents/embedded.provisionprofile"
  find "$app" -name "*.cstemp" -delete 2>/dev/null || true

  # Inside-out codesign (Sparkle Hardened Runtime recipe — same as release.sh).
  local sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$sparkle/XPCServices/Downloader.xpc" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$sparkle/XPCServices/Installer.xpc" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$sparkle/Updater.app/Contents/MacOS/Updater" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$sparkle/Updater.app" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$sparkle/Autoupdate" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    "$app/Contents/Frameworks/Sparkle.framework" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --entitlements "$SHARE_ENTITLEMENTS" \
    "$app/Contents/PlugIns/Voxhora-Mac-Share.appex" 2>&1 | tail -1
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --entitlements "$entitlements" \
    "$app" 2>&1 | tail -1

  codesign --verify --deep --strict "$app" || die "$name: codesign verification failed"
  codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "application-identifier" \
    || die "$name: missing application-identifier — AMFI will SIGKILL."

  # Env-key cross-check — the guard against sealing the wrong variant.
  local has_prod=0
  codesign -d --entitlements - --xml "$app" 2>/dev/null \
    | grep -q "icloud-container-environment" && has_prod=1
  [[ "$has_prod" == "$expect_prod" ]] \
    || die "$name: icloud-container-environment presence=$has_prod, expected $expect_prod — VARIANT MIX-UP."

  done_ "$name sealed + verified (Production key present: $has_prod)"
}

seal_variant "export-development" "Voxhora EXPORT tool" "$RELEASE_ENTITLEMENTS" 0
seal_variant "import-production"  "Voxhora IMPORT tool" "$IMPORT_ENTITLEMENTS"  1

# ─── NOTARIZE BOTH (submit both, then poll both) ───────────────────────
say "Submitting both apps to Apple notarization…"
declare -a NAMES=("export-development" "import-production")
declare -A SUBMISSION_IDS
for name in "${NAMES[@]}"; do
  zip_path="$BUILD_DIR/$name.zip"
  ditto -c -k --keepParent "$BUILD_DIR/$name/Voxhora-Mac.app" "$zip_path"
  submit_output="$(xcrun notarytool submit "$zip_path" \
    --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)"
  sid="$(echo "$submit_output" | grep -oE '"id":"[a-f0-9-]+"' | head -1 | cut -d'"' -f4)"
  [[ -n "$sid" ]] || { echo "$submit_output"; die "Notarization submit failed for $name"; }
  SUBMISSION_IDS[$name]="$sid"
  echo "  $name → submission $sid"
done

for name in "${NAMES[@]}"; do
  sid="${SUBMISSION_IDS[$name]}"
  until status="$(xcrun notarytool info "$sid" \
    --keychain-profile "$NOTARY_PROFILE" 2>/dev/null \
    | grep -E '^\s*status:' | awk '{print $2}')" \
    && [[ "$status" =~ ^(Accepted|Invalid|Rejected)$ ]]; do
    printf "  %s  %s: %s\n" "$(date '+%H:%M:%S')" "$name" "${status:-waiting}"
    sleep 30
  done
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" 2>&1 | head -40
    die "Notarization $status for $name"
  fi
  xcrun stapler staple "$BUILD_DIR/$name/Voxhora-Mac.app" >/dev/null || die "stapler failed for $name"
  done_ "$name notarized + stapled"
done

# ─── DMGs (hand-delivery; NEVER in releases/, NEVER on the appcast) ────
say "Building hand-delivery DMGs…"
mkdir -p "$OUT_DIR"
build_dmg() {
  local name="$1" volname="$2" dmg_name="$3"
  local staging="$BUILD_DIR/$name-dmg"
  mkdir -p "$staging"
  cp -R "$BUILD_DIR/$name/Voxhora-Mac.app" "$staging/"
  ln -s /Applications "$staging/Applications"
  rm -f "$OUT_DIR/$dmg_name"
  hdiutil create -volname "$volname" -srcfolder "$staging" -ov -format UDZO \
    "$OUT_DIR/$dmg_name" >/dev/null
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$OUT_DIR/$dmg_name"
  done_ "$OUT_DIR/$dmg_name"
}
build_dmg "export-development" "Voxhora EXPORT tool (Development)" \
  "Voxhora-EXPORT-tool-Development-$VERSION.dmg"
build_dmg "import-production" "Voxhora IMPORT tool (Production)" \
  "Voxhora-IMPORT-tool-Production-$VERSION.dmg"

say "DONE — Phase 0 tool builds"
cat <<EOF

  EXPORT (Development): $OUT_DIR/Voxhora-EXPORT-tool-Development-$VERSION.dmg
  IMPORT (Production):  $OUT_DIR/Voxhora-IMPORT-tool-Production-$VERSION.dmg

  Which is installed? Check the seal on the target Mac:
    codesign -d --entitlements - /Applications/Voxhora-Mac.app 2>/dev/null \\
      | grep -c icloud-container-environment
    0 = EXPORT (Development)   1 = IMPORT (Production)

  These DMGs are hand-delivered ONLY. Do not move them into releases/
  (generate_appcast scans that folder) and do not gh-release them.
EOF
