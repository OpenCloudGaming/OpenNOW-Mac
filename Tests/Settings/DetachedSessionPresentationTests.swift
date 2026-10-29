import AppKit
import SwiftUI
import Testing
import Vision
@testable import OpenNOW

@MainActor
@Suite(.serialized) struct DetachedSessionPresentationTests {
    @Test func dismissingAnUnrelatedConfirmationDoesNotDismissTheCurrentOwner() {
        let presentation = OPNConfirmationPresentation()
        let owner = UUID()
        var dismissals = 0
        presentation.present(request, ownerID: owner, onDismiss: { dismissals += 1 })

        presentation.dismiss(ownerID: UUID())

        #expect(presentation.request != nil)
        #expect(dismissals == 0)
        presentation.dismiss(ownerID: owner)
        #expect(presentation.request == nil)
        #expect(dismissals == 1)
    }

    @Test func replacingAConfirmationRetiresOnlyThePreviousOwnersState() {
        let presentation = OPNConfirmationPresentation()
        let previousOwner = UUID()
        let currentOwner = UUID()
        var previousDismissals = 0
        var currentDismissals = 0
        presentation.present(request, ownerID: previousOwner, onDismiss: { previousDismissals += 1 })
        presentation.present(request, ownerID: currentOwner, onDismiss: { currentDismissals += 1 })

        presentation.dismiss(ownerID: previousOwner)

        #expect(previousDismissals == 1)
        #expect(currentDismissals == 0)
        #expect(presentation.request != nil)
        presentation.dismiss(ownerID: currentOwner)
        #expect(currentDismissals == 1)
    }

    @Test func aDescendantConfirmationUsesItsDetachedRootsPresenter() async throws {
        _ = NSApplication.shared
        let confirmation = OPNConfirmationPresentation()
        let title = "Detached confirmation \(UUID().uuidString)"
        let hosting = NSHostingView(rootView: DetachedConfirmationFixture(title: title)
            .modifier(DetachedSessionModalHost(confirmation: confirmation, reportIssue: OPNReportIssuePresentation()))
            .environment(\.opnUIScale, 1.25))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            confirmation.dismiss()
            if OPNConfirmationPresentation.shared.request?.title == title { OPNConfirmationPresentation.shared.dismiss() }
            window.close()
        }
        for _ in 0..<100 {
            if confirmation.request != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(confirmation.request?.title == title)
        #expect(OPNConfirmationPresentation.shared.request?.title != title)
    }

    @Test(arguments: [CGFloat(1.25), CGFloat(1.5)])
    func aDetachedConfirmationDrawsOnlyInItsOwnRootAtLargerScales(_ scale: CGFloat) throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let detached = OPNConfirmationPresentation()
        detached.present(request, onDismiss: {})
        let other = OPNConfirmationPresentation()
        let detachedCapture = try render(
            confirmation: detached, report: OPNReportIssuePresentation(), scale: scale,
            name: "detached-confirmation-\(scale).png"
        )
        let otherCapture = try render(
            confirmation: other, report: OPNReportIssuePresentation(), scale: scale,
            name: "other-window-no-confirmation-\(scale).png"
        )

