//
//  CatalogStorePickerViews.swift
//  MacForceNow
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogStorePickerOverlay: View {
    let viewModel: CatalogViewModel

    var body: some View {
        if let game = viewModel.selectedGame {
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1920), contentMode: .fill, maxPixelSize: 1920)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    Color.black.opacity(0.68)
                    LinearGradient(colors: [.black.opacity(0.42), .clear, .black.opacity(0.58)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)

                    HStack(alignment: .top, spacing: max(52, min(proxy.size.width * 0.07, 104))) {
                        CatalogStorePickerPoster(viewModel: viewModel, game: game)
                            .padding(.top, max(88, proxy.size.height * 0.17))

                        VStack(alignment: .leading, spacing: 0) {
                            header(game: game)
                            content(game: game)
                        }
                        .frame(width: min(650, max(500, proxy.size.width * 0.38)), alignment: .leading)
                        .padding(.top, max(92, proxy.size.height * 0.17))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, max(38, min(proxy.size.width * 0.08, 150)))

                    Button { viewModel.closeStorePicker() } label: {
                        Image(systemName: "xmark")
                            .nvidiaFont(size: 24, weight: .regular)
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(Color.black)
        }
    }

    private func header(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(game.title.isEmpty ? "Selected Game" : game.title)
                .nvidiaFont(size: 17, weight: .bold)
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .padding(.bottom, 10)
            FlowLayout(spacing: 8) {
                if viewModel.ownershipFlowStage == .success, let option = selectedOption(game: game) {
                    storeInlineLabel(option: option, owned: true)
                } else {
                    Text("PC Digital Version")
                        .nvidiaFont(size: 14, weight: .medium)
                        .foregroundStyle(.white.opacity(0.72))
                    if viewModel.ownershipFlowStage == .manualMark, let option = selectedOption(game: game) {
                        Text("|")
                            .nvidiaFont(size: 14, weight: .medium)
                            .foregroundStyle(.white.opacity(0.72))
                        storeInlineLabel(option: option, owned: false)
                    }
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.24))
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 26)
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

    private func resyncingContent(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Finding where you own this game")
                .nvidiaFont(size: 24, weight: .bold)
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 12)
            Text("Checking all your connected accounts to sync this game. This may take some time...")
                .nvidiaFont(size: 15, weight: .medium)
                .foregroundStyle(.white.opacity(0.72))
            VStack(spacing: 18) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.7)
                    .tint(MacForceNowDesign.accent)
                Text(viewModel.ownershipFlowMessage.isEmpty ? "Syncing connected game libraries..." : viewModel.ownershipFlowMessage)
                    .nvidiaFont(size: 15, weight: .medium)
                    .foregroundStyle(.white.opacity(0.84))
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .center)
            HStack {
                Spacer()
                Button("STOP RESYNC") { viewModel.stopOwnershipResync() }
                    .buttonStyle(CatalogOwnershipTextButtonStyle())
            }
        }
    }

    private func storeSelectionContent(game: OPNCatalogGameObject) -> some View {
        let options = viewModel.platformOptions(for: game)
        let storeOptions = options.filter { !$0.isSubscription }
        let subscriptionOptions = options.filter { $0.isSubscription }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Choose a game store")
                .nvidiaFont(size: 24, weight: .bold)
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 12)
            Text("Where do you own this game and want to play?")
                .nvidiaFont(size: 15, weight: .medium)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.bottom, 32)
            VStack(alignment: .leading, spacing: 16) {
                if !storeOptions.isEmpty {
                    CatalogStorePickerSection(label: "Game stores:") {
                        storeOptionList(options: storeOptions)
                    }
                }
                if !subscriptionOptions.isEmpty {
                    CatalogStorePickerSection(label: "Subscriptions:") {
                        storeOptionList(options: subscriptionOptions)
                    }
                }
            }
        }
    }

    private func storeOptionList(options: [CatalogPlatformOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options) { option in
                CatalogStorePickerRow(
                    title: option.title,
                    iconURL: option.iconURL,
                    status: option.status,
                    isSelected: option.isSelected
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
            Text("Mark as owned")
                .nvidiaFont(size: 24, weight: .bold)
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 14)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Press CONTINUE to manually mark this game as owned only if you have this in your \(storeName) library or it may fail to launch. Don't own it? ")
                    .nvidiaFont(size: 15, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Button("Get this game.") { viewModel.openStoreForSelectedVariant() }
                    .buttonStyle(.plain)
                    .nvidiaFont(size: 15, weight: .bold)
                    .foregroundStyle(MacForceNowDesign.accent)
            }
            .lineLimit(3)
            .frame(maxWidth: 650, alignment: .leading)
            Spacer(minLength: 300)
            HStack(spacing: 28) {
                Spacer()
                Button("CONTINUE") { viewModel.confirmSelectedVariantOwned() }
                    .buttonStyle(CatalogOwnershipTextButtonStyle())
                Button("EXIT") { viewModel.closeStorePicker() }
                    .buttonStyle(CatalogOwnershipPrimaryButtonStyle())
            }
        }
    }

    private func successContent(game: OPNCatalogGameObject) -> some View {
        let option = selectedOption(game: game)
        let storeName = option?.title ?? "Game Store"
        let account = option.flatMap { viewModel.accountStatus(forStore: $0.accountStore) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("You're all set to play")
                .nvidiaFont(size: 24, weight: .bold)
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 30)
            HStack(alignment: .top, spacing: 16) {
                if let option { storeIconView(iconURL: option.iconURL) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(successAccountTitle(storeName: storeName, account: account))
                        .nvidiaFont(size: 18, weight: .medium)
                        .foregroundStyle(.white.opacity(0.96))
                    Text(successAccountSubtitle(storeName: storeName, account: account))
                        .nvidiaFont(size: 14, weight: .medium)
                        .foregroundStyle(.white.opacity(0.74))
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .nvidiaFont(size: 15, weight: .bold)
                        Text(successSyncText(account: account))
                            .nvidiaFont(size: 14, weight: .medium)
                    }
                    .foregroundStyle(.white.opacity(0.74))
                }
            }
            Spacer(minLength: 330)
            HStack {
                Spacer()
                Button("DONE") { viewModel.finishOwnershipFlow() }
                    .buttonStyle(CatalogOwnershipPrimaryButtonStyle())
            }
        }
    }

    private func selectedOption(game: OPNCatalogGameObject) -> CatalogPlatformOption? {
        viewModel.selectedPlatformOption(in: game)
    }

    private func storeInlineLabel(option: CatalogPlatformOption, owned: Bool) -> some View {
        HStack(spacing: 8) {
            storeIconView(iconURL: option.iconURL)
            Text(option.title)
                .nvidiaFont(size: 14, weight: .medium)
                .foregroundStyle(.white.opacity(0.82))
            if owned {
                Text(option.status.isEmpty ? "Ready" : option.status)
                    .nvidiaFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.black.opacity(0.24))
                Image(systemName: "checkmark")
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(MacForceNowDesign.accent)
            }
        }
    }

    @ViewBuilder
    private func storeIconView(iconURL: String) -> some View {
        if !iconURL.isEmpty {
            CatalogStoreIconImage(url: URL(string: iconURL), size: 20)
                .frame(width: 20, height: 20)
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

struct CatalogOwnershipTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .nvidiaFont(size: 14, weight: .bold)
            .tracking(0.6)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.62 : 0.96))
            .frame(height: 46)
            .padding(.horizontal, 8)
    }
}

