import SwiftUI

/// A single shimmering placeholder block used to build skeleton loading screens.
/// Falls back to a static translucent block when Reduce Motion is enabled.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let bandWidth = width * 0.55
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.white.opacity(0.14), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .offset(x: animate ? width : -bandWidth)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

/// One skeleton rail: a placeholder title plus a row of placeholder tiles, matching the real
/// `CatalogRailView` metrics so the transition to loaded content doesn't shift layout.
struct CatalogRailSkeletonView: View {
    var tileCount = 6
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBlock(cornerRadius: 4)
                .frame(width: 190, height: 20)
                .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))

            HStack(spacing: 0) {
                ForEach(0..<tileCount, id: \.self) { _ in
                    SkeletonBlock(cornerRadius: 2)
                        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                        .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
                }
            }
            .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
        }
    }
}

/// Full-page skeleton for the Home / catalog rails surface (hero banner + a few rails).
struct CatalogHomeSkeletonView: View {
    let availableWidth: CGFloat
    var railCount = 3
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SkeletonBlock()
                    .frame(height: CatalogVendorLayout.heroHeight(for: availableWidth, scale: uiScale))

                ForEach(0..<railCount, id: \.self) { _ in
                    CatalogRailSkeletonView()
                }
            }
            .padding(.bottom, 44)
        }
        .background(Color.gfnBackgroundGreen)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading games")
    }
}

/// Skeleton grid for the Show All (filtered catalog) page while a browse is in flight.
struct CatalogGridSkeletonView: View {
    var tileCount = 12
    @Environment(\.opnUIScale) private var uiScale

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2), spacing: 4, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(0..<tileCount, id: \.self) { _ in
                    SkeletonBlock(cornerRadius: 2)
                        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                        .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
                }
            }
            .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
            .padding(.bottom, 12)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Loading games")
    }
}
