//  CatalogView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Backend
import Combine
import SwiftUI

struct CatalogView: View {
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    let onRefreshAuth: () -> Void

    @StateObject private var viewModel: CatalogViewModel

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        onSwitch: @escaping (LoginAccount) -> Void,
        onSignOut: @escaping () -> Void,
        onForget: @escaping (LoginAccount) -> Void,
        onRefreshAuth: @escaping () -> Void
    ) {
        self.accounts = accounts
        self.onSwitch = onSwitch
        self.onSignOut = onSignOut
        self.onForget = onForget
        self.onRefreshAuth = onRefreshAuth
        _viewModel = StateObject(wrappedValue: CatalogViewModel(account: account, session: session, onRefreshAuth: onRefreshAuth))
    }

    var body: some View {
        VStack(spacing: 0) {
            CatalogTopBar(viewModel: viewModel, accounts: accounts, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
            CatalogContentView(viewModel: viewModel)
        }
        .background(Color.black)
        .task { viewModel.loadIfNeeded() }
        .preferredColorScheme(.dark)
    }
}

private struct CatalogTopBar: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 28) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Games")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            .padding(.leading, 20)

            catalogSearchField
                .frame(width: 540)

            HStack(spacing: 24) {
                Spacer()
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Color.openNowGreen)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }

                Menu {
                    ForEach(accounts) { account in
                        Button(account.displayName) { onSwitch(account) }
                    }
                    Divider()
                    Button("Sign Out", action: onSignOut)
                    ForEach(accounts) { account in
                        Button("Forget \(account.displayName)", role: .destructive) { onForget(account) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "headphones")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(viewModel.account.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Performance")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
                .menuStyle(.button)
            }
            .padding(.trailing, 22)
        }
        .frame(height: 64)
        .background(Color(red: 0.205, green: 0.205, blue: 0.205))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1) }
    }

    private var catalogSearchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
            TextField("Search games, stores, or genres", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .onSubmit { viewModel.browseCatalog() }
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = ""; viewModel.browseCatalog() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.52))
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 46)
        .background(Color(red: 0.145, green: 0.145, blue: 0.145))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct CatalogContentView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var heroIndex = 0
    @State private var heroAutoScrollEnabled = true
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let heroes = heroGames
        let hero = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
        let sections = viewModel.catalogSections
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if hero != nil {
                    CatalogHeroView(
                        viewModel: viewModel,
                        games: heroes,
                        activeIndex: heroes.indices.contains(heroIndex) ? heroIndex : 0,
                        onSelectSlide: { index in
                            heroAutoScrollEnabled = false
                            heroIndex = index
                        }
                    )
                }

                if !viewModel.errorMessage.isEmpty {
                    CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .padding(.horizontal, 56)
                }
                if viewModel.isLoading || viewModel.isLoadingPanels {
                    CatalogLoadingStrip()
                        .padding(.horizontal, 56)
                }

                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    CatalogRailView(viewModel: viewModel, title: section.title, games: section.games)
                    if shouldShowDetail(afterSectionAt: index, sections: sections) {
                        GameDetailPanel(viewModel: viewModel)
                            .padding(.horizontal, 44)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .padding(.bottom, 44)
        }
        .background(Color.black)
        .onReceive(heroTimer) { _ in
            guard heroAutoScrollEnabled, heroes.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                heroIndex = (heroIndex + 1) % heroes.count
            }
        }
        .onChange(of: heroIdentityList) { _, identities in
            guard !identities.isEmpty else {
                heroIndex = 0
                return
            }
            if heroIndex >= identities.count { heroIndex = 0 }
        }
    }

    private var heroGames: [OPNCatalogGameObject] {
        let featuredGames = viewModel.featuredGames
        if !featuredGames.isEmpty { return Array(featuredGames.prefix(8)) }
        return Array(viewModel.catalogGames.prefix(8))
    }

    private var heroIdentityList: [String] {
        heroGames.map { CatalogViewModel.identity(for: $0) }
    }

    private func shouldShowDetail(afterSectionAt index: Int, sections: [(title: String, games: [OPNCatalogGameObject])]) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        let selectedIdentity = CatalogViewModel.identity(for: selectedGame)
        guard sections[index].games.contains(where: { CatalogViewModel.identity(for: $0) == selectedIdentity }) else {
            return false
        }
        return !sections.prefix(index).contains { section in
            section.games.contains { CatalogViewModel.identity(for: $0) == selectedIdentity }
        }
    }
}

