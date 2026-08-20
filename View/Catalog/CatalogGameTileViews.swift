//
//  CatalogGameTileViews.swift
//  MacForceNow
//

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
    let showsFreeAccountAccessBadges: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onMarkOwned: () -> Void
    let onQueueForPatching: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    static func == (lhs: CatalogGameTile, rhs: CatalogGameTile) -> Bool {
        lhs.game.catalogIdentity == rhs.game.catalogIdentity &&
        lhs.imageURL == rhs.imageURL &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isSelectionActive == rhs.isSelectionActive &&
        lhs.isQueuedForPatching == rhs.isQueuedForPatching
    }

    var body: some View {
        CatalogHoverTracker(onHover: { isHovering = $0 }) {
            ZStack(alignment: .topLeading) {
                Button(action: onSelect) {
                    tileContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(game.title.isEmpty ? "Game tile" : game.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(isSelected ? "Details open" : "")

                ZStack(alignment: .topLeading) {
                    playButton
                }
                .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                .padding(.leading, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
                .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .accessibilityHidden(!isHovering)
                .zIndex(2)
            }
            .scaleEffect(isHovering && !isSelectionActive ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .zIndex(isHovering ? 1 : 0)
        }
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
            .foregroundStyle(game.isLaunchPatching ? (isQueuedForPatching ? MacForceNowDesign.accent.opacity(0.92) : .white.opacity(0.86)) : .black.opacity(0.88))
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 30 * uiScale)
            .background(game.isLaunchPatching ? Color.black.opacity(0.62) : MacForceNowDesign.accent)
            .overlay { Rectangle().stroke(game.isLaunchPatching ? (isQueuedForPatching ? MacForceNowDesign.accent.opacity(0.55) : Color.white.opacity(0.30)) : MacForceNowDesign.accent, lineWidth: 1) }
            .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 4)
        }
        .buttonStyle(.plain)
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
                    }
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                }
            }
        }
        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), alignment: .top)
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(MacForceNowDesign.accent)
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: 4)
                    .offset(y: CatalogVendorLayout.wideTileHeight(scale: uiScale) - 4)
            }
        }
        .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
        .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
        .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale), alignment: .top)
        .contentShape(Rectangle())
    }
}

struct CatalogGameCardBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            MallRibbonShape()
                .fill(MacForceNowDesign.accent)
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