        #expect(detachedCapture.greenDominantPixelCount(in: GlassCapture.wholeImage, threshold: 40) > 500)
        #expect(otherCapture.greenDominantPixelCount(in: GlassCapture.wholeImage, threshold: 40) == 0)
        #expect(detachedCapture.greenDominantPixelCount(in: CGRect(x: 0, y: 0, width: 0.15, height: 1), threshold: 40) == 0)
        #expect(detachedCapture.greenDominantPixelCount(in: CGRect(x: 0.85, y: 0, width: 0.15, height: 1), threshold: 40) == 0)
        detached.dismiss()
    }

    /// Offscreen evidence covers scoped modal chrome; the hosted test below verifies the form contents.
    @Test(arguments: [CGFloat(1.25), CGFloat(1.5)])
    func aDetachedReportDrawsOnlyInItsOwnRootAtLargerScales(_ scale: CGFloat) throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let detached = OPNReportIssuePresentation()
        let other = OPNReportIssuePresentation()
        detached.present(context: OPNIssueReportContext())
        let detachedCapture = try render(
            confirmation: OPNConfirmationPresentation(), report: detached, scale: scale,
            name: "detached-report-\(scale).png"
        )
        let otherCapture = try render(
            confirmation: OPNConfirmationPresentation(), report: other, scale: scale,
            name: "other-window-no-report-\(scale).png"
        )

        #expect(detached.isPresented)
        #expect(!other.isPresented)
        #expect(detachedCapture.greenDominantPixelCount(in: GlassCapture.wholeImage, threshold: 40) > 500)
        #expect(otherCapture.greenDominantPixelCount(in: GlassCapture.wholeImage, threshold: 40) == 0)
        #expect(detachedCapture.greenDominantPixelCount(in: CGRect(x: 0, y: 0, width: 1, height: 0.01), threshold: 40) == 0)
        #expect(detachedCapture.greenDominantPixelCount(in: CGRect(x: 0, y: 0.99, width: 1, height: 0.01), threshold: 40) == 0)
        detached.dismiss()
    }

    @Test(
        .enabled(if: GlassEvidence.captureDirectory != nil),
        .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)),
        arguments: [CGFloat(1.25), CGFloat(1.5)]
    )
    func aHostedDetachedReportExposesEditableFieldsAtLargerScales(_ scale: CGFloat) async throws {
        _ = NSApplication.shared
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let report = OPNReportIssuePresentation()
        report.present(context: OPNIssueReportContext())
        report.draft.category = .bug
        report.draft.summary = HostedReportFixture.summary
        report.draft.details = HostedReportFixture.details
        report.draft.includesDiagnostics = false
        defer { report.dismiss() }

        for viewport in HostedReportViewport.allCases {
            let name = "detached-report-hosted-\(scale)-\(viewport.rawValue).png"
            let capture = try await captureHostedReport(report, scale: scale, viewport: viewport, name: name)
            try verifyCapturedReport(capture, viewport: viewport, name: name)
        }
    }

    private func captureHostedReport(
        _ report: OPNReportIssuePresentation, scale: CGFloat, viewport: HostedReportViewport, name: String
    ) async throws -> GlassCapture {
        let suiteName = "DetachedSessionHostedReportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let probe = HostedReportWindowProbe()
        defer {
            probe.close()
            defaults.removePersistentDomain(forName: suiteName)
        }
        let content = OPNDesign.Surface.app
            .modifier(DetachedSessionModalHost(confirmation: OPNConfirmationPresentation(), reportIssue: report))
            .background(HostedReportWindowReader(probe: probe))
            .environment(\.opnUIScale, scale)
            .environment(\.opnLiquidGlass, .off)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .transaction { $0.disablesAnimations = true }
            .defaultAppStorage(defaults)
        let captureTask = Task {
            try await GlassEvidence.captureInWindow(
                content, over: OPNDesign.Surface.app,
                size: CGSize(width: 1100, height: 680), named: name
            )
        }
        do {
            let form = try await probe.waitForNativeForm()
            try form.reveal(viewport)
            try form.verifyVisibleField(in: viewport)
            let capture = try await captureTask.value
            #expect(report.draft.summary == HostedReportFixture.summary)
            #expect(report.draft.details == HostedReportFixture.details)
            return capture
        } catch {
            captureTask.cancel()
            _ = await captureTask.result
            throw error
        }
    }

    private func verifyCapturedReport(_ capture: GlassCapture, viewport: HostedReportViewport, name: String) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: capture.image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let recognized = lines.joined(separator: " ").lowercased().filter { $0.isLetter || $0.isNumber }
        let expectedField = viewport == .top ? HostedReportFixture.summary : HostedReportFixture.details
        let expected = expectedField.lowercased().filter { $0.isLetter || $0.isNumber }
        #expect(recognized.contains(expected), "\(name) omitted its seeded field value. Recognized text: \(lines)")
        #expect(recognized.contains("sendreport"), "\(name) lost its pinned footer. Recognized text: \(lines)")
        if viewport == .bottom {
            #expect(recognized.contains("includediagnostics"), "\(name) did not expose the bottom of the form. Recognized text: \(lines)")
        }
    }

    private var request: OPNConfirmationPresentation.Request {
        .init(eyebrow: "DETACHED ACCOUNT", title: "Sign out of this account?",
              message: "Only this saved account is signed out. The account in the main window stays connected.",
              actions: [OPNConfirmationAction("CANCEL", role: .cancel) {}, OPNConfirmationAction("SIGN OUT", role: .destructive) {}])
    }

    private func render(confirmation: OPNConfirmationPresentation, report: OPNReportIssuePresentation, scale: CGFloat, name: String) throws -> GlassCapture {
        let suiteName = "DetachedSessionPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let renderer = ImageRenderer(content: OPNDesign.Surface.app
            .modifier(DetachedSessionModalHost(confirmation: confirmation, reportIssue: report))
            .frame(width: 1100, height: 680)
            .environment(\.opnUIScale, scale)
            .environment(\.opnLiquidGlass, .off)
            .transaction { $0.disablesAnimations = true }
            .defaultAppStorage(defaults))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"] {
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        return GlassCapture(image: image)
    }
}

