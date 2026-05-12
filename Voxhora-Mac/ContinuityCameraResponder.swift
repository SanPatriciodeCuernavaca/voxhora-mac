//
//  ContinuityCameraResponder.swift
//  Voxhora-Mac — DECISION 056 Beat 1 v4 (Apple-canonical Continuity
//  Camera, 2026-05-11)
//
//  ── STATUS POST-BEAT-1 (Beat 2 / Hardening Round, 2026-05-11) ──
//
//  KEPT AS DOCUMENTED DEFENSE-IN-DEPTH + REFERENCE.
//
//  Beat 1 evidence proved that `.importsItemProviders` directly on
//  the SwiftUI row (ClientDocsSheet) is the route macOS actually
//  uses — it catches every Continuity Camera capture first. The
//  NSServicesMenuRequestor bridge below currently never receives a
//  payload in normal operation; the Beat 1 follow-up audit flagged
//  this for either deletion or explicit documentation.
//
//  Decision: KEEP. Reasons:
//    1. Apple's SwiftUI Continuity Camera routing is undocumented +
//       has changed between releases (Beat 1 had to discover the
//       row-level `.importsItemProviders` route experimentally). If a
//       future Xcode/macOS update changes that route, this responder
//       is the working fallback that needs zero rewiring.
//    2. Future Voxhora surfaces (e.g. CaseDocsSheet, EntryAttachments)
//       can attach this responder to get Continuity Camera support
//       without re-deriving the 6-iteration architecture journey.
//    3. The performance cost is zero: a 1×1 invisible NSView with
//       `.allowsHitTesting(false)` joins the responder chain but
//       never fires unless macOS routes Services calls to it.
//
//  When updating: the canonical row-level route in ClientDocsSheet
//  is the source of truth for behavior. This file is the documented
//  Apple-native AppKit pattern + a working fallback.
//
//  ── ORIGINAL DESIGN NOTES (BEAT 1 v4) ──
//
//  The PROVEN pattern: AppKit NSServicesMenuRequestor bridge embedded
//  in a SwiftUI sheet via NSViewRepresentable. Mirrors pd95/SwiftUI-
//  Continuity-Camera (the only known-working SwiftUI Continuity Camera
//  reference in production), with the three structural fixes the v1
//  attempt missed:
//
//    1. **Real frame.** v1 used `frame: .zero`; SwiftUI never expanded
//       it; zero-area NSViews are excluded from hit-testing + the
//       responder chain. v4 uses a 1×1 frame + `.allowsHitTesting(false)`
//       at the SwiftUI side so layout participates without intercepting
//       clicks meant for the foreground UI.
//
//    2. **validRequestor returns the NSResponder, not a bare NSObject.**
//       v1 returned the Coordinator directly; the system invokes
//       readSelection(from:) only on responders in the chain. v4
//       returns the Coordinator (which IS in the chain by virtue of
//       being the NSView's delegate target), but only AFTER the
//       NSView's own validRequestor signals image/PDF acceptance.
//
//    3. **viewDidMoveToWindow → makeFirstResponder.** v1 omitted this;
//       a non-first-responder view is never asked validRequestor when
//       a context-menu opens. v4 takes first-responder on appear via
//       the documented NSWindow.makeFirstResponder(_:) hook.
//
//  Bypasses FB14893699 (SwiftUI Toggle disables ImportFromDevicesCommands)
//  by NOT using ImportFromDevicesCommands at all — the AppKit Services
//  pipe is independent of that bug.
//
//  Apple references:
//    - https://developer.apple.com/documentation/appkit/supporting-continuity-camera-in-your-mac-app
//    - https://developer.apple.com/documentation/appkit/nsservicesmenurequestor
//    - https://developer.apple.com/documentation/appkit/nsresponder/validrequestor(forsendtype:returntype:)
//    - https://developer.apple.com/documentation/appkit/nsview/viewdidmovetowindow()
//    - https://developer.apple.com/documentation/appkit/nsapplication/registerservicesmenusendtypes(_:returntypes:)
//  Reference impl:
//    - https://github.com/pd95/SwiftUI-Continuity-Camera
//

