import QuartzCore
import SwiftUI

enum MacForceNowDesign {
    enum Surface {
        static let app = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
        static let appBar = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
        static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
        static let panelRaised = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
        static let tileTray = Color(red: 41 / 255, green: 41 / 255, blue: 41 / 255)
        static let field = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
        static let scrim = Color.black.opacity(0.58)
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
        static let pageHorizontal: CGFloat = 40
        static let railHorizontal: CGFloat = 32
        static let card: CGFloat = 18
    }

    enum Radius {
        static let avatar: CGFloat = 14
    }

    static let accent = Color.openNowGreen

    static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

extension View {
    func openNowFocusRing(_ isFocused: Bool) -> some View {
        overlay {
            Rectangle()
                .stroke(isFocused ? Color.openNowGreen : .clear, lineWidth: 2)
        }
    }

    func macForceNowInterfaceScale(_ scale: CGFloat) -> some View {
        modifier(MacForceNowInterfaceScaleModifier(scale: scale))
    }
}

private struct MacForceNowInterfaceScaleModifier: ViewModifier {
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

struct MacForceNowInterfaceScaleDensityBooster: NSViewRepresentable {
    let scale: CGFloat

    func makeNSView(context: Context) -> MacForceNowInterfaceScaleDensityView {
        MacForceNowInterfaceScaleDensityView(scale: scale)
    }

    func updateNSView(_ nsView: MacForceNowInterfaceScaleDensityView, context: Context) {
        nsView.scale = scale
    }

    static func dismantleNSView(_ nsView: MacForceNowInterfaceScaleDensityView, coordinator: ()) {
        nsView.restoreNaturalDensity()
        nsView.invalidate()
    }
}

final class MacForceNowInterfaceScaleDensityView: NSView {
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
