import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

enum CatalogSearchQueryParser {
    static func terms(from query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var isQuoted = false
        for character in query.lowercased() {
            if character == "\"" {
                append(current, to: &terms)
                current = ""
                isQuoted.toggle()
            } else if character.isWhitespace && !isQuoted {
                append(current, to: &terms)
                current = ""
            } else {
                current.append(character)
            }
        }
        append(current, to: &terms)
        return terms
    }

    private static func append(_ value: String, to terms: inout [String]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        terms.append(normalized)
    }
}

struct CatalogGameTile: View, @preconcurrency Equatable {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isSelected: Bool
    let isSelectionActive: Bool
    let isQueuedForPatching: Bool
    /// This game is the live seat session, so it carries the vendor's resumable treatment.
    let isResumableSession: Bool
    let showsFreeAccountAccessBadges: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onMarkOwned: () -> Void
    let onQueueForPatching: () -> Void
    /// The row owns the stacking order. `zIndex` set inside this view orders nothing useful: the
    /// rail wraps each tile in an `EquatableView`, which is its own single-child container, so the
    /// hovered tile kept drawing under the tile after it however high it set its own index. The
    /// tile reports hover; the row raises the wrapper it actually placed.
    var onHoverChanged: ((Bool) -> Void)?
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    static func == (lhs: CatalogGameTile, rhs: CatalogGameTile) -> Bool {
        lhs.game.catalogIdentity == rhs.game.catalogIdentity &&
        lhs.imageURL == rhs.imageURL &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isSelectionActive == rhs.isSelectionActive &&
        lhs.isQueuedForPatching == rhs.isQueuedForPatching &&
        lhs.isResumableSession == rhs.isResumableSession
    }

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
                .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                .padding(.leading, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
                .padding(.bottom, CatalogVendorLayout.tileBottomMargin(scale: uiScale))
                .opacity(isHovering ? 1 : 0)
                // Settles into place rather than materialising: the button is small and sits over
                // busy artwork, where a pure fade is easy to miss.
                .opnHoverScale(!isHovering, factor: 0.92, anchor: .topLeading)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
                .zIndex(2)
            }
            .opnHoverScale(isHovering && !isSelectionActive, factor: CatalogVendorLayout.tileScaleFactor)
            .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        }
        // Kept for the grid, where the tile is placed directly in the stack.
        .zIndex(isHovering ? 1 : 0)
    }

    private var playButton: some View {
        Button(action: primaryAction) {
            HStack(spacing: 7) {
                Image(systemName: primaryIconName)
                    .nvidiaFont(size: 10, weight: .bold)
                Text(primaryTitle)
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.9)
            }
            .foregroundStyle(game.isLaunchPatching ? (isQueuedForPatching ? OpenNOWDesign.accent.opacity(0.92) : .white.opacity(0.86)) : .black.opacity(0.88))
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 30 * uiScale)
            .background(game.isLaunchPatching ? Color.black.opacity(0.62) : OpenNOWDesign.accent)
            .overlay { Rectangle().stroke(game.isLaunchPatching ? (isQueuedForPatching ? OpenNOWDesign.accent.opacity(0.55) : Color.white.opacity(0.30)) : OpenNOWDesign.accent, lineWidth: 1) }
            .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 4)
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

    func primaryAction() {
        if game.isLaunchPatching {
            onQueueForPatching()
        } else if game.cardPrimaryActionIsLaunchable {
            onPlay()
        } else {
            onMarkOwned()
        }
    }

    private var primaryAccessibilityLabel: String {
        let title = game.title.isEmpty ? "game" : game.title
        if game.isLaunchPatching { return isQueuedForPatching ? "Queued \(title)" : "Queue \(title) after patching" }
        return game.cardPrimaryActionIsLaunchable ? "Play \(title)" : "Mark \(title) as owned"
    }

    private var tileContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                let isActive = isHovering || isSelected
                CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 768)
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                    .clipped()
                if isResumableSession {
                    ZStack {
                        Color.black.opacity(0.40)
                        GameTileResumableArrowSweep()
                    }
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                    .clipped()
                    .allowsHitTesting(false)
                }
                if isActive {
                    Color.black.opacity(0.50)
                    LinearGradient(colors: [CatalogVendorLayout.tileTray, CatalogVendorLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
                }
                if let badge = game.cardBadgeLabel {
                    CatalogGameCardBadge(label: badge)
                }
                if let badge = game.freeAccountAccessBadgeLabel(isFreeTierAccount: showsFreeAccountAccessBadges) {
                    CatalogGameAccessBadge(label: badge)
                        .padding(8)
                        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale), alignment: .topTrailing)
                }
                if isActive {
                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                                .nvidiaFont(size: 12, weight: isSelected ? .medium : .regular)
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.90))
                            Spacer(minLength: 0)
                            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                                .nvidiaFont(size: 10, weight: .bold)
                                .foregroundStyle(.white.opacity(0.76))
                        }
                        .padding(.horizontal, 16 * uiScale)
                        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.cardTrayHeight(scale: uiScale))
                        .background(CatalogVendorLayout.tileTray.opacity(1))
                        // The tray carries the chevron, so it reads as the control that opens and
                        // closes the details, but the taps were landing on the artwork button
                        // behind it and only ever opened. Its own gesture, so the chevron does what
                        // it points at.
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect() }
                    }
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                }
            }
        }
        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), alignment: .top)
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(OpenNOWDesign.accent)
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: 4)
                    .offset(y: CatalogVendorLayout.wideTileHeight(scale: uiScale) - 4)
            }
        }
        .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
        .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
        .padding(.bottom, CatalogVendorLayout.tileBottomMargin(scale: uiScale))
        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogVendorLayout.tileRowHeight(scale: uiScale), alignment: .top)
        .contentShape(Rectangle())
    }
}

