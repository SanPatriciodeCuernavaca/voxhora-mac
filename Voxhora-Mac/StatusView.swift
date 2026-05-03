//
//  StatusView.swift
//  Voxhora-Mac
//
//  Diagnostics drawer reachable from MacMainView's stethoscope toolbar
//  button. Shows CloudKit sync state, the count of entries in the
//  local cache, and the historical-CSV importer for migrating pre-
//  Voxhora time records. Renders as a sheet over the main attorney
//  surface; doesn't interrupt billing flow.
//

import SwiftUI
import SwiftData

struct StatusView: View {
    @Query(sort: \Entry.loggedAt, order: .reverse) private var entries: [Entry]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var cloudSync = CloudSyncMonitor.shared

    @State private var importStatus: String? = nil
    @State private var isImporting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: cloudSyncIcon)
                    .foregroundStyle(cloudSyncColor)
                    .font(.system(size: 24))
                Text("Voxhora — Diagnostics")
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
            }

            Divider()

            HStack {
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
