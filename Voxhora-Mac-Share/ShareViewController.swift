//
//  ShareViewController.swift
//  Voxhora-Mac-Share — DECISION 045 Stage 5 macOS Share Extension
//
//  AppKit-based macOS Share Extension principal class. Lives at
//  `Voxhora-Mac.app/Contents/PlugIns/Voxhora-Mac-Share.appex`. macOS
//  dispatches here when the lawyer clicks the Share button (square +
//  arrow up) on a PDF in Preview.app, Mail.app, Finder, etc.
//
//  Architecture (DECISION 045 — same self-contained pattern as iOS
//  Voxhora-Share, AppKit version):
//    - SUBCLASS: NSViewController (Mac equivalent of iOS UIKit subclass)
//    - loadView(): set up own loading-spinner view immediately
//    - viewDidAppear(): defer async work via DispatchQueue.main.async
//      + Task. Same Signal-iOS pattern that protects main thread.
//    - After parse: replace content with NSHostingController hosting
//      the same SwiftUI PDFIntakeShareForm the iOS extension uses
//      (single source of truth for the form layout).
//    - On Save: run ClientTrunk.findOrCreate → applyFields → save
//      → extensionContext.completeRequest. Same canonical save path
//      as iOS Voxhora-Share + main app's PDFImportSheet.
//    - On Cancel: extensionContext.completeRequest with no save.
//
//  EXPLICITLY NOT DOING (banned per BLACKLIST + Niagara Falls law):
//    - extensionContext.open(URL) — undocumented for Share Extensions;
//      caused 2 iPhone-freeze incidents in earlier iOS attempts.
//    - Any attempt to launch Voxhora-Mac.app — wrong architecture.
//

import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

class ShareViewController: NSViewController {

    private var hostingController: NSHostingController<AnyView>?
    private var statusLabel: NSTextField?

    /// Wave 4 (2026-07-03) — controller-owned save-status channel; the
    /// form renders the failed-save banner + Try Again from this.
    private let saveStatus = PDFIntakeShareSaveStatus()

    // MARK: - Lifecycle

    override func loadView() {
        // Mac Share Extension content view. Sized to a comfortable
        // portrait rectangle so the form has room to render. macOS
        // Share Sheet auto-fits the host window to the principal
        // view controller's preferredContentSize.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
        view.wantsLayer = true
        // voxPaper cream — #F8F4E8
        view.layer?.backgroundColor = NSColor(
            red: 248.0/255.0, green: 244.0/255.0, blue: 232.0/255.0, alpha: 1.0
        ).cgColor

        // Initial loading state — replaced by the parsed form once
        // viewDidAppear's async work completes.
        let label = NSTextField(labelWithString: "Loading…")
        label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor(
            red: 26.0/255.0, green: 47.0/255.0, blue: 74.0/255.0, alpha: 1.0
        )
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        statusLabel = label

        self.view = view
        self.preferredContentSize = NSSize(width: 480, height: 640)
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        DispatchQueue.main.async { [weak self] in
            Task { @MainActor [weak self] in
                await self?.runIntakeFlow()
            }
        }
    }

    // MARK: - Intake flow