struct CatalogGameCardBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            MallRibbonShape()
                .fill(OpenNOWDesign.accent)
                .frame(width: 7, height: 24)
            Text(label)
                .nvidiaFont(size: 13, weight: .bold)
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color(red: 56 / 255, green: 56 / 255, blue: 56 / 255).opacity(0.94))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct CatalogGameAccessBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .nvidiaFont(size: 11, weight: .bold)
            Text(label)
                .nvidiaFont(size: 11, weight: .bold)
                .tracking(0.7)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color(red: 164 / 255, green: 38 / 255, blue: 28 / 255).opacity(0.96))
        .overlay { Rectangle().stroke(Color.white.opacity(0.42), lineWidth: 1) }
        .shadow(color: .black.opacity(0.44), radius: 8, x: 0, y: 3)
        .fixedSize(horizontal: true, vertical: false)
    }
}

enum CatalogCardBadgeMapper {
    nonisolated static func label(promoTag: String, campaignIds: [String], skuTags: [String], genres: [String], featureLabels: [String]) -> String? {
        let normalizedPromoTag = normalizedValue(promoTag)
        if !normalizedPromoTag.isEmpty { return normalizedPromoTag }
        return label(campaignIds: campaignIds, skuTags: skuTags, genres: genres, featureLabels: featureLabels)
    }

    nonisolated static func label(campaignIds: [String], skuTags: [String], genres: [String], featureLabels: [String]) -> String? {
        let explicitValues = (skuTags + campaignIds).map(normalizedValue).filter { !$0.isEmpty }
        let taxonomyValues = (genres + featureLabels).map(normalizedValue).filter { !$0.isEmpty }
        let values = explicitValues + taxonomyValues
        for value in values {
            if let discount = discountLabel(value) { return discount }
        }
        if values.contains(where: isFree) { return "Free" }
        if values.contains(where: isNewSeason) { return "New Season" }
        if values.contains(where: isNewOnGFN) { return "New on GFN" }
        return explicitValues.compactMap(readableLabel).first
    }

    nonisolated private static func normalizedValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func discountLabel(_ value: String) -> String? {
        let lowercased = value.lowercased()
        guard lowercased.contains("discount") || lowercased.contains("off") || lowercased.contains("sale") || value.contains("%") else { return nil }
        guard let match = value.range(of: #"\d{1,2}"#, options: .regularExpression) else { return nil }
        return "-\(value[match])%"
    }

    nonisolated private static func isFree(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased == "free" || lowercased.contains("free_to_play") || lowercased.contains("free-to-play") || lowercased.contains("free2play")
    }

    nonisolated private static func isNewSeason(_ value: String) -> Bool {
        let lowercased = value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return lowercased.contains("new season") || lowercased.contains("season launch")
    }

    nonisolated private static func isNewOnGFN(_ value: String) -> Bool {
        let lowercased = value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return lowercased.contains("new on gfn") || lowercased.contains("new to gfn") || lowercased.contains("new release")
    }

    nonisolated private static func readableLabel(_ value: String) -> String? {
        let words = value
            .replacingOccurrences(of: #"^[A-Z]+_"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
        let label = words.joined(separator: " ")
        guard !label.isEmpty, label.count <= 18 else { return nil }
        return label
    }
}

struct MallRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.28))
        path.closeSubpath()
        return path
    }
}

/// The vendor's `game-tile-resumable-overlay` sweep: one chevron crossing the tile art in the first
/// 40% of a 2s cycle, then parked past the right edge until it loops. Shape, timing and alphas are
/// its own `gfn-game-tile_moveArrow` keyframes.
private struct GameTileResumableArrowSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: CaseIterable {
        case start, sweep, hold
    }

    var body: some View {
        GeometryReader { proxy in
            let arrowWidth = proxy.size.height * GameTileResumableArrowShape.aspectRatio
            if reduceMotion {
                // A looping sweep is the thing reduce-motion asks us to drop. The dimmed art still
                // marks the tile, and the banner names the session in text.
                Color.clear
            } else {
                PhaseAnimator(Phase.allCases) { phase in
                    GameTileResumableArrowShape()
                        .fill(Color.white)
                        .frame(width: arrowWidth, height: proxy.size.height)
                        .opacity(phase == .start ? 0.1 : 0.5)
                        .offset(x: phase == .start ? -arrowWidth : proxy.size.width)
                } animation: { phase in
                    switch phase {
                    case .sweep: .easeInOut(duration: 0.8)
                    case .hold: .linear(duration: 1.2)
                    // Reset behind the left edge with no tween, or the arrow tracks back visibly.
                    case .start: .linear(duration: 0)
                    }
                }
            }
        }
    }
}

/// The vendor's arrow path, verbatim from its inline SVG (`viewBox 0 0 103 168`), normalised to the
/// drawing rect.
private struct GameTileResumableArrowShape: Shape {
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
