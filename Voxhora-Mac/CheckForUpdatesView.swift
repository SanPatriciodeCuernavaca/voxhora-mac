//
//  CheckForUpdatesView.swift
//  Voxhora-Mac
//
//  Distribution Phase 1 (2026-05-19) — SwiftUI wrapper for Sparkle's
//  "Check for Updates…" menu item. Boilerplate per Sparkle's docs:
//  https://sparkle-project.org/documentation/programmatic-setup/
//
//  The view model observes SPUUpdater.canCheckForUpdates so the menu
//  item correctly greys out while a check is in flight or while
//  Sparkle is otherwise unable to check (e.g., automatic check already
//  running).
//

import SwiftUI
import Sparkle

struct CheckForUpdatesView: View {
    @ObservedObject private var checker: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checker.canCheckForUpdates)
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