    @MainActor
    private func runIntakeFlow() async {
        guard let pdfData = await readSharedPDFData() else {
            updateStatus("No PDF in shared item")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            complete()
            return
        }

        updateStatus("Parsing PDF…")

        let jurisdictionKey = readJurisdictionKey()
        guard let parser = AppointmentLetterParserRegistry.parser(
            forJurisdictionKey: jurisdictionKey
        ) else {
            updateStatus("No parser for jurisdiction \"\(jurisdictionKey)\"")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            complete()
            return
        }

        guard let parsed = parser.parse(pdfData: pdfData),
              parsed.hasMinimumFields else {
            updateStatus("Could not parse PDF (missing required fields)")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            complete()
            return
        }

        // Swap loading label for the SwiftUI form. Same form view the
        // iOS extension uses — single source of truth.
        let form = PDFIntakeShareForm(
            parsed: parsed,
            saveStatus: saveStatus,
            onSave: { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.runSave(state: state, parsed: parsed)
                }
            },
            onCancel: { [weak self] in
                self?.complete()
            }
        )
        presentForm(form)
    }

    @MainActor
    private func presentForm(_ form: PDFIntakeShareForm) {
        let host = NSHostingController(rootView: AnyView(form))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.width, .height]

        // Remove the loading label, add the SwiftUI host.
        statusLabel?.removeFromSuperview()
        statusLabel = nil
        view.addSubview(host.view)
        hostingController = host
    }

    @MainActor
    private func updateStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    // MARK: - Canonical save path (mirrors PDFImportSheet + iOS extension)

    @MainActor
    private func runSave(state: PDFIntakeShareFormState, parsed: ParsedAppointmentIntake) async {
        do {
            // 2026-07-02 — schema + container ID from VoxhoraSchema
            // (single source of truth; superset by construction — was
            // audit-H7's hand-copied full-union list).
            let schema = VoxhoraSchema.schema()
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private(VoxhoraSchema.cloudKitContainerID)
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            AuditLogger.shared.modelContext = context

            let profileDescriptor = FetchDescriptor<AttorneyProfile>()
            let profile = (try? context.fetch(profileDescriptor))?.first
            let attorneyId = profile?.attorneyId ?? ""

            let candidate = CandidateClient(
                name: state.name,
                source: "manual_add_from_pdf",
                attorneyId: attorneyId,
                hourlyRate: 0,
                callSite: "mac_share_extension",
                preferredLanguage: state.preferredLanguage
            )

            let target: Client
            switch ClientTrunk.findOrCreate(candidate: candidate, modelContext: context) {
            case .created(let new):
                target = new
            case .deduped(let existing):
                target = existing
            case .ambiguous:
                target = ClientTrunk.forceCreate(candidate: candidate, modelContext: context)
            }

            // Wave 4 (2026-07-03) — canonical apply via
            // ClientIntakeFieldApplier (one applier for PDFImportSheet +
            // both Share extensions; kills the drift that duplicated the
            // "[from intake PDF]" notes block on every re-share). Custody:
            // this form HAS a toggle → the lawyer's choice is authoritative.
            ClientIntakeFieldApplier.apply(
                ClientIntakeFieldValues(
                    name: state.name,
                    appointmentNumber: parsed.appointmentNumber,
                    preferredLanguage: state.preferredLanguage,
                    phone1: state.phone1,
                    phone2: state.phone2,
                    email: state.email,
                    addressStreet: state.addressStreet,
                    addressCity: state.addressCity,
                    addressState: state.addressState,
                    addressZip: state.addressZip,
                    dateOfBirth: state.dobEnabled ? state.dateOfBirth : nil,
                    arrestDate: state.arrestDateEnabled ? state.arrestDate : nil,
                    custodyFormToggle: state.inCustody,
                    attorneyNotes: state.attorneyNotes,
                    bookingNumber: parsed.bookingNumber,
                    notesFromPDF: parsed.notesFromPDF
                ),
                to: target
            )

            try context.save()

            // Audit-log AFTER the save landed (Wave 4 truthfulness — the
            // row never claims a client that didn't save).
            AuditLogger.shared.log(
                eventType: .clientCreatedFromPDF,
                payload: [
                    "appointmentNumber": parsed.appointmentNumber,
                    "parserVersion": parsed.parserVersion,
                    "fieldsExtractedCount": parsed.fieldsExtractedCount,
                    "sourceMode": "mac_share_extension",
                    "calendarEventCount": 0,
                    "autoBilledIntroEmail": false
                ],
                attorneyId: attorneyId
            )

            complete()
        } catch {
            // Wave 4 (2026-07-03, mockup-approved) — the panel STAYS OPEN:
            // banner + Try Again with the form still filled. Pre-Wave-4
            // this stderr'd and dismissed as if the save worked.
            FileHandle.standardError.write(
                "Voxhora-Mac-Share save error: \(error)\n".data(using: .utf8) ?? Data()
            )
            AuditLogger.shared.log(
                eventType: .modelSaveFailed,
                payload: [
                    "callSite": "ShareViewController.runSave(mac_share_extension)",
                    "error": "\(error)",
                    "errorType": String(describing: type(of: error))
                ],
                attorneyId: ""
            )
            saveStatus.errorMessage = "Save failed — the client was NOT saved."
            saveStatus.isSaving = false
        }
    }

    // MARK: - Shared SwiftData read (jurisdictionKey resolution)

    private func readJurisdictionKey() -> String {
        do {
            // 2026-07-02 — schema + container ID from VoxhoraSchema
            // (single source of truth; superset by construction — was
            // audit-H7's hand-copied full-union list).
            let schema = VoxhoraSchema.schema()
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private(VoxhoraSchema.cloudKitContainerID)
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<AttorneyProfile>()
            if let profile = (try? context.fetch(descriptor))?.first,
               !profile.jurisdictionKey.isEmpty {
                return profile.jurisdictionKey
            }
        } catch {
            // Sticky on error — fall back to default.
        }
        return "travis_county"
    }

    // MARK: - PDF Data extraction from input items

    private func readSharedPDFData() async -> Data? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }
        for item in items {
            for provider in item.attachments ?? [] {
                if let data = await loadPDF(from: provider) {
                    return data
                }
            }
        }
        return nil
    }

    private func loadPDF(from provider: NSItemProvider) async -> Data? {
        let pdfType = UTType.pdf.identifier

        if provider.hasItemConformingToTypeIdentifier(pdfType) {
            if let item = await loadItem(provider: provider, typeIdentifier: pdfType) {
                if let data = item as? Data { return data }
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    return data
                }
            }
        }

        let fileURLType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            if let url = await loadItem(provider: provider, typeIdentifier: fileURLType) as? URL,
               url.pathExtension.lowercased() == "pdf",
               let data = try? Data(contentsOf: url) {
                return data
            }
        }

        return nil
    }

    private func loadItem(provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - Completion

    @MainActor
    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
