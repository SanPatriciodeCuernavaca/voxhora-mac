//
//  EntryReplicator.swift
//  Voxhora-Mac — Phase 2 v0.3.2
//
//  Whenever the SwiftData/CloudKit Entry set changes, regenerate the
//  Mac-side artifacts:
//    1. ~/Dropbox/Voxhora/entries.json — full overwrite (idempotent;
//       no append+reconcile path because CloudKit is the source of
//       truth, not the file).
//    2. ~/Dropbox/Voxhora/today.html — single-file dashboard rendered
//       from the same Entry set. Self-contained HTML+CSS, no external
//       deps, opens in any browser.
//
//  Idempotent and crash-safe: writes via atomic temp-file rename. If a
//  crash interrupts a write, the previous file is still intact.
//

import Foundation
import Combine

@MainActor
final class EntryReplicator: ObservableObject {
    @Published var entriesJsonStatus: String = "—"
    @Published var dashboardStatus: String = "—"
    @Published var lastError: String? = nil

    private let voxhoraFolder: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Dropbox/Voxhora", isDirectory: true)
    }()

    private var entriesJsonURL: URL {
        voxhoraFolder.appendingPathComponent("entries.json")
    }

    private var todayHTMLURL: URL {
        voxhoraFolder.appendingPathComponent("today.html")
    }

    private let isoTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f
    }()

    func replicate(entries: [Entry]) {
        do {
            try writeEntriesJson(entries: entries)
            entriesJsonStatus = isoTimestampFormatter.string(from: Date())
        } catch {
            lastError = "entries.json write failed: \(error.localizedDescription)"
            return
        }

        do {
            try writeTodayHTML(entries: entries)
            dashboardStatus = isoTimestampFormatter.string(from: Date())
            lastError = nil
        } catch {
            lastError = "today.html write failed: \(error.localizedDescription)"
        }
    }

    // MARK: - entries.json

    private func writeEntriesJson(entries: [Entry]) throws {
        let payload = entries
            .filter { !$0.archived }
            .map { entry -> [String: Any] in
                [
                    "entry_id": entry.entryId,
                    "case_id": entry.caseId,
                    "client": entry.clientName,
                    "date": entry.date,
                    "category": entry.category,
                    "sub_activity": entry.subActivity,
                    "tidc_category": entry.tidcCategory,
                    "quantity": entry.quantity,
                    "description": entry.descriptionText,
                    "raw_entry": entry.rawEntry,
                    "logged_at": ISO8601DateFormatter().string(from: entry.loggedAt),
                    "exported": entry.exported,
                    "attorney_id": entry.attorneyId,
                    "schema_version": entry.schemaVersion
                ]
            }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ensureFolderExists()
        try atomicWrite(data: data, to: entriesJsonURL)
    }

    // MARK: - today.html

    private func writeTodayHTML(entries: [Entry]) throws {
        let active = entries.filter { !$0.archived }

        // Compute aggregates in attorney TZ (Travis County: America/Chicago).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        cal.firstWeekday = 1

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = cal.timeZone
        let today = dateFormatter.string(from: Date())

        let weekStart: String = {
            guard let d = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) else { return today }
            return dateFormatter.string(from: d)
        }()
        let monthStart: String = {
            guard let d = cal.date(from: cal.dateComponents([.year, .month], from: Date())) else { return today }
            return dateFormatter.string(from: d)
        }()
        let yearStart: String = {
            guard let d = cal.date(from: cal.dateComponents([.year], from: Date())) else { return today }
            return dateFormatter.string(from: d)
        }()

        let todayHrs = active.filter { $0.date == today }.reduce(0.0) { $0 + $1.quantity }
        let weekHrs = active.filter { $0.date >= weekStart }.reduce(0.0) { $0 + $1.quantity }
        let monthHrs = active.filter { $0.date >= monthStart }.reduce(0.0) { $0 + $1.quantity }
        let yearHrs = active.filter { $0.date >= yearStart }.reduce(0.0) { $0 + $1.quantity }
        let weekClients = Set(active.filter { $0.date >= weekStart }.map { $0.clientName }).count

        let recentRows = active
            .sorted { $0.loggedAt > $1.loggedAt }
            .prefix(40)
            .map { entry in
                let qtyStr = String(format: "%.1f", entry.quantity)
                let timeStr = isoTimestampFormatter.string(from: entry.loggedAt)
                let descPart = entry.descriptionText.isEmpty
                    ? ""
                    : " · \(escapeHTML(entry.descriptionText))"
                return """
                <tr>
                  <td class="time">\(timeStr)</td>
                  <td>
                    <div class="client">\(escapeHTML(entry.clientName)) <span class="cat cat-\(escapeAttribute(entry.category))">\(escapeHTML(entry.categoryDisplay))</span></div>
                    <div class="activity">\(escapeHTML(entry.subActivity))\(descPart)</div>
                  </td>
                  <td class="qty">\(qtyStr) h</td>
                </tr>
                """
            }
            .joined(separator: "\n")

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Voxhora — Today</title>
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <style>
            :root {
              --paper: #F7F2E7;
              --ink: #1F2A4A;
              --ink-soft: #5A607A;
              --gold: #B89968;
              --line: #DCD4BF;
              --cream: #FBF7EE;
            }
            html, body { margin: 0; padding: 0; background: var(--paper); color: var(--ink);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
            .wrap { max-width: 760px; margin: 0 auto; padding: 32px 20px 64px; }
            h1 { font-family: "Charter", Georgia, serif; font-weight: 600;
              font-size: 28px; margin: 0 0 8px; letter-spacing: 0.3px; }
            .subtitle { color: var(--ink-soft); font-size: 13px; margin-bottom: 24px; }
            .agg { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0;
              background: white; border: 1px solid var(--line); border-radius: 16px;
              padding: 18px 12px; margin-bottom: 18px; }
            .agg .cell { text-align: center; border-right: 1px solid var(--line); }
            .agg .cell:last-child { border-right: none; }
            .agg .num { font-family: "Charter", Georgia, serif; font-size: 30px; font-weight: 500; }
            .agg .num .h { font-size: 14px; color: var(--ink-soft); margin-left: 2px; }
            .agg .label { font-size: 10px; letter-spacing: 1.5px; text-transform: uppercase;
              color: var(--ink-soft); margin-top: 4px; }
            .summary { text-align: center; font-size: 13px; color: var(--ink-soft); margin-bottom: 20px; }
            .summary strong { color: var(--ink); }
            .section-label { font-size: 11px; letter-spacing: 1.4px; text-transform: uppercase;
              color: var(--ink-soft); margin: 22px 0 10px; }
            table { width: 100%; border-collapse: separate; border-spacing: 0 6px; }
            td { background: white; padding: 12px 14px; border-top: 1px solid var(--line);
              border-bottom: 1px solid var(--line); }
            td:first-child { border-left: 1px solid var(--line); border-top-left-radius: 12px; border-bottom-left-radius: 12px; }
            td:last-child { border-right: 1px solid var(--line); border-top-right-radius: 12px; border-bottom-right-radius: 12px; }
            td.time { color: var(--ink-soft); font-size: 11px; width: 70px; }
            td.qty { text-align: right; font-family: "Charter", Georgia, serif;
              font-size: 17px; font-weight: 500; width: 70px; }
            .client { font-weight: 600; font-size: 14px; }
            .activity { color: var(--ink-soft); font-size: 12px; margin-top: 3px; }
            .cat { display: inline-block; padding: 2px 8px; border-radius: 999px;
              font-size: 9.5px; font-weight: 600; letter-spacing: 0.7px; text-transform: uppercase;
              vertical-align: 1px; margin-left: 4px; background: rgba(184,153,104,0.18); color: var(--ink); }
            .cat-Court_Time { background: rgba(184,153,104,0.22); }
            .cat-Case_Work { background: rgba(31,42,74,0.10); }
            .cat-Communication { background: rgba(120,150,200,0.18); }
            .cat-Investigation { background: rgba(140,100,60,0.18); }
            .empty { text-align: center; color: var(--ink-soft); font-size: 13px;
              padding: 36px 12px; background: white; border: 1px solid var(--line); border-radius: 12px; }
            footer { text-align: center; color: var(--ink-soft); font-size: 11px; margin-top: 32px; }
          </style>
        </head>
        <body>
          <div class="wrap">
            <h1>Voxhora</h1>
            <div class="subtitle">Today's billing — synced from your iPhone via iCloud</div>

            <div class="agg">
              <div class="cell"><div class="num">\(formatHrs(todayHrs))<span class="h">h</span></div><div class="label">Today</div></div>
              <div class="cell"><div class="num">\(formatHrs(weekHrs))<span class="h">h</span></div><div class="label">Week</div></div>
              <div class="cell"><div class="num">\(formatHrs(monthHrs))<span class="h">h</span></div><div class="label">Month</div></div>
              <div class="cell"><div class="num">\(formatHrs(yearHrs))<span class="h">h</span></div><div class="label">Year</div></div>
            </div>

            <div class="summary">
              <strong>\(formatHrs(weekHrs)) h</strong> period total ·
              <strong>\(weekClients) client\(weekClients == 1 ? "" : "s")</strong> billed
            </div>

            <div class="section-label">Recent</div>
            \(active.isEmpty
              ? #"<div class="empty">No entries yet — dictate one on your iPhone to begin.</div>"#
              : "<table>\(recentRows)</table>")

            <footer>Rendered \(isoTimestampFormatter.string(from: Date())) — Voxhora-Mac v0.3.2 · CloudKit canonical</footer>
          </div>
        </body>
        </html>
        """

        try ensureFolderExists()
        guard let data = html.data(using: .utf8) else {
            throw NSError(domain: "VoxhoraMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't encode HTML as UTF-8"])
        }
        try atomicWrite(data: data, to: todayHTMLURL)
    }

    // MARK: - Helpers

    private func ensureFolderExists() throws {
        if !FileManager.default.fileExists(atPath: voxhoraFolder.path) {
            try FileManager.default.createDirectory(
                at: voxhoraFolder,
                withIntermediateDirectories: true
            )
        }
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private func formatHrs(_ h: Double) -> String {
        h >= 10 ? String(format: "%.0f", h) : String(format: "%.1f", h)
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
         .replacingOccurrences(of: "/", with: "_")
    }
}
