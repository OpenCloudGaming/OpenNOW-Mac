import SwiftUI

/// Shared shimmer clock: one 30 fps timer drives every `SkeletonBlock` on screen, so a grid of
/// loading tiles costs a single animation driver instead of one repeating animation per tile.
@MainActor
@Observable final class CatalogShimmerClock {
    static let shared = CatalogShimmerClock()

    private static let period: TimeInterval = 1.25
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    private(set) var phase: CGFloat = 0

    private var timer: Timer?
    private var subscriberCount = 0

    private init() {}

    func retain() {
        subscriberCount += 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { _ in
            MainActor.assumeIsolated { CatalogShimmerClock.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func release() {
        subscriberCount = max(subscriberCount - 1, 0)
        guard subscriberCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        phase = 0
    }

    private func tick() {
        phase = CGFloat(Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period)
    }
}

/// A single shimmering placeholder block used to build skeleton loading screens.
/// Falls back to a static translucent block when Reduce Motion is enabled.
struct SkeletonBlock: View {
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false
    @State private var isHoldingShimmerClock = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    var body: some View {
        Rectangle()
            .fill(OPNDesign.Fill.neutral(0.06))
            .overlay {
                if !isMotionReduced {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let bandWidth = width * 0.55
                        let progress = CatalogShimmerClock.shared.phase
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: OPNDesign.Fill.neutral(0.14), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .offset(x: -bandWidth + progress * (width + bandWidth))
                    }
                }
            }
            .onAppear {
                guard !isMotionReduced else { return }
                isHoldingShimmerClock = true
                CatalogShimmerClock.shared.retain()
            }
            .onDisappear {
                // Keyed on what this view actually took, not on the setting: Reduce Motion can be
                // toggled while skeletons are on screen, and reading it again here either leaked a
                // 30 fps timer for the life of the app or released one this view never held.
                guard isHoldingShimmerClock else { return }
                isHoldingShimmerClock = false
                CatalogShimmerClock.shared.release()
            }
    }
}

/// One skeleton rail. Every metric here mirrors `CatalogRailView.loadedBody` exactly - the 28pt
/// header row, the 14pt stack spacing, the tile row height and its 4pt bottom padding - so a rail
/// swapping from skeleton to games keeps the page at the same height and nothing below it moves.
///
/// A deferred library/favorites rail already knows its title before its games arrive, so it passes
/// one in and only the tiles read as loading.
struct CatalogRailSkeletonView: View {
    var title: String?
    var tileCount = 6
    var isPosterLayout = false
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity

    private var tileSize: CGSize {
        guard isPosterLayout else {
            return CGSize(width: CatalogVendorLayout.wideTileWidth(scale: uiScale, density: tileDensity), height: CatalogVendorLayout.wideTileHeight(scale: uiScale, density: tileDensity))
        }
        return CGSize(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity), height: CatalogPosterLayout.posterTileHeight(scale: uiScale, density: tileDensity))
    }

    private var rowHeight: CGFloat {
        isPosterLayout
            ? CatalogPosterLayout.tileRowHeight(scale: uiScale, density: tileDensity)
            : CatalogVendorLayout.tileRowHeight(scale: uiScale, density: tileDensity)
    }

    /// Top and bottom margins are equal in both layouts, so this is the one true source for both -
    /// no separate branch needed, and no way for it to drift out of sync with `rowHeight`.
    private var tileVerticalMargin: CGFloat { (rowHeight - tileSize.height) / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let title {
                    Text(title)
                        .catalogFont(size: 20, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.primary)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    SkeletonBlock()
                        .frame(width: 190 * uiScale, height: 20 * uiScale)
                }
                Spacer()
            }
            .frame(height: 28 * uiScale)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))

            HStack(spacing: 0) {
                ForEach(0..<tileCount, id: \.self) { _ in
                    SkeletonBlock()
                        .frame(width: tileSize.width, height: tileSize.height)
                        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                        .padding(.top, tileVerticalMargin)
                        .padding(.bottom, tileVerticalMargin)
                }
            }
            .frame(height: rowHeight, alignment: .top)
            .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
            .padding(.bottom, 4 * uiScale)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "Loading \($0)" } ?? "Loading games")
    }
}

/// Skeleton grid for a filtered catalog page while a browse is in flight.
///
/// `isScrollable` is off when this sits inside a page that already scrolls - a nested vertical
/// scroll view there has no height to resolve against and collapses.
struct CatalogGridSkeletonView: View {
    var tileCount = 12
    var isScrollable = true
    var isPosterLayout = false
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity

    private var tileSize: CGSize {
        guard isPosterLayout else {
            return CGSize(width: CatalogVendorLayout.wideTileWidth(scale: uiScale, density: tileDensity), height: CatalogVendorLayout.wideTileHeight(scale: uiScale, density: tileDensity))
        }
        return CGSize(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity), height: CatalogPosterLayout.posterTileHeight(scale: uiScale, density: tileDensity))
    }

    private var adaptiveMinimum: CGFloat {
        isPosterLayout
            ? CatalogPosterLayout.slotWidth(scale: uiScale, density: tileDensity)
            : CatalogVendorLayout.wideTileWidth(scale: uiScale, density: tileDensity) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: adaptiveMinimum), spacing: 4 * uiScale, alignment: .top)]
    }

    /// Derived from the row height the loaded tiles claim, so a placeholder row can never reserve a
    /// different height than the grid that replaces it.
    private var tileVerticalMargin: CGFloat {
        guard isPosterLayout else { return CatalogVendorLayout.tileTopMargin(scale: uiScale) }
        return CatalogPosterLayout.tileTopMargin(scale: uiScale)
    }

    var body: some View {
        Group {
            if isScrollable {
                ScrollView { grid }
            } else {
                grid
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Loading games")
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8 * uiScale) {
            ForEach(0..<tileCount, id: \.self) { _ in
                SkeletonBlock()
                    .frame(width: tileSize.width, height: tileSize.height)
                    .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                    .padding(.top, tileVerticalMargin)
                    .padding(.bottom, tileVerticalMargin)
            }
        }
        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
        .padding(.bottom, 12 * uiScale)
    }
}
