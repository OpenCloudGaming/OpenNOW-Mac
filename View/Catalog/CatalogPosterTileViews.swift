//  Portrait poster tiles for the Poster home layout - twins of the wide tiles in
//  CatalogGameTileViews.swift and CatalogRailViews.swift, built on CatalogPosterLayout metrics.
//

import SwiftUI

struct CatalogPosterTile: View, @preconcurrency Equatable {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isSelected: Bool
    let isSelectionActive: Bool
    let isQueuedForPatching: Bool
    let isResumableSession: Bool
    let showsFreeAccountAccessBadges: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onMarkOwned: () -> Void
    let onQueueForPatching: () -> Void
    var onHoverChanged: ((Bool) -> Void)?
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity
    @AppStorage(OPNThemePreferences.tileTitleVisibilityKey) private var tileTitleVisibilityRawValue = OPNThemePreferences.TileTitleVisibility.onHover.rawValue

    private var tileTitleVisibility: OPNThemePreferences.TileTitleVisibility {
        OPNThemePreferences.TileTitleVisibility(rawValue: tileTitleVisibilityRawValue) ?? .onHover
    }

    static func == (lhs: CatalogPosterTile, rhs: CatalogPosterTile) -> Bool {
        lhs.game.catalogIdentity == rhs.game.catalogIdentity &&
        lhs.imageURL == rhs.imageURL &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isSelectionActive == rhs.isSelectionActive &&
        lhs.isQueuedForPatching == rhs.isQueuedForPatching &&
        lhs.isResumableSession == rhs.isResumableSession
    }

