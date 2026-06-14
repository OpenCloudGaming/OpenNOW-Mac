import Backend
import SwiftUI

@objc(OPNErrorView)
@MainActor
final class OPNErrorView: NSView {
    @objc var onRetry: (() -> Void)?
    @objc var onBackToEmail: (() -> Void)?

    private var hostingView: NSHostingView<OPNErrorSwiftUIView>?

    @objc(initWithFrame:message:canRetry:)
    init(frame frameRect: NSRect, message rawMessage: String?, canRetry: Bool) {
        super.init(frame: frameRect)
        configure(message: rawMessage, canRetry: canRetry)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(message: nil, canRetry: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure(message: nil, canRetry: false)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    @objc func retryClicked() {
        onRetry?()
    }

    @objc func backClicked() {
        onBackToEmail?()
    }

    private func configure(message rawMessage: String?, canRetry: Bool) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let message = rawMessage?.isEmpty == false ? rawMessage! : "An unknown error occurred."
        let title: String
        if message.range(of: "stream", options: .caseInsensitive) != nil
            || message.range(of: "WebRTC", options: .caseInsensitive) != nil
            || message.range(of: "connection", options: .caseInsensitive) != nil {
            title = "Connection Error"
        } else {
            title = "Authentication Error"
        }
        let hosting = NSHostingView(rootView: OPNErrorSwiftUIView(title: title, message: message, canRetry: canRetry, onRetry: { [weak self] in self?.retryClicked() }, onBack: { [weak self] in self?.backClicked() }))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNErrorSwiftUIView: View {
    let title: String
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x191919, alpha: 1.0))
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Color(nsColor: OPNUIHelpers.color(rgb: 0xFF453A, alpha: 1.0)))
                    .frame(width: 72, height: 4)

                Text(title)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.top, 24)

                Text(message)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                    .padding(.top, 14)

                Rectangle()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 1)
                    .padding(.top, 18)

                if canRetry {
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(OPNErrorPrimaryButtonStyle())
                    .padding(.top, 22)
                }

                Button("Return to Sign In", action: onBack)
                    .buttonStyle(OPNErrorSecondaryButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .padding(.top, canRetry ? 12 : 22)
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 34)
            .frame(width: 456, height: canRetry ? 342 : 286, alignment: .topLeading)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x292929, alpha: 0.96)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.20), lineWidth: 1))
            .shadow(color: .black.opacity(0.48), radius: 28, y: 16)
        }
    }
}

private struct OPNErrorPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: configuration.isPressed ? 0.78 : 1.0)))
            .overlay(Rectangle().stroke(Color(nsColor: OPNUIHelpers.color(rgb: 0x8FD127, alpha: 0.75)), lineWidth: 1))
    }
}

private struct OPNErrorSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.58 : 0.78))
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x1F1F1F, alpha: 1.0)))
            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}