#if os(macOS)

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Hidden AppKit bridge that joins the docs sheet's responder chain
/// and receives Continuity Camera captures (Take Photo / Scan Documents
/// / Add Sketch) routed through the macOS Services subsystem.
///
/// Attach as `.background { ContinuityCameraResponder { data, uti in … }
///   .frame(width: 0, height: 0).allowsHitTesting(false) }` on the
/// SwiftUI sheet root. The handler closure is invoked with the captured
/// Data + UTType when the user picks a Continuity Camera item from any
/// `.contextMenu` inside the sheet (macOS auto-injects those items
/// into every contextMenu that has a responder advertising image/PDF
/// returnTypes). Returns `true` if the capture was accepted.
struct ContinuityCameraResponder: NSViewRepresentable {
    let onCapture: (Data, UTType) -> Bool

    func makeNSView(context: Context) -> ResponderView {
        let view = ResponderView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ResponderView, context: Context) {
        nsView.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    /// NSServicesMenuRequestor implementation. Owns the pasteboard
    /// read logic. Lives on the SwiftUI side so the closure stays
    /// bound to the latest render.
    final class Coordinator: NSObject, NSServicesMenuRequestor {
        var onCapture: (Data, UTType) -> Bool

        init(onCapture: @escaping (Data, UTType) -> Bool) {
            self.onCapture = onCapture
        }

        /// Called by macOS after the user picks a Continuity Camera
        /// item from any contextMenu in our sheet AND the iPhone has
        /// captured + returned the bytes via NSPasteboard. Priority
        /// matches what each capture mode produces:
        ///   - Take Photo  → JPEG (or HEIC on newer iPhones)
        ///   - Scan Docs   → PDF (multi-page lossless from VisionKit)
        ///   - Add Sketch  → PDF (vector strokes)
        /// PDF first so multi-page scans + sketches stay lossless;
        /// HEIC > JPEG > TIFF > PNG for photos.
        func readSelection(from pasteboard: NSPasteboard) -> Bool {
            let priority: [(NSPasteboard.PasteboardType, UTType)] = [
                (NSPasteboard.PasteboardType(UTType.pdf.identifier), .pdf),
                (NSPasteboard.PasteboardType("public.heic"), UTType("public.heic") ?? .image),
                (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg),
                (NSPasteboard.PasteboardType(UTType.tiff.identifier), .tiff),
                (NSPasteboard.PasteboardType(UTType.png.identifier), .png)
            ]
            for (pbType, uti) in priority {
                if let data = pasteboard.data(forType: pbType) {
                    return onCapture(data, uti)
                }
            }
            return false
        }
    }

    /// Bare NSView subclass that joins the responder chain on appear,
    /// claims first-responder status (so validRequestor is asked when
    /// context menus open), and advertises that the Coordinator
    /// accepts image/PDF return types from the Services subsystem.
    final class ResponderView: NSView {
        weak var coordinator: Coordinator?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Take first-responder so Services menu validation walks
            // through this view's validRequestor when the user opens
            // any context menu inside the sheet. Documented hook —
            // no timing hacks needed (macOS guarantees window is set
            // before viewDidMoveToWindow fires).
            window?.makeFirstResponder(self)
        }

        /// Advertise that the Coordinator accepts image / PDF return
        /// types from the Services subsystem. macOS uses this to
        /// decide whether to inject Continuity Camera items into any
        /// context menu in this responder chain.
        override func validRequestor(
            forSendType sendType: NSPasteboard.PasteboardType?,
            returnType: NSPasteboard.PasteboardType?
        ) -> Any? {
            if let r = returnType,
               NSImage.imageTypes.contains(r.rawValue)
                   || r.rawValue == UTType.pdf.identifier {
                return coordinator
            }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
    }
}

#endif
