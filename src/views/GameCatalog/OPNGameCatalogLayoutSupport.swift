import AppKit
import GameController
import QuartzCore

@objc enum OPNStoreControllerFamily: Int {
    case keyboard = 0
    case xbox
    case playStation
    case nintendo
    case generic
}

@objc enum OPNGameCatalogInputAction: Int {
    case passThrough = 0
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveBackward
    case moveForward
    case activate
    case cycleVariant
}

@objc(OPNStoreControllerHintStyle)
final class OPNStoreControllerHintStyle: NSObject {
    @objc let selectGlyph: String
    @objc let variantGlyph: String

    init(selectGlyph: String, variantGlyph: String) {
        self.selectGlyph = selectGlyph
        self.variantGlyph = variantGlyph
        super.init()
    }
}

@objc(OPNStoreDocumentView)
final class OPNStoreDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@objc(OPNStoreRailScrollView)
final class OPNStoreRailScrollView: NSScrollView {
    private var dragScrolling = false
    private var lastDragLocation = NSPoint.zero
    private var dragScrollVelocity: CGFloat = 0.0
    private var lastDragScrollTimestamp: TimeInterval = 0.0
    private var inertiaTimer: Timer?
    private var lastInertiaTimestamp: TimeInterval = 0.0

    @objc func scrollHorizontally(byDelta deltaX: CGFloat) {
        guard let documentView else { return }
        let maxX = max(0.0, documentView.frame.width - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(maxX, max(0.0, origin.x + deltaX))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    @objc(beginDragScrollingAtTime:)
    func beginDragScrolling(atTime timestamp: TimeInterval) {
        stopInertia()
        dragScrollVelocity = 0.0
        lastDragScrollTimestamp = timestamp
    }

    @objc(dragScrollHorizontallyByDelta:timestamp:)
    func dragScrollHorizontally(byDelta deltaX: CGFloat, timestamp: TimeInterval) {
        let elapsed = timestamp - lastDragScrollTimestamp
        if elapsed > 0.001 {
            let sampledVelocity = deltaX / CGFloat(elapsed)
            dragScrollVelocity = dragScrollVelocity == 0.0 ? sampledVelocity : (dragScrollVelocity * 0.55 + sampledVelocity * 0.45)
        }
        lastDragScrollTimestamp = timestamp
        scrollHorizontally(byDelta: deltaX)
    }

    @objc func endDragScrollingWithInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        if abs(dragScrollVelocity) < OPNGameCatalogLayoutSupport.storeRailInertiaMinimumVelocity {
            dragScrollVelocity = 0.0
            return
        }
        lastInertiaTimestamp = CACurrentMediaTime()
        inertiaTimer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(inertiaTimerFired), userInfo: nil, repeats: true)
    }

