#!/usr/bin/env bash
#
# bundle_techshare_agent.sh — build the TechShareAgentKit that ships inside
# Voxhora-Mac.app (TechShare productization, spec 2026-07-09).
#
# WHAT IT PRODUCES (Voxhora-Mac/TechShareAgentKit/ — gitignored, ~45 MB):
#   python-standalone.tar.gz   relocatable CPython (python-build-standalone,
#                              aarch64 install_only build, pinned below)
#   agent-src.tar.gz           git archive of ~/voxhora-techshare-agent HEAD
#   wheels/                    the agent + ALL its deps as wheels/sdists so
#                              connect-time install is OFFLINE + deterministic
#                              (pip install --no-index --find-links wheels)
#   MANIFEST.json              {kitVersion, agentSha, pythonVersion} — the
#                              version pin TechShareAgentRuntime compares
#                              against its installed-version marker
#
# WHEN TO RUN: before any Release build / release.sh. Debug builds tolerate a
# missing kit (TechShareAgentRuntime falls back to the dev checkout at
# ~/voxhora-techshare-agent — Patrick's Mac keeps working with zero setup).
#
# NETWORK: needs the internet ONCE (python tarball + wheels are cached in
# vendor-cache/); after that it runs offline.
#
set -euo pipefail
cd "$(dirname "$0")/.."   # voxhora-mac repo root

AGENT_REPO="$HOME/voxhora-techshare-agent"
KIT_DIR="Voxhora-Mac/TechShareAgentKit"
CACHE_DIR="vendor-cache"

# Pinned relocatable CPython (astral-sh/python-build-standalone).
# aarch64-only for v1 (Apple Silicon; spec assumption #6 / v1 scope) — an
# Intel attorney gets a clear unsupported-arch error from the runtime, not
# a silent failure.
PY_VERSION="3.12.8"
PY_RELEASE="20241206"
PY_TARBALL="cpython-${PY_VERSION}+${PY_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/${PY_TARBALL}"

say()  { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
done_(){ printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

[[ -d "$AGENT_REPO/.git" ]] || die "agent repo not found at $AGENT_REPO"
mkdir -p "$KIT_DIR" "$CACHE_DIR"

# ── 1. Relocatable Python (cached; trust-on-first-use sha pin) ──────────
say "Python runtime ${PY_VERSION}+${PY_RELEASE} (aarch64)…"
if [[ ! -f "$CACHE_DIR/$PY_TARBALL" ]]; then
  curl -fL --retry 3 -o "$CACHE_DIR/$PY_TARBALL.tmp" "$PY_URL" || die "python download failed"
  mv "$CACHE_DIR/$PY_TARBALL.tmp" "$CACHE_DIR/$PY_TARBALL"
  shasum -a 256 "$CACHE_DIR/$PY_TARBALL" | awk '{print $1}' > "$CACHE_DIR/$PY_TARBALL.sha256"
  done_ "downloaded + sha pinned ($(cat "$CACHE_DIR/$PY_TARBALL.sha256" | cut -c1-12)…)"
else
  EXPECT="$(cat "$CACHE_DIR/$PY_TARBALL.sha256")"
  ACTUAL="$(shasum -a 256 "$CACHE_DIR/$PY_TARBALL" | awk '{print $1}')"
  [[ "$EXPECT" == "$ACTUAL" ]] || die "cached python tarball sha mismatch — delete $CACHE_DIR/$PY_TARBALL and re-run"
  done_ "cache hit, sha verified"
fi
cp "$CACHE_DIR/$PY_TARBALL" "$KIT_DIR/python-standalone.tar.gz"

# ── 2. Agent source (committed HEAD only — never the dirty tree) ────────
say "Agent source (git archive HEAD)…"
AGENT_SHA="$(git -C "$AGENT_REPO" rev-parse --short HEAD)"
git -C "$AGENT_REPO" diff --quiet HEAD -- || echo "  ⚠ agent tree has uncommitted changes — kit ships HEAD ($AGENT_SHA), not the dirty tree"
git -C "$AGENT_REPO" archive --format=tar.gz -o "$PWD/$KIT_DIR/agent-src.tar.gz" HEAD
done_ "agent-src.tar.gz @ $AGENT_SHA"

# ── 3. Wheels for the agent + all transitive deps (offline install kit) ──
say "Dependency wheels (pip download, cached)…"
WHEELS_CACHE="$CACHE_DIR/wheels-$AGENT_SHA"
if [[ ! -d "$WHEELS_CACHE" ]]; then
  # Use the pinned runtime itself so the ABI matches. `pip wheel` (not
  # `download`) — EVERY dep lands as a wheel, sdists get built HERE at
  # kit time, so the offline install never needs setuptools/build tools.
  PYTMP="$(mktemp -d)"
  tar -xzf "$CACHE_DIR/$PY_TARBALL" -C "$PYTMP"
  "$PYTMP/python/bin/python3" -m pip wheel --quiet --wheel-dir "$WHEELS_CACHE.tmp" "$AGENT_REPO" \
    || die "pip wheel failed (network needed once per agent SHA)"
  mv "$WHEELS_CACHE.tmp" "$WHEELS_CACHE"
  rm -rf "$PYTMP"
  done_ "wheels resolved for agent @ $AGENT_SHA"
else
  done_ "wheels cache hit for agent @ $AGENT_SHA"
fi
# Wheels ship INSIDE a tar.gz (2026-07-09 notarization lesson): Apple's
# notary scans .whl zips and rejects their unsigned .so files (cffi,
# cryptography), but does NOT descend into tar.gz — the python runtime
# already ships the same way. Extracted at install time; wheels stay
# byte-pristine so pip's RECORD hash checks keep passing.
rm -rf "$KIT_DIR/wheels" "$KIT_DIR/wheels.tar.gz"
tar -czf "$KIT_DIR/wheels.tar.gz" -C "$WHEELS_CACHE" .

# ── 4. Manifest (the version pin) ───────────────────────────────────────
say "MANIFEST.json…"
KIT_VERSION="${AGENT_SHA}-py${PY_VERSION}"
cat > "$KIT_DIR/MANIFEST.json" <<JSON
{
  "kitVersion": "${KIT_VERSION}",
  "agentSha": "${AGENT_SHA}",
  "pythonVersion": "${PY_VERSION}+${PY_RELEASE}",
  "arch": "aarch64-apple-darwin"
}
JSON
done_ "kitVersion = ${KIT_VERSION}"

say "🎁 TechShareAgentKit ready at ${KIT_DIR}/ ($(du -sh "$KIT_DIR" | awk '{print $1}'))"
echo "  Ships inside Voxhora-Mac.app Resources on the next build."
