import AppKit

enum OPNViewColor {
    static let brandGreen: UInt32 = 0x34C759
    static let accentOn: UInt32 = 0x06140A
    static let textPrimary: UInt32 = 0xF5F5F7
    static let textSecondary: UInt32 = 0xB7B8BE
    static let errorRed: UInt32 = 0xFF453A
    static let linkBlue: UInt32 = 0x0A84FF
}

func opnColor(_ rgb: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    let red = CGFloat((rgb >> 16) & 0xFF) / 255.0
    let green = CGFloat((rgb >> 8) & 0xFF) / 255.0
    let blue = CGFloat(rgb & 0xFF) / 255.0
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

@MainActor
func opnLabel(
    _ text: String,
    _ frame: NSRect,
    _ size: CGFloat,
    _ color: NSColor,
    _ weight: NSFont.Weight = .regular,
    _ alignment: NSTextAlignment = .left
) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.frame = frame
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.alignment = alignment
    label.lineBreakMode = .byWordWrapping
    label.isEditable = false
    label.isSelectable = false
    label.drawsBackground = false
    label.isBordered = false
    return label
}

@MainActor
func opnButton(_ title: String, _ frame: NSRect, _ background: NSColor, _ textColor: NSColor) -> NSButton {
    let button = NSButton(frame: frame)
    button.title = title
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = background.cgColor
    button.layer?.cornerRadius = 10.0
    button.contentTintColor = textColor
    button.font = NSFont.systemFont(ofSize: 14.0, weight: .semibold)
    return button
}
