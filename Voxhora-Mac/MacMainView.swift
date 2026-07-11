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
import CloudKit

struct MacMainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allPreferences: [UserPreferences]
    @Query private var profiles: [AttorneyProfile]

    // Resilience Hardening (2026-06-10, audit rank 1 + 8) — CloudKit
    // hydration grace ported from iOS ContentView. The Mac onboarding
    // gate previously jumped straight to OnboardingView the instant
    // profiles.isEmpty was true, so a Sparkle update / new-Mac setup
    // opened before iCloud finished syncing would let OnboardingView
    // insert a SECOND AttorneyProfile (fresh UUID) — permanently
    // splitting the attorney's roster/billing/calendar. We now wait the
    // same 90s grace + verify iCloud availability before ever treating
    // an empty profile set as "fresh user".
    @State private var hydrationElapsed: Bool = false
    @State private var iCloudAvailable: Bool = true
    /// Attorney explicitly chose to continue onboarding on a DIFFERENT
    /// iCloud account than the one this device was bound to.
    @State private var mismatchOverridden: Bool = false

    /// First-run Setup Assistant gate (2026-07-10). @AppStorage so a write
    /// from the wizard's finish OR the launch backfill re-renders this view
    /// reactively (plain UserDefaults would not). `forceShow` re-arms the
    /// wizard for a preview even after completion.
    @AppStorage(SetupAssistantState.completedKey) private var setupAssistantComplete: Bool = false
    @AppStorage("voxhora.setupAssistant.forceShow") private var setupAssistantForceShow: Bool = false

    /// Generous grace — a fresh-Mac CloudKit cold-fetch with hundreds
    /// of records can take 30-60s. Padded to 90s (matches iOS).
    private static let hydrationGraceSeconds: Double = 90
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
        Group {
            if appState.accountLocked {
                // LLM Proxy kill switch (2026-06-07) — full-screen lock when the
                // attorney's account is suspended server-side (AccountStatusService).
                AccountLockedView()
                    .background(Color.voxPaper)
            } else if let p = profiles.first, termsGateNeeded(p) {
                // First-launch Terms consent gate (VOXHORA_TERMS_GATE). Blocks the
                // app until the attorney accepts; no-op when the flag is off.
                termsGate(p)
                    .background(Color.voxPaper)
            } else if showSetupAssistant {
                // First-run Setup Assistant (2026-07-10). Shows once, AFTER a
                // profile exists (OnboardingView made it) and terms are
                // accepted, until finished on this Mac. Existing installs are
                // marked complete by the launch backfill in VoxhoraMacApp, so
                // Patrick / Matt never see it. `setupAssistantComplete` is
                // @AppStorage on SetupAssistantState.completedKey, so finishing
                // (or the backfill) flips this branch reactively — no stale
                // wizard, no disappearing window. `forceShow` re-arms it for a
                // preview even once complete.
                SetupAssistantView(onComplete: completeSetupAssistant)
                    .background(Color.voxPaper)
            } else if !profiles.isEmpty {
                mainContent
            } else if iCloudAvailable && !hydrationElapsed {
                // Resilience rank 1 — wait for CloudKit before onboarding.
                cloudKitHydrationWaitView
            } else if iCloudAccountIdentity.accountMismatch() && !mismatchOverridden {
                // Resilience rank 8 — signed into a DIFFERENT iCloud account
                // than this device's data. Warn before spawning a duplicate.
                WrongICloudAccountView { mismatchOverridden = true }
            } else {
                OnboardingView()
                    .background(Color.voxPaper)
            }
        }
        .task {
            // Learn whether iCloud is available. Signed out / restricted →
            // jump straight to OnboardingView (nothing to hydrate from).
            let container = CKContainer(identifier: VoxhoraSchema.cloudKitContainerID)
            let status = (try? await container.accountStatus()) ?? .couldNotDetermine
            iCloudAvailable = (status == .available)
            if iCloudAvailable {
                try? await Task.sleep(nanoseconds: UInt64(Self.hydrationGraceSeconds * 1_000_000_000))
            }
            hydrationElapsed = true
            rememberAccountIfProfileExists()
        }
        // Latch this device's home iCloud account the moment a profile
        // is known to exist (rank 8 wrong-account detection depends on it).
        .onChange(of: profiles.isEmpty) { _, isEmpty in
            if !isEmpty { iCloudAccountIdentity.rememberCurrentAccount() }
        }
    }

    private func rememberAccountIfProfileExists() {
        if !profiles.isEmpty { iCloudAccountIdentity.rememberCurrentAccount() }
    }

    // MARK: - CloudKit hydration wait view (ported from iOS ContentView)

    private var cloudKitHydrationWaitView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .tint(.voxGold)
            VStack(spacing: 8) {
                Text("Syncing your account from iCloud")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.voxInk)
                Text("This usually takes a few seconds on a fresh device.")
                    .font(.system(size: 13))
                    .foregroundColor(.voxInkSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 6) {
                Text("Don't see anything after a minute?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.voxInkSoft)
                Text("Check that you're signed in to the same iCloud account as your other Voxhora devices.")
                    .font(.system(size: 11))
                    .foregroundColor(.voxInkSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.voxPaper.ignoresSafeArea())
    }

    /// True when the first-launch Terms gate should block the app for this
    /// profile. Always false unless VOXHORA_TERMS_GATE is compiled in.
    private func termsGateNeeded(_ p: AttorneyProfile) -> Bool {
        #if VOXHORA_TERMS_GATE
        return VoxhoraTerms.needsAcceptance(p)
        #else
        return false
        #endif
    }

    /// Show the first-run Setup Assistant only once a profile exists (the
    /// wizard's TechShare/storage steps assume one) and setup hasn't
    /// finished on this Mac — or whenever the preview flag re-arms it.
    private var showSetupAssistant: Bool {
        !profiles.isEmpty && (!setupAssistantComplete || setupAssistantForceShow)
    }

    /// Wizard finished (or skipped to the end). Persist completion and drop
    /// any preview re-arm; @AppStorage flips `showSetupAssistant` false so
    /// the app content appears in the same window.
    private func completeSetupAssistant() {
        SetupAssistantState.markComplete()
        setupAssistantComplete = true
        setupAssistantForceShow = false
    }

    @ViewBuilder
    private func termsGate(_ p: AttorneyProfile) -> some View {
        #if VOXHORA_TERMS_GATE
        TermsGateView(profile: p)
        #else
        EmptyView()
        #endif
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
