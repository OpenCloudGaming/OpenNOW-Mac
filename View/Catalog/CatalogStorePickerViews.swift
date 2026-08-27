//
//  CatalogStorePickerViews.swift
//  OpenNOW
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

private struct CatalogStorePickerMetrics {
    let horizontalPadding: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let columnGap: CGFloat
    let posterWidth: CGFloat
    let posterHeight: CGFloat
    let contentWidth: CGFloat

    init(viewport: CGSize, scale: CGFloat) {
        let padding = OpenNOWDesign.clamped(viewport.width * 0.07, minimum: 32, maximum: 120) * scale
        horizontalPadding = min(padding, viewport.width * 0.16)
        topInset = OpenNOWDesign.clamped(viewport.height * 0.14, minimum: 56, maximum: 128) * scale
        bottomInset = OpenNOWDesign.Spacing.xxxLarge(scale: scale)
        columnGap = OpenNOWDesign.clamped(viewport.width * 0.06, minimum: 40, maximum: 96) * scale
        posterWidth = 292 * scale
        posterHeight = 410 * scale
        let available = viewport.width - horizontalPadding * 2 - posterWidth - columnGap
        contentWidth = max(min(560 * scale, available), 320 * scale)
    }
}

struct CatalogStorePickerOverlay: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale
    @State private var isCloseHovering = false

    var body: some View {
        if let game = viewModel.selectedGame {
            GeometryReader { proxy in
                let metrics = CatalogStorePickerMetrics(viewport: proxy.size, scale: uiScale)
                ZStack(alignment: .topTrailing) {
                    background(game: game, viewport: proxy.size)

                    HStack(alignment: .top, spacing: metrics.columnGap) {
                        CatalogStorePickerPoster(viewModel: viewModel, game: game, width: metrics.posterWidth, height: metrics.posterHeight)
                            .padding(.top, metrics.topInset)

                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                header(game: game)
                                content(game: game)
                            }
                            .frame(width: metrics.contentWidth, alignment: .leading)
                            .padding(.top, metrics.topInset)
                            .padding(.bottom, metrics.bottomInset)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, metrics.horizontalPadding)

                    closeButton
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(Color.black)
        }
    }

    private func background(game: OPNCatalogGameObject, viewport: CGSize) -> some View {
        ZStack {
            CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1920), contentMode: .fill, maxPixelSize: 1920)
                .frame(width: viewport.width, height: viewport.height)
                .clipped()
                .blur(radius: 18)
            OpenNOWDesign.Surface.scrim
            LinearGradient(colors: [.black.opacity(0.36), .clear, .black.opacity(0.44)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var closeButton: some View {
        Button { viewModel.closeStorePicker() } label: {
            Image(systemName: "xmark")
                .nvidiaFont(size: 12, weight: .bold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .frame(width: 32 * uiScale, height: 32 * uiScale)
                .background(Color.white.opacity(isCloseHovering ? 0.16 : 0.08))
                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovering = $0 }
        .padding(.top, OpenNOWDesign.Spacing.medium(scale: uiScale))
        .padding(.trailing, OpenNOWDesign.Spacing.medium(scale: uiScale))
    }

    private func header(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(game.title.isEmpty ? "Selected Game" : game.title)
                .nvidiaFont(size: 14, weight: .bold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .lineLimit(1)
                .padding(.bottom, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            FlowLayout(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                if viewModel.ownershipFlowStage == .success, let option = selectedOption(game: game) {
                    storeInlineLabel(option: option, owned: true)
                } else {
                    Text("PC DIGITAL VERSION")
                        .nvidiaFont(size: 10, weight: .bold)
                        .tracking(1.1)
                        .foregroundStyle(OpenNOWDesign.Text.tertiary)
                    if viewModel.ownershipFlowStage == .manualMark, let option = selectedOption(game: game) {
                        Text("|")
                            .nvidiaFont(size: 10, weight: .bold)
                            .tracking(1.1)
                            .foregroundStyle(OpenNOWDesign.Text.tertiary)
                        storeInlineLabel(option: option, owned: false)
                    }
                }
            }
            Rectangle()
                .fill(OpenNOWDesign.Stroke.subtle)
                .frame(height: 1)
                .padding(.top, OpenNOWDesign.Spacing.contentVertical(scale: uiScale))
                .padding(.bottom, OpenNOWDesign.Spacing.xLarge(scale: uiScale))
        }
    }

    @ViewBuilder
    private func content(game: OPNCatalogGameObject) -> some View {
        switch viewModel.ownershipFlowStage {
        case .resyncing:
            resyncingContent(game: game)
        case .storeSelection:
            storeSelectionContent(game: game)
        case .manualMark:
            manualMarkContent(game: game)
        case .success:
            successContent(game: game)
        case .hidden:
            storeSelectionContent(game: game)
        }
    }

    private func stageTitle(_ title: String) -> some View {
        Text(title)
            .nvidiaFont(size: 20, weight: .bold)
            .foregroundStyle(OpenNOWDesign.Text.primary)
            .padding(.bottom, OpenNOWDesign.Spacing.small(scale: uiScale))
    }

    private func stageDescription(_ text: String) -> some View {
        Text(text)
            .nvidiaFont(size: 12, weight: .medium)
            .foregroundStyle(OpenNOWDesign.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func resyncingContent(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stageTitle("Finding where you own this game")
            stageDescription("Checking all your connected accounts to sync this game. This may take some time...")
            VStack(spacing: OpenNOWDesign.Spacing.large(scale: uiScale)) {
                ProgressView()
                    .controlSize(.large)
                    .tint(OpenNOWDesign.accent)
                Text(viewModel.ownershipFlowMessage.isEmpty ? "Syncing connected game libraries..." : viewModel.ownershipFlowMessage)
                    .nvidiaFont(size: 12, weight: .medium)
                    .foregroundStyle(OpenNOWDesign.Text.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OpenNOWDesign.Spacing.xxxLarge(scale: uiScale) * 2)
            HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                Button("STOP RESYNC") { viewModel.stopOwnershipResync() }
                    .buttonStyle(CatalogOwnershipSecondaryButtonStyle(uiScale: uiScale))
            }
            .padding(.top, OpenNOWDesign.Spacing.xxLarge(scale: uiScale))
        }
    }

    private func storeSelectionContent(game: OPNCatalogGameObject) -> some View {
        let options = viewModel.platformOptions(for: game)
        let storeOptions = options.filter { !$0.isSubscription }
        let subscriptionOptions = options.filter { $0.isSubscription }
        return VStack(alignment: .leading, spacing: 0) {
            stageTitle("Choose a game store")
            stageDescription("Where do you own this game and want to play?")
                .padding(.bottom, OpenNOWDesign.Spacing.xxLarge(scale: uiScale))
            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.large(scale: uiScale)) {
                if !storeOptions.isEmpty {
                    CatalogStorePickerSection(label: "GAME STORES", uiScale: uiScale) {
                        storeOptionList(options: storeOptions)
                    }
                }
                if !subscriptionOptions.isEmpty {
                    CatalogStorePickerSection(label: "SUBSCRIPTIONS", uiScale: uiScale) {
                        storeOptionList(options: subscriptionOptions)
                    }
                }
            }
        }
    }

    private func storeOptionList(options: [CatalogPlatformOption]) -> some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
            ForEach(options) { option in
                CatalogStorePickerRow(
                    title: option.title,
                    iconURL: option.iconURL,
                    status: option.status,
                    isSelected: option.isSelected,
                    uiScale: uiScale
                ) {
                    viewModel.selectGameStoreVariant(at: option.variantIndex)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func manualMarkContent(game: OPNCatalogGameObject) -> some View {
        let option = selectedOption(game: game)
        let storeName = option?.title ?? "this store"
        return VStack(alignment: .leading, spacing: 0) {
            stageTitle("Mark as owned")
            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                stageDescription("Press CONTINUE to manually mark this game as owned only if you have this in your \(storeName) library or it may fail to launch. Don't own it?")
                Button("Get this game.") { viewModel.openStoreForSelectedVariant() }
                    .buttonStyle(.plain)
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
            }
            HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                Button("CONTINUE") { viewModel.confirmSelectedVariantOwned() }
                    .buttonStyle(CatalogOwnershipPrimaryButtonStyle(uiScale: uiScale))
                Button("EXIT") { viewModel.closeStorePicker() }
                    .buttonStyle(CatalogOwnershipSecondaryButtonStyle(uiScale: uiScale))
            }
            .padding(.top, OpenNOWDesign.Spacing.xxLarge(scale: uiScale))
        }
    }

    private func successContent(game: OPNCatalogGameObject) -> some View {
        let option = selectedOption(game: game)
        let storeName = option?.title ?? "Game Store"
        let account = option.flatMap { viewModel.accountStatus(forStore: $0.accountStore) }
        return VStack(alignment: .leading, spacing: 0) {
            stageTitle("You're all set to play")
                .padding(.bottom, OpenNOWDesign.Spacing.xLarge(scale: uiScale))
            HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.medium(scale: uiScale)) {
                if let option { storeIconView(iconURL: option.iconURL, size: 20) }
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                    Text(successAccountTitle(storeName: storeName, account: account))
                        .nvidiaFont(size: 14, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                    Text(successAccountSubtitle(storeName: storeName, account: account))
                        .nvidiaFont(size: 12, weight: .medium)
                        .foregroundStyle(OpenNOWDesign.Text.secondary)
                    HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                        Image(systemName: "checkmark.circle.fill")
                            .nvidiaFont(size: 12, weight: .bold)
                            .foregroundStyle(OpenNOWDesign.accent)
                        Text(successSyncText(account: account))
                            .nvidiaFont(size: 12, weight: .medium)
                            .foregroundStyle(OpenNOWDesign.Text.secondary)
                    }
                }
            }
            HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                Button("DONE") { viewModel.finishOwnershipFlow() }
                    .buttonStyle(CatalogOwnershipPrimaryButtonStyle(uiScale: uiScale))
            }
            .padding(.top, OpenNOWDesign.Spacing.xxLarge(scale: uiScale))
        }
    }

    private func selectedOption(game: OPNCatalogGameObject) -> CatalogPlatformOption? {
        viewModel.selectedPlatformOption(in: game)
    }

    private func storeInlineLabel(option: CatalogPlatformOption, owned: Bool) -> some View {
        HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            storeIconView(iconURL: option.iconURL, size: 14)
            Text(option.title)
                .nvidiaFont(size: 11, weight: .medium)
                .foregroundStyle(OpenNOWDesign.Text.secondary)
            if owned {
                Text(option.status.isEmpty ? "Ready" : option.status)
                    .nvidiaFont(size: 10, weight: .medium)
                    .foregroundStyle(OpenNOWDesign.Text.secondary)
                    .padding(.horizontal, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                    .frame(height: 20 * uiScale)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                Image(systemName: "checkmark")
                    .nvidiaFont(size: 10, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
            }
        }
    }

    @ViewBuilder
    private func storeIconView(iconURL: String, size: CGFloat) -> some View {
        if !iconURL.isEmpty {
            CatalogStoreIconImage(url: URL(string: iconURL), size: size * uiScale)
        }
    }

    private func successAccountTitle(storeName: String, account: CatalogStoreAccount?) -> String {
        guard let account, !account.userDisplayName.isEmpty else { return storeName }
        return "\(storeName) | \(account.userDisplayName)"
    }

    private func successAccountSubtitle(storeName: String, account: CatalogStoreAccount?) -> String {
        account?.hasAccountLinkingData == true ? "Your \(storeName) account is connected." : "Your game store is selected."
    }

    private func successSyncText(account: CatalogStoreAccount?) -> String {
        guard let account else { return "Manual ownership selected" }
        if account.hasAccountSyncingData { return "Automatic game library sync enabled" }
        return "Automatic sign-in available when supported"
    }
}

struct CatalogOwnershipPrimaryButtonStyle: ButtonStyle {
    var uiScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidia(size: 14 * uiScale, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(.black.opacity(0.88))
            .padding(.horizontal, OpenNOWDesign.Spacing.medium(scale: uiScale))
            .padding(.vertical, OpenNOWDesign.Spacing.contentVertical(scale: uiScale))
            .background(OpenNOWDesign.accent.opacity(configuration.isPressed ? 0.76 : 1))
    }
}

struct CatalogOwnershipSecondaryButtonStyle: ButtonStyle {
    var uiScale: CGFloat = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidia(size: 13 * uiScale, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(OpenNOWDesign.Text.primary)
            .padding(.horizontal, OpenNOWDesign.Spacing.medium(scale: uiScale))
            .padding(.vertical, OpenNOWDesign.Spacing.contentVertical(scale: uiScale))
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
    }
}

struct CatalogStorePickerPoster: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            OpenNOWDesign.Surface.panel
            CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestStorePickerPosterURL, width: 720), contentMode: .fill, maxPixelSize: 720)
                .frame(width: width, height: height)
                .clipped()
        }
        .frame(width: width, height: height)
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
    }
}

