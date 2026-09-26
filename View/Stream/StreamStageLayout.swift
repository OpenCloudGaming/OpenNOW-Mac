//  Where the picture sits inside the stream window.
//
//  The window keeps a transparent titlebar with the content running under it, which is what gives
//  the catalog its full-bleed artwork. A stream cannot run under it: the traffic lights sit over
//  the top-left of the picture, and the HUD panels - the dock on the left, the stats panel on the
//  right - are anchored to the top of the picture, so their header rows came out sliced in half in
//  windowed mode. The stream area already excluded the titlebar's height; the slack was simply
//  left at the bottom of the window while the picture stayed pinned to the top.
//
//  So the strip is reserved here, at the top, and the picture is centred in what remains. Nothing
//  inside the stream needs a top padding of its own, and full screen - where the inset is zero -
//  is unchanged.
//

import SwiftUI

struct StreamStageLayout<Content: View>: View {
    let viewport: CGSize
    /// Height of the transparent titlebar the window content runs under; zero in full screen.
    let topInset: CGFloat
    let aspectRatio: CGFloat
    let content: (CGSize) -> Content

    init(viewport: CGSize, topInset: CGFloat, aspectRatio: CGFloat, @ViewBuilder content: @escaping (CGSize) -> Content) {
        self.viewport = viewport
        self.topInset = topInset
        self.aspectRatio = aspectRatio
        self.content = content
    }

    var reservedTopInset: CGFloat {
        min(max(topInset, 0), viewport.height)
    }

    var contentSize: CGSize {
        Self.contentSize(viewport: viewport, topInset: reservedTopInset, aspectRatio: aspectRatio)
    }

    /// The largest box of `aspectRatio` that fits the viewport once the titlebar strip is taken
    /// off it. Falls back to the whole viewport when there is no inset or no usable aspect.
    ///
    /// The arithmetic itself is `OPNStreamStageGeometry`, so the Picture-in-Picture resize - which
    /// is AppKit and never SwiftUI - measures the picture with the same function this does.
    static func contentSize(viewport: CGSize, topInset: CGFloat, aspectRatio: CGFloat) -> CGSize {
        OPNStreamStageGeometry.contentSize(viewport: viewport, topInset: topInset, aspectRatio: aspectRatio)
    }

    var body: some View {
        let size = contentSize
        VStack(spacing: 0) {
            Color.clear
                .frame(height: reservedTopInset)
            content(size)
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: viewport.width, height: viewport.height)
        .background(Color.black)
    }
}