    override func mouseDown(with event: NSEvent) {
        let maxX = documentView.map { max(0.0, $0.frame.width - contentView.bounds.width) } ?? 0.0
        if maxX <= 0.5 {
            super.mouseDown(with: event)
            return
        }
        dragScrolling = true
        lastDragLocation = convert(event.locationInWindow, from: nil)
        beginDragScrolling(atTime: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragScrolling else {
            super.mouseDragged(with: event)
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        let deltaX = lastDragLocation.x - location.x
        lastDragLocation = location
        dragScrollHorizontally(byDelta: deltaX, timestamp: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        if dragScrolling { endDragScrollingWithInertia() }
        dragScrolling = false
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let pageScrollView = enclosingScrollView, pageScrollView !== self {
            pageScrollView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopInertia() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func stopInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        dragScrollVelocity = 0.0
    }

    private func canScrollHorizontally(byDelta deltaX: CGFloat) -> Bool {
        guard let documentView else { return false }
        let maxX = max(0.0, documentView.frame.width - contentView.bounds.width)
        let currentX = contentView.bounds.origin.x
        if maxX <= 0.5 { return false }
        if deltaX < 0.0 { return currentX > 0.5 }
        if deltaX > 0.0 { return currentX < maxX - 0.5 }
        return false
    }

    @objc private func inertiaTimerFired() {
        let now = CACurrentMediaTime()
        let elapsed = max(0.001, now - lastInertiaTimestamp)
        lastInertiaTimestamp = now
        if abs(dragScrollVelocity) < OPNGameCatalogLayoutSupport.storeRailInertiaMinimumVelocity || !canScrollHorizontally(byDelta: dragScrollVelocity > 0.0 ? 1.0 : -1.0) {
            stopInertia()
            return
        }

        scrollHorizontally(byDelta: dragScrollVelocity * CGFloat(elapsed))
        dragScrollVelocity *= pow(OPNGameCatalogLayoutSupport.storeRailInertiaResistancePerSecond, CGFloat(elapsed))
    }
}

@objc(OPNStoreHintFixedView)
final class OPNStoreHintFixedView: NSView {
    @objc var fixedSize = NSSize.zero
    override var intrinsicContentSize: NSSize { fixedSize }
}

private final class OPNStoreControllerGlyphView: NSView {
    var glyph = ""

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = opnColor(OPNViewColor.textPrimary, 0.92)
        let bounds = self.bounds.insetBy(dx: 1.0, dy: 1.0)
        let minSide = min(bounds.width, bounds.height)
        let circleRect = NSRect(x: bounds.midX - minSide * 0.42, y: bounds.midY - minSide * 0.42, width: minSide * 0.84, height: minSide * 0.84)

        if glyph == "dpad" {
            color.setFill()
            let arm = floor(minSide * 0.22)
            let length = floor(minSide * 0.76)
            let horizontal = NSRect(x: bounds.midX - length * 0.5, y: bounds.midY - arm * 0.5, width: length, height: arm)
            let vertical = NSRect(x: bounds.midX - arm * 0.5, y: bounds.midY - length * 0.5, width: arm, height: length)
            NSBezierPath(roundedRect: horizontal, xRadius: arm * 0.38, yRadius: arm * 0.38).fill()
            NSBezierPath(roundedRect: vertical, xRadius: arm * 0.38, yRadius: arm * 0.38).fill()
            return
        }

        if glyph == "stick" {
            color.setStroke()
            let outer = NSBezierPath(ovalIn: circleRect)
            outer.lineWidth = 1.8
            outer.stroke()
            NSBezierPath(ovalIn: circleRect.insetBy(dx: minSide * 0.18, dy: minSide * 0.18)).fill()
            return
        }

        color.setStroke()
        let button = NSBezierPath(ovalIn: circleRect)
        button.lineWidth = 1.8
        button.stroke()

        if glyph == "triangle" {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: circleRect.midX, y: circleRect.minY + circleRect.height * 0.25))
            path.line(to: NSPoint(x: circleRect.minX + circleRect.width * 0.25, y: circleRect.maxY - circleRect.height * 0.25))
            path.line(to: NSPoint(x: circleRect.maxX - circleRect.width * 0.25, y: circleRect.maxY - circleRect.height * 0.25))
            path.close()
            path.lineWidth = 1.7
            path.stroke()
            return
        }

        if glyph == "cross" {
            let path = NSBezierPath()
            let inset = minSide * 0.28
            path.move(to: NSPoint(x: circleRect.minX + inset, y: circleRect.minY + inset))
            path.line(to: NSPoint(x: circleRect.maxX - inset, y: circleRect.maxY - inset))
            path.move(to: NSPoint(x: circleRect.maxX - inset, y: circleRect.minY + inset))
            path.line(to: NSPoint(x: circleRect.minX + inset, y: circleRect.maxY - inset))
            path.lineWidth = 2.0
            path.stroke()
            return
        }

        if glyph == "square" {
            let inset = minSide * 0.25
            let path = NSBezierPath(rect: circleRect.insetBy(dx: inset, dy: inset))
            path.lineWidth = 1.8
            path.stroke()
            return
        }

        let label = glyph.uppercased()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.0, weight: .black),
            .foregroundColor: color,
        ]
        let labelSize = label.size(withAttributes: attributes)
        let labelRect = NSRect(x: floor(circleRect.midX - labelSize.width * 0.5), y: floor(circleRect.midY - labelSize.height * 0.5) - 0.5, width: labelSize.width, height: labelSize.height)
        label.draw(in: labelRect, withAttributes: attributes)
    }
}

@objc(OPNStoreHintPillView)
final class OPNStoreHintPillView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isMousePoint(point, in: bounds) ? self : nil
    }
}

