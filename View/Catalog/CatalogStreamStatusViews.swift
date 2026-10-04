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

/// The banner for a stream that is live elsewhere in the app. END goes through
/// `StreamSessionLifecycle`, like the menu bar's End Session and the PiP control strip.
struct VendorRunningStreamHomeBanner: View {
    let title: String
    var availableWidth: CGFloat = 0
    let onFocus: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VendorStatusBannerChrome(eyebrow: "STREAM RUNNING", title: title, availableWidth: availableWidth) {
            Button("FOCUS") { onFocus() }
                .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: true))
            Button("END") { onEnd() }
                .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: false))
        }
    }
}

/// The running game's artwork behind the page: artwork fill, an 18pt blur and the same scrim and
/// gradient the store picker already uses for the same job, so the two surfaces match.
///
/// Deliberately not hit-testable and hidden from accessibility: it is a backdrop, and everything
/// the page offers is still drawn on top of it.
///
/// The size is passed in and applied as an explicit frame rather than left as an unbounded
/// `maxWidth`/`maxHeight` child with `ignoresSafeArea()`. As a ZStack sibling that is free to report
/// its own ideal size, a full-window backdrop can resize the page it sits behind - the page then
/// lays out larger than the window and reads as cropped. The store picker's artwork solves this the
/// same way: `GeometryReader` measures, the backdrop frames itself to that measurement.
struct VendorRunningStreamBackdrop: View {
    let artworkURL: URL?
    let viewport: CGSize

    var body: some View {
        ZStack {
            if let artworkURL {
                CatalogRemoteImage(url: artworkURL, contentMode: .fill, maxPixelSize: 1920)
                    .frame(width: viewport.width, height: viewport.height)
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
        .frame(width: viewport.width, height: viewport.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
