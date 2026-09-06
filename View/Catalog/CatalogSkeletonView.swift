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
    var cornerRadius: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let bandWidth = width * 0.55
                        let progress = CatalogShimmerClock.shared.phase
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
                        .offset(x: -bandWidth + progress * (width + bandWidth))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                guard !reduceMotion else { return }
                CatalogShimmerClock.shared.retain()
            }
            .onDisappear {
                guard !reduceMotion else { return }
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
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let title {
                    Text(title)
                        .catalogFont(size: 20, weight: .medium)
                        .foregroundStyle(.white.opacity(0.96))
                        .accessibilityAddTraits(.isHeader)
                } else {
                    SkeletonBlock(cornerRadius: 4)
                        .frame(width: 190 * uiScale, height: 20 * uiScale)
                }
                Spacer()
            }
            .frame(height: 28 * uiScale)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))

            HStack(spacing: 0) {
                ForEach(0..<tileCount, id: \.self) { _ in
                    SkeletonBlock(cornerRadius: 2)
                        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                        .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
                    .padding(.bottom, CatalogVendorLayout.tileBottomMargin(scale: uiScale))
                        .padding(.bottom, CatalogVendorLayout.tileBottomMargin(scale: uiScale))
                }
            }
            .frame(height: CatalogVendorLayout.tileRowHeight(scale: uiScale), alignment: .top)
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
    @Environment(\.opnUIScale) private var uiScale

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2), spacing: 4 * uiScale, alignment: .top)]
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
                SkeletonBlock(cornerRadius: 2)
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                    .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                    .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
                    .padding(.bottom, CatalogVendorLayout.tileBottomMargin(scale: uiScale))
            }
        }
        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
        .padding(.bottom, 12 * uiScale)
    }
}
