import Backend
import SwiftUI

@MainActor
private final class OPNAuthenticatingModel: ObservableObject {
    @Published var message: String

    init(message: String?) {
        self.message = message?.isEmpty == false ? message! : "Loading..."
    }
}

@objc(OPNAuthenticatingView)
@MainActor
final class OPNAuthenticatingView: NSView {
    @objc var statusLabel: NSTextField?

    private var hostingView: NSHostingView<OPNAuthenticatingSwiftUIView>?
    private var model: OPNAuthenticatingModel?

    @objc(initWithFrame:message:)
    init(frame frameRect: NSRect, message: String?) {
        super.init(frame: frameRect)
        configure(message: message)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(message: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure(message: nil)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    private func configure(message: String?) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let model = OPNAuthenticatingModel(message: message)
        self.model = model
        let status = NSTextField(labelWithString: model.message)
        statusLabel = status
        let hosting = NSHostingView(rootView: OPNAuthenticatingSwiftUIView(model: model))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNAuthenticatingSwiftUIView: View {
    @ObservedObject var model: OPNAuthenticatingModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 5)
                    Circle()
                        .trim(from: 0.12, to: 0.86)
                        .stroke(Color(red: 0.204, green: 0.780, blue: 0.349), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(28))
                }
                .frame(width: 82, height: 82)

                Text(model.message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(36)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
        }
    }
}
