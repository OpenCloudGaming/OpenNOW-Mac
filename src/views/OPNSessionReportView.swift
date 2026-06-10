import AppKit
import UniformTypeIdentifiers

@objc(OPNSessionReportView)
final class OPNSessionReportView: NSView {
    @objc var onDone: (() -> Void)?

    private let report: OPNSessionReportPayload
    private var statusLabel: NSTextField?
    private var rebuilding = false

    @objc(initWithFrame:report:)
    init(frame frameRect: NSRect, report: OPNSessionReportPayload) {
        self.report = report
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = opnColor(0x020304, 0.50).cgColor
        buildContent()
    }

    override init(frame frameRect: NSRect) {
        report = OPNSessionReportPayload(gameTitle: "Unknown Game", success: false, launchText: "Unknown", averageLatencyText: "Unknown", averageBitrateText: "Unknown", droppedFramesText: "0", reportText: "", copyText: "", shouldShow: false, displayScore: 0, displayReason: "")
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = opnColor(0x020304, 0.50).cgColor
        buildContent()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        rebuildContentForCurrentBounds()
    }

    private func rebuildContentForCurrentBounds() {
        guard !rebuilding else { return }
        rebuilding = true
        subviews.forEach { $0.removeFromSuperview() }
        buildContent()
        rebuilding = false
    }

