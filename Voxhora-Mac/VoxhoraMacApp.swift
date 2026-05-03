//
//  VoxhoraMacApp.swift
//  Voxhora-Mac — Phase 2 v0.3.2
//
//  Mac CloudKit subscriber. Subscribes to the same private CloudKit
//  database the iOS app writes to (`iCloud.com.patrickfagerberg.voxhora`).
//  When entries arrive (from any signed-in device), regenerates the
//  Mac-side artifacts: ~/Dropbox/Voxhora/entries.json and today.html.
//
//  This app replaces the v0.1–v0.2 Python watcher.py that polled
//  Inbox.txt. There is no longer any Dropbox-as-data-path; the trunk
//  is CloudKit. Dropbox is now an OUTPUT location for the human-facing
//  dashboard (today.html), not an input transport.
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
                Voucher.self                  // DECISION 012 — Phase C voucher state model
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
