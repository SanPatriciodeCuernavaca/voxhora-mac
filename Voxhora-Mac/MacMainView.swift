//
//  MacMainView.swift
//  Voxhora-Mac — Phase 2 v0.4.2
//
//  The Mac primary attorney workstation. Replaces `StatusView` as the
//  root. Provides full functional parity with the iPhone app: the
//  attorney can capture (manual entry today; voice in v0.4.x), review,
//  edit, and export voucher CSVs to drag into the county portal.
//
//  Layout:
//    AppHeader (V wordmark + LIVE/OFFLINE)
//    NavigationSplitView
//      sidebar — TODAY / CLIENTS / VOUCHERS / INSIGHTS
//      detail  — selected section (TODAY shows TodayView; others show
//                ComingSoonView placeholders honestly stating the
//                target version)
//
//  StatusView is preserved as a developer-debug drawer reachable from
//  the toolbar (`...` menu → "Diagnostics") so the CloudKit sync state,
//  entry count, regenerate, and historical-CSV-import buttons stay
//  one tap away during the v0.4.x build-out without cluttering the
//  attorney-facing surface.
//

import SwiftUI
import SwiftData

struct MacMainView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selection: Section = .today
    @State private var showingDiagnostics = false

    enum Section: Hashable {
        case today, clients, vouchers, calendar
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader()

            NavigationSplitView {
                List(selection: $selection) {
                    sidebarRow(.today, label: "Today", systemImage: "clock")
                    sidebarRow(.clients, label: "Clients", systemImage: "person.2")
                    sidebarRow(.vouchers, label: "Vouchers", systemImage: "doc.text")
                    sidebarRow(.calendar, label: "Calendar", systemImage: "calendar")
                }
                .listStyle(.sidebar)
                .navigationTitle("Voxhora")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingDiagnostics = true
                        } label: {
                            Image(systemName: "stethoscope")
                        }
                        .help("Diagnostics — CloudKit sync, entry count, regenerate, historical import")
                    }
                }
            } detail: {
                detailContent
            }
        }
        .background(Color.voxPaper)
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                StatusView()
                    .frame(minWidth: 480, minHeight: 380)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingDiagnostics = false }
                        }
                    }
            }
        }
    }

    private func sidebarRow(_ section: Section, label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage)
            .tag(section)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .today:
            TodayView()
        case .clients:
            ClientsView()
        case .vouchers:
            VouchersView()
        case .calendar:
            CalendarView()
        }
    }
}
