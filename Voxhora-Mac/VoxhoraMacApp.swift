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
import Sparkle

/// 2026-06-09 — App-termination cleanup. The Mail scan runs as an
/// `osascript` subprocess; if Voxhora-Mac quits (Cmd-Q, graceful
/// NSApp.terminate, or deploy.sh's `osascript … to quit`) while a scan is in
/// flight, that subprocess would otherwise orphan to launchd and keep
/// hammering Mail.app's AppleEvent queue for up to its full timeout
/// (appointment scan 2700s / TechShare 1800s) — the root cause of the
/// 2026-06-09 Mail freeze (orphaned osascripts surviving repeated app kills).
/// `killAllScansNow()` reaps every in-flight scan subprocess before exit.
/// (A hard SIGKILL / crash can't be caught — acceptable residual; the common
/// quit paths all fire applicationWillTerminate.)
final class VoxhoraMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MailInboxBridge.killAllScansNow()
    }
}

@main
struct VoxhoraMacApp: App {
    /// Kills any in-flight Mail-scan osascript on quit so it can't orphan
    /// and wedge Mail (2026-06-09). See VoxhoraMacAppDelegate above.
    @NSApplicationDelegateAdaptor(VoxhoraMacAppDelegate.self) private var appDelegate

    /// Shared schema with iOS. Same container ID. Same models.
    let modelContainer: ModelContainer

    /// Distribution Phase 1 (2026-05-19) — Sparkle auto-updater.
    /// Polls SUFeedURL (Info.plist) every 24h, verifies downloaded DMGs
    /// against SUPublicEDKey, and applies the update on next quit.
    /// `startingUpdater: true` means the updater starts the moment the
    /// app launches — no further wiring required. The menu item lives
    /// in `.commands` below; automatic background checks need no UI.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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

    #if VOXHORA_TODOS
    /// To-Dos / Reminders (2026-06-06) — routes a to-do nag body-tap to
    /// TodoReminderSheet + handles the Done/Snooze action buttons.
    @StateObject private var todoNotificationRouter = TodoNotificationRouter()
    #endif

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
        // 2026-05-31 — window-state bloat self-clean. SwiftUI/AppKit autosave
        // a window-frame + split-view layout key PER unique root-view type
        // signature; every release changes that signature, so old keys
        // ORPHAN and never get reaped — the prefs plist balloons (Patrick's
        // reached 1.87 MB / ~1,150 such keys, contributing to the app
        // failing to draw/restore its window). Pruned here at the earliest
        // point — before the WindowGroup scene reads any frame — and only
        // when clearly bloated, so normal window-position memory survives
        // day-to-day. See WindowStateBloatCleanup.
        WindowStateBloatCleanup.runIfNeeded()

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
        // 2026-07-02 — schema list + container ID now come from
        // VoxhoraSchema, the single source of truth shared by all 7
        // former hand-maintained Schema sites (superset by construction).
        let schema = VoxhoraSchema.schema()
        let bootResult = ModelContainerBootstrap.boot(
            schema: schema,
            cloudKitContainerID: VoxhoraSchema.cloudKitContainerID
        )
        modelContainer = bootResult.container
        containerDegradedToInMemory = bootResult.degraded

        // Phase B Gap #2 closure (2026-05-16) — register the Mac SIP
        // background poll. SIPPollScheduler.registerBackgroundTask() is
        // platform-switched: iOS registers a BGTaskScheduler handler;
        // Mac schedules a recurring NSBackgroundActivityScheduler that
        // fires every ~4h (iOS DECISION 029 cadence). Mac lawyers who
        // keep Voxhora-Mac open (or come back after sleep) now get
        // SIP custody status updates without needing iPhone-side polls.
        SIPPollScheduler.registerBackgroundTask()

