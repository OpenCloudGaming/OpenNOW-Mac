import AppKit

@objc(OPNGameCardView)
final class OPNGameCardView: NSView {
    @objc var selectedVariantIndex: Int32 = -1
    @objc var imageRevealDelay: TimeInterval = 0.0
    @objc var onPlay: (() -> Void)?

    private let contentView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton(frame: .zero)
    private var mouseHovering = false
    private var gamepadFocused = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildViewHierarchy()
    }

    override var isFlipped: Bool { true }

    @objc class func cardSize() -> NSSize {
        NSSize(width: 288.0, height: 288.0)
    }

    @objc class func imageHeight() -> CGFloat {
        288.0
    }

    @objc class func infoHeight() -> CGFloat {
        0.0
    }

    override func layout() {
        super.layout()
        let shortestSide = max(1.0, min(bounds.width, bounds.height))
        let cornerRadius = shortestSide * (20.0 / 180.0)
        layer?.cornerRadius = cornerRadius
        contentView.frame = bounds
        contentView.layer?.cornerRadius = cornerRadius
        titleLabel.frame = NSRect(x: 16.0, y: max(12.0, bounds.height - 44.0), width: max(0.0, bounds.width - 32.0), height: 22.0)
        let playWidth = bounds.width * (76.0 / 180.0)
        let playHeight = bounds.height * (34.0 / 180.0)
        playButton.frame = NSRect(x: (bounds.width - playWidth) / 2.0, y: 10.0, width: playWidth, height: playHeight)
        updatePlayButtonVisibility()
    }

    @objc func selectVariant(at index: Int32) {
        selectedVariantIndex = index
    }

    @objc func setGamepadFocused(_ focused: Bool) {
        guard gamepadFocused != focused else { return }
        gamepadFocused = focused
        updateInteractionChrome()
    }

    @objc func resetMouseTrackingIfOutside() {
        guard mouseHovering, let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        if !bounds.contains(localPoint) {
            mouseHovering = false
            updateInteractionChrome()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseHovering = true
        updateInteractionChrome()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseHovering = false
        updateInteractionChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let nextTrackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        trackingAreaRef = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = opnColor(0xFFFFFF, 0.13).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.38
        layer?.shadowRadius = 20.0
        layer?.shadowOffset = CGSize(width: 0.0, height: 16.0)

        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = opnColor(0x071108, 0.84).cgColor
        addSubview(contentView)

        titleLabel.stringValue = "Game"
        titleLabel.font = NSFont.systemFont(ofSize: 14.0, weight: .bold)
        titleLabel.textColor = opnColor(OPNViewColor.textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true
        contentView.addSubview(titleLabel)

        playButton.title = "PLAY"
        playButton.isBordered = false
        playButton.font = NSFont.systemFont(ofSize: 12.0, weight: .bold)
        playButton.contentTintColor = opnColor(OPNViewColor.accentOn)
        playButton.wantsLayer = true
        playButton.layer?.cornerRadius = 17.0
        playButton.layer?.backgroundColor = opnColor(OPNViewColor.brandGreen, 0.94).cgColor
        playButton.isHidden = true
        playButton.target = self
        playButton.action = #selector(playClicked)
        addSubview(playButton)
    }

    private func updateInteractionChrome() {
        let focused = mouseHovering || gamepadFocused
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        layer?.borderWidth = focused ? 2.0 : 1.0
        layer?.borderColor = focused ? opnColor(OPNViewColor.brandGreen, 0.88).cgColor : opnColor(0xFFFFFF, 0.10).cgColor
        layer?.shadowOpacity = focused ? 0.52 : 0.38
        layer?.shadowRadius = focused ? 26.0 : 20.0
        layer?.zPosition = gamepadFocused ? 6.0 : 0.0
        CATransaction.commit()
        updatePlayButtonVisibility()
    }

    private func updatePlayButtonVisibility() {
        playButton.isHidden = !(mouseHovering || gamepadFocused)
    }

    @objc private func playClicked() {
        onPlay?()
    }
}
