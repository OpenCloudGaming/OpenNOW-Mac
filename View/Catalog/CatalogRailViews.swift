//  The home rails and the destination grid they scroll inside, plus the tiles that end them.
//  Split out of CatalogContentViews.swift.
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogRailView: View {
    let viewModel: CatalogViewModel
    let section: CatalogSectionModel
    let onShowAll: () -> Void
    @State private var scrollIndex = 0
    @State private var isRailHovering = false
    @Environment(\.opnUIScale) private var uiScale

    private var games: [OPNCatalogGameObject] {
        var visibleGames = section.visibleGames(expanded: false)
        guard let selectedGame = viewModel.selectedGame else { return visibleGames }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return visibleGames }
        guard !visibleGames.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }),
              let sectionGame = section.games.first(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else { return visibleGames }
        visibleGames.append(sectionGame)
        return visibleGames
    }
    private var canShowAll: Bool { section.canLoadFullList }

    var body: some View {
        if section.isPlaceholder {
            // Deferred library/favorites rail: keep its title and reserve the row with a skeleton
            // so the layout does not jump when the games arrive a moment later. The skeleton owns
            // the header too - drawing a title here as well stacked two headers and made the
            // placeholder rail taller than the loaded one it turns into.
            CatalogRailSkeletonView(title: section.title)
                .transition(.opacity)
        } else {
            loadedBody
        }
    }

    private var loadedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(section.title)
                    .nvidiaFont(size: 20, weight: .medium)
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canShowAll {
                    Button("SHOW ALL", action: onShowAll)
                        .buttonStyle(.plain)
                        .nvidiaFont(size: 13, weight: .bold)
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(height: 28 * uiScale)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))

            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(games, id: \.catalogIdentity) { game in
                                EquatableView(content: CatalogGameTile(
                                    game: game,
                                    imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 768),
                                    isSelected: isSelected(game),
                                    isSelectionActive: viewModel.selectedGame != nil,
                                    isQueuedForPatching: viewModel.isQueuedForPatching(game),
                                    isResumableSession: viewModel.isResumableSessionGame(game),
                                    showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                                    onSelect: { viewModel.toggleGameSelection(game, inSection: section.id) },
                                    onPlay: { viewModel.launch(game: game) },
                                    onMarkOwned: {
                                        viewModel.selectGame(game, inSection: section.id)
                                        viewModel.handleUnownedSelectedVariantPrimaryAction()
                                    },
                                    onQueueForPatching: { viewModel.queuePatchingLaunch(game: game) }
                                ))
                                    .id(game.catalogIdentity)
                            }
                            ForEach(Array(section.tiles.enumerated()), id: \.offset) { _, tile in
                                CatalogPanelActionTile(
                                    tile: tile,
                                    imageURL: viewModel.optimizedImageURL(tile.imageUrl, width: 768),
                                    action: { viewModel.openPanelTile(tile) }
                                )
                            }
                            if canShowAll {
                                CatalogSeeMoreTile(title: "Show All", action: onShowAll)
                            }
                        }
                        .frame(height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale))
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
                        .padding(.bottom, 4 * uiScale)
                    }
                    if games.count > 3 {
                        HStack {
                            CatalogRailArrow(name: "lt_arrow") {
                                moveRail(proxy: proxy, delta: -3)
                            }
                            Spacer()
                            CatalogRailArrow(name: "rt_arrow") {
                                moveRail(proxy: proxy, delta: 3)
                            }
                        }
                        .padding(.horizontal, 8)
                        // The arrows sit on top of the artwork, so they only earn their place while
                        // the pointer is on this rail. Hit testing follows the opacity - an
                        // invisible target that still swallows clicks is worse than no target.
                        .opacity(isRailHovering ? 1 : 0)
                        .allowsHitTesting(isRailHovering)
                        .accessibilityHidden(!isRailHovering)
                        .opnMotion(OpenNOWDesign.Motion.hover, value: isRailHovering)
                    }
                }
                .onHover { isRailHovering = $0 }
                .onAppear { revealSelectedGameIfNeeded(proxy: proxy, request: viewModel.selectedGameRevealRequest) }
                .onChange(of: viewModel.selectedGameRevealRequest) { _, request in revealSelectedGameIfNeeded(proxy: proxy, request: request) }
            }
        }
        .onAppear { prefetchNearVisibleImages() }
        .onChange(of: games.map(\.catalogIdentity)) { _, _ in prefetchNearVisibleImages() }
    }

    private func moveRail(proxy: ScrollViewProxy, delta: Int) {
        guard !games.isEmpty else { return }
        scrollIndex = min(max(scrollIndex + delta, 0), max(games.count - 1, 0))
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(games[scrollIndex].catalogIdentity, anchor: .leading)
        }
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func prefetchNearVisibleImages() {
        viewModel.prefetchRailImages(section: section, games: games)
    }

    private func revealSelectedGameIfNeeded(proxy: ScrollViewProxy, request: CatalogGameRevealRequest?) {
        guard let request, request.sectionId.isEmpty || request.sectionId == section.id else { return }
        guard games.contains(where: { $0.catalogIdentity == request.gameIdentity }) else { return }
        Task { @MainActor in
            guard games.contains(where: { $0.catalogIdentity == request.gameIdentity }) else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(request.gameIdentity, anchor: .center)
            }
        }
    }
}

