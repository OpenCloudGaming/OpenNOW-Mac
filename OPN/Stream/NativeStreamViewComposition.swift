//  The in-stream composition bar: the marked text an IME is still composing, drawn over the video
//  so the player can see what a conversion is about to commit. It never takes input, and the
//  candidate panel is anchored to the bar through `firstRect` so it docks above visible text.
//

import AppKit

/// Over-video chrome takes fixed values, not the appearance palette. Those tokens are SwiftUI
/// `Color`s and `OPN/` must not import SwiftUI, so they are restated here per the AGENTS.md exception.
@MainActor
private enum NativeNVSTCompositionBarPalette {
    static let fill = NSColor.black.withAlphaComponent(0.45)
    static let ink = NSColor.white.withAlphaComponent(0.96)
    static let rule = NSColor.white.withAlphaComponent(0.85)
}

/// Draws the marked string and its underline. Hit-testing is deliberately empty: the bar sits over
/// the video but every click still belongs to the stream.
final class NativeNVSTCompositionBarView: NSView {
    var markedText = NSAttributedString() {
        didSet { needsDisplay = true }
    }
    var selection = NSRange(location: 0, length: 0) {
        didSet { needsDisplay = true }
    }
    var font = NativeStreamView.compositionFont(scale: 1) {
        didSet { needsDisplay = true }
    }
    var uiScale: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    /// Flipped so the draw rect reads from the top and the underline math runs downward.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = markedText
        guard !text.string.isEmpty else { return }
        let horizontalPadding = NativeStreamView.compositionHorizontalPadding(scale: uiScale)
        let verticalPadding = NativeStreamView.compositionVerticalPadding(scale: uiScale)
        NativeNVSTCompositionBarPalette.fill.setFill()
        NSBezierPath(rect: bounds).fill()
        let textFrame = NSRect(x: horizontalPadding,
                               y: verticalPadding,
                               width: max(0, bounds.width - horizontalPadding * 2),
                               height: max(0, bounds.height - verticalPadding * 2))
        (text.string as NSString).draw(in: textFrame, withAttributes: [
            .font: font,
            .foregroundColor: NativeNVSTCompositionBarPalette.ink,
        ])
        let textSize = NativeStreamView.compositionTextSize(text, font: font)
        let thickness = NativeStreamView.compositionUnderlineThickness(scale: uiScale)
        NativeNVSTCompositionBarPalette.rule.setFill()
        NSRect(x: horizontalPadding,
               y: verticalPadding + font.ascender + uiScale,
               width: textSize.width,
               height: thickness).fill()
        guard selection.length == 0 else { return }
        let caretX = horizontalPadding + NativeStreamView.compositionPrefixWidth(text, upTo: selection.location, font: font)
        NSRect(x: caretX, y: verticalPadding, width: max(1, thickness), height: textSize.height).fill()
    }
}

extension NativeStreamView {
    /// The font shared by the drawn bar, `firstRect` and `characterIndex`, so the candidate panel
    /// anchors to the text the player sees. Project face per DESIGN.md, scaled with the UI preference.
    nonisolated static func compositionFont(scale: CGFloat) -> NSFont {
        OPNUIFont.nsFont(size: 15 * scale, weight: .regular)
    }

    nonisolated static func compositionScale() -> CGFloat {
        CGFloat(OPNInterfacePreferences.uiScale)
    }

    nonisolated static func compositionHorizontalPadding(scale: CGFloat) -> CGFloat {
        OPNDesign.Spacing.small * scale
    }

    nonisolated static func compositionVerticalPadding(scale: CGFloat) -> CGFloat {
        OPNDesign.Spacing.xSmall * scale
    }

    nonisolated static func compositionInset(scale: CGFloat) -> CGFloat {
        OPNDesign.Spacing.large * scale
    }

    nonisolated static func compositionUnderlineThickness(scale: CGFloat) -> CGFloat {
        max(1, 1.5 * scale)
    }

    nonisolated static func compositionTextSize(_ markedText: NSAttributedString, font: NSFont) -> CGSize {
        let width = (markedText.string as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(0, width), height: font.ascender - font.descender)
    }

    /// Width of the marked text before `location`, clamped into the string. Shared by the bar caret
    /// and `firstRect`, so the candidate panel tracks the drawn caret exactly.
    nonisolated static func compositionPrefixWidth(_ markedText: NSAttributedString, upTo location: Int, font: NSFont) -> CGFloat {
        let length = markedText.length
        guard location > 0, length > 0 else { return 0 }
        let clamped = min(location, length)
        let prefix = markedText.attributedSubstring(from: NSRange(location: 0, length: clamped)).string as NSString
        return prefix.size(withAttributes: [.font: font]).width
    }

    nonisolated static func compositionBarFrame(in contentFrame: CGRect, textSize: CGSize, scale: CGFloat) -> CGRect {
        let horizontalPadding = compositionHorizontalPadding(scale: scale)
        let verticalPadding = compositionVerticalPadding(scale: scale)
        let inset = compositionInset(scale: scale)
        let width = textSize.width + horizontalPadding * 2
        let height = textSize.height + verticalPadding * 2
        let originX = min(contentFrame.minX + inset, max(contentFrame.minX, contentFrame.maxX - inset - width))
        let originY = min(contentFrame.minY + inset, max(contentFrame.minY, contentFrame.maxY - inset - height))
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Where the bar is drawn for the state at this moment. Shared with `firstRect`, so the IME
    /// candidate panel docks above the visible bar rather than a screen corner.
    func compositionBarFrame() -> CGRect {
        let scale = Self.compositionScale()
        let textSize = Self.compositionTextSize(textInputState.markedText, font: Self.compositionFont(scale: scale))
        return Self.compositionBarFrame(in: videoContentFrame(), textSize: textSize, scale: scale)
    }

    nonisolated static func compositionTextOriginX(in barFrame: CGRect, scale: CGFloat) -> CGFloat {
        barFrame.minX + compositionHorizontalPadding(scale: scale)
    }

    func compositionTextOriginX() -> CGFloat {
        Self.compositionTextOriginX(in: compositionBarFrame(), scale: Self.compositionScale())
    }

    /// Repaints the bar from the marked-text state: shown with the composing text, hidden on
    /// commit, cancel, teardown and window close.
    func updateCompositionBar() {
        guard textInputState.hasMarkedText else {
            nativeNVSTCompositionBar.markedText = NSAttributedString()
            nativeNVSTCompositionBar.isHidden = true
            return
        }
        let scale = Self.compositionScale()
        nativeNVSTCompositionBar.uiScale = scale
        nativeNVSTCompositionBar.font = Self.compositionFont(scale: scale)
        nativeNVSTCompositionBar.markedText = textInputState.markedText
        nativeNVSTCompositionBar.selection = textInputState.selection
        nativeNVSTCompositionBar.frame = compositionBarFrame()
        nativeNVSTCompositionBar.isHidden = false
        nativeNVSTCompositionBar.needsDisplay = true
    }
}
