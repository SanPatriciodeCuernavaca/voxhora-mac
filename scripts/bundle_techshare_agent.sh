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

# Developer ID — the notary descends into every archive layer (tar.gz →
# tar → whl/zip) and requires each nested Mach-O to carry a VALID
# Developer ID signature + secure timestamp + (executables) hardened
# runtime. python-build-standalone binaries AND PyPI wheels ship
# ad-hoc/unsigned, so we sign them here (2026-07-09 notarization saga).
SIGN_ID="Developer ID Application: Richard Patrick Fagerberg (S4GM27H6N5)"

say()  { printf "\n\033[1;34m▸ %s\033[0m\n" "$*"; }
done_(){ printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# Developer-ID-sign every Mach-O under $1 (recursively, by file(1) magic —
# NOT the exec bit; many .so lack it). Hardened runtime + secure
# timestamp satisfy all three notary complaints. Verifies each sign stuck
# (capture-to-var, never `| grep -q` — under `set -o pipefail` grep -q
# SIGPIPEs its producer and the pipe falsely reports failure). Returns
# the count signed.
sign_machos_in_dir() {
  local root="$1" label="$2"
  local machos=()
  # Enumerate by file(1) magic. A universal (fat) binary prints THREE
  # lines — a "Mach-O universal binary" header plus one
  # "(for architecture …)" continuation per slice; keep only the header
  # (drop continuations) and strip ":[tab/space]Mach-O…" to the bare
  # path. codesign signs all slices of a fat binary in one call.
  while IFS= read -r f; do machos+=("$f"); done < <(
    find "$root" -type f -exec file {} + 2>/dev/null \
      | grep "Mach-O" \
      | grep -v "(for architecture" \
      | sed 's/:[[:space:]]*Mach-O.*//'
  )
  # Empty-array expansion under `set -u` on bash 3.2 (macOS default) is an
  # "unbound variable" error, so the loop must be guarded — this helper is
  # now called on EVERY wheel, most of which contain zero Mach-Os.
  if [[ ${#machos[@]} -gt 0 ]]; then
    for macho in "${machos[@]}"; do
      codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$macho" \
        || die "codesign failed for ${macho#$root/} ($label)"
      local vout
      vout="$(codesign -dvvv "$macho" 2>&1 || true)"
      case "$vout" in
        *"Authority=Developer ID Application"*) : ;;
        *) die "sign did not stick for ${macho#$root/} ($label)" ;;
      esac
    done
  fi
  echo "${#machos[@]}"
}

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
# The runtime's own Mach-Os (python3.12, libpython3.12.dylib, and any
# lib-dynload extensions) ship ad-hoc from python-build-standalone — the
# notary rejects them at this nesting depth. Extract → Developer-ID-sign
# → re-tar. Cached by the tarball's sha so repeat builds are fast.
PY_SIGNED_CACHE="$CACHE_DIR/python-signed-$(cat "$CACHE_DIR/$PY_TARBALL.sha256" | cut -c1-16)"
if [[ ! -f "$PY_SIGNED_CACHE" ]]; then
  say "Signing the Python runtime's Mach-Os (Developer ID + hardened runtime)…"
  PYSIGN_TMP="$(mktemp -d)"
  tar -xzf "$CACHE_DIR/$PY_TARBALL" -C "$PYSIGN_TMP"
  py_count="$(sign_machos_in_dir "$PYSIGN_TMP" "python runtime")"
  # Re-tar preserving the top-level `python/` prefix. Absolute output
  # path — the tar runs from inside $PYSIGN_TMP so a relative one would
  # resolve to a nonexistent dir (same class as the wheel-repack fix).
  PY_SIGNED_ABS="$(cd "$CACHE_DIR" && pwd)/$(basename "$PY_SIGNED_CACHE")"
  ( cd "$PYSIGN_TMP" && tar -czf "$PY_SIGNED_ABS.tmp" . )
  mv "$PY_SIGNED_ABS.tmp" "$PY_SIGNED_CACHE"
  rm -rf "$PYSIGN_TMP"
  done_ "signed $py_count runtime Mach-O(s)"
else
  done_ "signed-runtime cache hit"
fi
cp "$PY_SIGNED_CACHE" "$KIT_DIR/python-standalone.tar.gz"

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
# ── 3b. Developer-ID-sign every Mach-O inside the wheels ────────────────
# The notary descends into EVERY archive layer (zip, whl, tar.gz) and
# requires each nested Mach-O to carry a valid Developer ID signature +
# secure timestamp. PyPI wheels (cffi, cryptography, …) ship
# ad-hoc/unsigned .so files → sign them, then rewrite each wheel's RECORD
# hashes so pip's install verification still passes.
say "Signing nested Mach-Os inside wheels (Developer ID + timestamp)…"
SIGNED_WHEELS="$CACHE_DIR/wheels-signed-$AGENT_SHA"
if [[ ! -d "$SIGNED_WHEELS" ]]; then
  rm -rf "$SIGNED_WHEELS.tmp"
  cp -R "$WHEELS_CACHE" "$SIGNED_WHEELS.tmp"
  for whl in "$SIGNED_WHEELS.tmp"/*.whl; do
    # Sign by Mach-O MAGIC, never by filename. The old gate grepped the
    # listing for `\.(so|dylib)` and skipped any wheel without one — which
    # silently shipped imageio-ffmpeg's extension-less `ffmpeg-macos-…`
    # EXECUTABLE ad-hoc-signed (2026-07-11). The notary rejects ANY nested
    # ad-hoc Mach-O regardless of name, so extract every wheel, let
    # sign_machos_in_dir (file(1)-magic based) decide, and only rewrite +
    # repack the ones that actually contained a Mach-O.
    WTMP="$(mktemp -d)"
    unzip -qq "$whl" -d "$WTMP"
    wc="$(sign_machos_in_dir "$WTMP" "$(basename "$whl")")"
    if [[ "$wc" -gt 0 ]]; then
      # Rewrite RECORD hashes for EVERY file on disk (a superset of what we
      # re-signed — Mach-Os with no extension are covered too; recompute is
      # idempotent for untouched members so the RECORD always matches disk).
      python3 - "$WTMP" <<'PYEOF'
import base64, hashlib, os, sys
root = sys.argv[1]
record_path = None
for dirpath, _, files in os.walk(root):
    for f in files:
        if f == "RECORD" and dirpath.endswith(".dist-info"):
            record_path = os.path.join(dirpath, f)
if not record_path:
    raise SystemExit("no RECORD found")
lines_out = []
for line in open(record_path):
    line = line.rstrip("\n")
    if not line:
        continue
    path = line.split(",")[0]
    full = os.path.join(root, path)
    # The RECORD line for RECORD itself carries no hash — leave verbatim.
    if os.path.abspath(full) == os.path.abspath(record_path) or not os.path.exists(full):
        lines_out.append(line)
        continue
    data = open(full, "rb").read()
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    lines_out.append(f"{path},sha256={digest},{len(data)}")
open(record_path, "w").write("\n".join(lines_out) + "\n")
PYEOF
      # Absolute path — the repack runs from inside $WTMP, so a relative
      # "$whl" would resolve to a nonexistent dir (2026-07-09 bug: the
      # wheel got rm'd then the zip silently failed, dropping it).
      # NB: zip preserves the unix exec bit (in the external attrs) even
      # with -X, and pip restores it on install — ffmpeg stays runnable.
      whl_abs="$(cd "$(dirname "$whl")" && pwd)/$(basename "$whl")"
      rm -f "$whl_abs"
      (cd "$WTMP" && zip -qq -r -X "$whl_abs" .) || die "wheel repack failed: $(basename "$whl")"
      done_ "signed $wc Mach-O(s) in $(basename "$whl")"
    fi
    rm -rf "$WTMP"
  done
  mv "$SIGNED_WHEELS.tmp" "$SIGNED_WHEELS"
else
  done_ "signed-wheels cache hit"
fi

# Wheels ship inside a tar.gz (single kit member; runtime untars before
# pip). Contents are Developer-ID signed above, so every notarization
# layer is clean.
rm -rf "$KIT_DIR/wheels" "$KIT_DIR/wheels.tar.gz"
tar -czf "$KIT_DIR/wheels.tar.gz" -C "$SIGNED_WHEELS" .

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
