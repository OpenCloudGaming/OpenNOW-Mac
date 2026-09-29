import AppKit
import QuickLookUI
import SwiftUI

/// One Quick Look request. The identity is per request rather than per file, so pressing space or
/// Quick Look again on the same item re-presents the panel instead of being read as no change.
struct OPNQuickLookRequest: Equatable, Identifiable {
    let id = UUID()
    let url: URL
}

/// Hosts the shared Quick Look panel for a SwiftUI surface. Placed in the page's background, it
/// draws nothing and never takes mouse input; it only supplies the responder the panel asks for.
struct OPNQuickLookHost: NSViewRepresentable {
    @Binding var request: OPNQuickLookRequest?

    func makeNSView(context: Context) -> OPNQuickLookSourceView {
        let view = OPNQuickLookSourceView()
        view.onStop = { request = nil }
        return view
    }

    func updateNSView(_ nsView: OPNQuickLookSourceView, context: Context) {
        nsView.onStop = { request = nil }
        guard let request, nsView.presentedRequestID != request.id else { return }
        nsView.present(request.url, requestID: request.id)
    }
}

/// The responder that controls `QLPreviewPanel`. Previewing takes first responder for the life of
/// the panel and hands it back on close, so the surface's own focus is where it was.
final class OPNQuickLookSourceView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onStop: (() -> Void)?
    private var previewURL: URL?
    private(set) var presentedRequestID: UUID?
    private weak var previousFirstResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            if let previousFirstResponder, previousFirstResponder !== panel {
                window?.makeFirstResponder(previousFirstResponder)
            }
            onStop?()
        }
    }

    func present(_ url: URL, requestID: UUID) {
        guard let panel = QLPreviewPanel.shared() else { return }
        previewURL = url
        presentedRequestID = requestID
        previousFirstResponder = window?.firstResponder
        window?.makeFirstResponder(self)
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }
}