@objc(OPNGameCatalogLayoutSupport)
final class OPNGameCatalogLayoutSupport: NSObject {
    @objc static let storeTopInset: CGFloat = 0.0
    @objc static let storeNavigationClearance: CGFloat = 0.0
    @objc static let storeHeroHeightRatio: CGFloat = 0.3229
    @objc static let storeRowHeight: CGFloat = 282.0
    @objc static let storeCardSpacing: CGFloat = 18.0
    @objc static let storeTileWidth: CGFloat = 268.0
    @objc static let storeTileHeight: CGFloat = 151.0
    @objc static let storeHeroMinContentInset: CGFloat = 30.0
    @objc static let storeHeroMaxContentInset: CGFloat = 106.0
    @objc static let storeHeroContentInsetRatio: CGFloat = 0.055
    @objc static let storeFallbackHeroAspect: CGFloat = 1.0 / storeHeroHeightRatio
    @objc static let storeHeroMaxHeight: CGFloat = 820.0
    @objc static let storeHeroMaxViewportRatio: CGFloat = 0.62
    @objc static let storeHeroLogoMaxWidth: CGFloat = 520.0
    @objc static let storeHeroLogoMaxHeight: CGFloat = 180.0
    @objc static let storeHeroFirstRowSpacing: CGFloat = 64.0
    @objc static let storeButtonHintPillHeight: CGFloat = 40.0
    @objc static let storeButtonHintPillBottomInset: CGFloat = 18.0
    @objc static let storeTopFoldNextRowInset: CGFloat = -100.0
    @objc static let storeSearchPanelMinWidth: CGFloat = 300.0
    @objc static let storeSearchPanelMaxWidth: CGFloat = 420.0
    @objc static let storeRailInertiaMinimumVelocity: CGFloat = 8.0
    @objc static let storeRailInertiaResistancePerSecond: CGFloat = 0.035
    @objc static let storeRailImagePreloadCardBuffer: Int = 4
    @objc static let storeSearchDebounceInterval: TimeInterval = 0.18
    @objc static let storeHeroBackgroundFadeDuration: TimeInterval = 0.34
    @objc static let storeHeroLogoFadeDuration: TimeInterval = 0.24
    @objc static let storeHeroLogoFadeDelay: TimeInterval = 0.10

    @objc(heroHeightForWidth:viewportHeight:)
    static func heroHeight(forWidth width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let fallbackHeight = max(1.0, width) / storeFallbackHeroAspect
        let viewportHeightLimit = viewportHeight > 0.0 ? viewportHeight * storeHeroMaxViewportRatio : fallbackHeight
        return floor(min(storeHeroMaxHeight, viewportHeightLimit))
    }

    @objc(nextRowYAfterRow:rowIndex:hasHero:viewportHeight:)
    static func nextRowY(afterRow rowY: CGFloat, rowIndex: Int, hasHero: Bool, viewportHeight: CGFloat) -> CGFloat {
        var nextRowY = rowY + storeRowHeight
        if hasHero && rowIndex == 0 {
            nextRowY = max(nextRowY, floor(max(1.0, viewportHeight) + storeTopFoldNextRowInset))
        }
        return nextRowY
    }

    @objc static func connectedControllerFamily() -> OPNStoreControllerFamily {
        for controller in GCController.controllers() where controller.extendedGamepad != nil {
            let identity = controllerIdentity(controller)
            if identity.contains("PLAYSTATION") || identity.contains("DUALSENSE") || identity.contains("DUALSHOCK") || identity.contains("SONY") || identity.contains("PS4") || identity.contains("PS5") {
                return .playStation
            }
            if identity.contains("NINTENDO") || identity.contains("SWITCH") || identity.contains("JOY-CON") || identity.contains("JOYCON") || identity.contains("PRO CONTROLLER") {
                return .nintendo
            }
            if identity.contains("XBOX") || identity.contains("MICROSOFT") { return .xbox }
            return .generic
        }
        return .keyboard
    }

    @objc(controllerHintStyleForFamily:)
    static func controllerHintStyle(for family: OPNStoreControllerFamily) -> OPNStoreControllerHintStyle {
        switch family {
        case .playStation: return OPNStoreControllerHintStyle(selectGlyph: "cross", variantGlyph: "triangle")
        case .nintendo: return OPNStoreControllerHintStyle(selectGlyph: "a", variantGlyph: "x")
        case .xbox, .generic: return OPNStoreControllerHintStyle(selectGlyph: "a", variantGlyph: "y")
        case .keyboard: return OPNStoreControllerHintStyle(selectGlyph: "", variantGlyph: "")
        @unknown default: return OPNStoreControllerHintStyle(selectGlyph: "a", variantGlyph: "y")
        }
    }