private struct CatalogHeroView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let games: [OPNCatalogGameObject]
    let activeIndex: Int
    let onSelectSlide: (Int) -> Void

    private var game: OPNCatalogGameObject? {
        games.indices.contains(activeIndex) ? games[activeIndex] : games.first
    }

    var body: some View {
        if let game {
            ZStack(alignment: .bottom) {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 1400), contentMode: .fill)
                    .frame(maxWidth: .infinity, minHeight: 486, maxHeight: 486)
                    .clipped()
                    .id(game.catalogIdentity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                LinearGradient(colors: [.black.opacity(0.88), .black.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.82), .black.opacity(0.96)], startPoint: .center, endPoint: .bottom)

                VStack(spacing: 26) {
                    Spacer(minLength: 108)
                    Text(game.mallDisplayTitle)
                        .font(.system(size: 52, weight: .light))
                        .tracking(8)
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Spacer(minLength: 42)
                    VStack(spacing: 2) {
                        Text(game.primaryStoreLabel)
                            .font(.system(size: 13, weight: .black))
                        Text(game.ratingLabel)
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.94))
                    Button { viewModel.selectGame(game) } label: {
                        Text("VIEW DETAILS")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 142, height: 41)
                    }
                    .buttonStyle(VendorGetInButtonStyle())
                    Spacer(minLength: 58)
                }
                .frame(width: 470)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 38)

                HStack(spacing: 8) {
                    ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { index, _ in
                        Button { onSelectSlide(index) } label: {
                            Circle()
                                .fill(index == activeIndex ? Color.openNowGreen : Color.white.opacity(0.58))
                                .frame(width: index == activeIndex ? 12 : 9, height: index == activeIndex ? 12 : 9)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 34)
            }
            .clipShape(Rectangle())
        }
    }
}

private struct CatalogRailView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let title: String
    let games: [OPNCatalogGameObject]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
                Spacer()
                Button("SEE ALL") {}
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 44)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { _, game in
                        CatalogGameTile(viewModel: viewModel, game: game)
                    }
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 4)
            }
        }
    }
}