struct CatalogStorePickerSection<Content: View>: View {
    let label: String
    let uiScale: CGFloat
    private let content: Content

    init(label: String, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.label = label
        self.uiScale = uiScale
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            sectionLabel
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sectionLabel: some View {
        Text(label)
            .nvidiaFont(size: 10, weight: .bold)
            .tracking(1.1)
            .foregroundStyle(OpenNOWDesign.Text.tertiary)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct CatalogStorePickerRow: View {
    let title: String
    let iconURL: String
    let status: String
    let isSelected: Bool
    let uiScale: CGFloat
    let action: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
    }
}

extension CatalogStorePickerRow {
    private var rowContent: some View {
        HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            storeIcon
            Text(title)
                .nvidiaFont(size: 13, weight: .bold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusTag
            selectedCheckmark
        }
        .frame(maxWidth: .infinity, minHeight: 44 * uiScale, maxHeight: 44 * uiScale, alignment: .leading)
        .padding(.horizontal, OpenNOWDesign.Spacing.controlRow(scale: uiScale))
        .background(Color.white.opacity(isHovering ? 0.16 : 0.08))
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusTag: some View {
        if !status.isEmpty {
            Text(status)
                .nvidiaFont(size: 11, weight: .medium)
                .foregroundStyle(OpenNOWDesign.Text.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                .frame(height: 22 * uiScale)
                .background(Color.white.opacity(0.08))
                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        }
    }

    private var selectedCheckmark: some View {
        Image(systemName: "checkmark")
            .nvidiaFont(size: 12, weight: .bold)
            .foregroundStyle(OpenNOWDesign.accent)
            .frame(width: 18 * uiScale, height: 18 * uiScale)
            .opacity(isSelected ? 1 : 0)
    }

    @ViewBuilder
    private var storeIcon: some View {
        if !iconURL.isEmpty {
            CatalogStoreIconImage(url: URL(string: iconURL), size: 18 * uiScale)
        } else {
            Color.clear.frame(width: 18 * uiScale, height: 18 * uiScale)
        }
    }
}

struct CatalogStoreIconImage: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        CatalogCachedImageView(url: url, contentMode: .fit, placeholder: Color.clear, failure: Color.clear)
            .frame(width: size, height: size)
    }
}
