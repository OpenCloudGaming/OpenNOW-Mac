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
            Color.black.opacity(0.94)
            VStack(spacing: 0) {
                Circle()
                    .fill(Color(red: 1, green: 0.271, blue: 0.227).opacity(0.18))
                    .overlay(Circle().stroke(Color(red: 1, green: 0.271, blue: 0.227).opacity(0.42), lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .padding(.top, 34)

                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 14)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(width: 332, height: 78)
                    .padding(.top, 10)

                if canRetry {
                    Button(action: onRetry) {
                        Text("Try Again")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 292, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.204, green: 0.780, blue: 0.349))
                    .padding(.top, 4)
                }

                Button("Return to Sign In", action: onBack)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.039, green: 0.518, blue: 1))
                    .padding(.top, canRetry ? 18 : 66)
            }
            .frame(width: 420, height: 300, alignment: .top)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 22, y: 12)
        }
    }
}