struct CatalogDestinationGridView: View {
    let viewModel: CatalogViewModel
    let section: CatalogSectionModel
    @Environment(\.opnUIScale) private var uiScale

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2), spacing: 4 * uiScale, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            HStack(alignment: .lastTextBaseline, spacing: 20 * uiScale) {
                Text(section.title)
                    .nvidiaFont(size: 24, weight: .bold)
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                if !section.isPlaceholder {
                    Text("\(section.games.count) game\(section.games.count == 1 ? "" : "s")")
                        .nvidiaFont(size: 12, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.accent.opacity(0.86))
                        .tracking(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
            .padding(.top, 24 * uiScale)

            if section.isPlaceholder {
                CatalogGridSkeletonView(isScrollable: false)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8 * uiScale) {
                    ForEach(Array(section.games.enumerated()), id: \.element.catalogIdentity) { _, game in
                        CatalogGameTile(
                            game: game,
                            imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 768),
                            isSelected: isSelected(game),
                            isSelectionActive: viewModel.selectedGame != nil,
                            isQueuedForPatching: viewModel.isQueuedForPatching(game),
                            isResumableSession: viewModel.isResumableSessionGame(game),
                            showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                            onSelect: { viewModel.toggleGameSelection(game, inSection: section.id) },
                            onPlay: { viewModel.launch(game: game) },
                            onMarkOwned: {
                                viewModel.selectGame(game, inSection: section.id)
                                viewModel.handleUnownedSelectedVariantPrimaryAction()
                            },
                            onQueueForPatching: { viewModel.queuePatchingLaunch(game: game) }
                        )
                    }
                }
                .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
                .padding(.bottom, 12 * uiScale)
            }
        }
        .onAppear { prefetchGridImages() }
        .onChange(of: section.games.map(\.catalogIdentity)) { _, _ in prefetchGridImages() }
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func prefetchGridImages() {
        viewModel.prefetchGridImages(section: section)
    }
}

struct CatalogRailArrow: View {
    let name: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .background(.black.opacity(isHovering ? 0.52 : 0.24), in: Circle())
                .opnHoverScale(isHovering, factor: 1.10)
        }
        .buttonStyle(.opnPressable(scale: 0.92))
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
    }
}

struct CatalogSeeMoreTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .nvidiaFont(size: 34, weight: .bold)
                    .foregroundStyle(.white.opacity(0.82))
                Text(title.uppercased())
                    .nvidiaFont(size: 16, weight: .medium)
                    .foregroundStyle(.white.opacity(0.88))
            }
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
            .background(Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.24), lineWidth: 2) }
            .opnHoverScale(isHovering, factor: CatalogVendorLayout.tileScaleFactor)
            .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
            .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
            .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale), alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all")
    }
}

struct CatalogPanelActionTile: View {
    let tile: OPNCatalogPanelTileObject
    let imageURL: URL?
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 768)
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    if !tile.subtitle.isEmpty {
                        Text(tile.subtitle.uppercased())
                            .nvidiaFont(size: 10, weight: .bold)
                            .tracking(0.8)
                            .foregroundStyle(OpenNOWDesign.accent)
                            .lineLimit(1)
                    }
                    Text(tile.title.isEmpty ? (tile.kind == "filter" ? "Browse Games" : "Featured") : tile.title)
                        .nvidiaFont(size: 17, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(actionLabel)
                        .nvidiaFont(size: 11, weight: .bold)
                        .tracking(0.7)
                        .foregroundStyle(.black.opacity(0.88))
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(OpenNOWDesign.accent)
                }
                .padding(14)
            }
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
            .overlay { Rectangle().stroke(isHovering ? OpenNOWDesign.accent : Color.white.opacity(0.16), lineWidth: isHovering ? 2 : 1) }
            .opnHoverScale(isHovering, factor: CatalogVendorLayout.tileScaleFactor)
            .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
            .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
            .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale), alignment: .top)
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tile.title.isEmpty ? actionLabel : tile.title)
    }

    private var actionLabel: String {
        if !tile.actionLabel.isEmpty { return tile.actionLabel.uppercased() }
        return tile.kind == "filter" ? "BROWSE" : "OPEN"
    }
}

struct VendorActiveSessionHomeBanner: View {
    let title: String
    let isResumable: Bool
    let serverIp: String
    let onResume: () -> Void
    let onEnd: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(OpenNOWDesign.accent)
                .frame(width: 8 * uiScale, height: 8 * uiScale)
                .shadow(color: OpenNOWDesign.accent, radius: 4)
                .padding(.trailing, 10 * uiScale)

            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("SESSION ACTIVE")
                    .nvidiaFont(size: 10, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.2)
                Text(title)
                    .nvidiaFont(size: 14, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 16 * uiScale)

            HStack(spacing: 8 * uiScale) {
                if isResumable {
                    Button("RESUME") { onResume() }
                        .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: true))
                }
                Button("END") { onEnd() }
                    .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: false))
            }
        }
        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
        .padding(.vertical, 10 * uiScale)
        .background(OpenNOWDesign.Surface.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct VendorActiveSessionBannerButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .nvidiaFont(size: 11, weight: .bold)
            .foregroundStyle(primary ? .black : .white.opacity(0.86))
            .tracking(0.8)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(primary
                ? OpenNOWDesign.accent.opacity(configuration.isPressed ? 0.78 : 1.0)
                : Color.white.opacity(configuration.isPressed ? 0.10 : 0.055))
            .overlay {
                if !primary {
                    Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
            }
    }
}
