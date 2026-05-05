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

@main
struct VoxhoraMacApp: App {
    /// Shared schema with iOS. Same container ID. Same models.
    let modelContainer: ModelContainer

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
                CalendarEvent.self            // DECISION 022 — Calendar feature (DSA-driven court schedule)
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
    }

    var body: some Scene {
        WindowGroup {
            MacMainView()
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
                    }
                    CloudSyncMonitor.shared.start()
                }
                .preferredColorScheme(.light)
        }
        .modelContainer(modelContainer)
    }
}