    private var posterWidth: CGFloat { CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity) }
    private var posterHeight: CGFloat { CatalogPosterLayout.posterTileHeight(scale: uiScale, density: tileDensity) }

    var body: some View {
        CatalogHoverTracker(onHover: { isHovering = $0; onHoverChanged?($0) }) {
            ZStack(alignment: .topLeading) {
                Button(action: onSelect) {
                    tileContent
                }
                .buttonStyle(.opnPressable(scale: 0.985))
                .accessibilityLabel(game.title.isEmpty ? "Game tile" : game.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isSelected ? "Details open" : "")

                ZStack(alignment: .topLeading) {
                    playButton
                }
                .frame(width: posterWidth, height: posterHeight)
                .padding(.leading, CatalogPosterLayout.tileHorizontalMargin(scale: uiScale))
                .padding(.top, CatalogPosterLayout.tileTopMargin(scale: uiScale))
                .padding(.bottom, CatalogPosterLayout.tileBottomMargin(scale: uiScale))
                .opacity(isHovering ? 1 : 0)
                // Settles into place rather than materialising, same reasoning as the wide tile's button.
                .opnHoverScale(!isHovering, factor: 0.92, anchor: .topLeading)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
                .zIndex(2)
            }
            .opnHoverScale(isHovering && !isSelectionActive, factor: CatalogPosterLayout.tileScaleFactor)
            .opnMotion(OPNDesign.Motion.hover, value: isHovering)
        }
        // Kept for the grid, where the tile is placed directly in the stack.
        .zIndex(isHovering ? 1 : 0)
    }

    private var playButton: some View {
        Button(action: primaryAction) {
            HStack(spacing: 7) {
                Image(systemName: primaryIconName)
                    .catalogFont(size: 10, weight: .bold)
                Text(primaryTitle)
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(0.9)
            }
            .foregroundStyle(game.isLaunchPatching ? (isQueuedForPatching ? OPNDesign.Fixed.accent.opacity(0.92) : OPNDesign.Text.primary) : .black.opacity(0.88))
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 30 * uiScale)
            .background(game.isLaunchPatching ? Color.black.opacity(0.62) : OPNDesign.Fixed.accent)
            .overlay { Rectangle().stroke(game.isLaunchPatching ? (isQueuedForPatching ? OPNDesign.Fixed.accent.opacity(0.55) : OPNDesign.Fill.neutral(0.30)) : OPNDesign.Fixed.accent, lineWidth: 1) }
        }
        .buttonStyle(.opnPressable(scale: 0.94))
        .disabled(game.isLaunchPatching && isQueuedForPatching)
        .accessibilityLabel(primaryAccessibilityLabel)
    }

    private var primaryTitle: String {
        if game.isLaunchPatching { return isQueuedForPatching ? "QUEUED" : "QUEUE" }
        return game.cardPrimaryActionIsLaunchable ? "PLAY" : "MARK OWNED"
    }

    private var primaryIconName: String {
        if game.isLaunchPatching { return isQueuedForPatching ? "clock.fill" : "plus.circle.fill" }
        return game.cardPrimaryActionIsLaunchable ? "play.fill" : "checkmark.seal.fill"
    }

    private func primaryAction() {
        guard !game.isLaunchPatching else {
            onQueueForPatching()
            return
        }
        guard !game.cardPrimaryActionIsLaunchable else {
            onPlay()
            return
        }
        onMarkOwned()
    }

    private var primaryAccessibilityLabel: String {
        let title = game.title.isEmpty ? "game" : game.title
        if game.isLaunchPatching { return isQueuedForPatching ? "Queued \(title)" : "Queue \(title) after patching" }
        return game.cardPrimaryActionIsLaunchable ? "Play \(title)" : "Mark \(title) as owned"
    }

    private var tileContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                let showsTitleTray = OPNThemePreferences.showsTileTitle(visibility: tileTitleVisibility, isHovering: isHovering, isSelected: isSelected)
                CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 512)
                    .frame(width: posterWidth, height: posterHeight)
                    .clipped()
                if isResumableSession {
                    ZStack {
                        Color.black.opacity(0.40)
                        CatalogPosterResumableArrowSweep()
                    }
                    .frame(width: posterWidth, height: posterHeight)
                    .clipped()
                    .allowsHitTesting(false)
                }
                if isHovering || isSelected {
                    Color.black.opacity(0.50)
                }
                if showsTitleTray {
                    LinearGradient(colors: [CatalogVendorLayout.tileTray, CatalogVendorLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
                }
                if let badge = game.cardBadgeLabel {
                    CatalogGameCardBadge(label: badge)
                }
                if let badge = game.freeAccountAccessBadgeLabel(isFreeTierAccount: showsFreeAccountAccessBadges) {
                    CatalogGameAccessBadge(label: badge)
                        .padding(8)
                        .frame(width: posterWidth, height: posterHeight, alignment: .topTrailing)
                }
                if showsTitleTray {
                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                                .catalogFont(size: 12, weight: isSelected ? .medium : .regular)
                                .lineLimit(1)
                                .foregroundStyle(OPNDesign.Text.primary)
                            Spacer(minLength: 0)
                            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                                .catalogFont(size: 10, weight: .bold)
                                .foregroundStyle(OPNDesign.Text.secondary)
                        }
                        .padding(.horizontal, 12 * uiScale)
                        .frame(width: posterWidth, height: CatalogPosterLayout.trayHeight(scale: uiScale))
                        .background(CatalogVendorLayout.tileTray)
                        // Its own gesture for the same reason as the wide tile's tray: the tap would
                        // otherwise land on the artwork button behind it.
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect() }
                    }
                    .frame(width: posterWidth, height: posterHeight)
                }
            }
            .overlay {
                Rectangle().stroke(isSelected ? OPNDesign.Fixed.accent : OPNDesign.Stroke.subtle, lineWidth: isSelected ? 2 : 1)
            }
        }
        .frame(width: posterWidth, alignment: .top)
        .padding(.horizontal, CatalogPosterLayout.tileHorizontalMargin(scale: uiScale))
        .padding(.top, CatalogPosterLayout.tileTopMargin(scale: uiScale))
        .padding(.bottom, CatalogPosterLayout.tileBottomMargin(scale: uiScale))
        .frame(width: posterWidth + CatalogPosterLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogPosterLayout.tileRowHeight(scale: uiScale, density: tileDensity), alignment: .top)
        .contentShape(Rectangle())
    }
}

struct CatalogPosterSeeMoreTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .catalogFont(size: 34, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.secondary)
                Text(title.uppercased())
                    .catalogFont(size: 16, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.primary)
            }
            .frame(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity), height: CatalogPosterLayout.posterTileHeight(scale: uiScale, density: tileDensity))
            .background(OPNDesign.Surface.tileTray)
            .overlay { Rectangle().stroke(OPNDesign.Stroke.strong, lineWidth: 2) }
            .opnHoverScale(isHovering, factor: CatalogPosterLayout.tileScaleFactor)
            .opnMotion(OPNDesign.Motion.hover, value: isHovering)
            .padding(.horizontal, CatalogPosterLayout.tileHorizontalMargin(scale: uiScale))
            .padding(.top, CatalogPosterLayout.tileTopMargin(scale: uiScale))
            .padding(.bottom, CatalogPosterLayout.tileBottomMargin(scale: uiScale))
            .frame(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity) + CatalogPosterLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogPosterLayout.tileRowHeight(scale: uiScale, density: tileDensity), alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all")
    }
}

