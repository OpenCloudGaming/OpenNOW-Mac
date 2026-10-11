import SwiftUI

/// The app's opt-in Liquid Glass appearance, resolved once per subtree.
///
/// Three things decide what an eligible surface actually draws, and only the first is a choice the
/// user owns: whether they asked for glass at all, whether this Mac can draw it (macOS 26 and
/// later), and whether the system is asking for less transparency. Resolving them into one value
/// keeps every surface asking the same question, and keeps Off honest — the flat treatment a
/// surface already had is what it draws whenever the answer is no.
///
/// This is deliberately not a design token: it carries no colour, no shape and no geometry. It is
/// the capability/accessibility gate that decides which of two already-existing appearances a
/// surface wears.
struct OPNLiquidGlassPolicy: Equatable, Sendable {
    /// The stored preference. Off when the key was never written, which is what makes an upgrade
    /// keep the appearance it already had.
    var isRequested: Bool
    /// This Mac can draw native Liquid Glass.
    var isSupported: Bool
    /// macOS Reduce Transparency is on, which forces the flat path without touching the stored
    /// preference.
    var isReduceTransparency: Bool

    /// Whether eligible surfaces draw glass right now.
    var isEffective: Bool { isRequested && isSupported && !isReduceTransparency }

    /// The policy a Mac that never opened the setting resolves to.
    static let off = OPNLiquidGlassPolicy(
        isRequested: false,
        isSupported: isSupportedOnThisMac,
        isReduceTransparency: false
    )

    /// The one place the OS floor is written down, so the settings row and every surface agree on
    /// what "unsupported" means.
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

/// Injects the live policy into the environment. Every detached root observes it itself — the main
/// window, each stream window, the menu-bar scene and the Remote Co-Op window — for the same reason
/// the corner geometry does: SwiftUI does not inherit environment across an `NSHostingView` or a
/// separate scene, so a root that only received the value once would keep drawing a stale answer.
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

/// Draws an eligible chrome surface with Liquid Glass when the policy allows it, and with the flat
/// treatment the caller hands over when it does not.
///
/// The flat branch is not a second appearance invented for the toggle: it is the fills, borders and
/// shadows the surface already shipped, which is why every call site passes over its own exact
/// treatment rather than a thin-material approximation. A surface that has no backing of its own
/// today passes `EmptyView()`, so Off is byte-for-byte today's appearance.
private struct OPNLiquidGlassChromeModifier<Flat: View>: ViewModifier {
    let role: OPNDesign.CornerRole
    let scale: CGFloat
    let tint: Color?
    let isInteractive: Bool
    @ViewBuilder let flat: () -> Flat

    @Environment(\.opnLiquidGlass) private var policy
    @Environment(\.opnCornerGeometry) private var geometry

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), policy.isEffective {
            content.glassEffect(glassEffect, in: geometry.shape(role, scale: scale))
        } else {
            content.background { flat() }
        }
    }

    @available(macOS 26.0, *)
    private var glassEffect: Glass {
        var effect = Glass.regular
        if isInteractive { effect = effect.interactive() }
        if let tint { effect = effect.tint(tint) }
        return effect
    }
}

extension View {
    /// Applies the app's opt-in Liquid Glass to one chrome surface, falling back to `flat` — the
    /// treatment the surface already had — whenever the policy is not effective.
    ///
    /// `isInteractive` belongs to enabled, actionable controls only: a press and a hover answering
    /// through the material is what says the control is live. Panels and backings leave it off.
    func opnLiquidGlassChrome<Flat: View>(
        role: OPNDesign.CornerRole,
        scale: CGFloat = 1,
        tint: Color? = nil,
        isInteractive: Bool = false,
        @ViewBuilder flat: @escaping () -> Flat
    ) -> some View {
        modifier(OPNLiquidGlassChromeModifier(role: role, scale: scale, tint: tint, isInteractive: isInteractive, flat: flat))
    }
}

/// Gathers neighboring glass elements into one sampling region, the way Apple asks for when several
/// glass shapes sit side by side: one region, and shapes that can interact rather than sample each
/// other. A no-op when the policy is not effective, so the flat path keeps exactly the layout it
/// always had.
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
