//
//  HistoricalCSVImporter.swift
//  Voxhora-Mac — Phase 2 v0.3.4
//
//  One-time migration of pre-v0.3 entries from Patrick's existing per-client
//  CSV ledgers (`~/voxhora/clients/<Client_Name>.csv`) into CloudKit-backed
//  SwiftData. The CSVs were maintained by the v0.1-v0.2 Python watcher.py;
//  they represent the canonical historical billing record before CloudKit
//  became the trunk.
//
//  Idempotent: dedupes by (date, clientName, subActivity, quantity, rawEntry)
//  fingerprint so repeated runs don't multiply-create entries.
//

import Foundation
import SwiftData

@MainActor
final class HistoricalCSVImporter {
    /// `homeDirectoryForCurrentUser` always returns the actual user's home
    /// (e.g., `/Users/patrickfagerberg/`) regardless of sandbox state. We
    /// then point at the legacy Python watcher's per-client CSV ledger.
    private let csvFolder: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("voxhora/clients", isDirectory: true)
    }()

    struct ImportSummary {
        let csvsRead: Int
        let rowsScanned: Int
        let entriesCreated: Int
        let clientsCreated: Int
        let casesCreated: Int
        let duplicatesSkipped: Int
        let errors: [String]
    }

    func importAll(into context: ModelContext) -> ImportSummary {
        var csvsRead = 0
        var rowsScanned = 0
        var entriesCreated = 0
        var clientsCreated = 0
        var casesCreated = 0
        var duplicatesSkipped = 0
        var errors: [String] = []

        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: csvFolder, includingPropertiesForKeys: nil)
        } catch {
            return ImportSummary(
                csvsRead: 0, rowsScanned: 0,
                entriesCreated: 0, clientsCreated: 0, casesCreated: 0,
                duplicatesSkipped: 0,
                errors: ["Folder \(csvFolder.path): \(error.localizedDescription)"]
            )
        }

        // Build dedup index from existing entries (by content fingerprint).
        let existingEntries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        var fingerprints = Set<String>(existingEntries.map { entryFingerprint(
            date: $0.date,
            clientName: $0.clientName,
            subActivity: $0.subActivity,
            quantity: $0.quantity,
            rawEntry: $0.rawEntry
        ) })

        // Cache lookups so we don't re-create the same Client/Case for each row.
        var existingClients = (try? context.fetch(FetchDescriptor<Client>())) ?? []
        var clientByLowerName = Dictionary(
            uniqueKeysWithValues: existingClients.map { ($0.name.lowercased(), $0) }
        )
        var caseByClientId: [String: Case] = [:]

        // Default attorneyId for migration. Falls back to the singleton AttorneyProfile if present.
        let profileFetch = (try? context.fetch(FetchDescriptor<AttorneyProfile>())) ?? []
        let attorneyId = profileFetch.first?.attorneyId ?? UUID().uuidString

        for url in urls where url.pathExtension == "csv" {
            csvsRead += 1
            let clientNameFromFile = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")

            guard let rawContent = try? String(contentsOf: url, encoding: .utf8) else {
                errors.append("Could not read \(url.lastPathComponent)")
                continue
            }
            // Normalize CRLF + lone CR → LF before splitting. The legacy
            // Python watcher.py wrote CSVs with \r\n endings; Swift's
            // `split(separator: "\n")` would otherwise return rows with
            // trailing \r and confuse downstream parsing.
            let content = rawContent
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count >= 2 else { continue }   // header only = no entries

            for line in lines.dropFirst() {
                rowsScanned += 1
                guard let row = parseCSVLine(String(line)) else {
                    errors.append("Couldn't parse row in \(url.lastPathComponent)")
                    continue
                }
                guard row.count >= 11 else { continue }

                let date         = row[0]
                let category     = row[1]
                let subActivity  = row[2]
                let tidcCategory = row[3]
                let quantity     = Double(row[4]) ?? 0
                let description  = row[5]
                let rawEntry     = row[6]
                let loggedAtStr  = row[7]
                // exported: row[8]
                // schema_version: row[9]
                // entry_id: row[10] — historical UUID, ignore (we issue a fresh one)
                let archived     = row.count > 11 ? (row[11].lowercased() == "true") : false

                let fp = entryFingerprint(
                    date: date, clientName: clientNameFromFile,
                    subActivity: subActivity, quantity: quantity,
                    rawEntry: rawEntry
                )
                if fingerprints.contains(fp) {
                    duplicatesSkipped += 1
                    continue
                }
                fingerprints.insert(fp)

                // Find or create Client.
                let client: Client
                if let existing = clientByLowerName[clientNameFromFile.lowercased()] {
                    client = existing
                } else {
                    let c = Client(
                        name: clientNameFromFile,
                        source: "history_import",
                        attorneyId: attorneyId
                    )
                    context.insert(c)
                    clientByLowerName[clientNameFromFile.lowercased()] = c
                    existingClients.append(c)
                    clientsCreated += 1
                    client = c
                }

                // Find or create Case (one default Case per client for migration —
                // historical CSVs don't carry case_number).
                let case_: Case
                if let cached = caseByClientId[client.attorneyId + ":" + client.name] {
                    case_ = cached
                } else if let active = (client.cases ?? []).first(where: { $0.status == "active" }) {
                    case_ = active
                    caseByClientId[client.attorneyId + ":" + client.name] = case_
                } else {
                    let c = Case(
                        clientName: client.name,
                        caseNumber: "(historical)",
                        caseType: "Other",
                        offense: "",
                        attorneyId: attorneyId,
                        client: client
                    )
                    context.insert(c)
                    if client.cases == nil { client.cases = [] }
                    client.cases?.append(c)
                    caseByClientId[client.attorneyId + ":" + client.name] = c
                    casesCreated += 1
                    case_ = c
                }

                let loggedAt = parseISO8601(loggedAtStr) ?? Date()

                let entry = Entry(
                    caseId: case_.caseId,
                    clientName: client.name,
                    date: date,
                    category: category,
                    subActivity: subActivity,
                    tidcCategory: tidcCategory,
                    quantity: quantity,
                    descriptionText: description,
                    rawEntry: rawEntry,
                    loggedAt: loggedAt,
                    exported: false,
                    archived: archived,
                    attorneyId: attorneyId,
                    billedCase: case_
                )
                context.insert(entry)
                entriesCreated += 1
            }
        }

        if !AuditLogger.saveOrLog(context, callSite: "HistoricalCSVImporter.run", attorneyId: attorneyId) {
            errors.append("Save failed during bulk import — \(entriesCreated) staged entries may not have persisted. See audit chain (event MODEL_SAVE_FAILED).")
        }

        // Audit the import as one event so the chain knows this happened.
        if entriesCreated > 0 {
            AuditLogger.shared.log(
                eventType: .rosterImport,
                payload: [
                    "source": "historical_csv_ledgers",
                    "csvs_read": csvsRead,
                    "rows_scanned": rowsScanned,
                    "entries_created": entriesCreated,
                    "clients_created": clientsCreated,
                    "cases_created": casesCreated,
                    "duplicates_skipped": duplicatesSkipped
                ],
                attorneyId: attorneyId
            )
        }

        return ImportSummary(
            csvsRead: csvsRead,
            rowsScanned: rowsScanned,
            entriesCreated: entriesCreated,
            clientsCreated: clientsCreated,
            casesCreated: casesCreated,
            duplicatesSkipped: duplicatesSkipped,
            errors: errors
        )
    }

    // MARK: - CSV parsing

    /// Minimal CSV parser handling double-quoted fields containing commas.
    /// Sufficient for the watcher.py-produced files (no embedded newlines).
    private func parseCSVLine(_ line: String) -> [String]? {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                if inQuotes,
                   line.index(after: i) < line.endIndex,
                   line[line.index(after: i)] == "\"" {
                    current.append("\"")
                    i = line.index(after: i)
                } else {
                    inQuotes.toggle()
                }
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    private func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // watcher.py format: "2026-04-28T17:40:27"
        let alt = DateFormatter()
        alt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        alt.timeZone = TimeZone(identifier: "America/Chicago")
        return alt.date(from: s)
    }

    private func entryFingerprint(
        date: String,
        clientName: String,
        subActivity: String,
        quantity: Double,
        rawEntry: String
    ) -> String {
        "\(date)|\(clientName.lowercased())|\(subActivity.lowercased())|\(String(format: "%.2f", quantity))|\(rawEntry)"
    }
}