        #if VOXHORA_MUGSHOT
        // Booking-photo auto-fetch (Mac agent). Daily NSBackgroundActivity-
        // Scheduler; files the client's booking photo into their Documents
        // vault during the site's ~2-week availability window. Mac-only scrape;
        // CloudKit syncs the JPEG to every device.
        MugShotFetcher.registerBackgroundActivity()
        #endif

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
                #if VOXHORA_TODOS
                // To-Dos / Reminders — inject the to-do nag router
                // (TodoReminderSheet reads it; sheet wired in T8).
                .environmentObject(todoNotificationRouter)
                #endif
                .environment(appState)  // DECISION 054 follow-up
                .sheet(item: $reminderActionRouter.pending) { pending in
                    SendReminderSheet(pending: pending)
                        .environmentObject(reminderActionRouter)
                }
                #if VOXHORA_TODOS
                // To-Dos / Reminders — present the to-do nag sheet on a
                // notification body-tap (Done/Snooze actions skip this).
                .sheet(item: $todoNotificationRouter.pendingTodo) { pending in
                    TodoReminderSheet(pending: pending)
                        .environmentObject(todoNotificationRouter)
                }
                #endif
                // 2026-07-03 (11-inch audit, Matt's Mac) — minHeight 680
                // exceeded a short display's usable area with the Dock
                // visible (~674 at 1366×768), so the window's bottom edge
                // sat under the Dock. 600 fits every Mac laptop screen.
                .frame(minWidth: 980, minHeight: 600)
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
                #if VOXHORA_SETUP
                // Setup Assistant token drop-in (slice #1) — confirmation after a
                // one-tap setup link is redeemed (mirrors iOS VoxhoraApp).
                .alert(
                    appState.connectResult?.title ?? "",
                    isPresented: Binding(
                        get: { appState.connectResult != nil },
                        set: { if !$0 { appState.connectResult = nil } }
                    ),
                    presenting: appState.connectResult
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { result in
                    Text(result.message)
                }
                #endif
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
                    #if VOXHORA_SETUP
                    // Setup Assistant token drop-in (slice #1) — redeem a one-tap
                    // setup code (voxhora://connect?code= or the voxhora.app
                    // universal link) into the synced Keychain, then re-check
                    // account status. Handled before PDF intake.
                    if let code = VoxhoraConnectClaim.extractCode(from: url) {
                        Task { @MainActor in
                            appState.connectResult = await VoxhoraConnectClaim.redeem(code: code)
                            await AccountStatusService.refresh(appState)
                        }
                        return
                    }
                    #endif
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

                        // LLM Proxy kill switch (2026-06-07) — check account status
                        // at launch. Fail-open; only a definite server "suspended"
                        // (or 30+ days unable to verify) locks the app.
                        await AccountStatusService.refresh(appState)

                        // CloudKitSyncAuditor (2026-05-22) — subscribe to
                        // NSPersistentCloudKitContainer.eventChangedNotification
                        // for the Mac peer. Same defense-in-depth as iPhone +
                        // Watch — silent CloudKit halts now surface to the
                        // audit chain within minutes.
                        CloudKitSyncAuditor.shared.start()

                        // Path A3 (2026-05-13) — record degraded init to
                        // audit chain when CloudKit fallback was hit.
                        if containerDegradedToInMemory {
                            // 2026-07-02 (analysis Beat 3) — this audit row
                            // lands in the IN-MEMORY store and evaporates on
                            // quit. Remember the degraded session in
                            // UserDefaults so the next HEALTHY launch writes
                            // the durable row.
                            UserDefaults.standard.set(true, forKey: "voxhora.degradedLaunchPending")
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
                        } else if UserDefaults.standard.bool(forKey: "voxhora.degradedLaunchPending") {
                            UserDefaults.standard.removeObject(forKey: "voxhora.degradedLaunchPending")
                            AuditLogger.shared.log(
                                eventType: .modelContainerInitDegraded,
                                payload: [
                                    "platform": "macOS",
                                    "operation": "prior_session_was_degraded",
                                    "note": "a previous launch ran in-memory; any billing from that session was lost"
                                ],
                                attorneyId: ""
                            )
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

                        // EOS-FINAL-19 (Pending Intake Review, 2026-05-17) —
                        // Client v10 → v11 sanity pass + backfill of today's
                        // agent_appointment_intake clients to pendingReview.
                        // Same wiring as iPhone side.
                        ClientSchemaV11Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // SIP sticky-booking (2026-05-24) — same as iPhone
                        // wiring. Seeds historicalBookingNumbers for the
                        // currently-in-custody roster on first run.
                        ClientSchemaV12Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // Client v12 → v13 (2026-06-13) — TCSO booking-photo
                        // request stamps (VOXHORA_MUGSHOT_REQUEST). Additive
                        // default-safe; no seed.
                        ClientSchemaV13Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

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

                        // Discovery Portal v2 Phase 2.7 (2026-05-26) —
                        // AttorneyProfile schema v16 → v17. Adds
                        // discoveryPortalPresetsJSON (standalone
                        // preset list for the Bill Confirmation Sheet,
                        // independent of watchBillingPresets per
                        // Patrick's smoke-test feedback). Drill #5
                        // additive default-safe — no seed data.
                        AttorneyProfileSchemaV17Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // BYO Downloader + TechShare Login (2026-05-26) —
                        // v17 → v18 sanity pass. Adds discoverySourceMode
                        // + discoveryFolderNamingConvention for per-
                        // attorney choice between Voxhora's TechShare
                        // agent (Patrick default) and external downloaders
                        // (Scover Legal, etc.). Default "voxhora" +
                        // "canonical" preserves existing behavior byte-
                        // for-byte.
                        AttorneyProfileSchemaV18Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // v18 → v19 sanity pass. Adds discoveryDownloadVenue
                        // ("mac" default) — Settings → Advanced toggle that
                        // routes Discovery downloads through voxhora-agent-
                        // fagerberg on Fly.io ("cloud") vs the local
                        // voxhora-techshare-agent subprocess ("mac" — Patrick's
                        // pre-2026-05-27 setup).
                        AttorneyProfileSchemaV19Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // Cloud-Native Discovery (Patrick 2026-05-28) —
                        // v19→v20 adds discoveryCloudOnly (default false):
                        // the opt-in cloud-only Discovery toggle (list via
                        // Dropbox API + stream + fetch-to-temp). Mac + iPad UI;
                        // iPhone syncs the field via CloudKit for parity.
                        AttorneyProfileSchemaV20Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // Email templates (2026-06-05) — signatureTitle field.
                        AttorneyProfileSchemaV21Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // Step 2 (2026-06-06) — customVocabularyJSON field.
                        AttorneyProfileSchemaV22Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // Step 2 appellate prep (2026-06-06) — travisAppellateEnabled field.
                        AttorneyProfileSchemaV23Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // To-Dos / Reminders (2026-06-06) — v23→v24 adds the global
                        // todoRemindersEnabled master switch. Unconditional + inert
                        // (soaks the CloudKit migration ahead of the gated UI).
                        AttorneyProfileSchemaV24Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // Terms-of-Service gate (2026-06-09) — v24→v25 adds
                        // termsAcceptedVersion + termsAcceptedAt. Unconditional +
                        // inert (soaks the CloudKit migration ahead of the gate).
                        AttorneyProfileSchemaV25Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // TCSO booking-photo request policy (2026-06-13) —
                        // v25→v26 adds tcsoBookingPhotoRequestEnabled.
                        // Unconditional + inert (soaks ahead of the gated UI).
                        AttorneyProfileSchemaV26Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // To-Dos / Reminders (2026-06-06) — ceremonial Todo v1
                        // bootstrap (migrates nothing; defers via !todos.isEmpty).
                        TodoSchemaV1Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)
                        // Step 2 Phase B (B4) — feed the in-memory JurisdictionRegistry
                        // from the synced profile so a firm's custom_<id> daily vocab
                        // resolves. Runs every launch (registry is in-memory). Gated;
                        // a no-op for Travis. Never flips jurisdictionKey.
                        #if VOXHORA_CUSTOM_VOCAB
                        CustomVocabularyRegistration.refresh(modelContext: modelContainer.mainContext)
                        #endif
                        // Step 2 appellate prep — push the attorney's appellate
                        // toggle into the registry. Gated; no-op for the ~98%.
                        #if VOXHORA_TRAVIS_APPELLATE
                        TravisAppellateRegistration.refresh(modelContext: modelContainer.mainContext)
                        #endif
                        // Email templates (2026-06-05) — merge letter+email shelves into one.
                        EmailTemplatesMergeBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 055.8 (2026-05-10 EOS-9) — one-time
                        // backfill: copy Client.inmateBookingNumber +
                        // Client.arrestDate to every Case row owned by
                        // that Client where the Case's own field is
                        // empty. Fixes legacy appointment-letter imports
                        // that landed pre-DECISION-054.
                        ClientToCaseBackfillBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // 2026-05-30 — Case v3 → v4. Adds
                        // pcAffidavitSourceHash (String, default "") for
                        // the Cloud PC-Affidavit Synopsis sweeper's
                        // idempotency. Drill #5 additive default-safe.
                        // Same wiring as iPhone/iPad.
                        CaseSchemaV4Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // 2026-05-30 — Cloud PC-Affidavit Synopsis: auto-run
                        // the cloud sweep when a Case is created (e.g. a
                        // Travis appointment letter) so the new case's PC
                        // affidavit is synopsized without opening the Portal.
                        // Self-gates for non-cloud attorneys. This is the
                        // primary path for Matt's Scover Mac.
                        CloudPCSynopsisSweeper.shared.startObservingCaseCreation(modelContext: modelContainer.mainContext)

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

                        // DECISION 067 — Fun Mode iPad split-out
                        // (2026-05-21). Schema v14 → v15 adds
                        // funModeVisualKeyIPad + funModeSoundKeyIPad +
                        // funModeSoundEnabledIPad so iPad's Fun Mode
                        // state is independent of iPhone's. Mac doesn't
                        // run iPad Fun Mode but the schema bump is the
                        // "device has v15 fields locally" marker.
                        UserPreferencesSchemaV15Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // 2026-05-25 — Bulk-Import Mode removal. Same
                        // wiring as iPhone side.
                        UserPreferencesSchemaV16Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // Register all Fun Mode visuals + sounds.
                        FunModeBootstrap.registerAllEffects()

                        // DECISION 040 — one-shot cleanup of legacy
                        // CalendarEvent rows the new trunk discipline
                        // would have prevented. UserDefaults-gated;
                        // runs once per device, no-ops on subsequent
                        // launches.
                        CalendarCleanupMigration.runIfNeeded(modelContext: modelContainer.mainContext)

                        // One-shot recovery for duplicate AttorneyProfile
                        // rows spawned by CloudKit-hydration race
                        // (2026-05-21 root cause of the Jaret Watts 6→3
                        // calendar duplicates). Consolidates onto a single
                        // canonical profile per bar number, re-attributes
                        // every cross-model attorneyId reference, and
                        // recomputes CalendarEvent.stableEventId for the
                        // migrated rows so the trunk's dedup self-heals.
                        // UserDefaults-gated + race-safe (only flags
                        // complete when profiles non-empty).
                        AttorneyProfileDuplicateRecoveryBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // One-shot recovery for AttorneyProfile rows whose
                        // quickActions array is empty because V8Bootstrap
                        // set its UserDefaults flag prematurely
                        // (CloudKit-hydration race fix family, 2026-05-21).
                        // Idempotent + race-safe; no-op on devices whose
                        // profile already has actions.
                        AttorneyProfileQuickActionsRecoveryBootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

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

                        #if VOXHORA_MUGSHOT
                        // Foreground kick (cooldown-gated) so a freshly-opened
                        // Mac gets a recent booking-photo sweep even if the
                        // daily background activity was deferred.
                        MugShotFetcher.runForegroundSweepIfDue(modelContext: modelContainer.mainContext)
                        #endif

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
                        #if VOXHORA_TODOS
                        // To-Dos / Reminders — wire the to-do nag router + its
                        // model context (action-button path) + register the
                        // net-new TODO_REMINDER Done/Snooze category.
                        VoxhoraNotificationDelegate.shared.todoRouter = todoNotificationRouter
                        todoNotificationRouter.modelContext = modelContainer.mainContext
                        TodoNotificationCategory.register()
                        #endif
                        await SMSReminderScheduler.rescheduleAllOnLaunch(modelContext: modelContainer.mainContext)
                        #if VOXHORA_TODOS
                        // To-Dos / Reminders (2026-06-06) — rebuild the daily
                        // to-do nags from the live open set on every launch.
                        await TodoReminderScheduler.rescheduleAllOnLaunch(modelContext: modelContainer.mainContext)
                        #endif

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
                            // Sticky-enable recovery (2026-05-26) — defensive
                            // against SwiftData wipes from hard resets / fresh
                            // installs that revert autoIntakeEnabled to its
                            // schema default `false`. UserDefaults is
                            // device-local and survives SwiftData wipes, so
                            // a flag set when the lawyer first enables
                            // auto-intake (in SettingsView) persists across
                            // resets. One-way latch: never auto-enables on a
                            // device that has never been enabled. Restores
                            // ~/Downloads seed if paths empty so the watcher
                            // has somewhere to start (same seed logic as
                            // SettingsView's first-flip-ON).
                            let userEverEnabledKey = "voxhora.autoIntake.userHasEverEnabled"
                            if !prefs.autoIntakeEnabled
                               && UserDefaults.standard.bool(forKey: userEverEnabledKey) {
                                prefs.autoIntakeEnabled = true
                                if prefs.autoIntakeWatchedFolderPaths.isEmpty {
                                    let downloads = (NSHomeDirectory() as NSString)
                                        .appendingPathComponent("Downloads")
                                    prefs.autoIntakeWatchedFolderPaths = [downloads]
                                }
                                try? modelContainer.mainContext.save()
                                AutoIntakeWatcher.shared.log(
                                    "STICKY-ENABLE RESTORED — autoIntakeEnabled was false on launch but UserDefaults remembers user previously enabled it. Restored to true (likely SwiftData wipe from hard reset / fresh install)."
                                )
                            }
                            // Backfill the UserDefaults marker for lawyers who
                            // enabled auto-intake BEFORE the sticky-enable
                            // pattern shipped (2026-05-26). Only fires when
                            // UserDefaults has NEVER been written (object ==
                            // nil) — once written, the SettingsView onChange
                            // handler owns it. Distinguishing "never written"
                            // from "set to false" matters: a lawyer who
                            // explicitly disabled the toggle should NOT have
                            // their disable overridden by a backfill.
                            if prefs.autoIntakeEnabled
                               && UserDefaults.standard.object(forKey: userEverEnabledKey) == nil {
                                UserDefaults.standard.set(true, forKey: userEverEnabledKey)
                                AutoIntakeWatcher.shared.log(
                                    "STICKY-ENABLE BACKFILL — autoIntakeEnabled was already true on launch; recorded UserDefaults marker for future hard-reset recovery."
                                )
                            }

                            // Cloud-only discovery sticky-enable (2026-05-30) —
                            // same latch family. discoveryCloudOnly defaults
                            // false + is CloudKit-synced, so a store wipe / fresh
                            // install reverts it, silently routing TechShare
                            // downloads back into the local Dropbox folder
                            // (loading the Mac) instead of the staging→cloud→
                            // delete path. Restore to true when the profile
                            // reports false but UserDefaults remembers the lawyer
                            // enabled it; an explicit OFF wrote false, so this
                            // never overrides intent. Backfill the marker for a
                            // lawyer who enabled it before this latch shipped.
                            let cloudOnlyKey = "voxhora.discoveryCloudOnly.userHasEverEnabled"
                            let profileDescriptor = FetchDescriptor<AttorneyProfile>()
                            if let profile = try? modelContainer.mainContext.fetch(profileDescriptor).first {
                                if !profile.discoveryCloudOnly
                                   && UserDefaults.standard.bool(forKey: cloudOnlyKey) {
                                    profile.discoveryCloudOnly = true
                                    try? modelContainer.mainContext.save()
                                } else if profile.discoveryCloudOnly
                                   && UserDefaults.standard.object(forKey: cloudOnlyKey) == nil {
                                    UserDefaults.standard.set(true, forKey: cloudOnlyKey)
                                }

                                // Discovery SOURCE + LAYOUT sticky-restore
                                // (2026-05-30) — same latch family. These two
                                // CloudKit-synced fields revert to their
                                // "voxhora"/"canonical" defaults after a store
                                // wipe / fresh install, which silently breaks a
                                // Scover attorney (Matt): the cloud PC-synopsis
                                // sweep + Discovery Portal then look in the wrong
                                // tree. DiscoverySourcePickerSettingsRow mirrors
                                // the user's choice into UserDefaults on every
                                // change; restore it here when the profile has
                                // reverted to the default but the marker shows a
                                // non-default choice. An explicit switch back to
                                // Voxhora/canonical wrote that value to the marker,
                                // so this never overrides intent.
                                let modeKey = "voxhora.discoverySourceMode.userValue"
                                if let savedMode = UserDefaults.standard.string(forKey: modeKey),
                                   !savedMode.isEmpty,
                                   savedMode != profile.discoverySourceMode,
                                   profile.discoverySourceMode == "voxhora" {
                                    profile.discoverySourceMode = savedMode
                                    try? modelContainer.mainContext.save()
                                }
                                let conventionKey = "voxhora.discoveryFolderNamingConvention.userValue"
                                if let savedConvention = UserDefaults.standard.string(forKey: conventionKey),
                                   !savedConvention.isEmpty,
                                   savedConvention != profile.discoveryFolderNamingConvention,
                                   profile.discoveryFolderNamingConvention == "canonical" {
                                    profile.discoveryFolderNamingConvention = savedConvention
                                    try? modelContainer.mainContext.save()
                                }
                            }
                            AutoIntakeWatcher.shared.refresh(
                                paths: prefs.autoIntakeWatchedFolderPaths,
                                enabled: prefs.autoIntakeEnabled
                            )
                            // Beat 2 (2026-05-15) — Patrick Law
                            // Office Agent Phase 1 Source A timer
                            // auto-poll. Sibling to AutoIntakeWatcher;
                            // starts the Mail inbox Timer when
                            // mailInboxMonitoringEnabled is ON.
                            // Reactive restart on settings change is
                            // wired from SettingsView's .onChange
                            // handlers (master toggle / sender list /
                            // interval / processed mailbox name).
                            MailInboxWatcher.shared.setModelContext(modelContainer.mainContext)
                            // Sticky-enable recovery for the two Mail-inbox
                            // monitoring toggles (2026-06-09) — same latch
                            // family as autoIntake above. mailInboxMonitoring
                            // (appointment letters) + techshareMailboxScan (PC
                            // affidavits) both default `false` + are
                            // CloudKit-synced, so the UserPreferences hydration
                            // race after a Mac deploy (a fresh empty prefs row
                            // is created with the schema default before the
                            // synced row replicates down) silently reverts them
                            // to OFF — Patrick's autonomous intake stops every
                            // time the Mac is updated. UserDefaults is
                            // device-local + survives the deploy (lives in
                            // ~/Library/Preferences/, not the SwiftData store),
                            // so a flag set when Patrick first enables each
                            // toggle (in SettingsView's onChange) persists.
                            // One-way latch: restore to true ONLY when SwiftData
                            // reports false but UserDefaults remembers true; an
                            // explicit user-disable writes false, so a future
                            // launch respects that intent. Backfill the marker
                            // for a toggle enabled before this latch shipped
                            // (object == nil → never written).
                            let mailMonitorKey = "voxhora.mailInboxMonitoring.userHasEverEnabled"
                            if !prefs.mailInboxMonitoringEnabled
                               && UserDefaults.standard.bool(forKey: mailMonitorKey) {
                                prefs.mailInboxMonitoringEnabled = true
                                try? modelContainer.mainContext.save()
                            } else if prefs.mailInboxMonitoringEnabled
                               && UserDefaults.standard.object(forKey: mailMonitorKey) == nil {
                                UserDefaults.standard.set(true, forKey: mailMonitorKey)
                            }
                            let techshareScanKey = "voxhora.techshareMailboxScan.userHasEverEnabled"
                            if !prefs.techshareMailboxScanEnabled
                               && UserDefaults.standard.bool(forKey: techshareScanKey) {
                                prefs.techshareMailboxScanEnabled = true
                                try? modelContainer.mainContext.save()
                            } else if prefs.techshareMailboxScanEnabled
                               && UserDefaults.standard.object(forKey: techshareScanKey) == nil {
                                UserDefaults.standard.set(true, forKey: techshareScanKey)
                            }
                            MailInboxWatcher.shared.refresh(
                                enabled: prefs.mailInboxMonitoringEnabled,
                                senders: prefs.mailInboxSenderFilter,
                                intervalSeconds: prefs.mailInboxPollIntervalSeconds,
                                processedMailboxName: prefs.mailInboxProcessedMailboxName
                            )
                            // Restore TechShare scan toggle + interval from persisted prefs (CloudKit-synced).
                            MailInboxWatcher.shared.setTechshareScanConfig(
                                enabled: prefs.techshareMailboxScanEnabled,
                                intervalSeconds: prefs.techshareMailboxScanIntervalSeconds
                            )
                            // Discovery Portal v2 Phase 1.1+1.2+1.3 (2026-05-25)
                            // — eager DownloadQueue init at app launch.
                            // Without this, the queue's restoreFromDisk +
                            // advanceQueue only fires when a user opens
                            // CaseInfoSheet (lazy singleton access). Eager
                            // init means: (a) Voxhora-Mac quit + relaunch
                            // immediately resumes any .running items as
                            // .queued + spawns fresh agents, (b) Phase 1.2
                            // side effects (sleep prevention + Dock badge
                            // + macOS Notification permission prompt)
                            // engage at launch, (c) Phase 1.3 audit
                            // events have attorneyId populated via
                            // setModelContext below.
                            DownloadQueue.shared.setModelContext(modelContainer.mainContext)
                            // Migration Import Portal v1 Session 4
                            // (2026-05-16) — sweep orphan bulk-import
                            // PDFs (`*__voxmigr-*.pdf`) older than 30
                            // days from the watched folders. Cheap
                            // (file enumeration + age check); runs
                            // once per launch. Only touches PDFs
                            // Voxhora itself copied via bulk-drop;
                            // never deletes the lawyer's own files.
                            MigrationOrphanCleanup.runIfDue(modelContext: modelContainer.mainContext)
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
                            // LLM Proxy kill switch — re-check on foreground in case
                            // the account changed while the app was in the background.
                            await AccountStatusService.refresh(appState)
                            await CalendarRefreshScheduler.runIfStale(
                                modelContext: modelContainer.mainContext
                            )
                            CalendarRefreshScheduler.startForegroundTimer(
                                modelContext: modelContainer.mainContext
                            )
                            #if VOXHORA_TODOS
                            // To-Dos / Reminders — re-sync the daily nags on
                            // foreground (a to-do may have changed elsewhere).
                            await TodoReminderScheduler.rescheduleAllOnLaunch(modelContext: modelContainer.mainContext)
                            #endif
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
        //
        // Distribution Phase 1 (2026-05-19) — adds "Check for Updates…"
        // under the Voxhora menu (right after "About Voxhora"), the
        // macOS-canonical location. CommandGroup(after: .appInfo) is
        // unaffected by FB14893699 (which only impacts File-menu
        // Continuity items, not App-menu Sparkle items).
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            // Discovery Portal v2 Phase 2.1 (2026-05-26) — Window menu
            // entry that opens the standalone Discovery Portal window
            // (⇧⌘D). Placed after .windowList so it lives in the Window
            // menu alongside the SwiftUI auto-added window listing —
            // Mac-canonical placement for "open another window" actions.
            // Original ⌃⌘D shortcut + .toolbar placement (2026-05-26
            // first pass) was changed because ⌃⌘D collides with macOS's
            // system "Look Up" / Dictionary shortcut and the menu
            // binding never fired. ⇧⌘D is clean + memorable + free of
            // system conflicts. Future entry points (CaseInfoSheet button,
            // MainTabView Discovery tab row tap) reuse the same
            // openWindow(id:) call via @Environment(\.openWindow).
            CommandGroup(after: .windowList) {
                DiscoveryPortalMenuButton()
                // Migration Phase 0 (2026-07-05) — Window-menu entry for the
                // one-time Dev→Prod migration window. Tool builds only
                // (Patrick's Debug + the two hand-installed tool apps);
                // compiled out of Matt's Sparkle Release.
                #if VOXHORA_MIGRATION
                MigrationDataMenuButton()
                #endif
            }
        }

