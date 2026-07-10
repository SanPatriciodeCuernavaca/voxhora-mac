# CLAUDE.md — Voxhora

**This file is auto-loaded by Claude Code every session. It is the policy document for working on Voxhora. Read it. Follow it. Don't drift.**

Voxhora is a native iPhone + Mac + Apple Watch app for criminal defense attorneys that tracks billable time. Public-Voxhora target: thousands of attorneys, 1M-user scale, App Store quality, lawyer-grade audit chain. Travis County is the test jurisdiction; the master product is the public app.

---

## Bar

* **Apple-quality only. No hacks. No shortcuts. No duct tape.** Patrick: "I will not accept any kind of patch."
* **Lawyer-grade audit chain.** Every billable action gets a hash-chained audit row. Trail must be legally defensible.
* **Niagara Falls trunk discipline.** Mutable data types (Client, CalendarEvent, Entry, Case, ClientNote, ClientDoc) flow through centralized trunk guardians that own writes + enforce invariants. Features TAP INTO the trunk; never own pipes other features depend on.
* **Parallel iOS + Mac + Watch.** Every meaningful change builds + verifies on all 3 platforms before commit. No Mac-only sprints, no iPhone-only sprints. See `feedback_parallel_build_violation_2026_05_13.md` in user memory.
* **Public-Voxhora first.** Every decision is for the master product. Travis County is just the test case. Foundation-first beats Travis-polish-first.

---

## Hard-won traps (DO NOT REDISCOVER)

### SwiftUI / iOS / watchOS

