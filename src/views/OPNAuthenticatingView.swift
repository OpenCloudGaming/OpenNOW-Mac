import AppKit

@objc(OPNAuthenticatingView)
final class OPNAuthenticatingView: NSView {
    @objc var statusLabel: NSTextField?

    private var loadingView: OPNLoadingView?

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
        loadingView?.frame = bounds
    }

    private func configure(message: String?) {
        wantsLayer = true
        layer?.backgroundColor = opnColor(0x020304, 0.94).cgColor

        let loading = OPNLoadingView(frame: NSRect(x: 0.0, y: 0.0, width: 420.0, height: 252.0), message: message ?? "")
        loading.autoresizingMask = [.width, .height]
        addSubview(loading)
        loadingView = loading
        statusLabel = loading.messageLabel
    }
}
