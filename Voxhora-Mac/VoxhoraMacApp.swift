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
                    }
                    CloudSyncMonitor.shared.start()
                }
                .preferredColorScheme(.light)
        }
        .modelContainer(modelContainer)
    }
}
