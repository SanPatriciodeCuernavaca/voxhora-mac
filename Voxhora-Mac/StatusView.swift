//
//  StatusView.swift
//  Voxhora-Mac — Phase 2 v0.3.2
//
//  Minimal status window. Shows: how many entries are in the local
//  CloudKit-backed cache, when each artifact was last regenerated,
//  and a quick "open dashboard" link. The actual sync work is driven
//  by `EntryReplicator` — this view just observes and triggers.
//

import SwiftUI
import SwiftData

struct StatusView: View {
    @Query(sort: \Entry.loggedAt, order: .reverse) private var entries: [Entry]
    @Environment(\.modelContext) private var modelContext

    @StateObject private var replicator = EntryReplicator()
    @ObservedObject private var cloudSync = CloudSyncMonitor.shared

    @State private var importStatus: String? = nil
    @State private var isImporting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: cloudSyncIcon)
                    .foregroundStyle(cloudSyncColor)
                    .font(.system(size: 24))
                Text("Voxhora — Mac CloudKit subscriber")
                    .font(.system(size: 18, weight: .semibold))
            }

            if !cloudSync.state.isHealthy && cloudSync.state != .checking {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cloudSync.state.bannerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if !cloudSync.state.bannerDetail.isEmpty {
                        Text(cloudSync.state.bannerDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.72, green: 0.30, blue: 0.30))
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("iCloud sync:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(cloudSyncShortStatus)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(cloudSyncColor)
                }
                HStack {
                    Text("Entries in cache:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entries.count)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                HStack {
                    Text("entries.json last written:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(replicator.entriesJsonStatus)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("today.html last rendered:")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(replicator.dashboardStatus)
                        .font(.system(.body, design: .monospaced))
                }
                if let err = replicator.lastError {
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }

            Divider()

            HStack {
                Button("Regenerate now") {
                    replicator.replicate(entries: entries)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Open dashboard") {
                    let url = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Dropbox/Voxhora/today.html")
                    NSWorkspace.shared.open(url)
                }

                Button(isImporting ? "Importing…" : "Import historical CSVs") {
                    isImporting = true
                    importStatus = nil
                    Task {
                        let summary = HistoricalCSVImporter().importAll(into: modelContext)
                        var msg = "Imported \(summary.entriesCreated) entries (\(summary.clientsCreated) clients, \(summary.casesCreated) cases, \(summary.duplicatesSkipped) dupes skipped)"
                        if !summary.errors.isEmpty {
                            msg += "\nERRORS: \(summary.errors.prefix(3).joined(separator: " | "))"
                        }
                        importStatus = msg
                        isImporting = false
                    }
                }
                .disabled(isImporting)

                Spacer()

                Text("CloudKit container: iCloud.com.patrickfagerberg.voxhora")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let status = importStatus {
                Text(status)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        // .onChange(of: entries) only fires on array SHAPE changes (insert/delete),
        // not on field-level edits to existing entries — SwiftData @Model objects
        // use identity-based Equatable so mutating one entry doesn't make the
        // array "different". We trigger on a content digest instead, plus the
        // CloudKit remote-change notification as a safety net.
        .onChange(of: entryDigest) { _, _ in
            replicator.replicate(entries: entries)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            replicator.replicate(entries: entries)
        }
        .task {
            // Initial render on launch so dashboard reflects whatever's cached.
            replicator.replicate(entries: entries)
        }
    }

    // MARK: - Reactive digest

    /// String representation of all editable entry fields. Changes when ANY
    /// entry's content changes (clientName edit, quantity change, soft-delete,
    /// etc.) — not just when the array shape changes. Used as the trigger for
    /// .onChange so we regenerate Mac artifacts on every meaningful update.
    private var entryDigest: String {
        entries.map {
            "\($0.entryId):\($0.clientName):\($0.date):\($0.category):\($0.subActivity):\($0.quantity):\($0.descriptionText):\($0.archived)"
        }.joined(separator: "|")
    }

    // MARK: - CloudKit sync status helpers

    private var cloudSyncIcon: String {
        switch cloudSync.state {
        case .checking:               return "icloud"
        case .healthy:                return "checkmark.icloud.fill"
        case .noAccount, .restricted: return "xmark.icloud.fill"
        default:                      return "exclamationmark.icloud.fill"
        }
    }

    private var cloudSyncColor: Color {
        switch cloudSync.state {
        case .healthy:                return .green
        case .checking:               return .secondary
        case .noAccount, .restricted: return Color(red: 0.72, green: 0.30, blue: 0.30)
        default:                      return .orange
        }
    }

    private var cloudSyncShortStatus: String {
        switch cloudSync.state {
        case .checking:               return "checking…"
        case .healthy:                return "active"
        case .noAccount:              return "no account"
        case .restricted:             return "restricted"
        case .temporarilyUnavailable: return "unavailable"
        case .couldNotDetermine:      return "unknown"
        case .unknownError:           return "error"
        }
    }
}