struct CatalogPosterActionTile: View {
    let tile: OPNCatalogPanelTileObject
    let imageURL: URL?
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 768)
                    .frame(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity), height: CatalogPosterLayout.posterTileHeight(scale: uiScale, density: tileDensity))
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    if !tile.subtitle.isEmpty {
                        Text(tile.subtitle.uppercased())
                            .catalogFont(size: 10, weight: .bold)
                            .tracking(0.8)
                            .foregroundStyle(OPNDesign.Fixed.accent)
                            .lineLimit(1)
                    }
                    Text(tile.title.isEmpty ? (tile.kind == "filter" ? "Browse Games" : "Featured") : tile.title)
                        .catalogFont(size: 17, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(actionLabel)
                        .catalogFont(size: 11, weight: .bold)
                        .tracking(0.7)
                        .foregroundStyle(.black.opacity(0.88))
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(OPNDesign.Fixed.accent)
                }
                .padding(14)
            }
            .frame(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity), height: CatalogPosterLayout.posterTileHeight(scale: uiScale, density: tileDensity))
            .overlay { Rectangle().stroke(isHovering ? OPNDesign.Fixed.accent : OPNDesign.Stroke.regular, lineWidth: isHovering ? 2 : 1) }
            .opnHoverScale(isHovering, factor: CatalogPosterLayout.tileScaleFactor)
            .opnMotion(OPNDesign.Motion.hover, value: isHovering)
            .padding(.horizontal, CatalogPosterLayout.tileHorizontalMargin(scale: uiScale))
            .padding(.top, CatalogPosterLayout.tileTopMargin(scale: uiScale))
            .padding(.bottom, CatalogPosterLayout.tileBottomMargin(scale: uiScale))
            .frame(width: CatalogPosterLayout.posterTileWidth(scale: uiScale, density: tileDensity) + CatalogPosterLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogPosterLayout.tileRowHeight(scale: uiScale, density: tileDensity), alignment: .top)
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

/// Portrait twin of `GameTileResumableArrowSweep` in CatalogGameTileViews.swift, duplicated rather
/// than shared: the original is file-scoped `private` there and that file is out of this stage's scope.
private struct CatalogPosterResumableArrowSweep: View {
    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    private enum Phase: CaseIterable {
        case start, sweep, hold
    }

    var body: some View {
        GeometryReader { proxy in
            let arrowWidth = proxy.size.height * CatalogPosterResumableArrowShape.aspectRatio
            if isMotionReduced {
                Color.clear
            } else {
                PhaseAnimator(Phase.allCases) { phase in
                    CatalogPosterResumableArrowShape()
                        .fill(Color.white)
                        .frame(width: arrowWidth, height: proxy.size.height)
                        .opacity(phase == .start ? 0.1 : 0.5)
                        .offset(x: phase == .start ? -arrowWidth : proxy.size.width)
                } animation: { phase in
                    switch phase {
                    case .sweep: .easeInOut(duration: 0.8)
                    case .hold: .linear(duration: 1.2)
                    case .start: .linear(duration: 0)
                    }
                }
            }
        }
    }
}

private struct CatalogPosterResumableArrowShape: Shape {
    static let aspectRatio: CGFloat = 103.0 / 168.0

    private static let points = [
        CGPoint(x: 103, y: 84),
        CGPoint(x: 54.6607, y: 168),
        CGPoint(x: 0, y: 168),
        CGPoint(x: 47.6725, y: 84),
        CGPoint(x: 0, y: 0),
        CGPoint(x: 54.6607, y: 0),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scaleX = rect.width / 103
        let scaleY = rect.height / 168
        for (index, point) in Self.points.enumerated() {
            let scaled = CGPoint(x: rect.minX + point.x * scaleX, y: rect.minY + point.y * scaleY)
            if index == 0 {
                path.move(to: scaled)
            } else {
                path.addLine(to: scaled)
            }
        }
        path.closeSubpath()
        return path
    }
}
