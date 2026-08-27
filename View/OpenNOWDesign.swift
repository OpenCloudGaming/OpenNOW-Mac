import QuartzCore
import SwiftUI

enum OpenNOWDesign {
    enum Surface {
        static let app = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
        static let appBar = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
        static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
        static let panelRaised = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
        static let tileTray = Color(red: 41 / 255, green: 41 / 255, blue: 41 / 255)
        static let field = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
        static let scrim = Color.black.opacity(0.58)
        static let deep = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)
        static let overlay = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
        static let chrome = Color(red: 57 / 255, green: 57 / 255, blue: 59 / 255)
    }

    enum Semantic {
        static let destructive = Color(red: 1, green: 0.54, blue: 0.50)
    }

    enum Text {
        static let primary = Color.white.opacity(0.96)
        static let secondary = Color.white.opacity(0.72)
        static let tertiary = Color.white.opacity(0.52)
        static let muted = Color.white.opacity(0.38)
    }

    enum Stroke {
        static let subtle = Color.white.opacity(0.10)
        static let regular = Color.white.opacity(0.14)
        static let strong = Color.white.opacity(0.22)
    }

    enum Spacing {
        private static let baseXXSmall: CGFloat = 4
        private static let baseXSmall: CGFloat = 8
        private static let baseSmall: CGFloat = 12
        private static let baseMedium: CGFloat = 16
        private static let baseLarge: CGFloat = 20
        private static let baseXLarge: CGFloat = 24
        private static let baseXXLarge: CGFloat = 32
        private static let baseXXXLarge: CGFloat = 40
        private static let basePageHorizontal: CGFloat = 40
        private static let baseRailHorizontal: CGFloat = 32
        private static let baseCard: CGFloat = 18
        private static let baseSection: CGFloat = 10
        private static let baseContentVertical: CGFloat = 14
        private static let baseControlRow: CGFloat = 12
        private static let baseMenuPanelVertical: CGFloat = 4

        static let xxSmall: CGFloat = baseXXSmall
        static let xSmall: CGFloat = baseXSmall
        static let small: CGFloat = baseSmall
        static let medium: CGFloat = baseMedium
        static let large: CGFloat = baseLarge
        static let xLarge: CGFloat = baseXLarge
        static let xxLarge: CGFloat = baseXXLarge
        static let xxxLarge: CGFloat = baseXXXLarge
        static let pageHorizontal: CGFloat = basePageHorizontal
        static let railHorizontal: CGFloat = baseRailHorizontal
        static let card: CGFloat = baseCard
        static let section: CGFloat = baseSection
        static let contentVertical: CGFloat = baseContentVertical
        static let controlRow: CGFloat = baseControlRow
        static let menuPanelVertical: CGFloat = baseMenuPanelVertical

        static func xxSmall(scale: CGFloat) -> CGFloat { baseXXSmall * scale }
        static func xSmall(scale: CGFloat) -> CGFloat { baseXSmall * scale }
        static func small(scale: CGFloat) -> CGFloat { baseSmall * scale }
        static func medium(scale: CGFloat) -> CGFloat { baseMedium * scale }
        static func large(scale: CGFloat) -> CGFloat { baseLarge * scale }
        static func xLarge(scale: CGFloat) -> CGFloat { baseXLarge * scale }
        static func xxLarge(scale: CGFloat) -> CGFloat { baseXXLarge * scale }
        static func xxxLarge(scale: CGFloat) -> CGFloat { baseXXXLarge * scale }
        static func pageHorizontal(scale: CGFloat) -> CGFloat { basePageHorizontal * scale }
        static func railHorizontal(scale: CGFloat) -> CGFloat { baseRailHorizontal * scale }
        static func card(scale: CGFloat) -> CGFloat { baseCard * scale }
        static func section(scale: CGFloat) -> CGFloat { baseSection * scale }
        static func contentVertical(scale: CGFloat) -> CGFloat { baseContentVertical * scale }
        static func controlRow(scale: CGFloat) -> CGFloat { baseControlRow * scale }
        static func menuPanelVertical(scale: CGFloat) -> CGFloat { baseMenuPanelVertical * scale }
    }

    enum Radius {
        private static let baseAvatar: CGFloat = 14
        private static let baseChip: CGFloat = 0
        private static let baseCard: CGFloat = 2
        private static let basePanel: CGFloat = 3

        static let chip: CGFloat = baseChip
        static let card: CGFloat = baseCard
        static let panel: CGFloat = basePanel

        static func avatar(scale: CGFloat) -> CGFloat { baseAvatar * scale }
        static func chip(scale: CGFloat) -> CGFloat { baseChip * scale }
        static func card(scale: CGFloat) -> CGFloat { baseCard * scale }
        static func panel(scale: CGFloat) -> CGFloat { basePanel * scale }
    }

    /// Type roles for the app. `label`/`body` use NVIDIA Sans (brand voice);
    /// `mono` is reserved for machine readouts (telemetry, counters, codes) so
    /// numerals stay column-aligned while they tick.
    enum Typography {
        static func display(size: CGFloat, scale: CGFloat = 1) -> Font {
            .nvidiaSans(size: size * scale, weight: .black)
        }

        static func label(size: CGFloat, scale: CGFloat = 1, weight: OpenNOWNVIDIAFont.Weight = .bold) -> Font {
            .nvidiaSans(size: size * scale, weight: weight)
        }

        static func body(size: CGFloat, scale: CGFloat = 1, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
            .nvidiaSans(size: size * scale, weight: weight)
        }

        static func mono(size: CGFloat, scale: CGFloat = 1, weight: Font.Weight = .bold) -> Font {
            .system(size: size * scale, weight: weight, design: .monospaced)
        }
    }

    enum Motion {
        /// 30 fps clock for decorative ambient `TimelineView` animations. The native
        /// `.animation` schedule fires every display frame (up to 120 Hz on ProMotion),
        /// so throttling to 30 fps halves render work on 60 Hz panels and quarters it
        /// on 120 Hz panels with no perceptible change for slow, large-area motion.
        static let ambientFrameInterval: TimeInterval = 1.0 / 30.0

        /// 60 fps clock for short, foreground-hero motion (the startup scan sweep).
        /// Fast small-area travel reads as stepped at 30 fps, and these surfaces
        /// live for under three seconds, so the extra frames are worth paying for.
        static let heroFrameInterval: TimeInterval = 1.0 / 60.0
    }

    static let accent = Color(red: 0.46, green: 0.90, blue: 0.10)

    static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

