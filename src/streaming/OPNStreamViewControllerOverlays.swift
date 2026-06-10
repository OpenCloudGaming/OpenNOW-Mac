import AppKit

private func overlayColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

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
