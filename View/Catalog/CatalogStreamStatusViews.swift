//  What the catalog shows while a stream is running in its own window.
//
//  The catalog window used to be replaced by the stream, so nothing on the page ever had to say a
//  game was running. Now it stays mounted behind the stream for the whole session, and without this
//  the app has a live game and a catalog that looks idle.
//
//  Two pieces, both in the active-session banner's visual language because a running stream and a
//  suspended seat are the same kind of fact:
//
//  * `VendorRunningStreamHomeBanner` takes the banner slot the session banner uses, with the one
//    action that one has no equivalent for - FOCUS, which brings the stream window forward.
//  * `VendorRunningStreamBackdrop` gives the page the game's own artwork, dimmed and blurred, so the
//    window reads as "this game is running" rather than as a catalog someone left open.
//

import SwiftUI

/// The banner for a stream that is live elsewhere in the app.
///
/// END routes through `StreamSessionLifecycle`, the same registry the menu bar's End Session and the
/// PiP control strip use, so all three tear down exactly the same thing.
struct VendorRunningStreamHomeBanner: View {
    let title: String
    var availableWidth: CGFloat = 0
    let onFocus: () -> Void
    let onEnd: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(OPNDesign.accent)
                .frame(width: 8 * uiScale, height: 8 * uiScale)
                .padding(.trailing, 10 * uiScale)

            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("STREAM RUNNING")
                    .catalogFont(size: 10, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                    .tracking(1.2)
                Text(title)
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                // Deliberately constant rather than the last progress message: that is whatever the
                // launch said on its way past ("Starting GeForce NOW stream..."), and a running
                // stream showing that reads as a stall. What is true for the whole session is where
                // the picture is.
                Text("Playing in its own window")
                    .catalogFont(size: 11)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16 * uiScale)

            HStack(spacing: 8 * uiScale) {
                Button("FOCUS") { onFocus() }
                    .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: true))
                Button("END") { onEnd() }
                    .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: false))
            }
        }
        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
        .padding(.vertical, 10 * uiScale)
        .frame(maxWidth: availableWidth > 0 ? availableWidth : .infinity, alignment: .leading)
        .background(OPNDesign.Surface.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)
        }
    }
}

/// The running game's artwork behind the page: artwork fill, an 18pt blur and the same scrim and
/// gradient the store picker already uses for the same job, so the two surfaces match.
///
/// Deliberately not hit-testable and hidden from accessibility: it is a backdrop, and everything
/// the page offers is still drawn on top of it.
struct VendorRunningStreamBackdrop: View {
    let artworkURL: URL?

    var body: some View {
        ZStack {
            if let artworkURL {
                CatalogRemoteImage(url: artworkURL, contentMode: .fill, maxPixelSize: 1920)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 18)
            }
            OPNDesign.Surface.scrim
            LinearGradient(
                colors: [.black.opacity(0.36), .clear, .black.opacity(0.44)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
