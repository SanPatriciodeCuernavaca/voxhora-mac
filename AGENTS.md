# AGENTS.md — voxhora-mac

Mac entry point for Voxhora (criminal-defense billing app). This repo holds ONLY the
Mac-specific pieces: `VoxhoraMacApp` entry point, entitlements, `project.yml`
(xcodegen — folder-globs shared Engine/Models from `../voxhora-ios`), deploy/release
scripts, the Sparkle appcast, and the embedded TechShare agent bundling. **Most app
code lives in `~/voxhora-ios` — read that repo's AGENTS.md too.**

**Full onboarding for a new agent: read the private repo
`SanPatriciodeCuernavaca/voxhora-exit-kit` (README first).**

## Build, deploy (Debug), release (Production)

```bash
# Debug build + install on Patrick's Mac (single-slot, mv never rm)
./deploy.sh

# RELEASE (Sparkle appcast, notarized, CloudKit Production)
./scripts/bundle_techshare_agent.sh   # ALWAYS FIRST — signs every nested Mach-O in the
                                      # embedded Python agent kit; Apple's notary recurses
                                      # into .app→tar.gz→whl and rejects ad-hoc signatures
./release.sh <version>                # runs scripts/notary_preflight.sh as the local gate
```

## HARD RULES

- **Release train = CloudKit Production.** Every appcast release is Production-sealed
  (`Voxhora-Mac-Release.entitlements` pins the container environment). **Patrick's
  own Mac stays Debug/Development and must NEVER take an appcast build.** Matt
  (the first customer) runs the appcast builds.
- Version is pinned in `project.yml`. Entitlements files must be PLAIN ASCII (AMFI
  rejects fancy comments). Sparkle requires the embedded Developer ID provisioning
  profile; sign with direct `codesign`, not `-exportArchive`.
- Deploy uses ONE `/tmp` slot; register with `lsregister -f -R -trusted` — NEVER
  `-u` (bricks the install). Park old stores/apps with `mv`, never `rm`.
- Every Mac sheet routes through `voxSheetFrame` (sheets hang from the WINDOW
  toolbar; the cap needs the 140pt margin — the 11-inch-MacBook trap). Every macOS
  `Form` gets `.formStyle(.grouped)`. Main window minHeight ≤ 600.
- New shared engine files in voxhora-ios must be added to this repo's `project.yml`
  target lists or the Mac build silently misses them.
- bash on macOS is 3.2: with `set -o pipefail`, `… | grep -q` SIGPIPEs its producer
  on match and reports failure — capture to a var + `case` instead. Subshell `cd` +
  relative output paths resolve to nowhere; use absolute paths.

## What runs here besides the app

- **Embedded TechShare agent** (`TechShareAgentKit` in Resources): pinned
  python-build-standalone 3.12.8 + the agent from `~/voxhora-techshare-agent`,
  installed at first Connect to `~/Library/Application Support/Voxhora/TechShareAgent`,
  launched ONLY as the SecStaticCode-verified venv python (`python -m
  voxhora_techshare_agent`, team S4GM27H6N5). Kill switch: `voxhora.techshare.disabled`.
- **Sparkle appcast** (`appcast.xml`, served from raw.githubusercontent.com/main).
- Mac-only engines (in shared source): AutoIntakeWatcher (FSEvents),
  MailInboxWatcher/Bridge (AppleScript Mail), TechShareAgentRuntime/BackfillEngine.

## Working with the owner

Patrick is a lawyer, not a coder: plain English. Ask before the first code edit of a
task; then run the loop without per-step asks. Never deploy to Matt's Mac without
explicit instruction. End status messages with "what's next?".