        // VoxHelp Phase 1 Edit #3.2 (2026-05-20) — separate floating
        // window for the in-app AI assistant. On Mac, VoxHelpButton's
        // toolbar tap calls openWindow(id: "voxhelp") instead of
        // presenting a modal sheet — lets the attorney read Claude's
        // answer alongside the main Voxhora-Mac window rather than
        // having it block the rest of the app. Window has its own
        // red close button + Cmd-W dismissal; no toolbar Done needed.
        // iOS uses sheet detents (.medium / .large + background
        // interaction) instead of a window — same end goal (read +
        // interact concurrently), different SwiftUI pattern per
        // platform conventions.
        Window("VoxHelp", id: "voxhelp") {
            VoxHelpView()
                .modelContainer(modelContainer)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 620)
        .defaultPosition(.topTrailing)

        // Discovery Portal v2 Phase 2.1 (2026-05-26) — standalone
        // NSWindow for the discovery review surface. Parallel to
        // VoxHelp's floating window above (same scene-declaration
        // pattern). Window is openable via the View → Discovery
        // Portal (⌃⌘D) menu item below; future Phase 2.4 + 2.11
        // entry points (CaseInfoSheet "Review Full Discovery"
        // button + MainTabView Discovery tab row tap) call
        // `openWindow(id: "discovery-portal")` from their tap
        // handlers. Default 1400×900 per the implementation plan
        // (visual workspace for AVPlayer + PDFKit panes).
        Window("Discovery Portal", id: "discovery-portal") {
            DiscoveryPortalWindowView()
                .modelContainer(modelContainer)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1400, height: 900)