    @objc(hintKeyViewWithSymbolName:fallback:width:)
    static func hintKeyView(symbolName: String, fallback: String, width: CGFloat) -> OPNStoreHintFixedView {
        MainActor.assumeIsolated {
            let keyView = baseKeyView(width: width)
            let symbolImage: NSImage?
            if #available(macOS 11.0, *) {
                symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: fallback)
                symbolImage?.isTemplate = true
            } else {
                symbolImage = nil
            }

            if let symbolImage {
                let imageView = NSImageView(frame: keyView.bounds.insetBy(dx: 5.0, dy: 4.0))
                imageView.image = symbolImage
                imageView.imageScaling = .scaleProportionallyDown
                if #available(macOS 10.14, *) { imageView.contentTintColor = opnColor(OPNViewColor.textPrimary, 0.92) }
                imageView.autoresizingMask = [.width, .height]
                keyView.addSubview(imageView)
            } else {
                let fallbackLabel = hintLabel(fallback, fontSize: 12.0, weight: .bold, color: opnColor(OPNViewColor.textPrimary, 0.92))
                fallbackLabel.frame = keyView.bounds.insetBy(dx: 4.0, dy: 5.0)
                fallbackLabel.autoresizingMask = [.width, .height]
                keyView.addSubview(fallbackLabel)
            }
            return keyView
        }
    }

    @objc(controllerIconKeyViewWithGlyph:width:)
    static func controllerIconKeyView(glyph: String, width: CGFloat) -> OPNStoreHintFixedView {
        MainActor.assumeIsolated {
            let keyView = baseKeyView(width: width)
            let glyphView = OPNStoreControllerGlyphView(frame: keyView.bounds.insetBy(dx: 4.0, dy: 3.0))
            glyphView.glyph = glyph
            glyphView.autoresizingMask = [.width, .height]
            keyView.addSubview(glyphView)
            return keyView
        }
    }

    @objc(hintGroupWithKeys:title:)
    static func hintGroup(keys: [OPNStoreHintFixedView], title: String) -> NSStackView {
        MainActor.assumeIsolated {
            let group = NSStackView(frame: .zero)
            group.orientation = .horizontal
            group.alignment = .centerY
            group.distribution = .gravityAreas
            group.spacing = 5.0
            for key in keys { group.addArrangedSubview(key) }
            group.addArrangedSubview(hintLabel(title, fontSize: 12.0, weight: .semibold, color: opnColor(OPNViewColor.textSecondary)))
            return group
        }
    }

    @objc(removeButtonHintGroupsFromStackView:)
    static func removeButtonHintGroups(from stackView: NSStackView?) {
        MainActor.assumeIsolated {
            let arrangedSubviews = stackView?.arrangedSubviews ?? []
            for view in arrangedSubviews {
                stackView?.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }
    }

    @objc(rebuildButtonHintStackView:currentFamily:)
    static func rebuildButtonHintStackView(_ stackView: NSStackView?, currentFamily: OPNStoreControllerFamily) -> OPNStoreControllerFamily {
        MainActor.assumeIsolated {
            guard let stackView else { return currentFamily }
            let family = connectedControllerFamily()
            if family == currentFamily, !stackView.arrangedSubviews.isEmpty { return currentFamily }
            removeButtonHintGroups(from: stackView)

            if family == .keyboard {
                stackView.addArrangedSubview(hintGroup(keys: [
                    hintKeyView(symbolName: "arrow.up", fallback: "Up", width: 24.0),
                    hintKeyView(symbolName: "arrow.down", fallback: "Dn", width: 24.0),
                    hintKeyView(symbolName: "arrow.left", fallback: "Lt", width: 24.0),
                    hintKeyView(symbolName: "arrow.right", fallback: "Rt", width: 24.0)
                ], title: "Move"))
                stackView.addArrangedSubview(hintGroup(keys: [
                    hintKeyView(symbolName: "return", fallback: "Ent", width: 30.0),
                    hintKeyView(symbolName: "space", fallback: "Space", width: 46.0)
                ], title: "Select"))
                stackView.addArrangedSubview(hintGroup(keys: [
                    hintKeyView(symbolName: "v.circle", fallback: "V", width: 26.0)
                ], title: "Variant"))
            } else {
                let style = controllerHintStyle(for: family)
                stackView.addArrangedSubview(hintGroup(keys: [
                    controllerIconKeyView(glyph: "dpad", width: 28.0),
                    controllerIconKeyView(glyph: "stick", width: 28.0)
                ], title: "Move"))
                stackView.addArrangedSubview(hintGroup(keys: [
                    controllerIconKeyView(glyph: style.selectGlyph, width: 28.0)
                ], title: "Select"))
                stackView.addArrangedSubview(hintGroup(keys: [
                    controllerIconKeyView(glyph: style.variantGlyph, width: 28.0)
                ], title: "Variant"))
            }

            stackView.needsLayout = true
            return family
        }
    }

    @objc(heroContentInsetForWidth:)
    static func heroContentInset(forWidth width: CGFloat) -> CGFloat {
        min(storeHeroMaxContentInset, max(storeHeroMinContentInset, width * storeHeroContentInsetRatio))
    }

    @objc(tileWidthForRailWidth:)
    static func tileWidth(forRailWidth width: CGFloat) -> CGFloat {
        let idealColumns = max(1.0, (width + storeCardSpacing) / (storeTileWidth + storeCardSpacing))
        let columns = max(1.0, idealColumns.rounded())
        return floor((width - storeCardSpacing * (columns - 1.0)) / columns)
    }

    @objc(tileMetricsForRailWidth:)
    static func tileMetrics(forRailWidth width: CGFloat) -> NSSize {
        let bucketedWidth = floor(max(320.0, width))
        let tileWidth = tileWidth(forRailWidth: bucketedWidth)
        let tileHeight = floor(tileWidth * storeTileHeight / storeTileWidth)
        return NSSize(width: tileWidth, height: tileHeight)
    }

    @objc(clampedIndexForIndex:count:)
    static func clampedIndex(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, index))
    }

    @objc(inputActionForEvent:)
    static func inputAction(for event: NSEvent) -> OPNGameCatalogInputAction {
        let characters = event.charactersIgnoringModifiers ?? ""
        guard let scalar = characters.unicodeScalars.first else { return .passThrough }
        switch scalar.value {
        case UInt32(NSLeftArrowFunctionKey), UnicodeScalar("a").value, UnicodeScalar("A").value:
            return .moveLeft
        case UInt32(NSRightArrowFunctionKey), UnicodeScalar("d").value, UnicodeScalar("D").value:
            return .moveRight
        case UInt32(NSUpArrowFunctionKey), UnicodeScalar("w").value, UnicodeScalar("W").value:
            return .moveUp
        case UInt32(NSDownArrowFunctionKey):
            return .moveDown
        case UInt32(NSTabCharacter):
            return event.modifierFlags.contains(.shift) ? .moveBackward : .moveForward
        case UInt32(NSCarriageReturnCharacter), UInt32(NSEnterCharacter), UnicodeScalar(" ").value:
            return .activate
        case UnicodeScalar("v").value, UnicodeScalar("V").value:
            return .cycleVariant
        default:
            return .passThrough
        }
    }

    private static func controllerIdentity(_ controller: GCController) -> String {
        var parts: [String] = []
        if let vendorName = controller.vendorName, !vendorName.isEmpty { parts.append(vendorName) }
        if #available(macOS 11.0, *), !controller.productCategory.isEmpty { parts.append(controller.productCategory) }
        return parts.joined(separator: " ").uppercased()
    }

    @MainActor
    private static func hintLabel(_ text: String, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = opnLabel(text, .zero, fontSize, color, weight, .center)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    @MainActor
    private static func baseKeyView(width: CGFloat) -> OPNStoreHintFixedView {
        let keyView = OPNStoreHintFixedView(frame: NSRect(x: 0.0, y: 0.0, width: width, height: 24.0))
        keyView.fixedSize = NSSize(width: width, height: 24.0)
        keyView.wantsLayer = true
        keyView.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.13).cgColor
        keyView.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor
        keyView.layer?.borderWidth = 1.0
        keyView.layer?.cornerRadius = 7.0
        keyView.layer?.masksToBounds = true
        return keyView
    }
}
