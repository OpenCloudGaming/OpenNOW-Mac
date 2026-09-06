import Darwin
import ObjectiveC
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
        /// Degraded-but-not-broken state on app-shell surfaces: unsaved edits, a low battery, a
        /// value that still works but wants attention. Matches `WebRTCMediaStreamTheme.warning`
        /// so the same condition reads the same colour in the stream HUD and in Settings.
        static let warning = Color.orange
    }

    enum Text {
        static let primary = Color.white.opacity(0.96)
        static let secondary = Color.white.opacity(0.72)
        static let tertiary = Color.white.opacity(0.52)
        static let muted = Color.white.opacity(0.38)
    }

    /// Budget for `opnTakingFocus`.
    static let focusAttempts = 6
    static let focusRetryMilliseconds = 30

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

    /// Type roles for the app. `label`/`body` use the app's UI sans (brand voice);
    /// `mono` is reserved for machine readouts (telemetry, counters, codes) so
    /// numerals stay column-aligned while they tick.
    enum Typography {
        static func display(size: CGFloat, scale: CGFloat = 1) -> Font {
            .uiSans(size: size * scale, weight: .black)
        }

        static func label(size: CGFloat, scale: CGFloat = 1, weight: OpenNOWUIFont.Weight = .bold) -> Font {
            .uiSans(size: size * scale, weight: weight)
        }

        static func body(size: CGFloat, scale: CGFloat = 1, weight: OpenNOWUIFont.Weight = .regular) -> Font {
            .uiSans(size: size * scale, weight: weight)
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

        /// Shared curve vocabulary. Every interactive surface should reach for one of these rather
        /// than inventing a duration: the durations used to be spread across twenty files, so two
        /// adjacent controls could fade at different speeds for no reason. Use them through
        /// `opnMotion(_:value:)`, which drops the motion under Reduce Motion.
        ///
        /// Pointer-driven state that must feel instant (hover tints, borders).
        static let hover = Animation.easeOut(duration: 0.16)
        /// Click feedback. Shorter than `hover` so the press reads as a direct response.
        static let press = Animation.easeOut(duration: 0.10)
        /// A control changing state in place (chevron flip, disclosure, tab tint).
        static let toggle = Animation.easeInOut(duration: 0.18)
        /// Panels and menus entering or leaving. The only spring in the set - travel is the point.
        static let panel = Animation.spring(response: 0.34, dampingFraction: 0.86)
        /// Whole-surface swaps (page change, skeleton to content).
        static let page = Animation.easeInOut(duration: 0.24)

        /// Substitute used when Reduce Motion is on: same timing family, no spring overshoot, and
        /// paired with `opnTransition` so nothing travels or scales.
        static let reduced = Animation.easeInOut(duration: 0.12)

        /// Per-item delay for staggered appearance, and the index it stops growing at. Without the
        /// cap a 400-tile grid would ripple for ten seconds.
        static let stagger: TimeInterval = 0.028
        static let staggerLimit = 12

        static func staggered(_ animation: Animation, index: Int) -> Animation {
            animation.delay(Double(min(max(index, 0), staggerLimit)) * stagger)
        }
    }

    static let accent = Color(red: 0.46, green: 0.90, blue: 0.10)

    static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

extension View {
    /// Now sits over interactive rows (settings toggles, sliders), not just buttons, so it is
    /// explicitly inert and absent rather than a permanently installed clear stroke.
    func openNowFocusRing(_ isFocused: Bool) -> some View {
        overlay {
            if isFocused {
                Rectangle()
                    .stroke(OpenNOWDesign.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Takes `@FocusState` for a field that is being inserted, retrying briefly.
    ///
    /// A focus request made in the same frame as the insertion is dropped - the field is not in the
    /// responder chain yet - so this yields, then re-asks while the field is still meant to be
    /// focused. Both the search field in the top bar and the one in controller mode need it, and a
    /// per-site copy meant the attempt count and delay had to stay in sync by hand.
    func opnTakingFocus(_ isFocused: FocusState<Bool>.Binding, while shouldFocus: Bool) -> some View {
        task(id: shouldFocus) {
            guard shouldFocus else { return }
            await Task.yield()
            for _ in 0..<OpenNOWDesign.focusAttempts {
                guard !Task.isCancelled, shouldFocus else { return }
                if isFocused.wrappedValue { return }
                isFocused.wrappedValue = true
                try? await Task.sleep(for: .milliseconds(OpenNOWDesign.focusRetryMilliseconds))
            }
        }
    }

    func opnInterfaceScale(_ scale: CGFloat) -> some View {
        modifier(OpenNOWInterfaceScaleModifier(scale: scale))
    }

    /// `animation(_:value:)` that answers to Reduce Motion. Springs and long curves collapse to
    /// `Motion.reduced`, so a state change still cross-fades instead of snapping, but nothing
    /// overshoots. One switch here beats a `guard !reduceMotion` at every call site.
    func opnMotion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(OpenNOWMotionModifier(animation: animation, value: value))
    }

    /// Transition that degrades to a plain cross-fade under Reduce Motion, which is exactly what
    /// the setting asks for: the state change still reads, the travel does not happen.
    func opnTransition(_ transition: AnyTransition) -> some View {
        modifier(OpenNOWTransitionModifier(transition: transition))
    }

    /// Hover scale that Reduce Motion flattens. Callers still pair it with `opnMotion` for timing;
    /// this only decides whether the transform is applied at all.
    func opnHoverScale(_ isActive: Bool, factor: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(OpenNOWHoverScaleModifier(isActive: isActive, factor: factor, anchor: anchor))
    }
}

private struct OpenNOWMotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? OpenNOWDesign.Motion.reduced : animation, value: value)
    }
}

private struct OpenNOWTransitionModifier: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

private struct OpenNOWHoverScaleModifier: ViewModifier {
    let isActive: Bool
    let factor: CGFloat
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.scaleEffect(reduceMotion || !isActive ? 1 : factor, anchor: anchor)
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
        walkInterval = Self.activeInterval
        applyDensity(targetScale: effectiveTargetScale())
        guard scale != 1 else { return }
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self, window != nil, window?.inLiveResize == false else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastApplication >= walkInterval else { return }
            lastApplication = now
            // A settled window needs no correcting, and re-walking it ten times a second is pure
            // cost. Back off while nothing changes; a page rebuild puts it straight back.
            walkInterval = applyDensity(targetScale: effectiveTargetScale()) ? Self.activeInterval : min(walkInterval * 2, Self.settledInterval)
        }
        runLoopObserver = observer
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private var lastApplication: CFAbsoluteTime = 0
    private var walkInterval: CFTimeInterval = OpenNOWInterfaceScaleDensityView.activeInterval
    /// How often the tree is corrected while it is still changing, and the ceiling once it is not.
    private static let activeInterval: CFTimeInterval = 0.1
    private static let settledInterval: CFTimeInterval = 0.8

    private func effectiveTargetScale() -> CGFloat {
        scale * (window?.backingScaleFactor ?? 1)
    }

    private func stopObserver() {
        if let runLoopObserver {
            CFRunLoopObserverInvalidate(runLoopObserver)
            self.runLoopObserver = nil
        }
    }

    @discardableResult
    private func applyDensity(targetScale: CGFloat) -> Bool {
        guard let root = window?.contentView?.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let didChange = forceContentsScale(root, targetScale: targetScale)
        CATransaction.commit()
        return didChange
    }

    /// The layer class SwiftUI draws its vector content into, resolved once. Identifying it by
    /// `String(describing: type(of:))` allocated a string and ran type introspection for every
    /// layer in the window on every pass, which is most of what this walk used to cost.
    private static let drawingLayerClass: AnyClass? = NSClassFromString("CGDrawingLayer")

    /// Returns whether anything needed changing, so the caller can walk less often while the tree
    /// is settled.
    @discardableResult
    private func forceContentsScale(_ layer: CALayer, targetScale: CGFloat) -> Bool {
        if layer is CAMetalLayer { return false }
        var didChange = false
        if let drawingLayerClass = Self.drawingLayerClass, object_getClass(layer) === drawingLayerClass,
           abs(layer.contentsScale - targetScale) > 0.0001 {
            layer.contentsScale = targetScale
            layer.setNeedsDisplay()
            markOwningHostingViewDirty(layer)
            didChange = true
        }
        guard let sublayers = layer.sublayers else { return didChange }
        for sublayer in sublayers where forceContentsScale(sublayer, targetScale: targetScale) {
            didChange = true
        }
        return didChange
    }

    private func markOwningHostingViewDirty(_ layer: CALayer) {
        var current: CALayer? = layer
        while let candidate = current {
            if let view = candidate.delegate as? NSView {
                // `strncmp` on the runtime's own name: the generic parameter makes an `is` check
                // impossible, and describing the type would allocate on a path that runs per layer.
                if strncmp(object_getClassName(view), "NSHostingView", 13) == 0 {
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
