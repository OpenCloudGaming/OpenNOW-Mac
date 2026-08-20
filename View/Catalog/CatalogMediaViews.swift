//
//  CatalogMediaViews.swift
//  MacForceNow
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode
    var fallbackIconOffsetX: CGFloat = 0
    var maxPixelSize: CGFloat = 1920 * 2

    var body: some View {
        CatalogCachedImageView(url: url, contentMode: contentMode, maxPixelSize: maxPixelSize, placeholder: CatalogImageFallback(iconOffsetX: fallbackIconOffsetX, isLoading: true), failure: CatalogImageFallback(iconOffsetX: fallbackIconOffsetX))
    }
}

struct CatalogCachedImageView<Placeholder: View, Failure: View>: View {
    let url: URL?
    let contentMode: ContentMode
    var maxPixelSize: CGFloat = 1920 * 2
    let placeholder: Placeholder
    let failure: Failure

    @State private var image: NSImage?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasFailed {
                failure
            } else {
                placeholder
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let url else {
            hasFailed = true
            return
        }
        guard let cached = await CatalogImageCache.shared.image(for: url, maxPixelSize: maxPixelSize), !Task.isCancelled else {
            hasFailed = !Task.isCancelled
            return
        }
        image = cached.image
        hasFailed = false
    }
}

struct CatalogImageFallback: View {
    var iconOffsetX: CGFloat = 0
    /// When true the placeholder shimmers to signal the image is still loading (vs. a hard failure).
    var isLoading = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if isLoading {
                SkeletonBlock()
            } else {
                Image(systemName: "play.rectangle.fill")
                    .nvidiaFont(size: 34, weight: .bold)
                    .foregroundStyle(Color.openNowGreen.opacity(0.78))
                    .offset(x: iconOffsetX)
            }
        }
    }
}

struct CatalogMessageView: View {
    let message: String
    let systemImage: String
    @State private var copiedDetails = false

    var body: some View {
        let presentation = CatalogErrorPresentation(rawMessage: message)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Rectangle()
                    .fill(Color.openNowGreen.opacity(0.13))
                Image(systemName: systemImage)
                    .nvidiaFont(size: 15, weight: .bold)
                    .foregroundStyle(Color.openNowGreen)
            }
            .frame(width: 36, height: 36)
            .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(.white.opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = presentation.hint {
                    Text(hint)
                        .nvidiaFont(size: 12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let details = presentation.technicalDetails {
                Button { copy(details) } label: {
                    Text(copiedDetails ? "COPIED" : "COPY DETAILS")
                        .nvidiaFont(size: 10, weight: .bold)
                        .foregroundStyle(.white.opacity(0.76))
                        .tracking(0.7)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.065))
                        .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.060))
        .overlay(alignment: .leading) { Rectangle().fill(Color.openNowGreen).frame(width: 3) }
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedDetails = true
    }
}

struct CatalogErrorPresentation {
    let title: String
    let hint: String?
    let technicalDetails: String?

    init(rawMessage: String) {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeAppPatching(message) {
            title = "GeForce NOW is preparing this game."
            hint = "The vendor is patching the app before launch. Try again after patching finishes."
            technicalDetails = message
            return
        }
        if Self.looksLikeClaimFailure(message) {
            title = "GeForce NOW could not start this session."
            hint = Self.claimFailureHint(from: message)
            technicalDetails = message
            return
        }
        if Self.looksTechnical(message) {
            title = "MacForce Now received an unexpected service response."
            hint = "Try again in a moment. If it keeps happening, copy the details for diagnostics."
            technicalDetails = message
            return
        }
        title = message.isEmpty ? "Something went wrong." : message
        hint = nil
        technicalDetails = nil
    }

