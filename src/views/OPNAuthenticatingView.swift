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
            Color(nsColor: OPNUIHelpers.color(rgb: 0x191919, alpha: 1.0))
                .ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Rectangle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)))
                }
                .frame(width: 72, height: 72)

                Text(model.message)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(36)
            .frame(width: 420, height: 220)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x292929, alpha: 0.96)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.20), lineWidth: 1))
            .shadow(color: .black.opacity(0.42), radius: 24, y: 14)
        }
    }
}
