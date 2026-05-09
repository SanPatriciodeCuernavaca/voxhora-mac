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

@main
struct VoxhoraMacApp: App {
    /// Shared schema with iOS. Same container ID. Same models.
    let modelContainer: ModelContainer

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

    init() {
        do {
            let schema = Schema([
                Entry.self,
                Client.self,
                Case.self,
                AttorneyProfile.self,
                UserPreferences.self,
                AuditLogEntry.self,
                Voucher.self,                 // DECISION 012 — Phase C voucher state model
                CalendarEvent.self,           // DECISION 022 — Calendar feature (DSA-driven court schedule)
                ClientNote.self               // DECISION 040.2 — Client notes journal
            ])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.patrickfagerberg.voxhora")
            )
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // DECISION 026 — wire VoxhoraNotificationDelegate so reminder
        // notification taps route into the ReminderActionRouter on Mac.
        UNUserNotificationCenter.current().delegate = VoxhoraNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            MacMainView()
                .funModeOverlay()  // DECISION 051 — global Fun Mode visual overlay
                .environmentObject(pdfIntakeRouter)
                .environmentObject(reminderActionRouter)
                .sheet(item: $reminderActionRouter.pending) { pending in
                    SendReminderSheet(pending: pending)
                        .environmentObject(reminderActionRouter)
                }
                .frame(minWidth: 980, minHeight: 680)
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
                    pdfIntakeRouter.receivePDF(data: data, sourceMode: "mac_open_with")
                }
                .onAppear {
                    Task { @MainActor in
                        AuditLogger.shared.modelContext = modelContainer.mainContext

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

                        // 2026-05-08 — UserPreferences v7 → v8. Adds
                        // calendarSegment for cross-device Calendar
                        // segment mirror. Same wiring as iPhone.
                        UserPreferencesSchemaV8Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

                        // DECISION 051 (Fun Mode plugin architecture,
                        // 2026-05-08 EOS-5+). Adds 3 Fun Mode fields
                        // on UserPreferences. Drill #5 additive
                        // default-safe.
                        UserPreferencesSchemaV9Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

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
    }
}