struct CatalogOwnershipPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .nvidiaFont(size: 14, weight: .bold)
            .tracking(0.8)
            .foregroundStyle(.black.opacity(0.88))
            .frame(width: 112, height: 46)
            .background(MacForceNowDesign.accent.opacity(configuration.isPressed ? 0.78 : 1))
    }
}

struct CatalogStorePickerPoster: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestStorePickerPosterURL, width: 720), contentMode: .fill, maxPixelSize: 720)
                .frame(width: 292, height: 410)
                .clipped()
        }
        .frame(width: 292, height: 410)
        .shadow(color: .black.opacity(0.42), radius: 20, x: 0, y: 10)
    }
}

struct CatalogStorePickerSection<Content: View>: View {
    let label: String
    private let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 48) {
                sectionLabel
                    .padding(.top, 12)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel
                    .padding(.bottom, 4)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sectionLabel: some View {
        Text(label)
            .nvidiaFont(size: 14, weight: .bold)
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct CatalogStorePickerRow: View {
    let title: String
    let iconURL: String
    let status: String
    let isSelected: Bool
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
        HStack(spacing: 8) {
            storeIcon
            Text(title)
                .nvidiaFont(size: 16, weight: .medium)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusTag
            selectedCheckmark
        }
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(isHovering ? 0.08 : 0))
        .overlay { Rectangle().stroke(Color.white.opacity(0), lineWidth: 1) }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusTag: some View {
        if !status.isEmpty {
            Text(status)
                .nvidiaFont(size: 14, weight: .medium)
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.black.opacity(0.32))
        }
    }

    private var selectedCheckmark: some View {
        Image(systemName: "checkmark")
            .nvidiaFont(size: 14, weight: .bold)
            .foregroundStyle(MacForceNowDesign.accent)
            .frame(width: 20, height: 20)
            .opacity(isSelected ? 1 : 0)
    }

    @ViewBuilder
    private var storeIcon: some View {
        if !iconURL.isEmpty {
            CatalogStoreIconImage(url: URL(string: iconURL), size: 20)
                .frame(width: 20, height: 20)
        } else {
            Color.clear.frame(width: 20, height: 20)
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
