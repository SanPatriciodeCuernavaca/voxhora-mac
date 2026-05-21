//
//  MacMainView.swift
//  Voxhora-Mac — Phase 2 v0.5 (DECISION 030 Step 5 — iOS 18 declarative TabView)
//
//  The Mac primary attorney workstation. Replaces the previous
//  `NavigationSplitView` + `List(selection:)` sidebar with the same
//  iOS 18 declarative `Tab(...)` API the iPhone uses (DECISION 030
//  Step 4). On macOS, `.tabViewStyle(.sidebarAdaptable)` renders the
//  TabView as a sidebar — visually similar to the prior
//  NavigationSplitView, plus drag-to-reorder + hide tabs via Apple's
//  native customize sheet (which NavigationSplitView lacked).
//
//  Layout (functional-identity-preserving on first launch):
//    AppHeader (V wordmark + LIVE/OFFLINE)
//    TabView (iOS 18 declarative)
//      sidebar — TODAY / CLIENTS / CALENDAR / INTAKE / VOUCHERS
//                (default order from TabRegistry.tabs(for: .mac);
//                 attorney can reorder/hide via right-click → customize)
//      detail  — selected tab's content view
//    Window toolbar — stethoscope diagnostics button (StatusView sheet)
//
//  StatusView is preserved as a developer-debug drawer reachable from
//  the toolbar's stethoscope button (`...` menu in v0.4 → primary
//  toolbar button in v0.5+) so CloudKit sync state, entry count,
//  regenerate, and historical-CSV-import buttons stay one tap away.
//
//  Persistence: `$prefs.macCustomization` is a Codable round-trip into
//  UserPreferences.macTabCustomizationData (DECISION 030 Step 3). The
//  blob lives in CloudKit's private DB; same attorney's iPhone +
//  iPad bind separate `iPhoneCustomization` / `iPadCustomization` so
//  the three customizations don't contaminate each other.
//

import SwiftUI
import SwiftData

struct MacMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @Query private var profiles: [AttorneyProfile]
    // 2026-05-15 — Initial Contact sidebar badge. Same predicate-
    // filtered @Query shape as MainTabView (iPhone). Filtering at
    // fetch time reduces body re-eval frequency vs raw allClients.
    @Query(filter: #Predicate<Client> {
        ($0.source == "agent_appointment_intake" || $0.source == "agent_pc_intake")
        && $0.firstOpenedByLawyerAt == nil
        && !$0.archived
    })
    private var pendingInitialContactClients: [Client]

    @State private var showingDiagnostics = false

    /// DECISION 054 follow-up round 2 (2026-05-10) — replaced the
    /// prior `@State selectedTab` + `TabSwitcher` Combine observer
    /// pattern with `@Environment(AppState.self)` + `@Bindable`.
    /// Same canonical Apple pattern as iPhone MainTabView. AppState
    /// lives at the App root via .environment(_:) in VoxhoraMacApp.
    @Environment(AppState.self) private var appState

    var body: some View {
        // DECISION 032 (Phase 4 onboarding wizard) — onboarding gate.
        // When no AttorneyProfile exists, render OnboardingView FIRST
        // to collect structured-name + jurisdiction + hourly rate.
        // After completion (Save tap → AttorneyProfile inserted),
        // @Query reactivity flips profiles.isEmpty to false and the
        // normal sidebar + TabView surface appears. For Patrick's
        // existing Mac install: AttorneyProfile already exists →
        // gate falls through immediately → unchanged UX.
        if profiles.isEmpty {
            OnboardingView()
                .background(Color.voxPaper)
        } else {
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        // @Bindable lets us derive a Binding<TabViewCustomization> from
        // the @Model's computed `macCustomization` accessor, even
        // though the underlying storage is the opaque
        // `macTabCustomizationData` Data field. Writes flow through
        // the setter → SwiftData → CloudKit.
        @Bindable var prefs = ensuredPreferences

        VStack(spacing: 0) {
            AppHeader()

            // Apple's documented `@Bindable var x = x` same-name
            // shadowing pattern. Projects `$appState.selectedTab` as
            // a Binding<TabID> inside the body without polluting the
            // surrounding scope with a renamed binding.
            @Bindable var appState = appState

            // 2026-05-15 — count from predicate-filtered @Query.
            let pendingInitialContactCount = pendingInitialContactClients.count

            TabView(selection: $appState.selectedTab) {
                ForEach(TabRegistry.tabs(for: .mac)) { def in
                    Tab(def.title, systemImage: def.systemImage, value: def.id, role: def.role) {
                        def.content()
                    }
                    .customizationID(def.id.customizationID)
                    .badge(def.id == .intake ? pendingInitialContactCount : 0)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewCustomization($prefs.macCustomization)
            .tint(.voxInk)
            .navigationTitle("Voxhora")
            // DECISION 030 Step 9 — same audit-event wiring as iPhone.
            // Fires when the Mac sidebar customization changes (right-
            // click → reorder/hide). `oldValue.isEmpty` guard suppresses
            // the CloudKit-hydration event so only user-driven changes
            // hit the audit chain.
            .onChange(of: prefs.macTabCustomizationData) { oldValue, newValue in
                guard !oldValue.isEmpty else { return }
                AuditLogger.shared.log(
                    eventType: .tabConfigurationChanged,
                    payload: [
                        "platform": "Mac",
                        "blobByteCount": newValue.count
                    ],
                    attorneyId: prefs.attorneyId
                )
            }
            .toolbar {
                // VoxHelp Phase 1 Edit #1b (2026-05-20) — in-app AI
                // assistant entry point. Sits at the very trailing edge
                // of the Mac window toolbar; stethoscope diagnostics
                // button renders just inboard of it.
                ToolbarItem(placement: .primaryAction) {
                    VoxHelpButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingDiagnostics = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .help("Diagnostics — CloudKit sync, entry count, regenerate, historical import")
                }
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

    /// Render-only fallback. `UserPreferencesBootstrap` (DECISION
    /// 036.5 Step 1) is the SOLE writer of UserPreferences row
    /// insertion — wired in `VoxhoraMacApp.onAppear`'s bootstrap chain.
    /// See `MainTabView.swift` (iOS) for the full rationale on why
    /// this must NEVER `modelContext.insert` from inside `body`.
    private var ensuredPreferences: UserPreferences {
        if let existing = allPreferences.first { return existing }
        return UserPreferences(
            attorneyId: profiles.first?.attorneyId ?? "",
            displayUnit: "hours"
        )
    }
}