        // Migration Phase 0 (2026-07-05) — standalone window for the
        // one-time Dev→Prod migration (MigrationInlineView + a live
        // entitlement-read environment badge). A WINDOW, not a Settings
        // section, because the IMPORT step runs on a FRESH store where
        // ContentView is gated on onboarding and the Settings tab is
        // unreachable. Same scene pattern as VoxHelp above. Tool builds
        // only — compiled out of Matt's Sparkle Release.
        #if VOXHORA_MIGRATION
        Window("Data Migration", id: "data-migration") {
            MigrationDataWindowView()
                .modelContainer(modelContainer)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 480)
        #endif
    }
}

/// Self-cleaning guard against window-state preference bloat.
///
/// SwiftUI + AppKit autosave a window-frame and split-view layout entry
/// keyed by the FULL root-view type signature. Every release changes that
/// signature (a new modifier, a new wrapper), so each version writes fresh
/// keys while the previous version's keys orphan and are never reaped. Over
/// many updates the app's preferences plist balloons — Patrick's reached
/// ~1.87 MB across ~1,150 `NSWindow Frame …` / `NSSplitView Subview Frames …`
/// keys, which contributed to the app failing to draw / restore its window
/// (the no-window-on-launch symptom of 2026-05-31).
///
/// This prunes those keys at launch, but ONLY when the count is clearly
/// abnormal — so ordinary window-position memory is preserved in day-to-day
/// use. When it does fire, the entire cost is the window opening at its
/// default size once; SwiftUI immediately re-saves a small, current set.
/// Called first thing in `VoxhoraMacApp.init()`, before the WindowGroup
/// scene reads any saved frame.
enum WindowStateBloatCleanup {

    /// Substrings that identify an AppKit/SwiftUI window-layout autosave key.
    private static let windowStateKeyMarkers = [
        "NSWindow Frame",
        "NSSplitView Subview Frames",
        "NSToolbar Configuration",
        "NSTableView",
        "NSOutlineView",
        "NSScrollView"
    ]

    /// Only act above this many window-layout keys. A healthy single-window
    /// app holds a small handful (one frame + a few split-view keys for the
    /// current signature); hundreds-to-thousands is pure orphaned bloat.
    private static let maxHealthyWindowStateKeys = 24

    static func runIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return }

        let windowStateKeys = domain.keys.filter { key in
            windowStateKeyMarkers.contains { key.contains($0) }
        }

        guard windowStateKeys.count > maxHealthyWindowStateKeys else { return }

        for key in windowStateKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NSLog("Voxhora: WindowStateBloatCleanup pruned \(windowStateKeys.count) orphaned window-layout preference keys.")
    }
}