private struct DetachedConfirmationFixture: View {
    let title: String
    @State private var isPresented = true

    var body: some View {
        OPNDesign.Surface.app
            .opnConfirmation(
                isPresented: $isPresented, eyebrow: "DETACHED", title: title, message: "Scoped to this window",
                actions: [OPNConfirmationAction("CLOSE", role: .cancel) { isPresented = false }]
            )
    }
}

private enum HostedReportFixture {
    static let summary = "Detached summary evidence"
    static let details = "Detached description evidence"
}

private enum HostedReportViewport: String, CaseIterable {
    case top
    case bottom
}

@MainActor
private struct HostedReportNativeForm {
    let summary: NSView
    let details: NSView
    let scrollView: NSScrollView

    func reveal(_ viewport: HostedReportViewport) throws {
        let document = try #require(scrollView.documentView)
        let clipView = scrollView.contentView
        #expect(document.bounds.height > clipView.bounds.height, "The fixture must exercise vertical form scrolling")
        let start = document.bounds.minY
        let end = max(start, document.bounds.maxY - clipView.bounds.height)
        let isShowingDocumentEnd = viewport == .bottom
        let originY = isShowingDocumentEnd == document.isFlipped ? end : start
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: originY))
        scrollView.reflectScrolledClipView(clipView)
        scrollView.window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.window?.displayIfNeeded()
    }

    func verifyVisibleField(in viewport: HostedReportViewport) throws {
        #expect(HostedReportWindowProbe.editableValue(in: summary) == HostedReportFixture.summary)
        #expect(HostedReportWindowProbe.editableValue(in: details) == HostedReportFixture.details)
        let window = try #require(scrollView.window)
        #expect(window.isVisible)
        let field = viewport == .top ? summary : details
        #expect(field.window === window)
        #expect(!field.isHiddenOrHasHiddenAncestor)
        #expect(!field.visibleRect.isEmpty, "The seeded field is outside the form viewport")
        #expect(field.visibleRect.width >= field.bounds.width * 0.95, "The form clips the native field horizontally")
    }
}

@MainActor
private final class HostedReportWindowProbe {
    private var window: NSWindow?

    func attach(_ window: NSWindow?) {
        guard let window else { return }
        window.isReleasedWhenClosed = false
        self.window = window
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    func waitForNativeForm() async throws -> HostedReportNativeForm {
        for _ in 0..<100 {
            if let form = nativeForm() { return form }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(nativeForm(), "The hosted report did not install editable Summary/Description controls inside a scroll view")
    }

    static func editableValue(in view: NSView) -> String? {
        if let field = view as? NSTextField, field.isEditable { return field.stringValue }
        if let editor = view as? NSTextView, editor.isEditable { return editor.string }
        return nil
    }

    private func nativeForm() -> HostedReportNativeForm? {
        guard let content = window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let inputs = editableInputs(in: content)
        guard let summary = inputs.first(where: { Self.editableValue(in: $0) == HostedReportFixture.summary }),
              let details = inputs.first(where: { Self.editableValue(in: $0) == HostedReportFixture.details }),
              !summary.bounds.isEmpty, !details.bounds.isEmpty,
              let scrollView = formScrollView(containing: summary, details: details) else { return nil }
        return HostedReportNativeForm(summary: summary, details: details, scrollView: scrollView)
    }

    private func editableInputs(in view: NSView) -> [NSView] {
        let descendants = view.subviews.flatMap { editableInputs(in: $0) }
        guard Self.editableValue(in: view) != nil else { return descendants }
        return [view] + descendants
    }

    private func formScrollView(containing summary: NSView, details: NSView) -> NSScrollView? {
        var ancestor = summary.superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView, let document = scrollView.documentView,
               details.isDescendant(of: document) { return scrollView }
            ancestor = view.superview
        }
        return nil
    }
}

private struct HostedReportWindowReader: NSViewRepresentable {
    let probe: HostedReportWindowProbe

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.probe = probe
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        probe.attach(nsView.window)
    }

    final class ProbeView: NSView {
        weak var probe: HostedReportWindowProbe?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            probe?.attach(window)
        }
    }
}
