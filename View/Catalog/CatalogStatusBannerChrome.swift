//  The chrome both catalog status banners are drawn on - the running-stream banner and the
//  active-session banner - so the surface, metrics and hairline are defined once.

import SwiftUI

/// The chrome a catalog status banner sits on: accent dot, eyebrow over title, actions trailing.
struct VendorStatusBannerChrome<Actions: View>: View {
    let eyebrow: String
    let title: String
    var availableWidth: CGFloat = 0
    @ViewBuilder let actions: Actions

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(OPNDesign.accent)
                .frame(width: 8 * uiScale, height: 8 * uiScale)
                .padding(.trailing, 10 * uiScale)

            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text(eyebrow)
                    .catalogFont(size: 10, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                    .tracking(1.2)
                Text(title)
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16 * uiScale)

            HStack(spacing: 8 * uiScale) { actions }
        }
        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
        .padding(.vertical, 10 * uiScale)
        // Clamp before the chrome so the background and hairline paint at the page width, not at
        // the scroll view's inflated content width.
        .frame(maxWidth: availableWidth > 0 ? availableWidth : .infinity, alignment: .leading)
        // The fill and its hairline are clipped together, so the rule follows the banner's corners
        // instead of running past them.
        .background {
            ZStack(alignment: .bottom) {
                OPNDesign.Surface.chrome
                Rectangle()
                    .fill(OPNDesign.Stroke.subtle)
                    .frame(height: 1)
            }
            // Pinned flush under the app bar and spanning the page, so its top corners stay square:
            // rounding them cut a notch of page background out of the seam the band shares with the
            // bar above it, which read as a broken top border. The free bottom corners still follow
            // the Corner Style, hairline included.
            .opnCornerClip(role: .card, scale: uiScale, corners: .bottom)
        }
    }
}
