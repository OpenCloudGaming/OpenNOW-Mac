import AppKit
import MetalKit
import QuartzCore

@objc(OPNCoreAnimationCoordinator)
final class OPNCoreAnimationCoordinator: NSObject {
    @objc(sharedCoordinator)
    nonisolated(unsafe) static let sharedCoordinator = OPNCoreAnimationCoordinator()

    @objc(appleQuinticTimingFunction)
    static func appleQuinticTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    }

    @objc(animateFocusForCardLayer:glowLayer:focused:prominence:accentColor:)
    func animateFocus(
        forCardLayer cardLayer: CALayer?,
        glowLayer: CALayer?,
        focused: Bool,
        prominence: CGFloat,
        accentColor: NSColor?
    ) {
        guard let cardLayer else { return }

        let resolvedAccent = accentColor ?? .white
        let focusAmount = focused ? 1.0 : max(0.0, min(1.0, prominence))
        let scale = 1.0 + 0.075 * focusAmount

        var targetTransform = CATransform3DIdentity
        targetTransform.m34 = -1.0 / 760.0
        targetTransform = CATransform3DTranslate(targetTransform, 0.0, -10.0 * focusAmount, 42.0 * focusAmount)
        targetTransform = CATransform3DScale(targetTransform, scale, scale, 1.0)
        targetTransform = CATransform3DRotate(targetTransform, -0.030 * focusAmount, 1.0, 0.0, 0.0)
        let currentTransform = Self.currentTransformValue(for: cardLayer)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        cardLayer.transform = targetTransform
        cardLayer.zPosition = 100.0 * focusAmount
        cardLayer.shadowColor = resolvedAccent.cgColor
        cardLayer.shadowOpacity = Float(0.24 + 0.34 * focusAmount)
        cardLayer.shadowRadius = 18.0 + 34.0 * focusAmount
        cardLayer.shadowOffset = CGSize(width: 0.0, height: 12.0 + 16.0 * focusAmount)

        let transformSpring = Self.springAnimation(
            keyPath: "transform",
            fromValue: currentTransform,
            toValue: NSValue(caTransform3D: targetTransform),
            mass: 0.78,
            stiffness: 560.0,
            damping: 40.0,
            velocity: 0.0
        )
        cardLayer.add(transformSpring, forKey: "opn.focus.transform")

        if let glowLayer {
            let presentationGlow = glowLayer.presentation()
            let targetOpacity: CGFloat = focused ? 0.74 : 0.0
            let fromOpacity = NSNumber(value: presentationGlow?.opacity ?? glowLayer.opacity)
            glowLayer.backgroundColor = resolvedAccent.cgColor
            glowLayer.opacity = Float(targetOpacity)
            glowLayer.shadowColor = resolvedAccent.cgColor
            glowLayer.shadowOpacity = Float(targetOpacity)
            glowLayer.shadowRadius = 24.0 + 18.0 * focusAmount

            let opacitySpring = Self.springAnimation(
                keyPath: "opacity",
                fromValue: fromOpacity,
                toValue: NSNumber(value: targetOpacity),
                mass: 0.70,
                stiffness: 500.0,
                damping: 38.0,
                velocity: 0.0
            )
            glowLayer.add(opacitySpring, forKey: "opn.focus.glow")
        }

        CATransaction.commit()
    }

    @MainActor
    @objc(animateCardLayer:metadataContainer:backgroundLayer:expanded:accentColor:)
    func animateCardLayer(
        _ cardLayer: CALayer?,
        metadataContainer: NSView?,
        backgroundLayer: CALayer?,
        expanded: Bool,
        accentColor: NSColor?
    ) {
        guard let cardLayer, let metadataContainerLayer = metadataContainer?.layer, let backgroundLayer else { return }

        let resolvedAccent = accentColor ?? .white
        let scale = expanded ? 1.18 : 1.0
        let metadataOpacity: Float = expanded ? 0.28 : 1.0

        var targetTransform = CATransform3DIdentity
        targetTransform.m34 = -1.0 / 900.0
        targetTransform = CATransform3DTranslate(targetTransform, 0.0, expanded ? -18.0 : 0.0, expanded ? 80.0 : 0.0)
        targetTransform = CATransform3DScale(targetTransform, scale, scale, 1.0)
        let currentTransform = Self.currentTransformValue(for: cardLayer)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.42)
        CATransaction.setAnimationTimingFunction(Self.appleQuinticTimingFunction())

        cardLayer.transform = targetTransform
        cardLayer.shadowColor = resolvedAccent.cgColor
        cardLayer.shadowOpacity = expanded ? 0.62 : 0.34
        cardLayer.shadowRadius = expanded ? 64.0 : 22.0
        cardLayer.shadowOffset = CGSize(width: 0.0, height: expanded ? 34.0 : 14.0)
        metadataContainerLayer.opacity = metadataOpacity
        backgroundLayer.opacity = expanded ? 0.62 : 1.0

        let transformSpring = Self.springAnimation(
            keyPath: "transform",
            fromValue: currentTransform,
            toValue: NSValue(caTransform3D: targetTransform),
            mass: 0.85,
            stiffness: 360.0,
            damping: 34.0,
            velocity: 0.0
        )
        cardLayer.add(transformSpring, forKey: "opn.expand.transform")

        CATransaction.commit()
    }

    @MainActor
    @objc(springScrollClipView:toX:velocity:)
    func springScrollClipView(_ clipView: NSClipView?, toX targetX: CGFloat, velocity: CGFloat) {
        guard let clipView else { return }

        clipView.wantsLayer = true
        let currentBounds = clipView.bounds
        let currentX = currentBounds.origin.x
        let distance = targetX - currentX
        let normalizedVelocity = abs(distance) > 1.0 ? velocity / distance : 0.0
        var targetBounds = currentBounds
        targetBounds.origin.x = targetX

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipView.bounds = targetBounds

        let spring = Self.springAnimation(
            keyPath: "bounds.origin.x",
            fromValue: NSNumber(value: currentX),
            toValue: NSNumber(value: targetX),
            mass: 1.0,
            stiffness: 220.0,
            damping: 29.0,
            velocity: normalizedVelocity
        )
        clipView.layer?.add(spring, forKey: "opn.carousel.snap")
        CATransaction.commit()

        clipView.scroll(to: NSPoint(x: targetX, y: currentBounds.origin.y))
        clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    @MainActor
    @objc(configureMetalViewForProMotion:)
    func configureMetalViewForProMotion(_ metalView: MTKView?) {
        guard let metalView else { return }

        var maximumFramesPerSecond = metalView.window?.screen?.maximumFramesPerSecond ?? 60
        if maximumFramesPerSecond <= 0 {
            maximumFramesPerSecond = 60
        }
        metalView.preferredFramesPerSecond = min(120, maximumFramesPerSecond)
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.framebufferOnly = true
    }

    private static func springAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any,
        mass: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat,
        velocity: CGFloat
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = fromValue
        animation.toValue = toValue
        animation.mass = mass
        animation.stiffness = stiffness
        animation.damping = damping
        animation.initialVelocity = velocity
        animation.duration = min(0.82, animation.settlingDuration)
        animation.isRemovedOnCompletion = true
        return animation
    }

    private static func currentTransformValue(for layer: CALayer) -> NSValue {
        NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
    }
}