private struct CatalogGameTile: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    @State private var isHovering = false

    var body: some View {
        Button { viewModel.selectGame(game) } label: {
            ZStack(alignment: .topLeading) {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestWideImageURL, width: 620), contentMode: .fill)
                    .frame(width: 304, height: 171)
                    .clipped()
                if game.isInLibrary {
                    MallRibbonShape()
                        .fill(Color.openNowGreen)
                        .frame(width: 7, height: 24)
                }
            }
            .scaleEffect(isHovering ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct MallRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct GameDetailPanel: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        if let game = viewModel.selectedGame {
            ZStack(alignment: .topTrailing) {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 1400), contentMode: .fill)
                    .frame(maxWidth: .infinity, minHeight: 430, maxHeight: 430)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.98), .black.opacity(0.72), .black.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)

                HStack(alignment: .top, spacing: 28) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestTileImageURL, width: 460), contentMode: .fill)
                        .frame(width: 180, height: 254)
                        .clipped()

                    VStack(alignment: .leading, spacing: 16) {
                        Text(game.title.isEmpty ? "Selected Game" : game.title)
                            .font(.system(size: 34, weight: .black))
                            .lineLimit(2)

                        if !game.detailChips.isEmpty {
                            detailChips(game: game)
                        }

                        Text(game.gameDescription.isEmpty ? "Play instantly through GeForce NOW cloud streaming." : game.gameDescription)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineSpacing(4)
                            .lineLimit(5)
                            .frame(maxWidth: 640, alignment: .leading)

                        HStack(spacing: 14) {
                            Button { viewModel.launchSelectedGame() } label: {
                                Text("PLAY")
                                    .font(.system(size: 15, weight: .black))
                                    .frame(width: 152, height: 42)
                            }
                            .buttonStyle(VendorGetInButtonStyle())

                            Button("Open Store") { viewModel.openStoreForSelectedVariant() }
                                .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                                .opacity(game.variants.isEmpty ? 0.5 : 1)
                                .disabled(game.variants.isEmpty)
                        }

                        if !game.variants.isEmpty {
                            Picker("Store", selection: $viewModel.selectedVariantIndex) {
                                ForEach(Array(game.variants.enumerated()), id: \.offset) { index, variant in
                                    Text(variant.appStore.isEmpty ? "GeForce NOW" : variant.appStore.uppercased()).tag(index)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 360)
                        }

                        if !viewModel.launchMessage.isEmpty {
                            CatalogMessageView(message: viewModel.launchMessage, systemImage: "play.circle.fill")
                                .frame(maxWidth: 520)
                        }

                        detailRows(game: game)
                    }

                    Spacer(minLength: 0)
                }
                .padding(28)
                .padding(.trailing, 54)

                Button { viewModel.selectGame(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.62))
                }
                .buttonStyle(.plain)
                .padding(18)
            }
            .frame(maxWidth: .infinity, minHeight: 430, maxHeight: 430)
            .background(Color(red: 0.075, green: 0.075, blue: 0.075))
            .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
            .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 18)
        }
    }

    private func detailChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(game.detailChips, id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            }
        }
    }

    private func detailRows(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogDetailRow(label: "Developer", value: game.developerName)
            CatalogDetailRow(label: "Publisher", value: game.publisherName)
            CatalogDetailRow(label: "Stores", value: game.storeLine)
            CatalogDetailRow(label: "Controls", value: game.supportedControls.joined(separator: ", "))
            CatalogDetailRow(label: "Features", value: game.featureLabels.joined(separator: ", "))
        }
    }
}

private struct CatalogDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 84, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CatalogRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                CatalogImageFallback()
            case .empty:
                CatalogImageFallback().overlay { ProgressView().controlSize(.small) }
            @unknown default:
                CatalogImageFallback()
            }
        }
    }
}

private struct CatalogImageFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(Color.openNowGreen.opacity(0.78))
        }
    }
}

private struct CatalogMessageView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.openNowGreen)
            Text(message)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct CatalogLoadingStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Loading GeForce NOW catalog")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(12)
        .background(Color.white.opacity(0.055))
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
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

private extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var bestHeroImageURL: String {
        if !heroImageUrl.isEmpty { return heroImageUrl }
        for key in ["HERO_IMAGE", "HERO", "BACKGROUND", "KEY_ART"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestTileImageURL: String {
        if !imageUrl.isEmpty { return imageUrl }
        for key in ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return heroImageUrl
    }

    var bestWideImageURL: String {
        for key in ["TILE", "HERO_IMAGE", "HERO", "BACKGROUND", "KEY_ART", "SCREENSHOT"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        return imageUrl
    }

    var mallDisplayTitle: String {
        let fallbackTitle = title.isEmpty ? "Featured Game" : title
        let split = fallbackTitle.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1|$2",
            options: .regularExpression
        )
        return split.uppercased()
    }

    var primaryStoreLabel: String {
        if let store = availableStores.first, !store.isEmpty { return store.capitalized }
        if let store = variants.first?.appStore, !store.isEmpty { return store.capitalized }
        return "GeForce NOW"
    }

    var ratingLabel: String {
        for chip in detailChips where chip.localizedCaseInsensitiveContains("rating") || chip.localizedCaseInsensitiveContains("ages") {
            return chip.capitalized
        }
        return "Rating: Ages 16+"
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var detailChips: [String] {
        var chips: [String] = []
        if isInLibrary { chips.append("IN LIBRARY") }
        if !membershipTierLabel.isEmpty { chips.append(membershipTierLabel.uppercased()) }
        if !playabilityState.isEmpty { chips.append(playabilityState.replacingOccurrences(of: "_", with: " ").uppercased()) }
        chips.append(contentsOf: genres.prefix(3).map { $0.uppercased() })
        return chips.isEmpty ? ["CLOUD READY"] : chips
    }
}
