//
//  VoxhoraMacApp.swift
//  Voxhora-Mac
//
//  Mac CloudKit subscriber. Subscribes to the same private CloudKit
//  database the iOS app writes to (`iCloud.com.patrickfagerberg.voxhora`).
//  Entries written on any device propagate here automatically. The
//  native MacMainView (TODAY / CLIENTS / VOUCHERS / INSIGHTS) is the
//  canonical Mac dashboard — no Dropbox bridge in either direction.
//

import SwiftUI
import SwiftData
import UserNotifications
import AppKit
import UniformTypeIdentifiers

@main
struct VoxhoraMacApp: App {
    /// Shared schema with iOS. Same container ID. Same models.
    let modelContainer: ModelContainer

    /// Path A3 (2026-05-13) — true when ModelContainerBootstrap fell back
    /// to in-memory mode because CloudKit-backed init failed. Surfaced
    /// to audit chain on first .onAppear.
    let containerDegradedToInMemory: Bool

    /// DECISION 025 (PDF intake portal) — shared state holder for
    /// drag-drop + file-picker PDF arrivals. IntakeView observes;
    /// PDFImportSheet presents when pendingPDF becomes non-nil.
    @StateObject private var pdfIntakeRouter = PDFIntakeRouter()

    /// DECISION 026 (SMS reminders) — shared state holder for "user
    /// tapped a reminder notification" on Mac. Mac uses the same
    /// UNUserNotificationCenter scheduling + delegate pattern as
    /// iOS; Mac-specific compose path is NSSharingService.composeMessage
    /// inside SendReminderSheet.
    @StateObject private var reminderActionRouter = ReminderActionRouter()

    /// DECISION 039 — drives `CalendarRefreshScheduler` Timer start /
    /// stop on scenePhase transitions. Mac has no BGAppRefreshTask
    /// equivalent (no BackgroundTasks framework on macOS); foreground
    /// Timer covers Mac's always-on workflow.
    @Environment(\.scenePhase) private var scenePhase

    /// DECISION 054 follow-up (2026-05-10) — shared @Observable
    /// model. Same as iPhone's VoxhoraApp.swift. Injected into the
    /// Mac SwiftUI environment so case-info sheets can mutate the
    /// sidebar selection by writing `appState.selectedTab` directly.
    @State private var appState = AppState()

    init() {
        // DECISION 059 Feature 1.7s v8 (2026-05-12 night) — auto-bill popup.
        // Mac uses NSPanel-backed AutoBillToastWindowController (NSSplitViewController
        // bridge consumes window content slot, defeating SwiftUI overlay attempts).
        // Force AutoBillFeedback singleton init at launch + start the
        // window controller's Combine subscription to AutoBillFeedback.shared.$pending.
        _ = AutoBillFeedback.shared
        AutoBillToastWindowController.shared.start()
        // Path A3 (2026-05-13) — graceful CloudKit-init fallback (was
        // prior fatalError). ModelContainerBootstrap returns the
        // container + a `degraded` flag the lawyer's session is in
        // in-memory mode, recorded to audit chain in onAppear.
        let schema = Schema([
            Entry.self,
            Client.self,
            Case.self,
            AttorneyProfile.self,
            UserPreferences.self,
            AuditLogEntry.self,
            Voucher.self,                 // DECISION 012 — Phase C voucher state model
            CalendarEvent.self,           // DECISION 022 — Calendar feature (DSA-driven court schedule)
            ClientNote.self,              // DECISION 040.2 — Client notes journal
            ClientDoc.self                // DECISION 056 — Client Docs vault (Session 1 data plumbing, 2026-05-11)
        ])
        let bootResult = ModelContainerBootstrap.boot(
            schema: schema,
            cloudKitContainerID: "iCloud.com.patrickfagerberg.voxhora"
        )
        modelContainer = bootResult.container
        containerDegradedToInMemory = bootResult.degraded

        // DECISION 026 — wire VoxhoraNotificationDelegate so reminder
        // notification taps route into the ReminderActionRouter on Mac.
        UNUserNotificationCenter.current().delegate = VoxhoraNotificationDelegate.shared

        // DECISION 056 Beat 1 v4 (2026-05-11) — process-global Services
        // registration. Tells macOS this app participates in the
        // Services subsystem with image + PDF return types, which is
        // the prerequisite for Continuity Camera items appearing in
        // any context menu inside Voxhora-Mac. Required once at app
        // launch — partner to ContinuityCameraResponder.swift's per-
        // responder validRequestor advertisement. Apple-documented
        // hook (NSApplication.registerServicesMenuSendTypes).
        NSApplication.shared.registerServicesMenuSendTypes(
            [],
            returnTypes: NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        )
    }