    private func addMetricLabel(title: String, value: String, frame: NSRect, parent: NSView) {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.cornerRadius = 16.0
        card.layer?.backgroundColor = opnColor(0x0A0D12, 0.50).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = opnColor(0xFFFFFF, 0.08).cgColor
        parent.addSubview(card)
        card.addSubview(opnLabel(title, NSRect(x: 16.0, y: 12.0, width: frame.width - 32.0, height: 18.0), 11.0, opnColor(0x8E8E93), .medium))
        let valueLabel = opnLabel(value, NSRect(x: 16.0, y: 34.0, width: frame.width - 32.0, height: 28.0), 21.0, opnColor(OPNViewColor.textPrimary), .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(valueLabel)
    }

    private func buildContent() {
        let width = bounds.width
        let height = bounds.height
        let panelWidth = width < 388.0 ? max(300.0, width - 24.0) : min(820.0, width - 48.0)
        let panelHeight = height < 492.0 ? max(320.0, height - 24.0) : min(640.0, height - 72.0)
        let panel = NSView(frame: NSRect(x: floor((width - panelWidth) / 2.0), y: floor((height - panelHeight) / 2.0), width: panelWidth, height: panelHeight))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 24.0
        panel.layer?.backgroundColor = opnColor(0x070A0E, 0.50).cgColor
        panel.layer?.borderWidth = 1.0
        panel.layer?.borderColor = opnColor(0xFFFFFF, 0.12).cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.22
        panel.layer?.shadowRadius = 28.0
        panel.layer?.shadowOffset = CGSize(width: 0.0, height: -10.0)
        addSubview(panel)

        let margin: CGFloat = panelWidth < 500.0 ? 18.0 : 26.0
        let contentWidth = max(300.0, panelWidth - margin * 2.0)
        var y: CGFloat = 24.0
        let gameTitle = report.gameTitle.isEmpty ? "Unknown Game" : report.gameTitle
        let result = report.success ? "Session ended normally" : "Session ended with an error"
        let resultColor = report.success ? opnColor(OPNViewColor.brandGreen) : opnColor(OPNViewColor.errorRed)

        panel.addSubview(opnLabel("Session Report", NSRect(x: margin, y: y, width: contentWidth, height: 32.0), 25.0, opnColor(OPNViewColor.textPrimary), .bold))
        y += 34.0
        panel.addSubview(opnLabel(gameTitle, NSRect(x: margin, y: y, width: contentWidth, height: 20.0), 14.0, opnColor(OPNViewColor.textSecondary), .medium))
        y += 25.0
        panel.addSubview(opnLabel(result, NSRect(x: margin, y: y, width: contentWidth, height: 18.0), 12.0, resultColor, .semibold))
        y += 32.0

        let gap: CGFloat = 12.0
        var cardWidth = floor((contentWidth - gap * 3.0) / 4.0)
        if cardWidth < 150.0 { cardWidth = floor((contentWidth - gap) / 2.0) }
        let cardHeight: CGFloat = 78.0
        let columns = cardWidth < 150.0 ? 1 : (contentWidth >= 720.0 ? 4 : 2)
        cardWidth = floor((contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let metrics = [("Launch", report.launchText.isEmpty ? "Unknown" : report.launchText), ("Avg Latency", report.averageLatencyText.isEmpty ? "Unknown" : report.averageLatencyText), ("Avg Bitrate", report.averageBitrateText.isEmpty ? "Unknown" : report.averageBitrateText), ("Dropped Frames", report.droppedFramesText.isEmpty ? "0" : report.droppedFramesText)]
        for (index, metric) in metrics.enumerated() {
            addMetricLabel(title: metric.0, value: metric.1, frame: NSRect(x: margin + CGFloat(index % columns) * (cardWidth + gap), y: y + CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight), parent: panel)
        }
        y += CGFloat((metrics.count + columns - 1) / columns) * (cardHeight + gap) + 18.0

        let copyButton = opnButton("Copy Diagnostics", NSRect(x: margin, y: y, width: 142.0, height: 38.0), opnColor(OPNViewColor.brandGreen, 0.50), opnColor(OPNViewColor.accentOn))
        copyButton.target = self
        copyButton.action = #selector(copyDiagnosticsClicked)
        panel.addSubview(copyButton)
        let saveButton = borderedButton("Save Report", NSRect(x: margin + 152.0, y: y, width: 118.0, height: 38.0))
        saveButton.target = self
        saveButton.action = #selector(saveReportClicked)
        panel.addSubview(saveButton)
        let doneButton = borderedButton("Done", NSRect(x: panelWidth - margin - 92.0, y: y, width: 92.0, height: 38.0))
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        panel.addSubview(doneButton)

        let status = opnLabel("", NSRect(x: margin, y: y + 46.0, width: contentWidth, height: 18.0), 12.0, opnColor(0x8E8E93), .regular)
        panel.addSubview(status)
        statusLabel = status
        y += 76.0

        let reportHeight = max(156.0, panelHeight - y - 24.0)
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: y, width: contentWidth, height: reportHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = NSTextView(frame: NSRect(x: 0.0, y: 0.0, width: contentWidth, height: reportHeight))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = opnColor(0x070A0E, 0.50)
        textView.textColor = opnColor(OPNViewColor.textSecondary)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
        textView.textContainerInset = NSSize(width: 16.0, height: 14.0)
        textView.string = report.reportText
        scrollView.documentView = textView
        panel.addSubview(scrollView)
    }

    private func borderedButton(_ title: String, _ frame: NSRect) -> NSButton {
        let button = opnButton(title, frame, opnColor(0x151A22, 0.50), opnColor(OPNViewColor.textPrimary))
        button.layer?.borderWidth = 1.0
        button.layer?.borderColor = opnColor(0xFFFFFF, 0.12).cgColor
        return button
    }

    private func reportTextForExport() -> String {
        var text = report.copyText
        let logPath = OPNLogCapture.capturedLogPath()
        if !logPath.isEmpty { text += "\n\nCaptured log: \(logPath)\n" }
        return text
    }

    @objc private func copyDiagnosticsClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportTextForExport(), forType: .string)
        statusLabel?.stringValue = "Session report copied to clipboard."
        OPNLogCapture.appendEvent("[SessionReport] Copied session report diagnostics")
    }

    @objc private func saveReportClicked() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenNOW-Session-Report.md"
        panel.allowedContentTypes = UTType(filenameExtension: "md").map { [$0] } ?? [.plainText]
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] result in
            guard let self, result == .OK, let url = panel?.url else { return }
            do {
                try reportTextForExport().write(to: url, atomically: true, encoding: .utf8)
                statusLabel?.stringValue = "Session report saved."
                OPNLogCapture.appendEvent("[SessionReport] Saved session report")
            } catch {
                statusLabel?.stringValue = error.localizedDescription.isEmpty ? "Unable to save session report." : error.localizedDescription
                OPNLogCapture.appendEvent("[SessionReport] Failed to save session report")
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func doneClicked() {
        onDone?()
    }
}
