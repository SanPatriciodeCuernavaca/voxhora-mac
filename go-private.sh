#!/usr/bin/env bash
#
# go-private.sh — take the Mac source private WITHOUT stranding anyone.
#
# Written 2026-08-08.
#
# THE PROBLEM THIS SOLVES
# The Mac app fetches its update feed from
#   raw.githubusercontent.com/SanPatriciodeCuernavaca/voxhora-mac/main/appcast.xml
# That URL is baked into every shipped binary and there is no runtime override
# (SPUStandardUpdaterController is constructed with a nil updaterDelegate, so
# Sparkle's feedURLString(for:) hook never runs). Simply flipping the repo to
# private returns 404 to every install still pointing there — permanently, and
# SILENTLY, because Sparkle's background checks swallow network errors and only
# a manual "Check for Updates…" ever surfaces an alert.
#
# 0.2.87 moved the feed to voxhora.app, but that only helps installs that
# actually TOOK 0.2.87. There is no telemetry anywhere that can enumerate who
# has the Mac app, so "everyone updated first" is not a provable claim — and a
# user who simply doesn't launch Voxhora during the changeover would be cut off
# forever without either of us knowing.
#
# THE FIX
# Keep the old URL alive. The source moves to a renamed private repo, and a new
# PUBLIC repo takes the name `voxhora-mac` containing nothing but appcast.xml.
# Old installs keep polling successfully and migrate themselves whenever their
# owner next opens the app. No deadline, no race, nobody stranded.
#
# GitHub documents that creating a new repo with a renamed repo's old name
# breaks the rename redirect — which is exactly what we want here: the name
# resolves to the shell, not to the private source.
#
# Usage:
#   ./go-private.sh --dry-run     # show every step, change nothing (DO THIS FIRST)
#   ./go-private.sh --confirm-matt-is-on-0.2.87
#
set -euo pipefail

OWNER="SanPatriciodeCuernavaca"
NAME="voxhora-mac"
NEWNAME="voxhora-mac-src"          # where the source ends up (private)
MAC_REPO="/Users/patrickfagerberg/voxhora-mac"
SHELL_DIR="/tmp/voxhora-mac-shell"
NEW_FEED="https://voxhora.app/appcast.xml"
OLD_FEED="https://raw.githubusercontent.com/${OWNER}/${NAME}/main/appcast.xml"

DRY=0
CONFIRMED=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --confirm-matt-is-on-0.2.87) CONFIRMED=1 ;;
    *) echo "unknown arg: $a" >&2; exit 1 ;;
  esac
done