    private static func looksLikeClaimFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Claim HTTP") || message.localizedCaseInsensitiveContains("Claim API error")
    }

    private static func looksLikeAppPatching(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("APP_PATCHING_STATUS") || message.localizedCaseInsensitiveContains("app patching")
    }

    private static func looksTechnical(_ message: String) -> Bool {
        message.count > 220 || message.contains("{\"") || message.contains("requestStatus") || message.contains("HTTP 400")
    }

    private static func claimFailureHint(from message: String) -> String {
        if message.localizedCaseInsensitiveContains("SESSION_NOT_PAUSED") {
            return "The existing cloud session is still shutting down. Wait a moment, then try again."
        }
        if message.localizedCaseInsensitiveContains("SESSION_LIMIT") {
            return "Your account appears to have reached the active session limit. End another session, then try again."
        }
        if message.localizedCaseInsensitiveContains("APP_PATCHING_STATUS") {
            return "GeForce NOW is patching this game before launch. Wait for setup to finish, or try again in a few minutes."
        }
        if let statusDescription = requestStatusDescription(from: message), !statusDescription.isEmpty {
            if statusDescription.localizedCaseInsensitiveContains("INTERNAL_ERROR_STATUS") {
                return "GeForce NOW returned an internal session error while claiming the launch slot. Try again, or switch server location if it repeats."
            }
            return "GeForce NOW rejected the launch request (\(statusDescription)). Try again or switch server location."
        }
        return "Try again in a moment. If it repeats, refresh your NVIDIA session or switch server location."
    }

    private static func requestStatusDescription(from message: String) -> String? {
        guard let json = jsonPayload(from: message),
              let requestStatus = json["requestStatus"] as? [String: Any] else { return nil }
        return requestStatus["statusDescription"] as? String
    }

    private static func jsonPayload(from message: String) -> [String: Any]? {
        guard let start = message.firstIndex(of: "{") else { return nil }
        let jsonString = String(message[start...])
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

struct CatalogDetailImageArrow: View {
    let name: String
    let action: () -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 34 * uiScale, height: 34 * uiScale)
                .frame(width: 48 * uiScale, height: 48 * uiScale)
                .background(.black.opacity(0.28), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.22), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width
        let width: CGFloat = (proposedWidth?.isFinite == true && proposedWidth! > 0) ? proposedWidth! : 320
        var size = CGSize(width: width, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + subviewSize.width > width, lineWidth > 0 {
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if x + subviewSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(subviewSize))
            x += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
    }
}

struct CatalogRatingBadge: View {
    let game: OPNCatalogGameObject
    let shortRating: String

    var body: some View {
        if let url = URL(string: game.ratingImageUrl), !game.ratingImageUrl.isEmpty {
            CatalogCachedImageView(url: url, contentMode: .fit, placeholder: fallbackBadge, failure: fallbackBadge)
                .frame(width: 58, height: 76)
                .background(.white)
        } else {
            fallbackBadge
        }
    }

    private var fallbackBadge: some View {
        VStack(spacing: 0) {
            Text(game.ratingLabel.uppercased())
                .font(.system(size: game.ratingLabel.count > 8 ? 7 : 8, weight: .black))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            Spacer(minLength: 0)
            Text(shortRating)
                .font(.system(size: shortRating.count > 2 ? 24 : 33, weight: .black, design: .default))
                .foregroundStyle(.black)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            Text(game.ratingSystemName.isEmpty ? "CONTENT RATED" : "CONTENT RATED BY")
                .font(.system(size: 5.5, weight: .black))
                .foregroundStyle(.black)
                .lineLimit(1)
            Text(game.ratingSystemName.isEmpty ? "" : game.ratingSystemName.uppercased())
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.black)
                .padding(.bottom, 4)
        }
        .frame(width: 58, height: 76)
        .background(.white)
        .overlay { Rectangle().stroke(.black, lineWidth: 2) }
    }
}

extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var cardBadgeLabel: String? {
        if isLaunchPatching { return patchStatusPrimaryDisplayText }
        return CatalogCardBadgeMapper.label(promoTag: promoTag, campaignIds: campaignIds, skuTags: skuTags, genres: genres, featureLabels: featureLabels)
    }

    var isLaunchPatching: Bool {
        isPatching || variants.contains { $0.isPatching }
    }

    var patchStatusPrimaryDisplayText: String {
        if !patchStatusPrimaryText.isEmpty { return patchStatusPrimaryText }
        return variants.first { !$0.patchStatusPrimaryText.isEmpty }?.patchStatusPrimaryText ?? "Patching"
    }

    var patchStatusSecondaryDisplayText: String {
        if !patchStatusSecondaryText.isEmpty { return patchStatusSecondaryText }
        return variants.first { !$0.patchStatusSecondaryText.isEmpty }?.patchStatusSecondaryText ?? ""
    }

    var cardPrimaryActionIsLaunchable: Bool {
        isInLibrary || variants.contains { $0.inLibrary || $0.librarySelected } || variants.isEmpty
    }

    var bestHeroImageURL: String {
        for key in ["MARQUEE_HERO_IMAGE", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        return bestTileImageURL
    }

    var bestMarqueeHeroImageURL: String {
        if let value = imageUrlsByType["MARQUEE_HERO_IMAGE"]?.first, !value.isEmpty { return value }
        if let value = imageUrlsByType["marquee_hero_image"]?.first, !value.isEmpty { return value }
        return bestHeroImageURL
    }

    var bestLogoImageURL: String {
        for key in ["GAME_LOGO", "LOGO", "TITLE_LOGO"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
        }
        return ""
    }

    var bestTileImageURL: String {
        if !imageUrl.isEmpty { return imageUrl }
        for key in ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return heroImageUrl
    }

    var bestStorePickerPosterURL: String {
        for key in ["GAME_BOX_ART", "BOX_ART", "BOXART", "KEY_ART", "KEY_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestWideImageURL: String {
        for key in ["TV_BANNER"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestDetailImageURL: String {
        for key in ["HERO_IMAGE", "MARQUEE_HERO_IMAGE", "FEATURE_IMAGE", "KEY_ART", "TV_BANNER"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return imageUrl
    }

    var detailImageURLs: [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty else { return }
            let key = String(value.prefix(while: { $0 != ";" }))
            guard !seen.contains(key) else { return }
            seen.insert(key)
            values.append(value)
        }

        func appendValues(forKey key: String) {
            for value in imageUrlsByType[key] ?? [] { append(value) }
            for value in imageUrlsByType[key.lowercased()] ?? [] { append(value) }
        }

        append(bestDetailImageURL)
        append(heroImageUrl)
        appendValues(forKey: "SCREENSHOTS")
        for value in screenshotUrls { append(value) }
        append(imageUrl)
        return values
    }

    var mallDisplayTitle: String {
        let displayTitle = shortName.isEmpty ? title : shortName
        return displayTitle.isEmpty ? "GEFORCE NOW" : displayTitle.uppercased()
    }

    var primaryStoreLabel: String {
        if let store = availableStores.first, !store.isEmpty { return store.capitalized }
        if let store = variants.first?.appStore, !store.isEmpty { return store.capitalized }
        return "GeForce NOW"
    }

    var ratingLabel: String {
        if !ratingCategoryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ratingCategoryTitle }
        return contentRatings.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    var supportsKeyboard: Bool {
        supportedControls.contains { control in
            let value = control.lowercased()
            return value.contains("keyboard") || value.contains("mouse")
        }
    }

    var supportsGamepad: Bool {
        supportedControls.contains { control in
            let value = control.lowercased()
            return value.contains("gamepad") || value.contains("controller")
        }
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var advancedSearchText: String {
        var values = [
            id,
            uuid,
            launchAppId,
            title,
            shortName,
            gameDescription,
            shortDescription,
            longDescription,
            developerName,
            publisherName,
            releaseDate,
            playType,
            membershipTierLabel,
            playabilityState,
            ratingSystemName,
            ratingCategoryKey,
            ratingCategoryTitle,
            promoTag,
            primaryStoreLabel,
            genreLine,
            storeLine
        ]
        values.append(contentsOf: genres)
        values.append(contentsOf: featureLabels)
        values.append(contentsOf: supportedControls)
        values.append(contentsOf: contentRatings)
        values.append(contentsOf: ratingDescriptors)
        values.append(contentsOf: ratingInteractiveElements)
        values.append(contentsOf: nvidiaTech)
        values.append(contentsOf: availableStores)
        values.append(contentsOf: campaignIds)
        values.append(contentsOf: skuTags)
        for variant in variants {
            values.append(contentsOf: [variant.id, variant.shortName, variant.appStore, variant.appStoreLabel, variant.serviceStatus, variant.libraryStatus, variant.libraryPlayStatus, variant.librarySubscription, variant.developerName, variant.publisherName, variant.releaseDate])
            values.append(contentsOf: variant.supportedControls)
            values.append(contentsOf: variant.subscriptionIds)
            values.append(contentsOf: variant.paymentModelTypes)
            values.append(contentsOf: variant.supportedLanguages)
            values.append(contentsOf: variant.gfnFeatureLabels)
            if variant.inLibrary || variant.librarySelected { values.append("owned in library") }
            if variant.libraryInstalled { values.append("installed") }
            if variant.cloudSaveSupported { values.append("cloud saves") }
        }
        if isInLibrary { values.append("owned in library") }
        return values.joined(separator: " ").lowercased()
    }

    var detailChips: [String] {
        var chips: [String] = []
        if isInLibrary { chips.append("IN LIBRARY") }
        if !skuPlayabilityText.isEmpty { chips.append(skuPlayabilityText.uppercased()) }
        if !membershipTierLabel.isEmpty { chips.append(membershipTierLabel.uppercased()) }
        if !playabilityState.isEmpty { chips.append(playabilityState.replacingOccurrences(of: "_", with: " ").uppercased()) }
        chips.append(contentsOf: genres.prefix(3).map { $0.uppercased() })
        return chips.isEmpty ? ["CLOUD READY"] : chips
    }
}
