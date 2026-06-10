import AppKit

@objc(OPNErrorView)
final class OPNErrorView: NSView {
    @objc var onRetry: (() -> Void)?
    @objc var onBackToEmail: (() -> Void)?

    @objc(initWithFrame:message:canRetry:)
    init(frame frameRect: NSRect, message rawMessage: String?, canRetry: Bool) {
        super.init(frame: frameRect)

        let message = rawMessage?.isEmpty == false ? rawMessage! : "An unknown error occurred."
        let title: String
        if message.range(of: "stream", options: .caseInsensitive) != nil
            || message.range(of: "WebRTC", options: .caseInsensitive) != nil
            || message.range(of: "connection", options: .caseInsensitive) != nil {
            title = "Connection Error"
        } else {
            title = "Authentication Error"
        }

        wantsLayer = true
        layer?.backgroundColor = opnColor(0x020304, 0.94).cgColor

        let card = NSView(frame: NSRect(x: frameRect.size.width / 2.0 - 210.0, y: frameRect.size.height / 2.0 - 150.0, width: 420.0, height: 300.0))
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        card.wantsLayer = true
        card.layer?.backgroundColor = opnColor(0x0A0C0F, 0.98).cgColor
        card.layer?.cornerRadius = 22.0
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = opnColor(0xFFFFFF, 0.10).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.24
        card.layer?.shadowRadius = 22.0
        card.layer?.shadowOffset = CGSize(width: 0.0, height: 12.0)
        addSubview(card)

        let errorDot = NSView(frame: NSRect(x: 199.0, y: 34.0, width: 22.0, height: 22.0))
        errorDot.wantsLayer = true
        errorDot.layer?.cornerRadius = 11.0
        errorDot.layer?.backgroundColor = opnColor(OPNViewColor.errorRed, 0.18).cgColor
        errorDot.layer?.borderWidth = 1.0
        errorDot.layer?.borderColor = opnColor(OPNViewColor.errorRed, 0.42).cgColor
        card.addSubview(errorDot)

        card.addSubview(opnLabel(title, NSRect(x: 0.0, y: 70.0, width: 420.0, height: 28.0), 22.0, opnColor(OPNViewColor.textPrimary), .semibold, .center))

        let messageLabel = opnLabel(message, NSRect(x: 44.0, y: 108.0, width: 332.0, height: 78.0), 13.0, opnColor(OPNViewColor.textSecondary), .regular, .center)
        messageLabel.maximumNumberOfLines = 5
        card.addSubview(messageLabel)

        if canRetry {
            let retryButton = opnButton("Try Again", NSRect(x: 64.0, y: 190.0, width: 292.0, height: 44.0), opnColor(OPNViewColor.brandGreen), opnColor(OPNViewColor.accentOn))
            retryButton.target = self
            retryButton.action = #selector(retryClicked)
            card.addSubview(retryButton)
        }

        let backButton = NSButton(frame: NSRect(x: 64.0, y: 242.0, width: 292.0, height: 30.0))
        backButton.title = "Return to Sign In"
        backButton.isBordered = false
        backButton.font = NSFont.systemFont(ofSize: 13.0)
        backButton.contentTintColor = opnColor(OPNViewColor.linkBlue)
        backButton.target = self
        backButton.action = #selector(backClicked)
        card.addSubview(backButton)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    @objc func retryClicked() {
        onRetry?()
    }

    @objc func backClicked() {
        onBackToEmail?()
    }
}