die(){ printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
say(){ printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
ok(){  printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
run(){ if [ "$DRY" = "1" ]; then printf "  \033[2m[dry-run] %s\033[0m\n" "$*"; else eval "$@"; fi; }

[ "$DRY" = "1" ] || [ "$CONFIRMED" = "1" ] || die \
"Refusing to run.

This is not reversible in the way that matters: once the source repo is private
and the shell exists, undoing it cleanly means renaming things back in the right
order under time pressure.

Before running for real, confirm BOTH:
  1. Matt has told you his Voxhora reads 0.2.87 (Voxhora → About). Not 'he
     clicked update' — the version number, read aloud. There is no telemetry
     that can check this for you.
  2. ./go-private.sh --dry-run printed what you expect.

Then re-run with --confirm-matt-is-on-0.2.87"

# ─── PRE-FLIGHT ────────────────────────────────────────────────────────
say "Pre-flight"
command -v gh >/dev/null 2>&1 || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"
ok "gh authenticated"

# The shell repo is only useful if the feed it will serve is already good.
# Verify the LIVE new feed before touching anything.
"$MAC_REPO/tools/check_appcast.sh" "$NEW_FEED" >/dev/null 2>&1 \
  || die "$NEW_FEED is not serving a healthy feed. Fix that BEFORE going private — it is what every migrated install depends on."
ok "voxhora.app feed healthy"

# The old feed must currently be serving 0.2.87 too, or old installs have not
# had their chance to migrate and the shell would preserve a stale feed.
OLDVER=$(curl -sS -L -m 30 "$OLD_FEED" 2>/dev/null | grep -o 'sparkle:shortVersionString="[^"]*"' | head -1 | sed 's/.*="//;s/"//')
[ "$OLDVER" = "0.2.87" ] || die "The OLD feed advertises '${OLDVER:-nothing}', not 0.2.87. Run ./publish-appcast.sh v0.2.87 first — otherwise the shell freezes old installs on an old version forever."
ok "old feed advertises 0.2.87"

git -C "$MAC_REPO" diff --quiet && git -C "$MAC_REPO" diff --cached --quiet \
  || die "voxhora-mac working tree is dirty — commit or stash before renaming the remote."
ok "working tree clean"

CURVIS=$(gh repo view "$OWNER/$NAME" --json visibility -q .visibility 2>/dev/null || echo "?")
ok "current visibility of $NAME: $CURVIS"

# ─── 1. RENAME THE SOURCE, FREEING THE NAME ────────────────────────────
# The old URL is briefly unavailable between here and step 2. Keep that window
# as small as possible; Sparkle retries on its next check either way.
say "1. Rename $NAME -> $NEWNAME (frees the public name)"
run "gh repo rename '$NEWNAME' --repo '$OWNER/$NAME' --yes"
ok "renamed"

# ─── 2. RE-POINT THE LOCAL CHECKOUT ────────────────────────────────────
# CRITICAL FOOTGUN: after step 3 a repo named voxhora-mac exists again — the
# SHELL. A local checkout still pointing at the old URL would push the entire
# Mac source into the public shell repo on the next `git push`, undoing the
# whole point of this exercise. Re-point before the shell exists.
say "2. Re-point local checkout at $NEWNAME"
run "git -C '$MAC_REPO' remote set-url origin 'https://github.com/$OWNER/$NEWNAME.git'"
if [ "$DRY" = "0" ]; then
  git -C "$MAC_REPO" remote -v | grep -q "$NEWNAME" || die "local remote did not update — STOP, do not create the shell yet."
fi
ok "local origin now points at $NEWNAME"

# ─── 3. CREATE THE PUBLIC SHELL ────────────────────────────────────────
say "3. Create public $NAME shell holding only appcast.xml"
if [ "$DRY" = "0" ]; then
  rm -rf "$SHELL_DIR"; mkdir -p "$SHELL_DIR"
  cp "$MAC_REPO/appcast.xml" "$SHELL_DIR/appcast.xml"
  cat > "$SHELL_DIR/README.md" <<'MD'
# voxhora-mac

This repository exists for one reason: to keep the Sparkle update feed at its
original URL alive.

Voxhora-Mac builds up to and including 0.2.86 have this URL compiled into them:

    https://raw.githubusercontent.com/SanPatriciodeCuernavaca/voxhora-mac/main/appcast.xml

That URL cannot be changed on an installed copy — it is baked into the binary,
and Sparkle reports a failed update check to nobody. If this repository were
deleted or made private, every one of those installs would stop receiving
updates permanently, without any visible error.

So `appcast.xml` stays here, and its enclosure points at voxhora.app. Older
installs keep updating and migrate to the voxhora.app feed the next time their
owner opens the app.

**Do not delete this repository. Do not make it private.**

The application source lives elsewhere and is private.
MD
  ( cd "$SHELL_DIR" && git init -q && git add . && \
    git -c user.email=patrickfagerberg@icloud.com -c user.name="Patrick Fagerberg" \
      commit -q -m "Keep the original Sparkle feed URL alive" \
      -m "Old Voxhora-Mac installs have this URL compiled in and cannot be repointed. Serving appcast.xml here lets them keep updating and migrate to voxhora.app on their own schedule." && \
    git branch -M main )
  gh repo create "$OWNER/$NAME" --public --source "$SHELL_DIR" --push
else
  printf "  \033[2m[dry-run] create public %s/%s from appcast.xml + README\033[0m\n" "$OWNER" "$NAME"
fi
ok "shell repo created"

# ─── 4. VERIFY THE OLD URL BEFORE LOCKING THE SOURCE ───────────────────
say "4. Verify the old feed URL still resolves"
if [ "$DRY" = "0" ]; then
  RESTORED=0
  for i in $(seq 1 20); do
    V=$(curl -sS -L -m 30 "$OLD_FEED" 2>/dev/null | grep -o 'sparkle:shortVersionString="[^"]*"' | head -1 | sed 's/.*="//;s/"//')
    if [ "$V" = "0.2.87" ]; then RESTORED=1; break; fi
    printf "  … not back yet (attempt %s/20, saw '%s')\n" "$i" "${V:-nothing}"
    sleep 10
  done
  [ "$RESTORED" = "1" ] || die "OLD FEED STILL DOWN. Source repo is renamed but NOT yet private — fix the shell before continuing. Old installs are currently not updating."
  "$MAC_REPO/tools/check_appcast.sh" "$OLD_FEED" || die "Old feed resolves but an enclosure is unreachable. Fix before making the source private."
fi
ok "old feed alive and serving 0.2.87 from the shell"

# ─── 5. NOW LOCK THE SOURCE ────────────────────────────────────────────
say "5. Make $NEWNAME private"
run "gh repo edit '$OWNER/$NEWNAME' --visibility private --accept-visibility-change-consequences"
ok "$NEWNAME is private"

# ─── 6. FINAL PROOF ────────────────────────────────────────────────────
say "6. Final verification"
if [ "$DRY" = "0" ]; then
  SRCVIS=$(gh repo view "$OWNER/$NEWNAME" --json visibility -q .visibility)
  SHLVIS=$(gh repo view "$OWNER/$NAME"    --json visibility -q .visibility)
  [ "$SRCVIS" = "PRIVATE" ] || die "source repo is $SRCVIS, expected PRIVATE"
  [ "$SHLVIS" = "PUBLIC" ]  || die "shell repo is $SHLVIS, expected PUBLIC"
  ok "source $NEWNAME = PRIVATE"
  ok "shell  $NAME = PUBLIC"
  "$MAC_REPO/tools/check_appcast.sh" "$OLD_FEED" || die "old feed broke after the visibility change"
  "$MAC_REPO/tools/check_appcast.sh" "$NEW_FEED" || die "new feed broke after the visibility change"
  ok "both feeds healthy AFTER the source went private"
fi

printf "\n\033[1;32m✓ Source is private. Both update feeds still work.\033[0m\n"
printf "  source: https://github.com/%s/%s (private)\n" "$OWNER" "$NEWNAME"
printf "  shell:  https://github.com/%s/%s (public — DO NOT DELETE)\n" "$OWNER" "$NAME"
printf "\n\033[1;33m  Remaining: voxhora-public must stay public forever. Making it private\n"
printf "  unpublishes voxhora.app and frees the domain for takeover.\033[0m\n\n"