extension View {
    func openNowFocusRing(_ isFocused: Bool) -> some View {
        overlay {
            Rectangle()
                .stroke(isFocused ? OpenNOWDesign.accent : .clear, lineWidth: 2)
        }
    }

    func macForceNowInterfaceScale(_ scale: CGFloat) -> some View {
        modifier(OpenNOWInterfaceScaleModifier(scale: scale))
    }
}

/// Real content-size UI scale for Catalog views (replaces the visual scaleEffect hack for that surface only).
private struct OPNUIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var opnUIScale: CGFloat {
        get { self[OPNUIScaleKey.self] }
        set { self[OPNUIScaleKey.self] = newValue }
    }
}

private struct OpenNOWInterfaceScaleModifier: ViewModifier {
    let scale: CGFloat

    private var effectiveScale: CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width / effectiveScale, height: proxy.size.height / effectiveScale)
                .scaleEffect(effectiveScale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
}

struct OpenNOWInterfaceScaleDensityBooster: NSViewRepresentable {
    let scale: CGFloat

    func makeNSView(context: Context) -> OpenNOWInterfaceScaleDensityView {
        OpenNOWInterfaceScaleDensityView(scale: scale)
    }

    func updateNSView(_ nsView: OpenNOWInterfaceScaleDensityView, context: Context) {
        nsView.scale = scale
    }

    static func dismantleNSView(_ nsView: OpenNOWInterfaceScaleDensityView, coordinator: ()) {
        nsView.restoreNaturalDensity()
        nsView.invalidate()
    }
}

final class OpenNOWInterfaceScaleDensityView: NSView {
    var scale: CGFloat {
        didSet { reconfigure() }
    }
    nonisolated(unsafe) private var runLoopObserver: CFRunLoopObserver?

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconfigure()
    }

    func restoreNaturalDensity() {
        applyDensity(targetScale: window?.backingScaleFactor ?? 1)
    }

    func invalidate() {
        stopObserver()
    }

    private func reconfigure() {
        stopObserver()
        guard window != nil else { return }
        applyDensity(targetScale: effectiveTargetScale())
        guard scale != 1 else { return }
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self, window != nil, window?.inLiveResize == false else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastApplication >= 0.1 else { return }
            lastApplication = now
            applyDensity(targetScale: effectiveTargetScale())
        }
        runLoopObserver = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private var lastApplication: CFAbsoluteTime = 0

    private func effectiveTargetScale() -> CGFloat {
        scale * (window?.backingScaleFactor ?? 1)
    }

    private func stopObserver() {
        if let runLoopObserver {
            CFRunLoopObserverInvalidate(runLoopObserver)
            self.runLoopObserver = nil
        }
    }

    private func applyDensity(targetScale: CGFloat) {
        guard let root = window?.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        forceContentsScale(root, targetScale: targetScale)
        CATransaction.commit()
    }

    private func forceContentsScale(_ layer: CALayer, targetScale: CGFloat) {
        if layer is CAMetalLayer { return }
        let isReRenderable = String(describing: type(of: layer)) == "CGDrawingLayer"
        if isReRenderable, abs(layer.contentsScale - targetScale) > 0.0001 {
            layer.contentsScale = targetScale
            layer.setNeedsDisplay()
            markOwningHostingViewDirty(layer)
        }
        layer.sublayers?.forEach { forceContentsScale($0, targetScale: targetScale) }
    }

    private func markOwningHostingViewDirty(_ layer: CALayer) {
        var current: CALayer? = layer
        while let candidate = current {
            if let view = candidate.delegate as? NSView {
                if String(describing: type(of: view)).hasPrefix("NSHostingView<") {
                    view.needsDisplay = true
                }
                return
            }
            current = candidate.superlayer
        }
    }

    deinit {
        if let runLoopObserver {
            CFRunLoopObserverInvalidate(runLoopObserver)
        }
    }
}
