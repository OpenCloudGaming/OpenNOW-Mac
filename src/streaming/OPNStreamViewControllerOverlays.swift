import AppKit
import Combine
import SwiftUI

typealias OverlayAction = @convention(block) () -> Void

@objc(OPNQuitGameOverlayView)
@MainActor
final class OPNQuitGameOverlayView: NSView {
    @objc var onCancel: OverlayAction?
    @objc var onQuit: OverlayAction?

    private var hostingView: NSHostingView<OPNQuitGameOverlaySwiftUIView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: OPNQuitGameOverlaySwiftUIView(
            onCancel: { [weak self] in self?.onCancel?() },
            onQuit: { [weak self] in self?.onQuit?() }
        ))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let commandQ = event.modifierFlags.contains(.command) && key == "q"
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 36 || commandQ {
            onQuit?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct OPNQuitGameOverlaySwiftUIView: View {
    let onCancel: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.52), Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.84)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("OpenNOW")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.72, green: 0.74, blue: 0.78))
                    Spacer()
                    Text("Command-Q")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.48, green: 0.50, blue: 0.56))
                }

                Text("End stream?")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.96, blue: 0.98))
                    .padding(.top, 26)

                Text("Your stream will close and you will return to the library. Unsaved in-game progress may be lost.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.66, green: 0.68, blue: 0.73))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 22)

                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(OPNQuitOverlayButtonStyle(background: Color(red: 0.20, green: 0.21, blue: 0.24), foreground: Color(red: 0.88, green: 0.89, blue: 0.92), border: .white.opacity(0.10)))
                        .frame(width: 124, height: 42)
                    Button("End Stream") { onQuit() }
                        .buttonStyle(OPNQuitOverlayButtonStyle(background: Color(red: 0, green: 0.48, blue: 1), foreground: .white, border: .clear))
                        .frame(width: 124, height: 42)
                }
                .padding(.top, 26)
            }
            .padding(28)
            .frame(minWidth: 320, idealWidth: 460, maxWidth: 460, minHeight: 236, idealHeight: 236, maxHeight: 236)
            .background(LinearGradient(colors: [Color(red: 0.15, green: 0.16, blue: 0.18).opacity(0.96), Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.96)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 40)
        }
    }
}

private struct OPNQuitOverlayButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background.opacity(configuration.isPressed ? 0.78 : 0.95), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(border, lineWidth: 1))
    }
}

@objc(OPNShortcutLegendView)
@MainActor
final class OPNShortcutLegendView: NSView {
    private var hostingView: NSHostingView<OPNShortcutLegendSwiftUIView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let hosting = NSHostingView(rootView: OPNShortcutLegendSwiftUIView())
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }
}

private struct OPNShortcutLegendSwiftUIView: View {
    private let rows: [(String, String)] = [
        ("Hold Options", "Home dashboard"),
        ("Command-H", "Toggle this legend"),
        ("Command-G", "Audio HUD"),
        ("Command-R", "Record stream"),
        ("Command-N", "Stats HUD"),
        ("Command-M", "Toggle microphone"),
        ("Command-K", "Anti-AFK"),
        ("Command-L", "Copy logs"),
        ("Command-Q", "Quit stream"),
        ("Hold Esc", "Release pointer")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shortcuts")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.96, green: 0.97, blue: 0.99))

            VStack(spacing: 10) {
                ForEach(rows, id: \.0) { shortcut, description in
                    HStack {
                        Text(shortcut)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.75, green: 0.92, blue: 0.86))
                        Spacer()
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.74, green: 0.76, blue: 0.80))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.035, blue: 0.045).opacity(0.90), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

@MainActor
private final class OPNStatsOverlayModel: ObservableObject {
    @Published var text = "Stats: measuring"
}

@objc(OPNStatsOverlayView)
@MainActor
final class OPNStatsOverlayView: NSView {
    private static let minWidth: CGFloat = 320
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    private static let minHeight: CGFloat = 22

    private let model = OPNStatsOverlayModel()
    private var hostingView: NSHostingView<OPNStatsOverlaySwiftUIView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.minXMargin, .minYMargin]
        let hosting = NSHostingView(rootView: OPNStatsOverlaySwiftUIView(model: model))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    @objc(preferredSizeForMaxWidth:)
    func preferredSize(forMaxWidth maxWidth: CGFloat) -> NSSize {
        let availableMaxWidth = max(1, maxWidth - Self.horizontalPadding * 2)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)]
        let textBounds = (model.text as NSString).boundingRect(
            with: NSSize(width: availableMaxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = min(maxWidth, max(Self.minWidth, ceil(textBounds.width) + Self.horizontalPadding * 2))
        let height = max(Self.minHeight, ceil(textBounds.height) + Self.verticalPadding * 2)
        return NSSize(width: width, height: height)
    }

    @objc(updateLatencyMs:bitrateMbps:packetsLost:resolution:fps:renderFps:codec:enhancement:framesDropped:)
    func update(latencyMs: Int, bitrateMbps: Double, packetsLost: Int64, resolution: String, fps: Int, renderFps: Double, codec: String, enhancement: String, framesDropped: UInt64) {
        let latencyText = latencyMs >= 0 ? "\(latencyMs) ms" : "measuring"
        let bitrateText = bitrateMbps >= 0 ? String(format: "%.1f Mbps", bitrateMbps) : "--"
        var streamText = "--"
        if !resolution.isEmpty && fps > 0 {
            streamText = "\(resolution)@\(fps)"
        } else if !resolution.isEmpty {
            streamText = resolution
        }
        if !codec.isEmpty { streamText = "\(streamText)/\(codec)" }
        let renderText = renderFps >= 0 ? String(format: "%.0f fps", renderFps) : "-- fps"
        let enhancementText = enhancement.isEmpty ? "enh --" : enhancement
        let dropText = framesDropped > 0 ? "drop \(framesDropped)" : "drop 0"
        let lossText = packetsLost > 0 ? "loss \(packetsLost)" : "loss 0"
        model.text = "\(latencyText) | \(bitrateText) | \(streamText) | \(renderText) | \(enhancementText) | \(dropText) | \(lossText)"
    }
}

private struct OPNStatsOverlaySwiftUIView: View {
    @ObservedObject var model: OPNStatsOverlayModel

    var body: some View {
        Text(model.text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.18))
            .lineLimit(nil)
            .shadow(color: .black, radius: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .allowsHitTesting(false)
    }
}