    var body: some Scene {
        WindowGroup {
            MacMainView()
                .funModeOverlay()  // DECISION 051 — global Fun Mode visual overlay
                .environmentObject(pdfIntakeRouter)
                .environmentObject(reminderActionRouter)
                .environment(appState)  // DECISION 054 follow-up
                .sheet(item: $reminderActionRouter.pending) { pending in
                    SendReminderSheet(pending: pending)
                        .environmentObject(reminderActionRouter)
                }
                .frame(minWidth: 980, minHeight: 680)
                // Path A3b (2026-05-13) — degraded-launch alert (Mac
                // companion to iOS VoxhoraApp). Fires when onAppear sets
                // appState.containerDegradedToInMemory = true on Tier 2
                // fallback. Lawyer learns immediately that the Mac
                // session is in-memory-only; can quit + relaunch.
                .alert("iCloud sync unavailable", isPresented: Binding(
                    get: { appState.containerDegradedToInMemory },
                    set: { newValue in
                        if !newValue { appState.containerDegradedToInMemory = false }
                    }
                )) {
                    Button("Got it", role: .cancel) {}
                } message: {
                    Text("Voxhora couldn't connect to iCloud when it started up. The app is working, but anything you bill right now will be lost when you quit. Quit and reopen in a few minutes — if the problem keeps happening, restart your Mac or check your iCloud settings.")
                }
                // 2026-05-07 — Mac PDF handler. Mirrors VoxhoraApp's iOS
                // handler (DECISION 025). Fires when a PDF opens via:
                //   - Right-click in Finder/Mail/Safari → Open With → Voxhora-Mac
                //   - Drag PDF onto Voxhora-Mac Dock icon
                //   - Mail's Share submenu → Voxhora-Mac
                //   - `open -a Voxhora-Mac path/to/pdf` from Terminal
                // Voxhora-Mac is registered as a `com.adobe.pdf` Default-
                // rank handler in Info.plist's CFBundleDocumentTypes
                // (project.yml info block).
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == "pdf" else { return }
                    // Mac: no security-scoped resource bookkeeping needed
                    // for non-sandboxed apps (Voxhora-Mac is not sandboxed
                    // — verified Voxhora-Mac.entitlements has no
                    // com.apple.security.app-sandbox key).
                    guard let data = try? Data(contentsOf: url) else { return }
                    pdfIntakeRouter.receivePDF(data: data, sourceMode: "mac_open_with", filename: url.lastPathComponent)
                }
                .onAppear {
                    Task { @MainActor in
                        AuditLogger.shared.modelContext = modelContainer.mainContext

                        // Path A3 (2026-05-13) — record degraded init to
                        // audit chain when CloudKit fallback was hit.
                        if containerDegradedToInMemory {
                            AuditLogger.shared.log(
                                eventType: .modelContainerInitDegraded,
                                payload: [
                                    "platform": "macOS",
                                    "fallbackTier": "in_memory",
                                    "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                                ],
                                attorneyId: ""
                            )
                            // Path A3b (2026-05-13) — propagate to AppState
                            // so the WindowGroup-level .alert fires for
                            // the lawyer.
                            appState.containerDegradedToInMemory = true
                        }

                        // Path A3 (2026-05-13) — start MetricKit subscriber
                        // (same hookup as iPhone; flows anonymized crash +
                        // diagnostic reports to the Voxhora developer
                        // account via App Store Connect).
                        MetricKitManager.shared.startObserving()

                        // One-shot quantitiesNormalizedV1 migration — same
                        // Money-precision invariant we ship on iPhone.
                        // Idempotent + audit-logged + UserDefaults-gated.
                        QuantityMigration.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 023 Correction-log #1 / Step 8a — same
                        // structured-court-name bootstrap as iPhone side, in
                        // lockstep so both platforms populate Patrick's
                        // AttorneyProfile fields without waiting for CloudKit
                        // sync from the other device.
                        AttorneyProfileBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // Client info schema v5 (Client info screen feature,
                        // 2026-05-04 evening) — same intakeDate ← createdAt
                        // backfill as iPhone side. Idempotent + UserDefaults-
                        // gated. Runs on Mac independently because Mac's
                        // local SwiftData mirror also reads `intakeDate` from
                        // every Client UI surface.
                        ClientSchemaV5Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // Client info schema v6 (PDF intake portal + SMS
                        // reminders, DECISION 025 + 026, 2026-05-04 night) —
                        // same v6 sanity-pass as iPhone side. Idempotent +
                        // UserDefaults-gated.
                        ClientSchemaV6Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // AttorneyProfile schema v4 → v5 (DECISION 027 Step 10,
                        // 2026-05-05 night) — same v5 sanity-pass as iPhone
                        // side. 4 reminder-config fields populated with
                        // defaults that match the prior hardcoded
                        // SMSReminderScheduler constants byte-for-byte.
                        // Idempotent + UserDefaults-gated.
                        AttorneyProfileSchemaV5Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // UserPreferences schema → v7 (DECISION 030 Step 3,
                        // 2026-05-05 night) — same v7 sanity-pass as iPhone
                        // side. 5 new fields for cross-platform tab
                        // customization (iPhone/iPad/Mac TabViewCustomization
                        // blobs + Watch order/hidden JSON). Drill #5 additive
                        // default-safe; empty blobs fall back to
                        // TabRegistry.defaultVisibleTabs(for:) → byte-for-byte
                        // identical UI on first launch. Idempotent +
                        // UserDefaults-gated, with the DECISION 028.6 flag-
                        // discipline pattern (fetch + save in do/catch; flag
                        // set ONLY on success).
                        UserPreferencesSchemaV7Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 036.5 Step 1 (2026-05-06) — sole writer of
                        // UserPreferences row insertion. Same wiring as iPhone
                        // side. Closes the body-side multi-insert race that
                        // would have bitten public-Voxhora users on fresh
                        // installs. Runs AFTER AttorneyProfileBootstrap so the
                        // new row carries a real attorneyId.
                        UserPreferencesBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 043 (bilingual client communications,
                        // 2026-05-06) — AttorneyProfile v6 → v7 sanity pass.
                        // Same wiring as iPhone side.
                        AttorneyProfileSchemaV7Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 043 + 044 — Client v6 → v7 sanity pass.
                        // Same wiring as iPhone side.
                        ClientSchemaV7Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 056 (Client Docs vault, 2026-05-11) —
                        // Client v7 → v8 sanity pass. Adds docs:
                        // [ClientDoc]? to-many relationship. Drill #5
                        // additive default-safe. Same wiring as iPhone
                        // side. Uses the do/catch save pattern (flag
                        // flips ONLY on success).
                        ClientSchemaV8Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 044 — Apple Contacts backfill on Mac.
                        // Independent of iPhone (each device runs its own
                        // backfill bootstrap; the Voxhora Clients CNGroup
                        // is unified via iCloud Contacts so duplicate
                        // pushes from both devices resolve to the same
                        // CNContact). Lazy authorization on first run.
                        //
                        // Then DECISION 044 hotfix — one-shot dedup of
                        // the "Voxhora Clients" CNGroup. Same wiring as
                        // iPhone side; runs once per device.
                        Task { @MainActor in
                            await ClientContactsBackfillBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                            await ClientContactsCleanupBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        }

                        // DECISION 043 Step 2 (2026-05-06) — AttorneyProfile
                        // schema v7 → v8 sanity pass + semantic migration +
                        // QuickActions defaults seed. Same wiring as iPhone.
                        AttorneyProfileSchemaV8Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 043 Step 3 (2026-05-06) — AttorneyProfile
                        // schema v8 → v9 sanity pass + structured email
                        // migration. Same wiring as iPhone.
                        AttorneyProfileSchemaV9Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 046 (voice resilience toggles,
                        // 2026-05-07) — AttorneyProfile v9 → v10.
                        // Same wiring as iPhone.
                        AttorneyProfileSchemaV10Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 047 (Watch rich experience,
                        // 2026-05-07) — AttorneyProfile v10 → v11.
                        // Adds 7 Watch customization fields. Same
                        // wiring as iPhone. Mac doesn't render Watch
                        // settings yet but must run the bootstrap so
                        // schemaVersion stays in lockstep across
                        // CloudKit-mirrored devices.
                        AttorneyProfileSchemaV11Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 048 (Watch status indicator
                        // framework, 2026-05-07) — AttorneyProfile
                        // v11 → v12. Adds watchStatusIndicatorsJSON +
                        // R9 Travis defaults auto-seed.
                        AttorneyProfileSchemaV12Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 049 (Watch manual billing +
                        // per-device Bill Time entry mode, 2026-05-08)
                        // — AttorneyProfile v12 → v13. Adds
                        // watchBillingPresetsJSON + 3 entry-mode +
                        // 3 last-used fields. Drill #5 additive
                        // default-safe; no seed data needed.
                        AttorneyProfileSchemaV13Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 050 (cross-platform billing presets
                        // + per-device Presets/Activities mode toggle,
                        // 2026-05-08) — AttorneyProfile v13 → v14.
                        // Adds 3 manualPickerMode<Platform> fields.
                        // Drill #5 additive default-safe.
                        AttorneyProfileSchemaV14Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 052 (Watch comment-required entries,
                        // 2026-05-09) — AttorneyProfile v14 → v15. Adds
                        // watchAllowsCommentEntries. Drill #5 additive
                        // default-safe (false default preserves byte-
                        // for-byte current Watch behavior).
                        AttorneyProfileSchemaV15Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 055 (practice-area pluggability,
                        // 2026-05-10) — AttorneyProfile v15 → v16. Adds
                        // practiceAreaKey (default "criminal_defense").
                        // Drill #5 additive default-safe — bootstrap seeds
                        // empty-after-migration values back to
                        // criminal_defense so the (practice area ×
                        // jurisdiction) detector registry resolves
                        // correctly on the first PDF intake post-upgrade.
                        AttorneyProfileSchemaV16Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 055.8 (2026-05-10 EOS-9) — one-time
                        // backfill: copy Client.inmateBookingNumber +
                        // Client.arrestDate to every Case row owned by
                        // that Client where the Case's own field is
                        // empty. Fixes legacy appointment-letter imports
                        // that landed pre-DECISION-054.
                        ClientToCaseBackfillBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // 2026-05-08 — UserPreferences v7 → v8. Adds
                        // calendarSegment for cross-device Calendar
                        // segment mirror. Same wiring as iPhone.
                        UserPreferencesSchemaV8Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 051 (Fun Mode plugin architecture,
                        // 2026-05-08 EOS-5+). Adds 3 Fun Mode fields
                        // on UserPreferences. Drill #5 additive
                        // default-safe.
                        UserPreferencesSchemaV9Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 051 per-device addendum (2026-05-08
                        // EOS-6) — UserPreferences v9 → v10. Adds 4
                        // per-device Fun Mode fields. Drill #5 additive
                        // default-safe.
                        UserPreferencesSchemaV10Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 053 (Fun Mode sound-picker rip-out,
                        // 2026-05-09 EOS-13) — UserPreferences v10 →
                        // v11. Adds 3 per-device Sound effects ON/OFF
                        // Bools (replaces sound picker). Drill #5
                        // additive default-safe.
                        UserPreferencesSchemaV11Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 054 (2026-05-10) — same Cases-
                        // promotion bootstrap as iPhone side. Mac
                        // runs it independently (each device runs
                        // its own UserDefaults-gated bootstrap; the
                        // SwiftData rows themselves CloudKit-mirror
                        // so the schema-bump-on-Case-rows side runs
                        // once per device but converges to the same
                        // canonical state).
                        UserPreferencesSchemaV12Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // Register all Fun Mode visuals + sounds.
                        FunModeBootstrap.registerAllEffects()

                        // DECISION 040 — one-shot cleanup of legacy
                        // CalendarEvent rows the new trunk discipline
                        // would have prevented. UserDefaults-gated;
                        // runs once per device, no-ops on subsequent
                        // launches.
                        CalendarCleanupMigration.runIfNeeded(modelContext: modelContainer.mainContext)

                        // SIP custody-status foreground re-check (Client
                        // info screen feature, 2026-05-04 evening). Mac
                        // doesn't ship BGAppRefreshTask scheduling (no
                        // BackgroundTasks framework on macOS); it relies
                        // on the foreground re-check at app launch +
                        // CloudKit sync of inmate* fields from iOS so the
                        // IN CUSTODY indicators stay accurate without
                        // independent Mac polling. SIPInmateFetcher runs
                        // identically on both platforms (no platform-
                        // specific code path).
                        SIPPollScheduler.runForegroundCheckIfStale(modelContext: modelContainer.mainContext)

                        // DECISION 039 — Calendar auto-refresh on Mac.
                        // Mac doesn't ship BGAppRefreshTask (no
                        // BackgroundTasks framework on macOS); the
                        // hourly foreground Timer + scenePhase-driven
                        // stale-check cover Mac's always-on workflow.
                        // Defers to DSAFetcher.refreshAndPersist —
                        // same canonical entry point iPhone uses.
                        await CalendarRefreshScheduler.runIfStale(
                            modelContext: modelContainer.mainContext
                        )
                        CalendarRefreshScheduler.startForegroundTimer(
                            modelContext: modelContainer.mainContext
                        )

                        // DECISION 026 — SMS reminder rebuild on Mac.
                        // Mac doesn't have BGAppRefreshTask but
                        // UNUserNotificationCenter scheduling works
                        // identically. Mac fires notifications
                        // independently of iPhone (no cross-device
                        // dismiss coordination in v1).
                        VoxhoraNotificationDelegate.shared.router = reminderActionRouter
                        await SMSReminderScheduler.rescheduleAllOnLaunch(modelContext: modelContainer.mainContext)

                        // DECISION 058 Step 3 (2026-05-12) — Patrick
                        // Law Office Agent Phase 1 file watcher.
                        // (1) Wire the SwiftData context so the
                        // watcher can look up the AttorneyProfile
                        // (for detector selection) + Case rows (for
                        // synopsis writes) + UserPreferences (for
                        // the Destroy-source toggle). Must happen
                        // BEFORE the first start() call.
                        AutoIntakeWatcher.shared.setModelContext(modelContainer.mainContext)
                        // (2) Read current Auto-intake settings and
                        // start the watcher if the master toggle is
                        // ON. Reactive restart on settings change is
                        // wired from SettingsView's .onChange
                        // handlers (avoids spurious restarts from
                        // unrelated SwiftData saves).
                        let prefsDescriptor = FetchDescriptor<UserPreferences>()
                        if let prefs = try? modelContainer.mainContext.fetch(prefsDescriptor).first {
                            AutoIntakeWatcher.shared.refresh(
                                paths: prefs.autoIntakeWatchedFolderPaths,
                                enabled: prefs.autoIntakeEnabled
                            )
                        }
                    }
                    CloudSyncMonitor.shared.start()
                }
                // DECISION 039 — drive CalendarRefreshScheduler's
                // foreground Timer on scenePhase transitions. Mac
                // window comes back from being hidden/minimized →
                // fire stale-check + restart Timer; window goes
                // away → invalidate Timer.
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        switch newPhase {
                        case .active:
                            await CalendarRefreshScheduler.runIfStale(
                                modelContext: modelContainer.mainContext
                            )
                            CalendarRefreshScheduler.startForegroundTimer(
                                modelContext: modelContainer.mainContext
                            )
                        case .background, .inactive:
                            CalendarRefreshScheduler.stopForegroundTimer()
                        @unknown default:
                            break
                        }
                    }
                }
                .preferredColorScheme(.light)
                // DECISION 040.5 (2026-05-06) — Voxhora's "blue plumbing"
                // tint. See VoxhoraApp.swift for the full rationale.
                // voxGold reserved for HERO; voxInk for PLUMBING.
                .tint(.voxInk)
        }
        .modelContainer(modelContainer)
        // 2026-05-11 — `.commands { ImportFromDevicesCommands() }` was
        // removed in v4 after 3-agent diagnosis. Apple bug FB14893699
        // permanently disables the File-menu Continuity items if any
        // SwiftUI Toggle ever rendered in the active window — Voxhora's
        // Settings sheet has many. The AppKit Services route via
        // ContinuityCameraResponder.swift bypasses this bug entirely
        // and surfaces Continuity items in every context menu inside
        // ClientDocsSheet via macOS's auto-injection mechanism.
    }
}