1. **`@StateObject = .shared` is the Sinclair trap.** `@StateObject` expects to OWN its instance; handing it a singleton breaks the Combine subscription chain. Use `private let foo = Foo.shared` + inject via `.environmentObject(foo)` + observe in consumer views via `@EnvironmentObject`. Hit twice in one day: `AutoBillFeedback` (auto-bill popup) + `CallTrackingService` (phone-call duration sheet). See [Apple Forums 763568](https://developer.apple.com/forums/thread/763568).

2. **`UIApplication.shared.open(url)` silently fails on iOS 18.** No-options form resolves to deprecated `openURL:` and returns false without firing. Always: `UIApplication.shared.open(url, options: [:]) { success in ... }`.

3. **`sheet(isPresented: Binding(get:set:))` has a watchOS race.** When `Button` action mutates `@State` and `List/ForEach` re-evaluates in the same render tick, SwiftUI silently drops the half-issued sheet. Use `sheet(item: $optional)` OR an explicit Bool driver decoupled from the Optional. ([Apple Forums 651869](https://developer.apple.com/forums/thread/651869))

4. **`.buttonStyle(.plain)` + `Spacer()` = empty-space hit-test gap.** Taps on whitespace between elements get dropped. Add `.contentShape(Rectangle())` on the label.

5. **Per-row `.focusable` + per-row `.digitalCrownRotation` inside ScrollView is the Watch Makros anti-pattern.** Focus engine auto-scrolls to focused offscreen children → finger-scroll snaps back to top. Scroll-position indicator flickers on every `@Query` tick. **Fix: single `.digitalCrownRotation` at parent level + state-switched Binding to active row's value.** No production watchOS app uses per-row crown. ([Apple Forums 749253](https://developer.apple.com/forums/thread/749253))

6. **`isContinuous: false` on `.digitalCrownRotation` triggers scroll-bar UI flicker** on every `.focusable(true)` re-evaluation. Always `isContinuous: true` unless you specifically want the discrete UI. ([Apple Forums 707381](https://developer.apple.com/forums/thread/707381))

7. **`.focused()` must come AFTER `.digitalCrownRotation()`.** Reverse order silently no-ops. ([freysie/watch-date-picker commit adc977a6](https://github.com/freysie/watch-date-picker/commit/adc977a6))

8. **`.focusable(true)` does NOT grant focus.** Just makes a view eligible. Must explicitly `@FocusState = true` via `DispatchQueue.main.async` to grab the crown on first tap.

9. **`.focusSection()` is iOS/macOS only. Not available on watchOS.** Don't.

10. **`UIApplication.didBecomeActiveNotification` doesn't always fire on tel: round-trips.** Pair with `UIApplication.willEnterForegroundNotification` as a second observer. ([Apple Forums 71662](https://developer.apple.com/forums/thread/71662))

### macOS

11. **Every `Form` on macOS MUST add `.formStyle(.grouped)`.** Default `.automatic` on macOS = `.columns` which left-bunches sections, ignores `.textFieldStyle(.roundedBorder)`, and can render blank inside TabView sidebars.

12. **`NavigationSplitView` / `TabView(.sidebarAdaptable)` on macOS consumes the WindowGroup content slot.** SwiftUI `.overlay()` and ZStack-sibling overlays at WindowGroup level are silently absorbed. **Fix: NSPanel via NSHostingView** (`AutoBillToastWindowController` pattern).

13. **Mac deploy: single `/tmp` slot, NEVER timestamped paths.** Build to `/tmp/voxhora-mac-build/`, backup old to `/tmp/voxhora-mac-prev.app` (overwritten each deploy). Apple removed `lsregister -kill`. Accumulating paths cluttered Spotlight with stale Voxhora entries.

14. **Mac deploy: `lsregister -f -R -trusted` (FORCE register). NEVER `-u` (unregister).** `-u` bricks the install — requires recovery sequence.

### Cross-platform

15. **Per-platform App entry points are separate files.** iOS uses `voxhora-ios/Voxhora/VoxhoraApp.swift`. Mac uses `voxhora-mac/Voxhora-Mac/VoxhoraMacApp.swift`. Engine + Models share via folder-glob in `voxhora-mac/project.yml`; App-init wiring does NOT.

16. **Modern Transferable / `.dropDestination` for drag-drop. NEVER `.onDrop(of:NSItemProvider)`.** The legacy NSItemProvider path is broken in ScrollViews (5 fixes burnt on it in DECISION 055).

---

## Cadence rules

* **Read freely. Search freely. List freely.** No permission needed for read-only ops.
* **ASK before code edits / builds / installs / deploys** the first time per task.
* **AUTO-PUSH once approved + green** — commit + push to all 5 repos is the automatic tail of every shipped feature. No second ask.
* **Inside the dev loop, just do it.** Once a task is authorized, no per-step asks. Build → deploy → smoke-test → commit → push without confirming each step.
* **Patrick's pause = thinking, NOT permission.** When he asks "confirm?" and doesn't respond immediately, he's typing. WAIT for explicit "yes" / "go" / "ship it" before code edits.
* **Plain English. He's a lawyer, not a coder.** No EXIF / byteCount / @MainActor / DerivedData / lsregister jargon in smoke-test instructions or status reports. Tell him what to click, what he should see, what it means.
* **End every message with "what's next?"** Patrick decides when work ends.
* **Paste content inline.** Never give file paths to read or links to open — paste the full content in a fenced code block.

---

## Build + deploy quick reference

### iPhone (force-quit + relaunch built-in)
```bash
cd /Users/patrickfagerberg/voxhora-ios
xcodebuild -project Voxhora.xcodeproj -scheme Voxhora -destination 'generic/platform=iOS' -configuration Debug build
xcrun devicectl device install app --device 73F7A09B-BB62-5D03-B583-AA9AB685464E ~/Library/Developer/Xcode/DerivedData/Voxhora-bewrilmthojyvhclggrcdvbvydnj/Build/Products/Debug-iphoneos/Voxhora.app
xcrun devicectl device process launch --device 73F7A09B-BB62-5D03-B583-AA9AB685464E --terminate-existing com.patrickfagerberg.voxhora
```

### Apple Watch — NO deploy step (HARD RULE, Patrick 2026-07-02 + 2026-07-10)
The Watch updates itself through the iPhone over-install above — never run a
direct devicectl install to the Watch in routine deploys. (Direct install of the
EMBEDDED `Voxhora.app/Watch/Voxhora.app` always fails with IXRemoteErrorDomain
error 5; the standalone `Debug-watchos` build to the Watch UDID is a manual
RECOVERY step only, and even then over-install, never delete.)

### Mac (single-slot procedure)
```bash
cd /Users/patrickfagerberg/voxhora-mac
xcodebuild -project Voxhora-Mac.xcodeproj -scheme Voxhora-Mac -configuration Debug -derivedDataPath /tmp/voxhora-mac-build build
pkill -x Voxhora-Mac
mv /Applications/Voxhora-Mac.app /tmp/voxhora-mac-prev.app
ditto /tmp/voxhora-mac-build/Build/Products/Debug/Voxhora-Mac.app /Applications/Voxhora-Mac.app
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted /Applications/Voxhora-Mac.app
open /Applications/Voxhora-Mac.app
```

### iPhone tunnel timeout retry pattern
```bash
until xcrun devicectl device install app --device <UDID> <APP> > /tmp/voxlast.txt 2>&1; do sleep 4; done
```

### Pull iOS diagnostic file from app sandbox
```bash
xcrun devicectl device copy from --device <UDID> --source Documents/voxhora-calltracker.log --destination /tmp/voxlog.txt --domain-type appDataContainer --domain-identifier com.patrickfagerberg.voxhora
```

### Query CloudKit-synced audit chain
```bash
sqlite3 ~/Library/Group\ Containers/group.com.patrickfagerberg.voxhora/Library/Application\ Support/default.store "SELECT * FROM ZAUDITLOGENTRY ORDER BY ZTIMESTAMP DESC LIMIT 10;"
```

### Devices
* iPhone 13 Pro UDID: `73F7A09B-BB62-5D03-B583-AA9AB685464E`
* Apple Watch Series 11 UDID: `08274665-3118-5DCF-934E-502F315D9BF6`

---

## Five-repo GitHub layout

All under `github.com/SanPatriciodeCuernavaca/`:
* `voxhora-ios` — iPhone + Watch source
* `voxhora-mac` — Mac source (folder-globs Engine + Models from voxhora-ios)
* `voxhora-android` — placeholder
* `voxhora-public` — public landing / docs (placeholder)
* `voxhora-docs` — Obsidian vault (`~/Obsidian/Voxhora`)

Auto-commit + auto-push after every meaningful change.

---

## Path to public launch (Path A → B → C → D)

* **Path A — Crash safety** (next sessions): every `!` / `try!` / `as!` / `fatalError` swept and guarded. Apple MetricKit integration for production crash + hang + battery reports. SwiftData migration paths tested. CloudKit error handling explicit. Audit punch-list at `~/Obsidian/Voxhora/Voxhora - Crash Risk Audit 2026-05-13.md` (generated tonight).
* **Path B — Swift 6 strict concurrency** (after A): flip build setting, fix every warning. Forces Sinclair-trap-class bugs to surface at compile time.
* **Path C — Observability**: `os.Logger` subsystem per feature, file-based diagnostic logs (pullable via devicectl), audit chain hash-chain integrity check on launch.
* **Path D — Public-scale gates**: A11y (VoiceOver, Dynamic Type), i18n (English + Spanish first), Privacy manifest, multi-jurisdiction (DECISION 055 framework), staged App Store rollout (1% → 10% → 50% → 100%), TestFlight beta with real lawyers, feature flags via CloudKit-stored AttorneyProfile fields.

---

## Memory + handoff

Full session-by-session history in user memory: `~/.claude/projects/-Users-patrickfagerberg-Documents-Documents---patrick-s-MacBook-Air-Claude-Projects-Voxhora/memory/MEMORY.md` (index) + individual `.md` files. Read these for context Voxhora-specific knowledge that doesn't fit here.

Latest decision audit log: `~/Obsidian/Voxhora/Voxhora - DA Log.md` (or latest session handoff doc in same folder).

---

## Generic principles (preserved from prior CLAUDE.md)

* Think before coding. State assumptions. Surface tradeoffs.
* Simplicity first. Minimum code that solves the problem. No speculative abstractions.
* Surgical changes. Touch only what you must. Match existing style.
* Goal-driven execution. Define success criteria. Loop until verified.
