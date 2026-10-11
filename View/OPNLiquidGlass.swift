import SwiftUI

/// The app's opt-in Liquid Glass appearance, resolved once per subtree. Three facts decide what an
/// eligible surface draws; only the first is the user's choice.
struct OPNLiquidGlassPolicy: Equatable, Sendable {
    /// The stored preference. Off when the key was never written, so an upgrade keeps its appearance.
    var isRequested: Bool
    /// This Mac can draw native Liquid Glass.
    var isSupported: Bool
    /// macOS Reduce Transparency is on. Forces the flat path without touching the stored preference.
    var isReduceTransparency: Bool

    /// Whether eligible surfaces draw glass right now.
    var isEffective: Bool { isRequested && isSupported && !isReduceTransparency }

    /// The policy a Mac that never opened the setting resolves to.
    static let off = OPNLiquidGlassPolicy(
        isRequested: false,
        isSupported: isSupportedOnThisMac,
        isReduceTransparency: false
    )

    /// The one place the OS floor is written down, so the settings row and every surface agree.
    static var isSupportedOnThisMac: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

private struct OPNLiquidGlassKey: EnvironmentKey {
    static let defaultValue = OPNLiquidGlassPolicy.off
}

extension EnvironmentValues {
    var opnLiquidGlass: OPNLiquidGlassPolicy {
        get { self[OPNLiquidGlassKey.self] }
        set { self[OPNLiquidGlassKey.self] = newValue }
    }
}

/// Injects the live policy at a detached root. SwiftUI inherits neither across an `NSHostingView`
/// nor across a scene, so a root that received the value once would keep drawing a stale answer.
private struct OPNLiquidGlassInjectionModifier: ViewModifier {
    @AppStorage(OPNThemePreferences.isLiquidGlassEnabledKey) private var isLiquidGlassEnabled = false
    @Environment(\.accessibilityReduceTransparency) private var isReduceTransparency

    func body(content: Content) -> some View {
        content.environment(\.opnLiquidGlass, OPNLiquidGlassPolicy(
            isRequested: isLiquidGlassEnabled,
            isSupported: OPNLiquidGlassPolicy.isSupportedOnThisMac,
            isReduceTransparency: isReduceTransparency
        ))
    }
}

extension View {
    func opnObservingLiquidGlass() -> some View {
        modifier(OPNLiquidGlassInjectionModifier())
    }
}

/// Draws one eligible chrome surface with Liquid Glass when the policy allows it, and with `flat`
/// when it does not. `flat` is the surface's existing treatment, never a thin material substitute.
private struct OPNLiquidGlassChromeModifier<Flat: View>: ViewModifier {
    let role: OPNDesign.CornerRole
    let scale: CGFloat
    let tint: Color?
    let glassScrim: Color?
    let isInteractive: Bool
    @ViewBuilder let flat: () -> Flat

    @Environment(\.opnLiquidGlass) private var policy
    @Environment(\.opnCornerGeometry) private var geometry

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), policy.isEffective {
            content
                .background { scrim }
                .glassEffect(glassEffect, in: geometry.shape(role, scale: scale))
        } else {
            content.background { flat() }
        }
    }

    /// Sits between the material and the content, so it darkens the glass without touching the flat
    /// path. A surface over video needs it: the bare material is legible for primary text and not for
    /// the dimmer tiers.
    @ViewBuilder
    private var scrim: some View {
        if let glassScrim { glassScrim }
    }

    @available(macOS 26.0, *)
    private var glassEffect: Glass {
        let effect = Glass.regular.interactive(isInteractive)
        guard let tintColor = tint else { return effect }
        return effect.tint(tintColor)
    }
}

extension View {
    /// Applies opt-in Liquid Glass to one chrome surface, falling back to `flat` when it is off.
    /// `isInteractive` belongs to enabled, actionable controls only; panels leave it off.
    func opnLiquidGlassChrome<Flat: View>(
        role: OPNDesign.CornerRole,
        scale: CGFloat = 1,
        tint: Color? = nil,
        glassScrim: Color? = nil,
        isInteractive: Bool = false,
        @ViewBuilder flat: @escaping () -> Flat
    ) -> some View {
        modifier(OPNLiquidGlassChromeModifier(
            role: role,
            scale: scale,
            tint: tint,
            glassScrim: glassScrim,
            isInteractive: isInteractive,
            flat: flat
        ))
    }

    /// The flat treatment most eligible surfaces share: a role-shaped fill under a 1pt border.
    func opnLiquidGlassChrome<Fill: ShapeStyle, Stroke: ShapeStyle>(
        role: OPNDesign.CornerRole,
        scale: CGFloat = 1,
        fill: Fill,
        stroke: Stroke,
        lineWidth: CGFloat = 1,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        opnLiquidGlassChrome(role: role, scale: scale, tint: tint, isInteractive: isInteractive) {
            ZStack {
                OPNCornerShape(role: role, scale: scale).fill(fill)
                OPNCornerShape(role: role, scale: scale).strokeBorder(stroke, lineWidth: lineWidth)
            }
        }
    }
}

/// Gathers neighboring glass elements into one sampling region. A no-op while glass is off, so the
/// flat path keeps the layout it already had.
private struct OPNLiquidGlassContainerModifier: ViewModifier {
    let spacing: CGFloat

    @Environment(\.opnLiquidGlass) private var policy

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), policy.isEffective {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    func opnLiquidGlassContainer(spacing: CGFloat) -> some View {
        modifier(OPNLiquidGlassContainerModifier(spacing: spacing))
    }
}
