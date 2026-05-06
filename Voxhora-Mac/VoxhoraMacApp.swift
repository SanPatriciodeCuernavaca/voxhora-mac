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
                .environmentObject(pdfIntakeRouter)
                .environmentObject(reminderActionRouter)
                .sheet(item: $reminderActionRouter.pending) { pending in
                    SendReminderSheet(pending: pending)
                        .environmentObject(reminderActionRouter)
                }
                .frame(minWidth: 980, minHeight: 680)
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

                        // DECISION 043 Step 2 (2026-05-06) — AttorneyProfile
                        // schema v7 → v8 sanity pass + semantic migration +
                        // QuickActions defaults seed. Same wiring as iPhone.
                        AttorneyProfileSchemaV8Bootstrap.runIfNeeded(modelContext: modelContainer.mainContext)

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
                .preferredColorScheme(.light)
                // DECISION 040.5 (2026-05-06) — Voxhora's "blue plumbing"
                // tint. See VoxhoraApp.swift for the full rationale.
                // voxGold reserved for HERO; voxInk for PLUMBING.
                .tint(.voxInk)
        }
        .modelContainer(modelContainer)
    }
}
