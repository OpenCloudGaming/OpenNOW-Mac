import SwiftUI

/// The menu bar popover's chrome, arranged the way Apple's Liquid Glass guidance asks for it.
///
/// The status-item popover is already Liquid Glass — the system draws it — so what goes *inside* it
/// is the question, and Apple is specific about it: Liquid Glass is "a distinct functional layer for
/// controls and navigation elements", custom glass should be applied "sparingly", to "the most
/// important functional elements", and glass must not be stacked on glass ("when placing elements on
/// top of Liquid Glass, avoid applying the material to both layers. Instead, use fills, transparency,
/// and vibrancy for the top elements").
///
/// So on macOS 26 and later: the panel is the system's glass, the session controls are glass
/// elements, and the cards and their list rows stay in the content layer as translucent fills. On
/// macOS 15.6 through 25 — the app's floor — there is no glass to draw and everything is the same
/// translucent fill, so nothing is lost by the older OS.
extension View {
    func opnMenuBarCard(radius: CGFloat = 14, fillOpacity: Double = 0.07) -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center cards
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(OPNDesign.Fill.neutral(fillOpacity))
            }
            .overlay {
                // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center cards
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(OPNDesign.Stroke.subtle, lineWidth: 1)
            }
    }

    /// A control inside a card: one of the few things that earns glass, because it is what the layer
    /// is for. Interactive glass is the variant that answers a press and a hover.
    @ViewBuilder
    func opnMenuBarControl(radius: CGFloat = 9) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: popoverShape(radius: radius))
        } else {
            background {
                // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center controls
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(OPNDesign.Fill.neutral(0.08))
            }
        }
    }

    /// A row in the popover's list: content, not chrome, so it stays a fill on every OS.
    @ViewBuilder
    func opnMenuBarRow(radius: CGFloat = 9, fillOpacity: Double = 0.08) -> some View {
        background {
            // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center list rows
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(OPNDesign.Fill.neutral(fillOpacity))
        }
    }

    /// An icon tab in the popover's top row. On macOS 26 and later the tabs are Liquid Glass
    /// elements, the way the session controls are — Apple lists navigation among the things the
    /// material is for — with the selected one tinted so the choice reads without a second layer of
    /// chrome. A `GlassEffectContainer` in the panel gathers the row into one sampling region, the
    /// same treatment the controls get. Before macOS 26 there is no glass to draw, so the tabs fall
    /// back to the translucent fill the rest of the surface uses, accent-marked when selected.
    @ViewBuilder
    func opnMenuBarTab(isSelected: Bool, radius: CGFloat = 9) -> some View {
        if #available(macOS 26.0, *) {
            if isSelected {
                glassEffect(.regular.tint(OPNDesign.accent).interactive(), in: popoverShape(radius: radius))
            } else {
                glassEffect(.regular.interactive(), in: popoverShape(radius: radius))
            }
        } else {
            background {
                // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center tab fills
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isSelected ? OPNDesign.accent.opacity(0.20) : OPNDesign.Fill.neutral(0.06))
            }
            .overlay {
                // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center tab fills
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(isSelected ? OPNDesign.accent.opacity(0.55) : OPNDesign.Stroke.subtle, lineWidth: 1)
            }
        }
    }
}

extension View {
    /// The popover's own backdrop. On macOS 26+ the status item's popover is already the system's
    /// glass panel, and a material under it would be the second layer Apple warns against; before
    /// that, the material *is* the panel.
    @ViewBuilder
    func opnMenuBarPanelBackground() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            background(.ultraThinMaterial)
        }
    }
}

/// The shape a glass element takes, in one place so the rounded-corner exception is annotated once
/// for the glass path as well as the flat one.
@available(macOS 26.0, *)
private func popoverShape(radius: CGFloat) -> RoundedRectangle {
    // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome, matches the Control Center glass elements
    RoundedRectangle(cornerRadius: radius, style: .continuous)
}
