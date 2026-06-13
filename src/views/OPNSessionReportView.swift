import Backend
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class OPNSessionReportViewModel: ObservableObject {
    @Published var statusText = ""
}

@objc(OPNSessionReportView)
@MainActor
final class OPNSessionReportView: NSView {
    @objc var onDone: (() -> Void)?

    private let report: OPNSessionReportPayload
    private let viewModel = OPNSessionReportViewModel()
    private var hostingView: NSHostingView<OPNSessionReportSwiftUIView>?

    @objc(initWithFrame:report:)
    init(frame frameRect: NSRect, report: OPNSessionReportPayload) {
        self.report = report
        super.init(frame: frameRect)
        configure()
    }

    override init(frame frameRect: NSRect) {
        report = OPNSessionReportPayload(gameTitle: "Unknown Game", success: false, launchText: "Unknown", averageLatencyText: "Unknown", averageBitrateText: "Unknown", droppedFramesText: "0", reportText: "", copyText: "", shouldShow: false, displayScore: 0, displayReason: "")
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let root = OPNSessionReportSwiftUIView(
            report: report,
            viewModel: viewModel,
            onCopy: { [weak self] in self?.copyDiagnosticsClicked() },
            onSave: { [weak self] in self?.saveReportClicked() },
            onDone: { [weak self] in self?.doneClicked() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
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
        viewModel.statusText = "Session report copied to clipboard."
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
                viewModel.statusText = "Session report saved."
                OPNLogCapture.appendEvent("[SessionReport] Saved session report")
            } catch {
                viewModel.statusText = error.localizedDescription.isEmpty ? "Unable to save session report." : error.localizedDescription
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

private struct OPNSessionReportSwiftUIView: View {
    let report: OPNSessionReportPayload
    @ObservedObject var viewModel: OPNSessionReportViewModel
    let onCopy: () -> Void
    let onSave: () -> Void
    let onDone: () -> Void

    private var metrics: [(String, String)] {
        [
            ("Launch", report.launchText.isEmpty ? "Unknown" : report.launchText),
            ("Avg Latency", report.averageLatencyText.isEmpty ? "Unknown" : report.averageLatencyText),
            ("Avg Bitrate", report.averageBitrateText.isEmpty ? "Unknown" : report.averageBitrateText),
            ("Dropped Frames", report.droppedFramesText.isEmpty ? "0" : report.droppedFramesText)
        ]
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.50)
            GeometryReader { proxy in
                let panelWidth = proxy.size.width < 388 ? max(300, proxy.size.width - 24) : min(820, proxy.size.width - 48)
                let panelHeight = proxy.size.height < 492 ? max(320, proxy.size.height - 24) : min(640, proxy.size.height - 72)
                VStack(alignment: .leading, spacing: 14) {
                    header
                    metricGrid(width: panelWidth)
                    actions
                    reportBody
                }
                .padding(panelWidth < 500 ? 18 : 26)
                .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
                .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session Report")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.primary)
            Text(report.gameTitle.isEmpty ? "Unknown Game" : report.gameTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(report.success ? "Session ended normally" : "Session ended with an error")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(report.success ? Color(red: 0.204, green: 0.780, blue: 0.349) : Color(red: 1, green: 0.271, blue: 0.227))
        }
    }

    private func metricGrid(width: CGFloat) -> some View {
        let columns = width >= 720 ? 4 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            ForEach(metrics, id: \.0) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(metric.1)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                .padding(.horizontal, 16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Copy Diagnostics", action: onCopy)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.204, green: 0.780, blue: 0.349))
            Button("Save Report", action: onSave)
            Spacer()
            Text(viewModel.statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Done", action: onDone)
        }
    }

    private var reportBody: some View {
        ScrollView {
            Text(report.reportText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
