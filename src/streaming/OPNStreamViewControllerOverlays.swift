import AppKit

import AppKit

@MainActor
private func overlayColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

@MainActor
private func overlayLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment) -> NSTextField {
    let label = NSTextField(frame: .zero)
    label.stringValue = text
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.alignment = alignment
    label.drawsBackground = false
    label.isBordered = false
    label.isEditable = false
    label.isSelectable = false
    return label
}

@MainActor
private func styleOverlayButton(_ button: NSButton, background: NSColor, textColor: NSColor) {
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = 10
    button.layer?.backgroundColor = background.cgColor
    button.attributedTitle = NSAttributedString(
        string: button.title,
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: textColor,
        ]
    )
}

typealias OverlayAction = @convention(block) () -> Void

@objc(OPNQuitGameOverlayView)
final class OPNQuitGameOverlayView: NSView {
    @objc var onCancel: OverlayAction?
    @objc var onQuit: OverlayAction?

    private var cardFrame = NSRect.zero
    private let brandLabel = overlayLabel("OpenNOW", size: 13, weight: .semibold, color: overlayColor(0.72, 0.74, 0.78, 1), alignment: .left)
    private let eyebrowLabel = overlayLabel("Command-Q", size: 12, weight: .medium, color: overlayColor(0.48, 0.50, 0.56, 1), alignment: .left)
    private let titleLabel = overlayLabel("End stream?", size: 24, weight: .semibold, color: overlayColor(0.96, 0.96, 0.98, 1), alignment: .left)
    private let messageLabel = overlayLabel(
        "Your stream will close and you will return to the library. Unsaved in-game progress may be lost.",
        size: 13,
        weight: .regular,
        color: overlayColor(0.66, 0.68, 0.73, 1),
        alignment: .left
    )
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let quitButton = NSButton(title: "End Stream", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        messageLabel.maximumNumberOfLines = 2

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        styleOverlayButton(cancelButton, background: overlayColor(0.20, 0.21, 0.24, 0.95), textColor: overlayColor(0.88, 0.89, 0.92, 1))
        cancelButton.layer?.borderWidth = 1
        cancelButton.layer?.borderColor = overlayColor(1, 1, 1, 0.10).cgColor

        quitButton.target = self
        quitButton.action = #selector(quitPressed(_:))
        styleOverlayButton(quitButton, background: overlayColor(0, 0.48, 1, 1), textColor: .white)
        quitButton.layer?.shadowColor = overlayColor(0, 0, 0, 1).cgColor
        quitButton.layer?.shadowOpacity = 0.20
        quitButton.layer?.shadowRadius = 12
        quitButton.layer?.shadowOffset = CGSize(width: 0, height: -3)

        [brandLabel, eyebrowLabel, titleLabel, messageLabel, cancelButton, quitButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        let cardWidth = min(460, max(320, bounds.width - 80))
        let cardHeight: CGFloat = 236
        cardFrame = NSRect(
            x: floor((bounds.width - cardWidth) / 2),
            y: floor((bounds.height - cardHeight) / 2),
            width: cardWidth,
            height: cardHeight
        )
        let x = cardFrame.minX
        let top = cardFrame.maxY
        let padding: CGFloat = 28
        brandLabel.frame = NSRect(x: x + padding, y: top - 43, width: 140, height: 18)
        eyebrowLabel.frame = NSRect(x: cardFrame.maxX - padding - 82, y: top - 43, width: 82, height: 18)
        titleLabel.frame = NSRect(x: x + padding, y: top - 88, width: cardWidth - padding * 2, height: 30)
        messageLabel.frame = NSRect(x: x + padding, y: top - 134, width: cardWidth - padding * 2, height: 42)

        let buttonWidth: CGFloat = 124
        let buttonY = cardFrame.minY + 26
        quitButton.frame = NSRect(x: cardFrame.maxX - padding - buttonWidth, y: buttonY, width: buttonWidth, height: 42)
        cancelButton.frame = NSRect(x: quitButton.frame.minX - 12 - buttonWidth, y: buttonY, width: buttonWidth, height: 42)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        overlayColor(0, 0, 0, 0.52).setFill()
        bounds.fill()

        NSGradient(starting: overlayColor(0.12, 0.13, 0.16, 0.58), ending: overlayColor(0.04, 0.05, 0.06, 0.84))?.draw(in: bounds, angle: 90)

        let outer = NSBezierPath(roundedRect: cardFrame, xRadius: 22, yRadius: 22)
        overlayColor(1, 1, 1, 0.12).setFill()
        outer.fill()

        let inner = NSBezierPath(roundedRect: cardFrame.insetBy(dx: 1, dy: 1), xRadius: 21, yRadius: 21)
        NSGradient(starting: overlayColor(0.15, 0.16, 0.18, 0.96), ending: overlayColor(0.10, 0.11, 0.13, 0.96))?.draw(in: inner, angle: 90)

        let divider = NSRect(x: cardFrame.minX + 28, y: cardFrame.minY + 78, width: cardFrame.width - 56, height: 1)
        overlayColor(1, 1, 1, 0.08).setFill()
        divider.fill()
    }

    @objc private func cancelPressed(_ sender: Any) {
        onCancel?()
    }

    @objc private func quitPressed(_ sender: Any) {
        onQuit?()
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

@objc(OPNShortcutLegendView)
final class OPNShortcutLegendView: NSView {
    private let titleLabel = overlayLabel(
        "Shortcuts",
        size: 18,
        weight: .semibold,
        color: overlayColor(0.96, 0.97, 0.99, 1),
        alignment: .left
    )
    private let shortcutLabels: [NSTextField]
    private let descriptionLabels: [NSTextField]

    override init(frame frameRect: NSRect) {
        let shortcuts = ["Hold Options", "Command-H", "Command-G", "Command-R", "Command-N", "Command-M", "Command-K", "Command-L", "Command-Q", "Hold Esc"]
        let descriptions = ["Home dashboard", "Toggle this legend", "Audio HUD", "Record stream", "Stats HUD", "Toggle microphone", "Anti-AFK", "Copy logs", "Quit stream", "Release pointer"]
        shortcutLabels = shortcuts.map { shortcut in
            overlayLabel(shortcut, size: 12, weight: .semibold, color: overlayColor(0.75, 0.92, 0.86, 1), alignment: .left)
        }
        descriptionLabels = descriptions.map { description in
            overlayLabel(description, size: 12, weight: .regular, color: overlayColor(0.74, 0.76, 0.80, 1), alignment: .right)
        }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = overlayColor(0.03, 0.035, 0.045, 0.90).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = overlayColor(1, 1, 1, 0.12).cgColor

        addSubview(titleLabel)
        for label in shortcutLabels { addSubview(label) }
        for label in descriptionLabels { addSubview(label) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 20
        let width = bounds.width
        let top = bounds.height
        titleLabel.frame = NSRect(x: padding, y: top - 42, width: width - padding * 2, height: 22)
        for index in shortcutLabels.indices {
            let y = top - 78 - CGFloat(index) * 28
            shortcutLabels[index].frame = NSRect(x: padding, y: y, width: 112, height: 18)
            descriptionLabels[index].frame = NSRect(x: 132, y: y, width: width - 132 - padding, height: 18)
        }
    }
}

@objc(OPNStatsOverlayView)
final class OPNStatsOverlayView: NSView {
    private static let minWidth: CGFloat = 320
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    private static let minHeight: CGFloat = 22

    private let statsLineLabel: NSTextField = {
        let label = overlayLabel("", size: 10, weight: .medium, color: .clear, alignment: .left)
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.attributedStringValue = OPNStatsOverlayView.outlinedLine("Stats: measuring")
        return label
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(statsLineLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        statsLineLabel.frame = bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
    }

    @objc(preferredSizeForMaxWidth:)
    func preferredSize(forMaxWidth maxWidth: CGFloat) -> NSSize {
        let availableMaxWidth = max(1, maxWidth - Self.horizontalPadding * 2)
        let text = statsLineLabel.attributedStringValue.length > 0 ? statsLineLabel.attributedStringValue : Self.outlinedLine("Stats: measuring")
        let textBounds = text.boundingRect(
            with: NSSize(width: availableMaxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let contentWidth = ceil(textBounds.width)
        let contentHeight = ceil(textBounds.height)
        let width = min(maxWidth, max(Self.minWidth, contentWidth + Self.horizontalPadding * 2))
        let height = max(Self.minHeight, contentHeight + Self.verticalPadding * 2)
        return NSSize(width: width, height: height)
    }

    @objc(updateLatencyMs:bitrateMbps:packetsLost:resolution:fps:renderFps:codec:enhancement:framesDropped:)
    func update(
        latencyMs: Int,
        bitrateMbps: Double,
        packetsLost: Int64,
        resolution: String,
        fps: Int,
        renderFps: Double,
        codec: String,
        enhancement: String,
        framesDropped: UInt64
    ) {
        let latencyText = latencyMs >= 0 ? "\(latencyMs) ms" : "measuring"
        let bitrateText = bitrateMbps >= 0 ? String(format: "%.1f Mbps", bitrateMbps) : "--"
        var streamText = "--"
        if !resolution.isEmpty && fps > 0 {
            streamText = "\(resolution)@\(fps)"
        } else if !resolution.isEmpty {
            streamText = resolution
        }
        if !codec.isEmpty {
            streamText = "\(streamText)/\(codec)"
        }
        let renderText = renderFps >= 0 ? String(format: "%.0f fps", renderFps) : "-- fps"
        let enhancementText = enhancement.isEmpty ? "enh --" : enhancement
        let dropText = framesDropped > 0 ? "drop \(framesDropped)" : "drop 0"
        let lossText = packetsLost > 0 ? "loss \(packetsLost)" : "loss 0"
        statsLineLabel.attributedStringValue = Self.outlinedLine("\(latencyText) | \(bitrateText) | \(streamText) | \(renderText) | \(enhancementText) | \(dropText) | \(lossText)")
    }

    private static func outlinedLine(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byCharWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: overlayColor(1, 0.86, 0.18, 1),
                .strokeColor: overlayColor(0, 0, 0, 1),
                .strokeWidth: -2.8,
                .paragraphStyle: style,
            ]
        )
    }
}
