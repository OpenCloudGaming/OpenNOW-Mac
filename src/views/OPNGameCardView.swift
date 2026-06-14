import AppKit
import Backend
import Combine
import SwiftUI

@MainActor
private final class OPNGameCardModel: ObservableObject {
    @Published var gamepadFocused = false
    @Published var mouseHovering = false
}

@objc(OPNGameCardView)
@MainActor
final class OPNGameCardView: NSView {
    @objc var selectedVariantIndex: Int32 = -1
    @objc var imageRevealDelay: TimeInterval = 0.0
    @objc var onPlay: (() -> Void)?

    private let model = OPNGameCardModel()
    private var hostingView: NSHostingView<OPNGameCardSwiftUIView>?
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
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
        hostingView?.frame = bounds
    }

    @objc func selectVariant(at index: Int32) {
        selectedVariantIndex = index
    }

    @objc func setGamepadFocused(_ focused: Bool) {
        model.gamepadFocused = focused
    }

    @objc func resetMouseTrackingIfOutside() {
        guard model.mouseHovering, let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        if !bounds.contains(localPoint) { model.mouseHovering = false }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        model.mouseHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        model.mouseHovering = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let nextTrackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        trackingAreaRef = nextTrackingArea
        addTrackingArea(nextTrackingArea)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let hosting = NSHostingView(rootView: OPNGameCardSwiftUIView(model: model, onPlay: { [weak self] in self?.onPlay?() }))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNGameCardSwiftUIView: View {
    @ObservedObject var model: OPNGameCardModel

    let onPlay: () -> Void

    private var focused: Bool { model.mouseHovering || model.gamepadFocused }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(nsColor: OPNUIHelpers.color(rgb: 0x071108, alpha: 0.84)))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(focused ? Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.88)) : .white.opacity(0.10), lineWidth: focused ? 2 : 1))
                .shadow(color: .black.opacity(focused ? 0.52 : 0.38), radius: focused ? 26 : 20, y: 16)

            if focused {
                Button("PLAY") { onPlay() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.accentOn, alpha: 1)))
                    .frame(width: 122, height: 54)
                    .background(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.94)), in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}
